//! The kernel's state and its per-frame step, without the Godot class around it
//! (`GooKernel` in lib.rs wraps a `Kernel`).
//!
//! Stage 2 of `docs/native-kernel-plan.md`: the kernel owns the beads. They are particles
//! in flat arrays (`Particles`: position, previous position, velocity, inverse mass,
//! radius, the frame's external force), each ring a contiguous range of them, moved by a
//! position-based (XPBD) solver; no physics server is involved. A `Kernel` also holds,
//! per ring, the rest shape, the tuning and the per-frame state `Goo2D` used to keep
//! (calm history, split timers, contacts, skin), and the static shapes the particles
//! collide with (statics.rs). It never holds a Godot object: rings are named by keys
//! (the `Goo2D`'s instance id), static shapes by ids.
//!
//! One `step(delta)` per physics frame does, in order:
//! 1. the split locks run down;
//! 2. per world (a `GooWorld2D`'s kernel only): the overlap push between rings whose boxes
//!    overlap (forces for this frame, per-bead pass-through for beads inside another
//!    ring's loop) and the Untangler (rings threaded through each other pass through
//!    each other and are pushed apart);
//! 3. the solver: `substeps` substeps (more while something moves fast), each one
//!    predicting every awake particle (gravity, the frame's forces, linear damping and
//!    the wall grip), then the ring constraints (skin and bending distances with
//!    compliance from the spring stiffnesses, the pressure as an area constraint toward
//!    `target_area`, shape matching toward the best-fit rest shape, the hard stretch
//!    limit), the contacts (static shapes, swept for fast particles; particle pairs
//!    through a hashed grid), the velocities from the positions, restitution and
//!    friction on the contacts, and internal damping, and every velocity capped at
//!    `max_bead_speed`;
//! 4. per awake ring: the touched rings (from the solver's own contacts), calm detection
//!    and settling by contact groups, the split check (pinch scan and splat), and the
//!    skin outline of every ring that moved.
//! Events for GDScript (touched, pinched, settled, woke) collect in `events`, four
//! integers per record.

use crate::consts::*;
use crate::forces::*;
use crate::geom::*;
use crate::grid::Grid;
use crate::links::{self, Link, LinkParams};
use crate::pinch;
use crate::skin;
use crate::statics::StaticShape;
use godot::builtin::{Transform2D, Vector2};
use godot::classes::Geometry2D;
use godot::obj::{Gd, Singleton};
use std::collections::{HashMap, VecDeque};

/// Event kinds, the first integer of each record in `Kernel::events`:
/// [TOUCHED, ring, other ring, 0], [PINCHED, ring, bead a, bead b], [SETTLED, ring, 0, 0],
/// [WOKE, ring, 0, 0]. Rings are named by their keys (the `Goo2D`'s instance id).
pub const EV_TOUCHED: i64 = 0;
pub const EV_PINCHED: i64 = 1;
pub const EV_SETTLED: i64 = 2;
pub const EV_WOKE: i64 = 3;

/// The "other particle" of a contact with a static shape.
const STATIC: u32 = u32::MAX;
/// How much further than its speed, gravity and force carry it in a step a particle's
/// reach for candidate pairs is grown (build_pairs()): constraints and contacts move
/// particles too.
const PAIR_SLACK: f32 = 1.5;
/// Pixels every awake particle's reach is grown by on top.
const PAIR_PAD: f32 = 1.0;
/// Pixels a bead must move from where the ring's skin was last built before the
/// skin is built again (and redrawn): a tenth of a pixel is invisible.
const SKIN_STILL: f32 = 0.25;
/// Steps a skin that Clipper had to repair waits before it is built again.
const SKIN_REPAIR_WAIT: u32 = 2;
/// Steps a ring's beads may stay inside another ring's loop (let through it and
/// pushed out bead by bead) before the pair is handed to the Untangler: 0.2 s.
const STUCK_STEPS: i64 = 12;

/// A ring's tuning and starting state, from `GooKernel.add_ring()`.
#[derive(Clone, Default, Debug)]
pub struct Params {
    pub radius: f64,
    pub bead_mass: f64,
    pub bead_radius: f64,
    pub pressure_k: f64,
    pub shape_k: f64,
    pub internal_damp: f64,
    pub settle_speed: f64,
    pub settle_time: f64,
    pub split_neck: f64,
    pub splat_area_ratio: f64,
    pub min_neck_rest: f64,
    pub target_area: f64,
    pub split_lock: f64,
    pub skin_stiffness: f64,
    pub skin_damping: f64,
    pub bending_stiffness: f64,
    pub bending_damping: f64,
    pub linear_damp: f64,
    pub bounce: f64,
    pub friction: f64,
}

/// The particles of every ring, ring after ring.
#[derive(Default)]
pub struct Particles {
    pub pos: Vec<Vector2>,
    pub prev: Vec<Vector2>,
    pub vel: Vec<Vector2>,
    /// External force for this frame (the overlap push, `apply_bead_forces`).
    pub force: Vec<Vector2>,
    /// Displacement this frame spreads over its substeps without changing the
    /// velocity (the overlap push).
    pub shift: Vec<Vector2>,
    pub r: Vec<f32>,
    /// The index of the ring each particle belongs to.
    pub ring: Vec<u32>,
    /// Touching a gripping static shape in the last substep / at any time this frame.
    pub grip_now: Vec<bool>,
    pub grip_frame: Vec<bool>,
}

impl Particles {
    fn remove_range(&mut self, start: usize, n: usize) {
        let end = start + n;
        self.pos.drain(start..end);
        self.prev.drain(start..end);
        self.vel.drain(start..end);
        self.force.drain(start..end);
        self.shift.drain(start..end);
        self.r.drain(start..end);
        self.ring.drain(start..end);
        self.grip_now.drain(start..end);
        self.grip_frame.drain(start..end);
    }
}

pub struct Ring {
    pub key: i64,
    /// Its particles: start .. start + n.
    pub start: usize,
    pub n: usize,
    pub rest: Vec<Vector2>,
    /// The skin (neighbour) and bending (next but one) rest lengths the solver holds:
    /// `rest_blend` of the way from `placed_edges` / `placed_bend` to `shape_edges` /
    /// `shape_bend` (Kernel::set_rest_blend()).
    pub rest_edges: Vec<f32>,
    rest_bend: Vec<f32>,
    /// The rest lengths of the rest shape: the given rest edges, and the next-but-one
    /// distances of `rest`.
    shape_edges: Vec<f32>,
    shape_bend: Vec<f32>,
    /// The same lengths measured on the loop the ring was placed on (its points at
    /// add_ring()).
    placed_edges: Vec<f32>,
    placed_bend: Vec<f32>,
    /// 0: the solver holds the lengths of the loop the ring was placed on; 1 (the
    /// default): its rest shape's.
    pub rest_blend: f32,
    pub rest_depths: Vec<f32>,
    pub corners: Vec<u8>,
    pub has_corners: bool,
    pub p: Params,
    pub target_area: f64,
    w: f32,
    frictionless: bool,
    /// Has bead or pair exclusions (pass-through): the contact loop asks `excluded()`.
    excl: bool,

    pub settled: bool,
    settled_step: i64,
    pub calm_time: f64,
    next_group_check: f64,
    pub split_lock: f64,
    pinch_time: f64,
    splat_frames: i64,
    frame: i64,

    /// The particles' positions and velocities at the end of the last step (or as set).
    pub points: Vec<Vector2>,
    pub velocities: Vec<Vector2>,
    pub center: Vector2,
    pub bounds: Rect,
    history: VecDeque<Vec<Vector2>>,
    pub touching: Vec<i64>,
    touching_now: Vec<i64>,

    pub skin: Vec<Vector2>,
    /// How many points of `skin` each of its polygons has (one entry for a skin that is
    /// one polygon; several when the outline crossed itself and was cut into loops).
    pub skin_sizes: Vec<i32>,
    pub raw: Vec<Vector2>,
    pub shader: Vec<Vector2>,
    pub skin_version: i64,
    skin_dirty: bool,
    /// The bead centres the skin was last built from.
    skin_points: Vec<Vector2>,
    /// Steps before a skin that needed repairing is built again.
    repair_wait: u32,
}

impl Ring {
    pub fn count(&self) -> usize {
        self.n
    }

    pub fn body_mass(&self) -> f64 {
        self.p.bead_mass * self.n as f64
    }

    fn neck_rest(&self) -> &[Vector2] {
        if self.has_corners {
            &self.rest
        } else {
            &[]
        }
    }

    fn bounce(&self) -> f32 {
        if self.frictionless {
            0.0
        } else {
            self.p.bounce as f32
        }
    }

    fn friction(&self) -> f32 {
        if self.frictionless {
            0.0
        } else {
            self.p.friction as f32
        }
    }
}

/// Beads of one ring let through another ring's beads (`GooWorld2D._let_through`).
struct Through {
    ring: i64,
    other: i64,
    beads: Vec<usize>,
    /// The step the first of them got inside (or was let through by hand).
    since: i64,
}

/// A contact of one substep, for the velocity pass.
#[derive(Clone, Copy)]
struct Contact {
    i: u32,
    j: u32,
    /// Unit normal pushing i away from j.
    n: Vector2,
    /// Normal relative velocity before the substep's position solve (negative: closing).
    vn_pre: f32,
    depth: f32,
    e: f32,
    mu: f32,
}

/// The solver's knobs (`GooTuning`, through `GooKernel.set_solver()`).
#[derive(Clone, Copy, Debug)]
pub struct Solver {
    pub substeps: usize,
    pub max_substeps: usize,
    pub gravity: Vector2,
    /// Linear damping every particle has on top of its ring's (the project's default).
    pub base_damp: f32,
    /// Extra linear damping of a particle touching a gripping static shape.
    pub grip_damp: f32,
    /// Contacts this close (px) count as touching (rings, grip) without being pushed.
    pub touch_slop: f32,
    /// A contact wakes a settled ring when it overlaps it by more (px) ...
    pub wake_depth: f32,
    /// ... or closes on it faster (px/s).
    pub wake_speed: f32,
    /// The fastest a particle may move, px/s: every velocity the solver derives and every
    /// one set from GDScript is clamped to this length (`GooTuning.MAX_BEAD_SPEED`). 0 or
    /// less: no cap.
    pub max_bead_speed: f32,
    /// The Untangler's push, px/s² per px of nominal overlap (`Untangler.STRENGTH`).
    pub untangle_strength: f64,
    /// The parting speed, px/s, past which the Untangler stops pushing a pair
    /// (`Untangler.SEPARATION_SPEED`).
    pub untangle_separation_speed: f64,
}

impl Solver {
    /// `v` clamped to `max_bead_speed`.
    pub fn capped(&self, v: Vector2) -> Vector2 {
        let cap = self.max_bead_speed;
        let sq = len_sq(v);
        if cap > 0.0 && sq > cap * cap {
            v * (cap / sq.sqrt())
        } else {
            v
        }
    }
}

impl Default for Solver {
    fn default() -> Self {
        Solver {
            substeps: 6,
            max_substeps: 12,
            gravity: Vector2::new(0.0, 980.0),
            base_damp: 0.1,
            grip_damp: 3.0,
            touch_slop: 1.0,
            wake_depth: 0.5,
            wake_speed: 30.0,
            max_bead_speed: 3000.0,
            untangle_strength: UNTANGLE_STRENGTH,
            untangle_separation_speed: UNTANGLE_SEPARATION_SPEED,
        }
    }
}

pub struct Kernel {
    pub rings: Vec<Ring>,
    index: HashMap<i64, usize>,
    pub ps: Particles,
    pub statics: Vec<StaticShape>,
    pub solver: Solver,
    pub events: Vec<i64>,
    /// Whether `step` runs the pair passes (a world's kernel; a lone ring's does not).
    pub pair_passes: bool,
    partners: HashMap<i64, i64>,
    through: Vec<Through>,
    untangling: Vec<(i64, i64)>,
    /// Ring pairs passing through each other on request (`set_pass_through`).
    passing: Vec<(i64, i64)>,
    /// The links between rings (links.rs, `add_link`).
    pub links: Vec<Link>,
    step_count: i64,
    /// Substeps of the last step (for the tests and the bench).
    pub last_substeps: usize,
    /// Particle velocities the last step clamped to `solver.max_bead_speed`, summed over
    /// its substeps (for tools/stability.gd's `births`).
    pub last_capped: usize,

    grid: Grid,
    /// This step's candidate pairs of particles (build_pairs()) and each particle's reach.
    pairs: Vec<(u32, u32)>,
    reach: Vec<f32>,
    flags: Vec<u8>,
    layout: Vec<(u32, u32, bool)>,
    /// Every particle's velocity at the start of the step: what restitution bounces.
    vel_frame: Vec<Vector2>,
    contacts: Vec<Contact>,
    touch_pairs: Vec<(u32, u32)>,
    to_wake: Vec<usize>,
    awake: Vec<bool>,
}

impl Default for Kernel {
    fn default() -> Self {
        Kernel {
            rings: Vec::new(),
            index: HashMap::new(),
            ps: Particles::default(),
            statics: Vec::new(),
            solver: Solver::default(),
            events: Vec::new(),
            pair_passes: false,
            partners: HashMap::new(),
            through: Vec::new(),
            untangling: Vec::new(),
            passing: Vec::new(),
            links: Vec::new(),
            step_count: 0,
            last_substeps: 0,
            last_capped: 0,
            grid: Grid::default(),
            pairs: Vec::new(),
            reach: Vec::new(),
            flags: Vec::new(),
            layout: Vec::new(),
            vel_frame: Vec::new(),
            contacts: Vec::new(),
            touch_pairs: Vec::new(),
            to_wake: Vec::new(),
            awake: Vec::new(),
        }
    }
}

#[inline]
fn pair_key(a: i64, b: i64) -> (i64, i64) {
    (a.min(b), a.max(b))
}

impl Kernel {
    pub fn find(&self, key: i64) -> Option<usize> {
        self.index.get(&key).copied()
    }

    pub fn ring(&self, key: i64) -> Option<&Ring> {
        self.find(key).map(|i| &self.rings[i])
    }

    /// Sets how far the ring `key`'s skin and bending rest lengths are from those of the
    /// loop it was placed on (0) to its rest shape's (1, the default); clamped to 0..1.
    /// A merged ring is placed on the union of its pair, which can be longer around than
    /// its rest shape or shaped otherwise, and blended from 0 to 1 over its inflate time
    /// (Goo2D.rest_blend), so its skin does not snap to the rest lengths in one step.
    pub fn set_rest_blend(&mut self, key: i64, blend: f64) {
        let Some(r) = self.ring_mut(key) else { return };
        let t = blend.clamp(0.0, 1.0) as f32;
        r.rest_blend = t;
        let lerp = |out: &mut Vec<f32>, from: &[f32], to: &[f32]| {
            if from.len() == to.len() && out.len() == to.len() {
                for i in 0..out.len() {
                    out[i] = from[i] + (to[i] - from[i]) * t;
                }
            }
        };
        lerp(&mut r.rest_edges, &r.placed_edges, &r.shape_edges);
        lerp(&mut r.rest_bend, &r.placed_bend, &r.shape_bend);
    }

    pub fn ring_mut(&mut self, key: i64) -> Option<&mut Ring> {
        self.find(key).map(move |i| &mut self.rings[i])
    }

    fn reindex(&mut self) {
        self.index.clear();
        for (i, r) in self.rings.iter().enumerate() {
            self.index.insert(r.key, i);
        }
    }

    // ---- Rings ----

    /// Adds (or replaces) the ring `key` with its beads at `points` (global, ring order),
    /// at rest.
    #[allow(clippy::too_many_arguments)]
    pub fn add_ring(
        &mut self,
        key: i64,
        points: Vec<Vector2>,
        rest: Vec<Vector2>,
        rest_edges: Vec<f32>,
        rest_depths: Vec<f32>,
        corners: Vec<u8>,
        p: Params,
    ) {
        if self.index.contains_key(&key) {
            self.remove_ring(key);
        }
        let n = points.len();
        let start = self.ps.pos.len();
        let idx = self.rings.len();
        let w = if p.bead_mass > 0.0 { (1.0 / p.bead_mass) as f32 } else { 0.0 };
        let rest_bend: Vec<f32> = (0..n).map(|i| dist(rest[i % rest.len().max(1)], rest[(i + 2) % rest.len().max(1)])).collect();
        let rest_bend = if rest.len() == n { rest_bend } else { vec![0.0; n] };
        let placed_edges: Vec<f32> = (0..n).map(|i| dist(points[i], points[(i + 1) % n])).collect();
        let placed_bend: Vec<f32> = (0..n).map(|i| dist(points[i], points[(i + 2) % n])).collect();
        let ps = &mut self.ps;
        ps.pos.extend_from_slice(&points);
        ps.prev.extend_from_slice(&points);
        ps.vel.extend(std::iter::repeat(Vector2::ZERO).take(n));
        ps.force.extend(std::iter::repeat(Vector2::ZERO).take(n));
        ps.shift.extend(std::iter::repeat(Vector2::ZERO).take(n));
        ps.r.extend(std::iter::repeat(p.bead_radius as f32).take(n));
        ps.ring.extend(std::iter::repeat(idx as u32).take(n));
        ps.grip_now.extend(std::iter::repeat(false).take(n));
        ps.grip_frame.extend(std::iter::repeat(false).take(n));
        let ring = Ring {
            key,
            start,
            n,
            has_corners: corners.iter().any(|&c| c == 1),
            shape_bend: rest_bend.clone(),
            rest_bend,
            rest,
            shape_edges: rest_edges.clone(),
            rest_edges,
            placed_edges,
            placed_bend,
            rest_blend: 1.0,
            rest_depths,
            corners,
            target_area: p.target_area,
            split_lock: p.split_lock,
            w,
            frictionless: false,
            excl: false,
            p,
            settled: false,
            settled_step: -1,
            calm_time: 0.0,
            next_group_check: 0.0,
            pinch_time: 0.0,
            splat_frames: 0,
            frame: 0,
            points: points.clone(),
            velocities: vec![Vector2::ZERO; n],
            center: Vector2::ZERO,
            bounds: Rect::default(),
            history: VecDeque::new(),
            touching: Vec::new(),
            touching_now: Vec::new(),
            skin: Vec::new(),
            skin_sizes: Vec::new(),
            raw: Vec::new(),
            shader: Vec::new(),
            skin_version: 0,
            skin_dirty: false,
            skin_points: Vec::new(),
            repair_wait: 0,
        };
        self.rings.push(ring);
        self.index.insert(key, idx);
        self.refresh_exclusion_flags();
        self.set_points(idx, &points);
    }

    pub fn remove_ring(&mut self, key: i64) {
        let Some(idx) = self.find(key) else { return };
        let ring = self.rings.remove(idx);
        self.ps.remove_range(ring.start, ring.n);
        for r in self.rings.iter_mut().skip(idx) {
            r.start -= ring.n;
        }
        for owner in self.ps.ring.iter_mut() {
            if *owner as usize > idx {
                *owner -= 1;
            }
        }
        self.through.retain(|t| t.ring != key && t.other != key);
        self.untangling.retain(|&(a, b)| a != key && b != key);
        self.passing.retain(|&(a, b)| a != key && b != key);
        self.links.retain(|l| l.ka != key && l.kb != key);
        self.partners.remove(&key);
        self.reindex();
        self.refresh_exclusion_flags();
    }

    /// Puts ring `idx`'s beads at `points` (one per bead, global), keeping their
    /// velocities, and rebuilds its skin: at build, and after beads were moved by hand.
    pub fn set_points(&mut self, idx: usize, points: &[Vector2]) {
        let r = &mut self.rings[idx];
        if points.len() != r.n {
            godot::global::godot_error!("GooKernel: {} points for a ring of {} beads", points.len(), r.n);
            return;
        }
        let range = r.start..r.start + r.n;
        self.ps.pos[range.clone()].copy_from_slice(points);
        self.ps.prev[range].copy_from_slice(points);
        r.points.copy_from_slice(points);
        r.center = centroid(&r.points);
        r.bounds = Rect::of_points(&r.points);
        r.history.clear();
        let mut geometry = Geometry2D::singleton();
        self.rebuild_skin(idx, &mut geometry);
    }

    /// Moves bead `bead` of ring `idx` to `point` (and rebuilds the skin).
    pub fn set_bead_position(&mut self, idx: usize, bead: usize, point: Vector2) {
        let mut points = self.rings[idx].points.clone();
        if bead < points.len() {
            points[bead] = point;
            self.set_points(idx, &points);
        }
    }

    pub fn set_merge_partners(&mut self, pairs: &[i64]) {
        self.partners.clear();
        for pair in pairs.chunks_exact(2) {
            self.partners.insert(pair[0], pair[1]);
            self.partners.insert(pair[1], pair[0]);
        }
    }

    pub fn set_frictionless(&mut self, idx: usize, on: bool) {
        self.rings[idx].frictionless = on;
    }

    pub fn is_frictionless(&self, idx: usize) -> bool {
        self.rings[idx].frictionless
    }

    // ---- Exclusions (pass-through) ----

    fn refresh_exclusion_flags(&mut self) {
        for r in self.rings.iter_mut() {
            r.excl = false;
        }
        let keys: Vec<i64> = self
            .through
            .iter()
            .flat_map(|t| [t.ring, t.other])
            .chain(self.untangling.iter().flat_map(|&(a, b)| [a, b]))
            .chain(self.passing.iter().flat_map(|&(a, b)| [a, b]))
            .chain(self.links.iter().flat_map(|l| [l.ka, l.kb]))
            .collect();
        for k in keys {
            if let Some(&i) = self.index.get(&k) {
                self.rings[i].excl = true;
            }
        }
    }

    /// Whether bead `ia` of ring `ra` and bead `ib` of ring `rb` (indices) do not collide.
    fn excluded(&self, ra: usize, ia: usize, rb: usize, ib: usize) -> bool {
        let (ka, kb) = (self.rings[ra].key, self.rings[rb].key);
        let pair = pair_key(ka, kb);
        if self.untangling.contains(&pair) || self.passing.contains(&pair) {
            return true;
        }
        if self.links.iter().any(|l| {
            (l.ka == ka && l.kb == kb && l.through_a.contains(&ia) && l.through_b.contains(&ib))
                || (l.ka == kb && l.kb == ka && l.through_a.contains(&ib) && l.through_b.contains(&ia))
        }) {
            return true;
        }
        self.through.iter().any(|t| {
            (t.ring == ka && t.other == kb && t.beads.contains(&ia)) || (t.ring == kb && t.other == ka && t.beads.contains(&ib))
        })
    }

    /// `Goo2D.set_pass_through`: every bead of ring `a` and of ring `b` pass through each
    /// other while `on`.
    pub fn set_pass_through(&mut self, a: i64, b: i64, on: bool) {
        if a == b {
            return;
        }
        let pair = pair_key(a, b);
        self.passing.retain(|&p| p != pair);
        if on {
            self.passing.push(pair);
        }
        self.refresh_exclusion_flags();
    }

    pub fn passes_through(&self, a: i64, b: i64) -> bool {
        let pair = pair_key(a, b);
        self.passing.contains(&pair) || self.untangling.contains(&pair)
    }

    /// `Goo2D.set_bead_pass_through`: bead `bead` of ring `ring` passes through every bead
    /// of ring `other` while `on`.
    pub fn set_bead_pass_through(&mut self, ring: i64, bead: usize, other: i64, on: bool) {
        let pos = self.through.iter().position(|t| t.ring == ring && t.other == other);
        match (pos, on) {
            (Some(k), true) => {
                if !self.through[k].beads.contains(&bead) {
                    self.through[k].beads.push(bead);
                }
            }
            (None, true) => self.through.push(Through { ring, other, beads: vec![bead], since: self.step_count }),
            (Some(k), false) => {
                self.through[k].beads.retain(|&b| b != bead);
                if self.through[k].beads.is_empty() {
                    self.through.remove(k);
                }
            }
            (None, false) => {}
        }
        self.refresh_exclusion_flags();
    }

    pub fn bead_passes_through(&self, ring: i64, bead: usize, other: i64) -> bool {
        self.through.iter().any(|t| t.ring == ring && t.other == other && t.beads.contains(&bead))
            || self.passing.contains(&pair_key(ring, other))
            || self.links.iter().any(|l| {
                (l.ka == ring && l.kb == other && l.through_a.contains(&bead))
                    || (l.kb == ring && l.ka == other && l.through_b.contains(&bead))
            })
    }

    // ---- Static shapes ----

    pub fn add_static_shape(&mut self, shape: StaticShape) {
        self.remove_static_shape(shape.id);
        self.statics.push(shape);
    }

    pub fn remove_static_shape(&mut self, id: i64) {
        self.statics.retain(|s| s.id != id);
    }

    pub fn set_static_transform(&mut self, id: i64, xform: Transform2D) {
        if let Some(s) = self.statics.iter_mut().find(|s| s.id == id) {
            s.set_transform(xform);
        }
    }

    // ---- Settling and waking ----

    /// Clears `settled` (`Goo2D.wake`). Records WOKE when `emit` and the ring was settled.
    pub fn wake(&mut self, idx: usize, emit: bool) {
        let r = &mut self.rings[idx];
        let was = r.settled;
        r.settled = false;
        r.calm_time = 0.0;
        r.next_group_check = 0.0;
        if was && emit {
            self.events.extend_from_slice(&[EV_WOKE, r.key, 0, 0]);
        }
    }

    /// Puts ring `idx` to sleep (`Goo2D._settle`): its particles stop where they are.
    pub fn settle(&mut self, idx: usize) {
        let step = self.step_count;
        let r = &mut self.rings[idx];
        r.settled = true;
        r.settled_step = step;
        r.calm_time = 0.0;
        r.history.clear();
        let range = r.start..r.start + r.n;
        for i in range {
            self.ps.vel[i] = Vector2::ZERO;
            self.ps.prev[i] = self.ps.pos[i];
            self.ps.force[i] = Vector2::ZERO;
        }
        r.velocities.iter_mut().for_each(|v| *v = Vector2::ZERO);
        self.events.extend_from_slice(&[EV_SETTLED, r.key, 0, 0]);
    }

    /// `Goo2D.apply_impulse`: wakes the ring and gives every bead `impulse` (each bead's
    /// velocity capped at `solver.max_bead_speed`).
    pub fn apply_impulse(&mut self, idx: usize, impulse: Vector2, emit: bool) {
        self.wake(idx, emit);
        let solver = self.solver;
        let r = &mut self.rings[idx];
        let dv = impulse * r.w;
        for i in r.start..r.start + r.n {
            self.ps.vel[i] = solver.capped(self.ps.vel[i] + dv);
        }
        for v in r.velocities.iter_mut() {
            *v = solver.capped(*v + dv);
        }
    }

    /// Adds `forces` (one per bead) to ring `idx`'s forces for the next step, waking it if
    /// settled (`Goo2D.apply_bead_forces`).
    pub fn add_bead_forces(&mut self, idx: usize, forces: &[Vector2], emit: bool) {
        if forces.len() != self.rings[idx].n || forces.is_empty() {
            return;
        }
        if self.rings[idx].settled {
            self.wake(idx, emit);
        }
        let start = self.rings[idx].start;
        for (k, &f) in forces.iter().enumerate() {
            self.ps.force[start + k] += f;
        }
    }

    /// `Goo2D.average_velocity`: zero while settled, else the beads' mean velocity.
    pub fn average_velocity(&self, idx: usize) -> Vector2 {
        let r = &self.rings[idx];
        if r.n == 0 || r.settled {
            return Vector2::ZERO;
        }
        centroid(&self.ps.vel[r.start..r.start + r.n])
    }

    /// Sets ring `idx`'s bead velocities (one per bead, or one for all), each capped at
    /// `solver.max_bead_speed`.
    pub fn set_velocities(&mut self, idx: usize, velocities: &[Vector2]) {
        let solver = self.solver;
        let r = &mut self.rings[idx];
        if velocities.len() == 1 {
            let v = solver.capped(velocities[0]);
            r.velocities.iter_mut().for_each(|w| *w = v);
        } else if velocities.len() == r.n {
            for (w, &v) in r.velocities.iter_mut().zip(velocities) {
                *w = solver.capped(v);
            }
        } else {
            return;
        }
        self.ps.vel[r.start..r.start + r.n].copy_from_slice(&r.velocities);
    }

    /// Sets one bead's velocity, capped at `solver.max_bead_speed`.
    pub fn set_bead_velocity(&mut self, idx: usize, bead: usize, velocity: Vector2) {
        let velocity = self.solver.capped(velocity);
        let r = &mut self.rings[idx];
        if bead < r.n {
            r.velocities[bead] = velocity;
            self.ps.vel[r.start + bead] = velocity;
        }
    }

    pub fn bead_gripping(&self, idx: usize, bead: usize) -> bool {
        let r = &self.rings[idx];
        bead < r.n && self.ps.grip_frame[r.start + bead]
    }

    // ---- The step ----

    /// One physics frame for every ring (see the module docs).
    pub fn step(&mut self, delta: f64) {
        self.step_count += 1;
        for r in self.rings.iter_mut() {
            r.split_lock = (r.split_lock - delta).max(0.0);
            r.touching_now.clear();
        }
        // A settled ring keeps its grip (it does not move); the others find theirs again.
        for r in &self.rings {
            if !r.settled {
                self.ps.grip_frame[r.start..r.start + r.n].iter_mut().for_each(|g| *g = false);
            }
        }
        // 2. Pair passes.
        if self.pair_passes {
            self.separate_overlaps(delta);
        }
        // Links: their ease, and a settled ring woken by a moving partner.
        if !self.links.is_empty() {
            self.step_links(delta);
        }
        // 3. The solver.
        let stepped: Vec<bool> = self.rings.iter().map(|r| !r.settled).collect();
        self.integrate(delta as f32);
        // 4. Rings: views and touching first (the calm groups read every ring's), then
        // the per-ring logic.
        for idx in 0..self.rings.len() {
            if !stepped[idx] && self.rings[idx].settled {
                continue;
            }
            let r = &mut self.rings[idx];
            let range = r.start..r.start + r.n;
            r.points.copy_from_slice(&self.ps.pos[range.clone()]);
            r.velocities.copy_from_slice(&self.ps.vel[range]);
            r.center = centroid(&r.points);
            r.bounds = Rect::of_points(&r.points);
            // The skin is rebuilt once a bead moved SKIN_STILL px from where the last
            // skin was built: a ring jiggling in a pile does not redraw every frame.
            let still_sq = SKIN_STILL * SKIN_STILL;
            r.skin_dirty = r.skin_points.len() != r.n
                || r.points.iter().zip(&r.skin_points).any(|(&p, &q)| dist_sq(p, q) > still_sq);
            if r.skin_dirty && r.repair_wait > 0 {
                r.repair_wait -= 1;
                r.skin_dirty = false;
            }
            for &other in &r.touching_now {
                self.events.extend_from_slice(&[EV_TOUCHED, r.key, other, 0]);
            }
            r.touching.clear();
            r.touching.extend_from_slice(&r.touching_now);
        }
        for idx in 0..self.rings.len() {
            if self.rings[idx].settled {
                continue;
            }
            self.ring_step(idx, delta);
        }
        self.ps.force.iter_mut().for_each(|f| *f = Vector2::ZERO);
        self.ps.shift.iter_mut().for_each(|f| *f = Vector2::ZERO);
        let mut geometry = Geometry2D::singleton();
        for idx in 0..self.rings.len() {
            if self.rings[idx].skin_dirty {
                self.rebuild_skin(idx, &mut geometry);
            }
        }
    }

    fn ring_step(&mut self, idx: usize, delta: f64) {
        {
            let r = &mut self.rings[idx];
            if Self::is_calm(r, delta) {
                r.calm_time += delta;
            } else {
                r.calm_time = 0.0;
                r.next_group_check = 0.0;
            }
        }
        let r = &self.rings[idx];
        if r.calm_time >= r.p.settle_time && r.calm_time >= r.next_group_check {
            let group = self.calm_group(idx);
            if !group.is_empty() {
                for g in group {
                    if !self.rings[g].settled {
                        self.settle(g);
                    }
                }
                return;
            }
            let r = &mut self.rings[idx];
            r.next_group_check = r.calm_time + GROUP_CHECK_INTERVAL;
        }
        let current = outline_area(&self.rings[idx].points, self.rings[idx].p.bead_radius);
        if let Some((a, b)) = Self::split_due(&mut self.rings[idx], current, delta) {
            let r = &mut self.rings[idx];
            r.split_lock = SPLIT_LOCK;
            r.pinch_time = 0.0;
            r.splat_frames = 0;
            self.events.extend_from_slice(&[EV_PINCHED, r.key, a, b]);
        }
    }

    /// `Goo2D._is_calm`: no bead drifted more than settle_speed × settle_time over the last
    /// settle_time, nor over two thirds and one third of it.
    fn is_calm(r: &mut Ring, delta: f64) -> bool {
        let frames = ((r.p.settle_time / delta.max(0.0001)).round() as i64).max(3) as usize;
        r.history.push_back(r.points.clone());
        if r.history.len() <= frames {
            return false;
        }
        r.history.pop_front();
        let limit = r.p.settle_speed * r.p.settle_time;
        let limit_sq = limit * limit;
        for sample in [0, frames / 3, 2 * frames / 3] {
            let then = &r.history[sample];
            if then.len() != r.points.len() {
                return false;
            }
            for i in 0..r.points.len() {
                if dist_sq(r.points[i], then[i]) as f64 > limit_sq {
                    return false;
                }
            }
        }
        true
    }

    /// `Goo2D._calm_group`: this ring and every ring connected to it through contacts, if
    /// all are calm or settled; empty otherwise. Rings of another kernel are not followed.
    fn calm_group(&self, idx: usize) -> Vec<usize> {
        let mut group = vec![idx];
        let mut k = 0;
        while k < group.len() {
            let r = &self.rings[group[k]];
            k += 1;
            if !r.settled && r.calm_time < r.p.settle_time {
                return Vec::new();
            }
            for other in &r.touching {
                if let Some(&o) = self.index.get(other) {
                    if !group.contains(&o) {
                        group.push(o);
                    }
                }
            }
            // Linked rings settle together, like rings in contact.
            for l in &self.links {
                let other = if l.ka == r.key {
                    l.kb
                } else if l.kb == r.key {
                    l.ka
                } else {
                    continue;
                };
                if let Some(&o) = self.index.get(&other) {
                    if !group.contains(&o) {
                        group.push(o);
                    }
                }
            }
        }
        group
    }

    /// The chord ring `r` should be cut along now, if any (advancing its split timers).
    fn split_due(r: &mut Ring, outline_area: f64, delta: f64) -> Option<(i64, i64)> {
        r.frame += 1;
        if r.split_lock > 0.0 {
            r.pinch_time = 0.0;
            r.splat_frames = 0;
            return None;
        }
        if outline_area < r.p.splat_area_ratio * r.target_area {
            r.splat_frames += 1;
            if r.splat_frames >= SPLAT_HOLD_FRAMES {
                let (a, b) = pinch::short_axis_beads(&r.points);
                return Some((a as i64, b as i64));
            }
        } else {
            r.splat_frames = 0;
        }
        if r.frame % PINCH_SCAN_FRAMES != 0 {
            return None;
        }
        let neck = pinch::find_pinch(
            &r.points,
            r.p.bead_radius,
            PINCH_CONSTRICTION,
            r.neck_rest(),
            r.p.min_neck_rest,
            &r.rest_depths,
        );
        if neck.gap >= r.p.split_neck {
            r.pinch_time = 0.0;
            return None;
        }
        r.pinch_time += delta * PINCH_SCAN_FRAMES as f64;
        if r.pinch_time >= SPLIT_HOLD - 1e-9 {
            return Some((neck.a, neck.b));
        }
        None
    }

    fn rebuild_skin(&mut self, idx: usize, geometry: &mut Gd<Geometry2D>) {
        let r = &mut self.rings[idx];
        r.skin_dirty = false;
        r.skin_points.clear();
        r.skin_points.extend_from_slice(&r.points);
        if r.points.is_empty() {
            return;
        }
        r.raw = skin::skin_offset(&r.points, r.p.bead_radius as f32);
        let (pieces, repaired) = skin::drawable_repaired(&r.points, r.p.bead_radius as f32, &r.corners, geometry);
        if !pieces.is_empty() {
            r.skin.clear();
            r.skin_sizes.clear();
            for piece in pieces {
                r.skin_sizes.push(piece.len() as i32);
                r.skin.extend_from_slice(&piece);
            }
        }
        // A ring whose outline keeps needing Clipper (an offset and two triangulations,
        // ten times a plain skin) waits SKIN_REPAIR_WAIT steps before the next one. A
        // folded ring cut into loops at its crossings costs little more than a plain
        // skin and is not made to wait.
        r.repair_wait = if repaired { SKIN_REPAIR_WAIT } else { 0 };
        r.shader = skin::shader_points(&r.raw, r.center);
        r.skin_version += 1;
    }

    // ---- The solver ----

    /// `delta` seconds of every awake ring: `solver.substeps` substeps, more (up to
    /// `max_substeps`) while a particle would move further than its radius in one.
    fn integrate(&mut self, delta: f32) {
        self.last_capped = 0;
        if self.ps.pos.is_empty() || delta <= 0.0 {
            self.last_substeps = 0;
            return;
        }
        let mut need = 0.0f32;
        for r in &self.rings {
            if r.settled {
                continue;
            }
            let rad = (r.p.bead_radius as f32).max(0.5);
            for i in r.start..r.start + r.n {
                need = need.max(len_sq(self.ps.vel[i]) / (rad * rad));
            }
        }
        let fast = (need.sqrt() * delta).ceil() as usize;
        let base = self.solver.substeps.max(1);
        let n = fast.clamp(base, self.solver.max_substeps.max(base));
        self.last_substeps = n;
        let h = delta / n as f32;
        self.vel_frame.clear();
        self.vel_frame.extend_from_slice(&self.ps.vel);
        self.frame_forces();
        self.build_pairs(delta);
        for _ in 0..n {
            self.substep(h);
        }
    }

    /// The ring forces that act over the whole step, from the state at its start, as
    /// 60 Hz forces (the form the tuning was found with, when the beads were Rapier
    /// bodies): the
    /// pressure along every edge's outward normal, pressure_k × (target_area / outline
    /// area − 1) capped at MAX_PRESSURE_RATIO × pressure_k (none while the loop is
    /// inside out), and internal damping of each bead's velocity relative to the ring's
    /// mean. Measured against the same pressure as an area constraint solved every
    /// substep and damping every substep: those made rings stiffer against impacts (a
    /// 28 px blob rebounded 17 px from a 500 px drop, not about 40) and wrapped around
    /// the wedge's apex longer. Shape matching stays a per-substep constraint
    /// (solve_ring()): as a force over the step it kept polygons from settling.
    fn frame_forces(&mut self) {
        for r in &self.rings {
            if r.settled || r.n < 3 {
                continue;
            }
            let (start, n) = (r.start, r.n);
            let pts = &self.ps.pos[start..start + n];
            if r.p.pressure_k > 0.0 && r.target_area > 0.0 && is_ccw(pts) {
                let current = outline_area(pts, r.p.bead_radius).max(MIN_AREA_RATIO * r.target_area);
                let max_p = MAX_PRESSURE_RATIO * r.p.pressure_k;
                let pressure = (r.p.pressure_k * (r.target_area / current - 1.0)).clamp(-max_p, max_p);
                let half = (0.5 * pressure) as f32;
                for k in 0..n {
                    let e = self.ps.pos[start + (k + 1) % n] - self.ps.pos[start + k];
                    let f = Vector2::new(-e.y, e.x) * half;
                    self.ps.force[start + k] += f;
                    self.ps.force[start + (k + 1) % n] += f;
                }
            }
            let mean = centroid(&self.ps.vel[start..start + n]);
            let drag = (r.p.internal_damp * r.p.bead_mass) as f32;
            for i in start..start + n {
                let f = (self.ps.vel[i] - mean) * -drag;
                self.ps.force[i] += f;
            }
        }
    }

    fn substep(&mut self, h: f32) {
        let solver = self.solver;
        self.awake.clear();
        self.awake.extend(self.rings.iter().map(|r| !r.settled));
        // Predict.
        {
            let part = 1.0 / self.last_substeps.max(1) as f32;
            let ps = &mut self.ps;
            for r in &self.rings {
                if r.settled {
                    continue;
                }
                let damp = r.p.linear_damp as f32 + solver.base_damp;
                for i in r.start..r.start + r.n {
                    let mut v = ps.vel[i] + (solver.gravity + ps.force[i] * r.w) * h;
                    let d = if ps.grip_now[i] { damp + solver.grip_damp } else { damp };
                    v = v / (1.0 + h * d);
                    ps.prev[i] = ps.pos[i] + ps.shift[i] * part;
                    ps.pos[i] = ps.prev[i] + v * h;
                    ps.vel[i] = v;
                }
            }
        }
        // Ring constraints.
        for idx in 0..self.rings.len() {
            if self.rings[idx].settled {
                continue;
            }
            let r = &self.rings[idx];
            solve_ring(r, &mut self.ps.pos[r.start..r.start + r.n], &self.ps.prev[r.start..r.start + r.n], h);
        }
        if !self.links.is_empty() {
            self.solve_links(h);
        }
        // Contacts.
        self.contacts.clear();
        self.touch_pairs.clear();
        self.to_wake.clear();
        self.collide_statics();
        self.collide_particles();
        // Velocities from positions, then the contacts' restitution and friction.
        {
            let ps = &mut self.ps;
            let inv_h = 1.0 / h;
            for r in &self.rings {
                if r.settled {
                    continue;
                }
                for i in r.start..r.start + r.n {
                    ps.vel[i] = (ps.pos[i] - ps.prev[i]) * inv_h;
                }
            }
        }
        self.contact_velocities(h);
        self.cap_speeds();
        // Rings touched and woken this substep.
        for k in 0..self.touch_pairs.len() {
            let (a, b) = self.touch_pairs[k];
            let (a, b) = (a as usize, b as usize);
            let (ka, kb) = (self.rings[a].key, self.rings[b].key);
            if !self.rings[a].settled && !self.rings[a].touching_now.contains(&kb) {
                self.rings[a].touching_now.push(kb);
            }
            if !self.rings[b].settled && !self.rings[b].touching_now.contains(&ka) {
                self.rings[b].touching_now.push(ka);
            }
        }
        for k in 0..self.to_wake.len() {
            let idx = self.to_wake[k];
            if self.rings[idx].settled {
                self.wake(idx, true);
            }
        }
    }

    /// Clamps every awake particle's velocity to `solver.max_bead_speed`, after the substep's
    /// velocity update (the last substep's is the step's): a ring built wrong (rest edges
    /// that do not fit its loop) can make its constraints throw beads at 4000-8000 px/s,
    /// which the contacts would hand on to every ring it touches; normal play stays well
    /// under the cap, so it is never felt.
    fn cap_speeds(&mut self) {
        let cap = self.solver.max_bead_speed;
        if cap <= 0.0 {
            return;
        }
        let cap_sq = cap * cap;
        let ps = &mut self.ps;
        for r in &self.rings {
            if r.settled {
                continue;
            }
            for v in &mut ps.vel[r.start..r.start + r.n] {
                let sq = len_sq(*v);
                if sq > cap_sq {
                    *v = *v * (cap / sq.sqrt());
                    self.last_capped += 1;
                }
            }
        }
    }

    /// Every awake particle against the static shapes; a particle that moved further than
    /// its radius this substep is checked along the way (swept), so it stops at the first
    /// shape it reaches instead of tunnelling through a thin one.
    fn collide_statics(&mut self) {
        if self.statics.is_empty() {
            return;
        }
        let slop = self.solver.touch_slop;
        let ps = &mut self.ps;
        for r in &self.rings {
            if r.settled {
                continue;
            }
            let e_ring = r.bounce();
            let mu_ring = r.friction();
            for i in r.start..r.start + r.n {
                let rad = ps.r[i];
                ps.grip_now[i] = false;
                let moved = ps.pos[i] - ps.prev[i];
                let travel = len(moved);
                let samples = if travel > rad { (travel / (0.5 * rad.max(0.1))).ceil().min(64.0) as usize } else { 1 };
                for m in 1..=samples {
                    let q = if samples == 1 { ps.pos[i] } else { ps.prev[i] + moved * (m as f32 / samples as f32) };
                    let mut at = q;
                    let mut hit = false;
                    for s in &self.statics {
                        if !s.aabb.grow(rad + slop).has_point(at) {
                            continue;
                        }
                        let Some((gap, dir)) = s.gap(at, rad, slop) else { continue };
                        if s.grip && !r.frictionless {
                            ps.grip_now[i] = true;
                            ps.grip_frame[i] = true;
                        }
                        if gap < 0.0 {
                            at += dir * -gap;
                            hit = true;
                            self.contacts.push(Contact {
                                i: i as u32,
                                j: STATIC,
                                n: dir,
                                vn_pre: dot(ps.vel[i], dir).min(dot(self.vel_frame[i], dir)),
                                depth: -gap,
                                e: (e_ring + s.bounce).clamp(0.0, 1.0),
                                mu: mu_ring.min(s.friction),
                            });
                        }
                    }
                    if hit || m == samples {
                        ps.pos[i] = at;
                        break;
                    }
                }
            }
        }
    }

    /// The candidate pairs of particles for this step's substeps: every pair that could
    /// come within touching distance during the step, found once through the hashed
    /// grid with each particle's reach grown by how far it can move in the step (its
    /// speed, gravity and the step's force, with slack; zero for a settled ring's). A
    /// particle reaching further than a cell (a fast one) is looked up over every cell
    /// its reach covers. Pairs of beads 1 or 2 apart along one ring, pairs that pass
    /// through each other and pairs of two settled rings are left out.
    fn build_pairs(&mut self, delta: f32) {
        self.pairs.clear();
        let total = self.ps.pos.len();
        if total < 2 {
            return;
        }
        let g = len(self.solver.gravity);
        let slop = self.solver.touch_slop;
        self.reach.clear();
        let mut rmax = 0.0f32;
        for r in &self.rings {
            rmax = rmax.max(r.p.bead_radius as f32);
        }
        for i in 0..total {
            let ring = &self.rings[self.ps.ring[i] as usize];
            let m = if ring.settled {
                0.0
            } else {
                let accel = g + len(self.ps.force[i]) * ring.w;
                PAIR_SLACK * (len(self.ps.vel[i]) * delta + 0.5 * accel * delta * delta) + PAIR_PAD
            };
            self.reach.push(self.ps.r[i] + m);
        }
        // Cells fit the slow particles' reach (at most twice the largest bead radius);
        // a fast particle is looked up on its own over every cell its reach covers.
        let fast_limit = 2.0 * rmax + PAIR_PAD;
        let mut cell_reach = 0.0f32;
        for &q in &self.reach {
            if q <= fast_limit {
                cell_reach = cell_reach.max(q);
            }
        }
        if cell_reach <= 0.0 {
            // Every particle is fast (a whole linked chain whipped about): cells fit the
            // shortest reach instead of collapsing to 1 px, which made each particle
            // look up thousands of cells.
            cell_reach = self.reach.iter().copied().fold(f32::INFINITY, f32::min);
        }
        let cell = (2.0 * cell_reach + slop).max(1.0);
        self.grid.build(&self.ps.pos, cell);
        // Compact per-particle flags (bit 0 settled, bit 1 fast) and per-ring layout,
        // so the inner loop does not walk the rings.
        self.flags.clear();
        for i in 0..total {
            let settled = self.rings[self.ps.ring[i] as usize].settled as u8;
            let fast = (self.reach[i] > fast_limit) as u8;
            self.flags.push(settled | (fast << 1));
        }
        self.layout.clear();
        self.layout.extend(self.rings.iter().map(|r| (r.start as u32, r.n as u32, r.excl)));
        let (grid, pos, ring_of, reach, flags, layout) =
            (&self.grid, &self.ps.pos, &self.ps.ring, &self.reach, &self.flags, &self.layout);
        let mut pairs = std::mem::take(&mut self.pairs);
        let mut excluded_check: Vec<(u32, u32)> = Vec::new();
        for i in 0..total {
            let fi = flags[i];
            if fi & 1 != 0 {
                // Settled: found from the awake particle's side.
                continue;
            }
            let fast = fi & 2 != 0;
            let qi = reach[i];
            let pi = pos[i];
            let ra = ring_of[i] as usize;
            // A fast particle finds its pairs with slow ones, and with fast ones whose
            // reach is no larger than its own: its cells cover twice its reach.
            let span = if fast { ((2.0 * qi + slop) / cell).ceil() as i32 } else { 1 };
            let (cx, cy) = grid.cells[i];
            for dy in -span..=span {
                for dx in -span..=span {
                    let (tx, ty) = (cx + dx, cy + dy);
                    let b = grid.bucket(tx, ty);
                    let (from, to) = (grid.start[b] as usize, grid.start[b + 1] as usize);
                    for k in from..to {
                        let j = grid.items[k] as usize;
                        if j == i || grid.cells[j] != (tx, ty) {
                            continue;
                        }
                        let fj = flags[j];
                        // Each pair once: from the awake one of an awake and a settled
                        // particle, from the fast one of a fast and a slow one, from the
                        // one reaching further of two fast ones, else from the lower index.
                        if (fj & 2 != 0) != fast {
                            if !fast {
                                continue;
                            }
                        } else if fast {
                            let qj = reach[j];
                            if qj > qi || (qj == qi && j < i) {
                                continue;
                            }
                        } else if j < i && fj & 1 == 0 {
                            continue;
                        }
                        let within = qi + reach[j] + slop;
                        if dist_sq(pi, pos[j]) >= within * within {
                            continue;
                        }
                        let rb = ring_of[j] as usize;
                        if ra == rb {
                            let (start, n, _) = layout[ra];
                            let hop = (i - start as usize).abs_diff(j - start as usize);
                            if hop.min(n as usize - hop) <= 2 {
                                continue;
                            }
                        } else if layout[ra].2 || layout[rb].2 {
                            excluded_check.push((i as u32, j as u32));
                            continue;
                        }
                        pairs.push((i as u32, j as u32));
                    }
                }
            }
        }
        for (i, j) in excluded_check {
            let (i, j) = (i as usize, j as usize);
            let (ra, rb) = (self.ps.ring[i] as usize, self.ps.ring[j] as usize);
            let (ia, ib) = (i - self.rings[ra].start, j - self.rings[rb].start);
            if !self.excluded(ra, ia, rb, ib) {
                pairs.push((i as u32, j as u32));
            }
        }
        self.pairs = pairs;
    }

    /// The candidate pairs (build_pairs()) closer than their radii, one of them awake,
    /// pushed apart; pairs within the touch slop count as touching.
    fn collide_particles(&mut self) {
        let slop = self.solver.touch_slop;
        for k in 0..self.pairs.len() {
            let (mut i, mut j) = (self.pairs[k].0 as usize, self.pairs[k].1 as usize);
            let (mut ra, mut rb) = (self.ps.ring[i] as usize, self.ps.ring[j] as usize);
            if !self.awake[ra] {
                if !self.awake[rb] {
                    continue;
                }
                std::mem::swap(&mut i, &mut j);
                std::mem::swap(&mut ra, &mut rb);
            }
            self.collide_pair(i, ra, j, rb, slop);
        }
    }

    #[inline]
    fn collide_pair(&mut self, i: usize, ra: usize, j: usize, rb: usize, slop: f32) {
        let ps = &self.ps;
        let reach = ps.r[i] + ps.r[j];
        let d = ps.pos[i] - ps.pos[j];
        let dsq = len_sq(d);
        if dsq >= (reach + slop) * (reach + slop) {
            return;
        }
        let (ring_a, ring_b) = (&self.rings[ra], &self.rings[rb]);
        if ra != rb {
            self.touch_pairs.push((ra as u32, rb as u32));
        }
        if dsq >= reach * reach {
            return;
        }
        let dist = dsq.sqrt();
        let n = if dist > 1e-6 { d / dist } else { Vector2::new(0.0, -1.0) };
        let depth = reach - dist;
        let vn_pre = dot(ps.vel[i] - ps.vel[j], n).min(dot(self.vel_frame[i] - self.vel_frame[j], n));
        let wa = ring_a.w;
        let mut wb = ring_b.w;
        if !self.awake[rb] {
            // A settled ring is immovable unless this contact wakes it.
            if depth > self.solver.wake_depth || -vn_pre > self.solver.wake_speed {
                if !self.to_wake.contains(&rb) {
                    self.to_wake.push(rb);
                }
            } else {
                wb = 0.0;
            }
        }
        let wsum = wa + wb;
        if wsum <= 0.0 {
            return;
        }
        let (e, mu) = if ra == rb {
            (0.0, ring_a.friction())
        } else {
            ((ring_a.bounce() + ring_b.bounce()).clamp(0.0, 1.0), ring_a.friction().min(ring_b.friction()))
        };
        let s = depth / wsum;
        self.ps.pos[i] += n * (s * wa);
        self.ps.pos[j] -= n * (s * wb);
        self.contacts.push(Contact { i: i as u32, j: if wb > 0.0 { j as u32 } else { STATIC }, n, vn_pre, depth, e, mu });
    }

    /// Restitution and friction of the substep's contacts, as velocity changes: a contact
    /// that was closing faster than gravity accelerates in two substeps leaves at `e` times
    /// that speed; the tangential relative velocity loses up to `mu` times the normal
    /// velocity change the position solve made (Coulomb), down to zero.
    fn contact_velocities(&mut self, h: f32) {
        let threshold = 2.0 * len(self.solver.gravity) * h;
        let ps = &mut self.ps;
        for c in &self.contacts {
            let i = c.i as usize;
            let wi = self.rings[ps.ring[i] as usize].w;
            let (vj, wj) = if c.j == STATIC {
                (Vector2::ZERO, 0.0)
            } else {
                let j = c.j as usize;
                (ps.vel[j], self.rings[ps.ring[j] as usize].w)
            };
            let wsum = wi + wj;
            if wsum <= 0.0 {
                continue;
            }
            let rel = ps.vel[i] - vj;
            let vn = dot(rel, c.n);
            let vt = rel - c.n * vn;
            let target = if c.vn_pre < -threshold { -c.e * c.vn_pre } else { 0.0 };
            let dvn = (target - vn).max(0.0);
            let mut dv = c.n * dvn;
            let vt_len = len(vt);
            if vt_len > 1e-6 && c.mu > 0.0 {
                let cut = (c.mu * c.depth / h).min(vt_len);
                dv -= vt * (cut / vt_len);
            }
            ps.vel[i] += dv * (wi / wsum);
            if c.j != STATIC {
                let j = c.j as usize;
                ps.vel[j] -= dv * (wj / wsum);
            }
        }
    }

    // ---- Links (links.rs) ----

    /// Adds (or replaces) the link `id` between rings `ka` and `kb`: the bead pairs
    /// `pairs` (bead of `ka`, bead of `kb`), the beads of each that pass through the
    /// other's (`through_a`, `through_b`) and its knobs. The ideal pose comes from the two
    /// rings' rest shapes; the link eases into it from where the rings are now. False
    /// (and nothing added) for a ring that is missing, the same ring twice, no pairs or
    /// a bead out of range.
    pub fn add_link(
        &mut self,
        id: i64,
        ka: i64,
        kb: i64,
        pairs: Vec<(usize, usize)>,
        through_a: Vec<usize>,
        through_b: Vec<usize>,
        p: LinkParams,
    ) -> bool {
        let (Some(a), Some(b)) = (self.find(ka), self.find(kb)) else { return false };
        if a == b || pairs.is_empty() {
            return false;
        }
        let (na, nb) = (self.rings[a].n, self.rings[b].n);
        if pairs.iter().any(|&(i, j)| i >= na || j >= nb) || self.rings[a].rest.len() != na || self.rings[b].rest.len() != nb {
            return false;
        }
        self.remove_link(id);
        let pose = links::ideal_pose(&self.rings[a].rest, &self.rings[b].rest, &pairs, p.gap);
        let (ra, rb) = (&self.rings[a], &self.rings[b]);
        let start: Vec<f32> = pairs.iter().map(|&(i, j)| dist(self.ps.pos[ra.start + i], self.ps.pos[rb.start + j])).collect();
        let start_angle = self.relative_angle(a, b);
        let mut link = Link {
            id,
            ka,
            kb,
            through_a: through_a.into_iter().filter(|&i| i < na).collect(),
            through_b: through_b.into_iter().filter(|&j| j < nb).collect(),
            pairs,
            pose,
            p,
            goal: Vec::new(),
            start,
            start_angle,
            ease: if p.ease_time > 0.0 { 0.0 } else { 1.0 },
            rest: Vec::new(),
            target_angle: 0.0,
        };
        link.set_goal();
        link.refresh();
        self.links.push(link);
        // A pair being untangled when linked is let go: the link holds it now.
        let pair = pair_key(ka, kb);
        self.untangling.retain(|&q| q != pair);
        self.refresh_exclusion_flags();
        if self.rings[a].settled {
            self.wake(a, true);
        }
        if self.rings[b].settled {
            self.wake(b, true);
        }
        true
    }

    pub fn remove_link(&mut self, id: i64) {
        let before = self.links.len();
        self.links.retain(|l| l.id != id);
        if self.links.len() != before {
            self.refresh_exclusion_flags();
        }
    }

    pub fn link(&self, id: i64) -> Option<&Link> {
        self.links.iter().find(|l| l.id == id)
    }

    pub fn link_mut(&mut self, id: i64) -> Option<&mut Link> {
        self.links.iter_mut().find(|l| l.id == id)
    }

    /// The index in `links` of a link between rings `ka` and `kb` (either way round).
    fn link_between(&self, ka: i64, kb: i64) -> Option<usize> {
        self.links.iter().position(|l| (l.ka == ka && l.kb == kb) || (l.ka == kb && l.kb == ka))
    }

    /// θ_b − θ_a of rings `a` and `b` (indices): their best-fit rotations' difference.
    pub fn relative_angle(&self, a: usize, b: usize) -> f32 {
        let (ra, rb) = (&self.rings[a], &self.rings[b]);
        let (ta, _) = links::frame(&ra.rest, &self.ps.pos[ra.start..ra.start + ra.n]);
        let (tb, _) = links::frame(&rb.rest, &self.ps.pos[rb.start..rb.start + rb.n]);
        links::wrap(tb - ta)
    }

    /// Once per step: every link eases on, and a settled ring linked to an awake one
    /// wakes (as a contact would wake it).
    fn step_links(&mut self, delta: f64) {
        let mut wake = Vec::new();
        for l in self.links.iter_mut() {
            if l.ease < 1.0 {
                l.ease = if l.p.ease_time > 0.0 { (l.ease + delta as f32 / l.p.ease_time).min(1.0) } else { 1.0 };
                l.refresh();
            }
            if let (Some(&a), Some(&b)) = (self.index.get(&l.ka), self.index.get(&l.kb)) {
                let (sa, sb) = (self.rings[a].settled, self.rings[b].settled);
                if sa != sb {
                    wake.push(if sa { a } else { b });
                }
            }
        }
        for idx in wake {
            if self.rings[idx].settled {
                self.wake(idx, true);
            }
        }
    }

    /// One substep `h` of every link: each pair's distance toward its rest length, then
    /// the relative angle toward its target (links.rs), XPBD with the link's stiffness
    /// and damping per reduced mass. A settled ring does not move (inverse mass 0).
    fn solve_links(&mut self, h: f32) {
        let h2 = h * h;
        for li in 0..self.links.len() {
            let l = &self.links[li];
            let (Some(&a), Some(&b)) = (self.index.get(&l.ka), self.index.get(&l.kb)) else { continue };
            let (ra, rb) = (&self.rings[a], &self.rings[b]);
            let wa = if ra.settled { 0.0 } else { ra.w };
            let wb = if rb.settled { 0.0 } else { rb.w };
            let wsum = wa + wb;
            if wsum <= 0.0 {
                continue;
            }
            let (sa, sb) = (ra.start, rb.start);
            let pos = &mut self.ps.pos;
            let prev = &self.ps.prev;
            if l.p.stiffness > 0.0 {
                let m = 1.0 / wsum;
                let alpha = 1.0 / (l.p.stiffness * m);
                let alpha_t = alpha / h2;
                let gamma = alpha * l.p.damping * m / h;
                let denom = (1.0 + gamma) * wsum + alpha_t;
                for (k, &(i, j)) in l.pairs.iter().enumerate() {
                    let (pi, pj) = (sa + i, sb + j);
                    let d = pos[pj] - pos[pi];
                    let length = len(d);
                    if length < 1e-6 {
                        continue;
                    }
                    let dir = d / length;
                    let c = length - l.rest[k];
                    let moving = dot(dir, (pos[pj] - prev[pj]) - (pos[pi] - prev[pi]));
                    let dl = (-c - gamma * moving) / denom;
                    pos[pi] -= dir * (wa * dl);
                    pos[pj] += dir * (wb * dl);
                }
            }
            if l.p.bend_stiffness > 0.0 {
                let (na, nb) = (ra.n, rb.n);
                let (ta, ca) = links::frame(&ra.rest, &pos[sa..sa + na]);
                let (tb, cb) = links::frame(&rb.rest, &pos[sb..sb + nb]);
                let (ta0, _) = links::frame(&ra.rest, &prev[sa..sa + na]);
                let (tb0, _) = links::frame(&rb.rest, &prev[sb..sb + nb]);
                let ia = if ra.settled { 0.0 } else { 1.0 / (ra.p.bead_mass as f32 * links::spread(&pos[sa..sa + na], ca)).max(1e-6) };
                let ib = if rb.settled { 0.0 } else { 1.0 / (rb.p.bead_mass as f32 * links::spread(&pos[sb..sb + nb], cb)).max(1e-6) };
                let isum = ia + ib;
                if isum > 0.0 {
                    let inertia = 1.0 / isum;
                    let alpha = 1.0 / (l.p.bend_stiffness * inertia);
                    let alpha_t = alpha / h2;
                    let gamma = alpha * l.p.bend_damping * inertia / h;
                    let c = links::wrap(tb - ta - l.target_angle);
                    let moving = links::wrap(tb - tb0) - links::wrap(ta - ta0);
                    let dl = (-c - gamma * moving) / ((1.0 + gamma) * isum + alpha_t);
                    links::turn(&mut pos[sa..sa + na], ca, -ia * dl);
                    links::turn(&mut pos[sb..sb + nb], cb, ib * dl);
                }
            }
        }
    }

    // ---- Pair passes (GooWorld2D._separate_overlaps) ----

    fn separate_overlaps(&mut self, delta: f64) {
        let count = self.rings.len();
        let mut forces: Vec<Vec<Vector2>> = vec![Vec::new(); count];
        let mut seen: Vec<(i64, i64)> = Vec::new();
        let boxes: Vec<Rect> = self
            .rings
            .iter()
            .map(|r| if r.points.is_empty() { r.bounds } else { r.bounds.grow((INTRUSION_MARGIN_BEADS * r.p.bead_radius) as f32) })
            .collect();
        for i in 0..count {
            for j in (i + 1)..count {
                if !boxes[i].intersects(&boxes[j]) {
                    continue;
                }
                let (ka, kb) = (self.rings[i].key, self.rings[j].key);
                if self.partners.get(&ka) == Some(&kb) {
                    continue;
                }
                let linked = if self.links.is_empty() { None } else { self.link_between(ka, kb) };
                if self.rings[i].settled && self.rings[j].settled && !self.is_untangling(ka, kb) {
                    // Asleep together: only a bead inside the other's loop matters.
                    let (a, b) = (&self.rings[i], &self.rings[j]);
                    if beads_inside(&a.points, a.bounds, &b.points, b.bounds, 0.0) == 0
                        && beads_inside(&b.points, b.bounds, &a.points, a.bounds, 0.0) == 0
                    {
                        continue;
                    }
                }
                let hit = {
                    let (a, b) = (&self.rings[i], &self.rings[j]);
                    let mut view_a = OverlapView::new(&a.points, &a.velocities, a.p.bead_radius, a.p.bead_mass, a.bounds);
                    let mut view_b = OverlapView::new(&b.points, &b.velocities, b.p.bead_radius, b.p.bead_mass, b.bounds);
                    view_a.prepare();
                    view_b.prepare();
                    intrusion(&view_a, &view_b)
                };
                if !hit.pressed {
                    continue;
                }
                let inside = hit.inside_a > 0 || hit.inside_b > 0;
                if self.rings[i].settled && self.rings[j].settled && !inside {
                    continue;
                }
                if inside {
                    if self.rings[i].settled {
                        self.wake(i, true);
                    }
                    if self.rings[j].settled {
                        self.wake(j, true);
                    }
                }
                let untangling = self.is_untangling(ka, kb);
                // Beads that stay inside the other ring for long are held there (by a
                // wall behind them, or a pile): the pair is untangled as a whole.
                let stuck = (hit.inside_a > 0 || hit.inside_b > 0)
                    && self.through.iter().any(|t| {
                        ((t.ring == ka && t.other == kb) || (t.ring == kb && t.other == ka))
                            && self.step_count - t.since >= STUCK_STEPS
                    });
                if linked.is_none() && (hit.deep() || untangling || stuck) {
                    if !untangling {
                        self.through.retain(|t| !((t.ring == ka && t.other == kb) || (t.ring == kb && t.other == ka)));
                        self.begin_untangle(i, j, delta);
                    }
                    continue;
                }
                self.let_through(i, j, &hit.beads_in_a, &hit.reach_a, &mut seen);
                self.let_through(j, i, &hit.beads_in_b, &hit.reach_b, &mut seen);
                let mut hit = hit;
                if let Some(l) = linked {
                    // A linked pair's own beads are not pushed apart (the link holds
                    // them together), and the pair is never handed to the Untangler,
                    // which would let every bead through and part them.
                    let l = &self.links[l];
                    let (own_i, own_j) = if l.ka == ka { (&l.through_a, &l.through_b) } else { (&l.through_b, &l.through_a) };
                    for &b in own_i {
                        if let Some(f) = hit.forces_a.get_mut(b) {
                            *f = Vector2::ZERO;
                        }
                    }
                    for &b in own_j {
                        if let Some(f) = hit.forces_b.get_mut(b) {
                            *f = Vector2::ZERO;
                        }
                    }
                }
                summed(&mut forces[i], &hit.forces_a);
                summed(&mut forces[j], &hit.forces_b);
            }
        }
        // The push both as a force over the step (as it was tuned) and as a
        // displacement spread over the step's substeps without changing velocities:
        // the force over the push's stiffness, the reduced-mass share of the depth
        // (and of a step's sinking). With the force alone, a body spawned half inside
        // another left its beads there for 2 to 5 samples of bench.gd's count; the
        // displacement takes them out within the step.
        for (i, f) in forces.iter().enumerate() {
            if f.is_empty() {
                continue;
            }
            self.add_bead_forces(i, f, true);
            let r = &self.rings[i];
            let scale = r.w / (INTRUSION_FREQUENCY * INTRUSION_FREQUENCY) as f32;
            for (k, &force) in f.iter().enumerate() {
                self.ps.shift[r.start + k] += force * scale;
            }
        }
        self.through.retain(|t| seen.contains(&(t.ring, t.other)));
        self.update_untangling(delta);
        self.refresh_exclusion_flags();
    }

    /// `GooWorld2D._let_through`: the beads of `ring` inside `other`'s loop pass through
    /// `other`'s beads until they are out of its reach again.
    fn let_through(&mut self, ring: usize, other: usize, inside: &[usize], reach: &[usize], seen: &mut Vec<(i64, i64)>) {
        let key = (self.rings[ring].key, self.rings[other].key);
        let mut pos = self.through.iter().position(|t| (t.ring, t.other) == key);
        if inside.is_empty() && pos.is_none() {
            return;
        }
        if pos.is_none() {
            self.through.push(Through { ring: key.0, other: key.1, beads: Vec::new(), since: self.step_count });
            pos = Some(self.through.len() - 1);
        }
        let pos = pos.unwrap();
        let t = &mut self.through[pos];
        for &bead in inside {
            if !t.beads.contains(&bead) {
                t.beads.push(bead);
            }
        }
        t.beads.retain(|b| reach.contains(b) || inside.contains(b));
        if t.beads.is_empty() {
            self.through.remove(pos);
        } else {
            seen.push(key);
        }
    }

    fn is_untangling(&self, a: i64, b: i64) -> bool {
        self.untangling.contains(&pair_key(a, b))
    }

    /// `Untangler.begin`.
    fn begin_untangle(&mut self, a: usize, b: usize, delta: f64) {
        let (ka, kb) = (self.rings[a].key, self.rings[b].key);
        if self.is_untangling(ka, kb) {
            return;
        }
        self.untangling.push(pair_key(ka, kb));
        self.untangle_push(a, b, delta);
    }

    /// `Untangler.update`.
    fn update_untangling(&mut self, delta: f64) {
        let mut k = 0;
        while k < self.untangling.len() {
            let (ka, kb) = self.untangling[k];
            let (Some(a), Some(b)) = (self.find(ka), self.find(kb)) else {
                self.untangling.remove(k);
                continue;
            };
            let margin = UNTANGLE_RELEASE_MARGIN * (self.rings[a].p.bead_radius + self.rings[b].p.bead_radius);
            if self.beads_inside(a, b, margin) > 0 || self.beads_inside(b, a, margin) > 0 {
                self.untangle_push(a, b, delta);
                k += 1;
                continue;
            }
            self.untangling.remove(k);
        }
    }

    fn untangle_push(&mut self, a: usize, b: usize, delta: f64) {
        let (ra, rb) = (&self.rings[a], &self.rings[b]);
        let (ia, ib) = untangle_push(
            ra.center,
            ra.p.radius,
            ra.body_mass(),
            rb.center,
            rb.p.radius,
            rb.body_mass(),
            delta,
            self.average_velocity(a),
            self.average_velocity(b),
            self.solver.untangle_strength,
            self.solver.untangle_separation_speed,
        );
        let (na, nb) = (ra.count().max(1) as f32, rb.count().max(1) as f32);
        self.apply_impulse(a, ia / na, true);
        self.apply_impulse(b, ib / nb, true);
    }

    /// `Goo2D.beads_inside`: ring `a`'s bead centres inside ring `b`'s loop grown by `margin`.
    pub fn beads_inside(&self, a: usize, b: usize, margin: f64) -> usize {
        let (ra, rb) = (&self.rings[a], &self.rings[b]);
        beads_inside(&ra.points, ra.bounds, &rb.points, rb.bounds, margin)
    }
}

/// The ring constraints of one substep `h` on its particles `pos` (previous positions
/// `prev`): skin (neighbour) and bending (next but one) distances, XPBD with compliance
/// 1 / stiffness and the springs' damping; shape matching toward the best-fit rest shape
/// at `shape_k` per unit mass (the force shape_k × mass × (goal − position), as a
/// compliant pull); the hard stretch limit (MAX_STRETCH × each skin edge's rest length).
/// The pressure and internal damping act as forces over the step (Kernel::frame_forces()).
fn solve_ring(r: &Ring, pos: &mut [Vector2], prev: &[Vector2], h: f32) {
    let n = pos.len();
    if n < 3 || r.rest.len() != n {
        return;
    }
    let w = r.w;
    let h2 = h * h;
    distances(pos, prev, &r.rest_edges, 1, r.p.skin_stiffness as f32, r.p.skin_damping as f32, w, h);
    distances(pos, prev, &r.rest_bend, 2, r.p.bending_stiffness as f32, r.p.bending_damping as f32, w, h);
    if r.p.shape_k > 0.0 {
        // GooLoop.goal_positions() (the rest shape is about its centroid already),
        // with the best-fit rotation's cosine and sine from the sums directly.
        let cc = centroid(pos);
        let (mut cs, mut dt) = (0.0f32, 0.0f32);
        for i in 0..n {
            let (q, p) = (r.rest[i], pos[i] - cc);
            cs += cross(q, p);
            dt += dot(q, p);
        }
        let norm_len = (cs * cs + dt * dt).sqrt();
        let (c, sn) = if norm_len > 0.0 { (dt / norm_len, cs / norm_len) } else { (1.0, 0.0) };
        let sk = r.p.shape_k as f32;
        let k = (sk * h2) / (1.0 + sk * h2);
        for i in 0..n {
            let q = r.rest[i];
            let goal = cc + Vector2::new(q.x * c - q.y * sn, q.x * sn + q.y * c);
            pos[i] += (goal - pos[i]) * k;
        }
    }
    for i in 0..n {
        let j = (i + 1) % n;
        let e = pos[j] - pos[i];
        let length = len(e);
        let limit = MAX_STRETCH as f32 * r.rest_edges[i];
        if length > limit && length > 0.0 {
            let corr = e * (0.5 * (length - limit) / length);
            pos[i] += corr;
            pos[j] -= corr;
        }
    }
}

/// XPBD distance constraints between particle i and i + `hop` of a loop, rest lengths
/// `rest[i]`, a spring of `stiffness` (compliance 1 / stiffness) and `damping` (force per
/// px/s), particles of inverse mass `w`, one substep `h`.
#[allow(clippy::too_many_arguments)]
fn distances(pos: &mut [Vector2], prev: &[Vector2], rest: &[f32], hop: usize, stiffness: f32, damping: f32, w: f32, h: f32) {
    let n = pos.len();
    if stiffness <= 0.0 || rest.len() != n {
        return;
    }
    let alpha = 1.0 / stiffness;
    let alpha_t = alpha / (h * h);
    let gamma = alpha * damping / h;
    let denom = (1.0 + gamma) * 2.0 * w + alpha_t;
    for i in 0..n {
        let j = (i + hop) % n;
        let d = pos[j] - pos[i];
        let length = len(d);
        if length < 1e-6 {
            continue;
        }
        let dir = d / length;
        let c = length - rest[i];
        let moving = dot(dir, (pos[j] - prev[j]) - (pos[i] - prev[i]));
        let dl = (-c - gamma * moving) / denom;
        let corr = dir * (w * dl);
        pos[i] -= corr;
        pos[j] += corr;
    }
}

/// `total` plus `more`, element by element (`more` itself if `total` is empty).
fn summed(total: &mut Vec<Vector2>, more: &[Vector2]) {
    if total.is_empty() {
        total.extend_from_slice(more);
        return;
    }
    for (t, &m) in total.iter_mut().zip(more) {
        *t += m;
    }
}
