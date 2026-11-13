//! GooCells: an exploration prototype (branch explore-cells, 2026-11-12) of creatures whose
//! every cell is ONE oriented disc particle (position, angle, velocity, spin, mass, moment,
//! radius), the model docs/explore-cells.md studies against the ring-per-cell colony
//! (colony.rs). Nothing else in the addon uses it: tools/cells_*.gd and
//! tests/unit/test_goo_cells.gd drive it through `GooCells` (lib.rs).
//!
//! A creature's cells are joined by links built at touch distance from a free-form design
//! (any radii; crossing links dropped so the graph is planar). A link is three XPBD
//! constraints solved once per substep: a distance (stretch) and, at each end, the angle of
//! the link in that cell's own frame against the angle it had when it was made (the
//! "oriented particle" bending of Primordialis): shape memory with no shape matching.
//! Shape matching over each cell's neighbourhood is the other bending model, for the
//! comparison. Links break past a force (a smoothed estimate from the constraints'
//! multipliers); a broken creature splits into its connected parts.
//!
//! Cells of one creature collide with each other only when asked (none, every pair not
//! linked, or cells of self-colliding types); cells of different creatures collide as
//! discs (boundary cells by default, every cell or capsules along the outline when asked),
//! with an optional compliance. Walls are convex polygons, against every cell.
//!
//! Per frame: muscles (cell radii, or a travelling curvature wave of the rest pose: link
//! lengths and anchor angles), plasticity, the water drag on the outline's edges (the fluid
//! game's law: normal / tangential, quadratic + linear, against a current), surface tension
//! as pairs of equal and opposite pulls along the outline, thrust along each cell's heading,
//! a twist (torque about the centre of mass with no net force); then substeps. Creatures are
//! stepped in parallel (rayon), contacts between creatures serially in a fixed order, and
//! topology changes (breaks, splits, joins, cells added or removed) between steps: the
//! threaded step is bit-identical to the serial one.

use crate::geom::{chaikin, cross, dot, len_sq as lsq, point_in_polygon};
use crate::statics::StaticShape;
use godot::builtin::{Transform2D, Vector2};
use rayon::prelude::*;
use std::time::Instant;

pub const BEND_NONE: u8 = 0;
/// Oriented particles: each link end's angle in its cell's frame (Primordialis).
pub const BEND_LINK: u8 = 1;
/// Shape matching over each cell and its linked neighbours.
pub const BEND_SHAPE: u8 = 2;

pub const SELF_NONE: u8 = 0;
/// Every pair of cells of one creature that are not linked.
pub const SELF_UNLINKED: u8 = 1;
/// Cells of a type marked self-colliding, against every unlinked cell of their creature.
pub const SELF_TYPES: u8 = 2;
/// Unlinked pairs that are not two links apart either (no cell sharing a neighbour).
pub const SELF_FAR: u8 = 3;

pub const WAVE_OFF: u8 = 0;
/// Radius muscles: one side of the body grows while the other shrinks (Primordialis' way).
pub const WAVE_RADIUS: u8 = 1;
/// The rest pose bent along a travelling curvature wave: link lengths and anchor angles.
pub const WAVE_POSE: u8 = 2;
/// Every cell across the body grows together: a squeeze wave.
pub const WAVE_SQUEEZE: u8 = 3;

pub const EVENT_PARTED: i32 = 0;
pub const EVENT_JOINED: i32 = 1;
pub const EVENT_SPLIT: i32 = 2;

pub const TYPES: usize = 16;

/// threads = 0: (live cells from, threads), measured with tools/cell_world_bench.gd
/// (docs/cells.md, "Threads").
pub const AUTO_THREADS: [(usize, usize); 3] = [(0, 1), (800, 2), (1600, 4)];

/// A type's body mode: the options' bend_mode (TypeParams.body's default).
pub const BODY_DEFAULT: u8 = 255;

#[inline]
fn rot(v: Vector2, c: f32, s: f32) -> Vector2 {
    Vector2::new(c * v.x - s * v.y, s * v.x + c * v.y)
}
#[inline]
fn perp(v: Vector2) -> Vector2 {
    Vector2::new(-v.y, v.x)
}
#[inline]
fn wrap(a: f32) -> f32 {
    let mut a = a;
    while a > std::f32::consts::PI {
        a -= std::f32::consts::TAU;
    }
    while a < -std::f32::consts::PI {
        a += std::f32::consts::TAU;
    }
    a
}
/// The angle from unit vector u to vector d (d need not be unit): sin while small.
#[inline]
fn angle_to(u: Vector2, d: Vector2, l: f32) -> f32 {
    let c = cross(u, d);
    let o = dot(u, d);
    if o > 0.9 * l {
        c / l
    } else {
        c.atan2(o)
    }
}

#[derive(Clone, Copy, Debug)]
pub struct Drag {
    pub enabled: bool,
    pub density: f32,
    pub normal: f32,
    pub tangent: f32,
    pub linear_normal: f32,
    pub linear_tangent: f32,
    pub max_step: f32,
    /// Only edges turned into the flow feel the normal drag (Primordialis); else both faces.
    pub facing_only: bool,
}

impl Default for Drag {
    fn default() -> Self {
        // The fluid game's numbers (GameSettings.DRAG_*).
        Drag { enabled: true, density: 1.0, normal: 0.1, tangent: 0.01, linear_normal: 60.0, linear_tangent: 8.0, max_step: 0.5, facing_only: false }
    }
}

/// What a cell type changes: factors over the options and flags.
#[derive(Clone, Copy, Debug)]
pub struct TypeParams {
    pub stretch: f32,
    pub bend: f32,
    pub brk: f32,
    pub self_collide: bool,
    /// Bit t: may join a cell of type t at a retopology.
    pub join_mask: u16,
    /// Contacts with other creatures: added to the radius (px) of this type's cells.
    pub pad: f32,
    /// How cells of this type hold their shape: BEND_NONE, BEND_LINK (oriented links),
    /// BEND_SHAPE (shape matching within their region), BODY_DEFAULT (the options').
    pub body: u8,
    /// Collides with other creatures' cells (its boundary cells are colliders).
    pub collide: bool,
    /// Collides with the walls.
    pub walls: bool,
    /// The skin's colour of this type's cells (r, g, b, a).
    pub color: [f32; 4],
    /// Its cells' share of the swim drive (× their mass; 1 a plain cell, 0 none).
    pub swim: f32,
}

impl Default for TypeParams {
    fn default() -> Self {
        TypeParams { stretch: 1.0, bend: 1.0, brk: 1.0, self_collide: false, join_mask: 0xffff, pad: 0.0, body: BODY_DEFAULT, collide: true, walls: true, color: [0.35, 0.75, 0.45, 1.0], swim: 1.0 }
    }
}

impl TypeParams {
    #[inline]
    pub fn mode(&self, opt_mode: u8) -> u8 {
        if self.body == BODY_DEFAULT { opt_mode } else { self.body }
    }
}

#[derive(Clone, Debug)]
pub struct Opt {
    pub threads: usize,
    pub substeps: usize,
    /// The links' stretch frequency (Hz) over their pair's reduced mass: sets compliance.
    pub stretch_hz: f32,
    /// The anchors' angular frequency (Hz) over the moment the constraint acts on.
    pub bend_hz: f32,
    pub bend_mode: u8,
    pub shape_k: f32,
    /// XPBD damping of each link's stretch and bend (a share of the substep's change).
    pub link_damp: f32,
    pub bend_damp: f32,
    pub collide_all: bool,
    pub capsules: bool,
    /// Contacts between creatures: their frequency (Hz) over the pair's reduced mass; 0 rigid.
    pub contact_hz: f32,
    /// Added to boundary cells' contact radius against other creatures, × the radius.
    pub contact_pad: f32,
    /// Passes over the contacts between creatures per substep.
    pub contact_iters: u32,
    pub self_mode: u8,
    /// The creature's own candidates are found every this many frames (a Verlet list with
    /// the margin the frames' speeds need); 1: every frame.
    pub self_every: u32,
    pub margin: f32,
    pub drag: Drag,
    pub drag_substep: bool,
    pub current: Vector2,
    /// Pull along each outline edge (force); 0 off.
    pub tension: f32,
    pub gravity: Vector2,
    /// Links: a strain (and an anchor angle, rad) past which the rest creeps toward now.
    pub plastic_yield: f32,
    pub plastic_rate: f32,
    /// The creep back toward the design (1/s).
    pub plastic_recover: f32,
    /// A link breaks when its smoothed force passes this (∞: never).
    pub break_force: f32,
    /// ... the torque at its ends over its length counts too, × this.
    pub break_torque: f32,
    /// The force's smoothing time (s).
    pub break_smooth: f32,
    /// Two cells closer than (r_a + r_b) × link_tol are linked at a build.
    pub link_tol: f32,
    pub max_speed: f32,
    /// A cell's mass per px² (its mass: this × π r0²).
    pub density: f32,
    /// A new cell grows in over this (s), from ease_from × its radius.
    pub ease_time: f32,
    pub ease_from: f32,
    pub types: [TypeParams; TYPES],
    /// Bumped when a type's body mode changes: creatures rebuild their regions.
    pub types_version: u32,
    /// The break test leaves out the creature's own share of each link's load (muscles,
    /// thrust, drag): a link breaks when its load passes break_force over the envelope of
    /// the loads it carried while the creature touched nothing (see `Link::env`).
    pub break_excess: bool,
    /// The envelope's decay time (s) while the creature touches nothing.
    pub break_envelope_time: f32,
    /// The envelope counts × this (> 1: a margin over the creature's own peaks).
    pub break_envelope_scale: f32,
}

impl Default for Opt {
    fn default() -> Self {
        Opt {
            threads: 1,
            substeps: 6,
            stretch_hz: 20.0,
            bend_hz: 4.0,
            bend_mode: BEND_LINK,
            shape_k: 0.3,
            link_damp: 0.02,
            bend_damp: 0.02,
            collide_all: false,
            capsules: false,
            contact_hz: 0.0,
            contact_pad: 0.0,
            contact_iters: 1,
            self_mode: SELF_NONE,
            self_every: 4,
            margin: 3.0,
            drag: Drag::default(),
            drag_substep: false,
            current: Vector2::ZERO,
            tension: 0.0,
            gravity: Vector2::ZERO,
            plastic_yield: f32::INFINITY,
            plastic_rate: 0.0,
            plastic_recover: 0.0,
            break_force: f32::INFINITY,
            break_torque: 0.0,
            break_smooth: 0.05,
            link_tol: 1.08,
            max_speed: 3000.0,
            density: 1.0,
            ease_time: 0.5,
            ease_from: 0.3,
            types: [TypeParams::default(); TYPES],
            types_version: 0,
            break_excess: false,
            break_envelope_time: 2.0,
            break_envelope_scale: 1.0,
        }
    }
}

#[derive(Clone, Copy, Default, Debug)]
pub struct Link {
    pub i: u32,
    pub j: u32,
    /// The rest length now and the design's (both before radius muscles); the plastic offset.
    pub d0: f32,
    /// As built (or joined): what the pose wave bends.
    pub d_base: f32,
    pub ai_base: f32,
    pub aj_base: f32,
    pub d_design: f32,
    pub d_plastic: f32,
    /// The anchors: the link's angle in each cell's frame now / in the design / plastic.
    pub ai: f32,
    pub aj: f32,
    pub ai_design: f32,
    pub aj_design: f32,
    pub ai_plastic: f32,
    pub aj_plastic: f32,
    /// Per frame: the rest length after muscles, anchors as unit vectors, compliances.
    pub rest: f32,
    pub ui: Vector2,
    pub uj: Vector2,
    pub alpha: f32,
    pub alpha_ang: f32,
    /// The frame's mean force (stretch) and torque, and the smoothed load.
    pub f_frame: f32,
    pub t_frame: f32,
    pub load: f32,
    /// A link of a cell growing in: its length when made; its rest eases from it.
    pub d_from: f32,
    /// Its angle constraints are solved (a link inside one shape-matched region has none).
    pub bend: bool,
    /// A joint between two regions: its index + 1 in the body's joints (0: none); `jflip`:
    /// its end i is in the joint's second region.
    pub joint: u32,
    pub jflip: bool,
    /// The envelope of the loads it carried while its creature touched nothing (decaying
    /// over break_envelope_time): the creature's own share, left out of the break test.
    pub env: f32,
}

/// Two regions of a creature that meet: the links between them bend about `pivot` (the
/// mean of their midpoints in the design) when the joint's angle is set.
#[derive(Clone, Copy, Debug, Default)]
pub struct Joint {
    pub ra: u32,
    pub rb: u32,
    /// The regions' keys (type << 16 | group), ka < kb.
    pub ka: u32,
    pub kb: u32,
    pub pivot: Vector2,
    pub links: u32,
}

#[derive(Clone, Copy, Default)]
pub struct Wave {
    pub mode: u8,
    pub amp: f32,
    pub k: f32,
    pub omega: f32,
    pub axis: Vector2,
    pub half_width: f32,
    /// WAVE_POSE: a constant curvature added (1/px), turning the swimmer.
    pub bias: f32,
    /// WAVE_POSE: the amplitude grows from (1 − envelope) at the head to 1 at the tail.
    pub envelope: f32,
    /// The wave's phase now (integrated from omega every frame).
    pub phase: f32,
    /// Seconds since the wave was set: its amplitude eases in over the first half second.
    pub age: f32,
}


/// The swim drive: every cell pushed along its own forward (`axis`, the creature's forward
/// in its design frame, turned by the cell's angle), so the thrust follows the body's curve.
/// Each cell's force is acc × M / Σ(m w p) × m w p, with w its type's swim weight and
/// p = 1 + pulse × sin(the pose wave's phase at the cell): the forces' magnitudes always
/// sum to acc × the creature's mass, and the pulse only moves the push along the body in
/// step with the stroke.
#[derive(Clone, Copy, Debug, Default)]
pub struct Swim {
    pub acc: f32,
    pub pulse: f32,
    pub axis: Vector2,
}

#[derive(Clone, Copy, Debug)]
pub struct Cross {
    pub a: u32,
    pub ai: u32,
    pub b: u32,
    pub bi: u32,
    pub edge: bool,
}

#[derive(Default, Clone)]
pub struct Body {
    pub alive: bool,
    pub n: usize,
    pub pos: Vec<Vector2>,
    pub prev: Vec<Vector2>,
    /// Where the substep's prediction put each cell (prev + vel × h, as stored): the
    /// substep's velocity is vel + (pos − pred) / h, so the rounding of f32 positions far
    /// from the origin never feeds back into the velocities (with (pos − prev) / h a blob
    /// drifting in a current at x ≈ 1000 px fell 0.8 % short of its speed).
    pub pred: Vec<Vector2>,
    pub vel: Vec<Vector2>,
    pub th: Vec<f32>,
    pub th_prev: Vec<f32>,
    pub om: Vec<f32>,
    pub r0: Vec<f32>,
    pub scale: Vec<f32>,
    /// What the links' rest lengths are scaled by (the ease, and radius muscles).
    pub rscale: Vec<f32>,
    pub r: Vec<f32>,
    pub mass: Vec<f32>,
    pub w: Vec<f32>,
    pub iw: Vec<f32>,
    pub typ: Vec<u8>,
    /// Its group: cells of one type and group linked together form one region.
    pub group: Vec<u16>,
    pub uid: Vec<u32>,
    /// A cell growing in: seconds left of its ease (0: done).
    pub ease: Vec<f32>,
    pub force: Vec<Vector2>,
    /// Script forces kept until changed.
    pub user_force: Vec<Vector2>,
    pub thrust: Vec<f32>,
    pub thrust_angle: Vec<f32>,
    pub muscle: Vec<f32>,
    pub muscles_set: bool,
    /// Positions in the design frame (about the centroid at build).
    pub rest_local: Vec<Vector2>,
    pub links: Vec<Link>,
    pub nb_start: Vec<u32>,
    pub nb: Vec<(u32, u32)>,
    pub sm_start: Vec<u32>,
    pub sm: Vec<u32>,
    pub sm_off: Vec<Vector2>,
    pub boundary: Vec<bool>,
    pub outline: Vec<u32>,
    pub colliders: Vec<u32>,
    pub push: Vector2,
    pub twist: f32,
    /// One-step forces: added to the next step's, then cleared (push_once, twist_once,
    /// per-cell forces; the last count as outside the creature, as user_force does).
    pub push_once: Vector2,
    pub twist_once: f32,
    pub force_once: Vec<Vector2>,
    /// push + push_once for this frame's substeps.
    pub push_frame: Vector2,
    pub swim: Swim,
    /// Damping of the creature's mean velocity and rigid spin relative to the water (1/s),
    /// an exact exponential decay per substep; the cells' motion relative to that rigid
    /// motion (the stroke, a wobble) is left alone.
    pub damp_lin: f32,
    pub damp_ang: f32,
    pub wave: Wave,
    pub time: f32,
    pub lo: Vector2,
    pub hi: Vector2,
    pub vmax: f32,
    pub grid: Vec<(u64, u32)>,
    pub egrid: Vec<(u64, u32)>,
    pub wall_c: Vec<(u32, u32)>,
    pub self_c: Vec<(u32, u32)>,
    pub drag_f: Vec<Vector2>,
    pub surf: Vec<Vector2>,
    pub cs: Vec<(f32, f32)>,
    /// Links that broke this frame (indices), found in parallel, applied serially.
    pub broken: Vec<u32>,
    pub topo_dirty: bool,
    /// WAVE_POSE: the bent design positions this frame (shape matching's goals).
    pub bent: Vec<Vector2>,
    /// WAVE_POSE: each cell's frame turn in the bent pose (the links' rest angles assume a
    /// cell's frame turned by it; a shape-matched cell's angle adds it to its fit).
    pub bent_turn: Vec<f32>,
    pub self_age: u32,
    pub self_stale: bool,
    pub near_start: Vec<u32>,
    pub near_list: Vec<u32>,
    /// The water's velocity per cell (empty: `current` if has_current, else the options').
    pub water: Vec<Vector2>,
    pub current: Vector2,
    pub has_current: bool,
    /// Per cell: its region (cells of one type and group linked together), shape matched.
    pub region: Vec<u32>,
    pub cell_shape: Vec<bool>,
    pub regions: u32,
    pub joints: Vec<Joint>,
    /// Joint angles by region keys (ka, kb, rad: the second region turned against the first).
    pub joint_angles: Vec<(u32, u32, f32)>,
    /// The options' types_version the regions were built for (u32::MAX: stale).
    pub regions_built: u32,
    /// Something outside the creature pushed one of its cells this frame (a wall, another
    /// creature, a script force): its links' envelopes hold still.
    pub contact: bool,
    /// The link graph's faces for the skin (cells_draw.rs), walked by after_topology().
    pub faces: std::sync::Arc<crate::cells_draw::Faces>,
    /// Cells near a moving obstacle this step (cell, wall index) and the impulses this
    /// substep's contacts gave them (wall index, point, impulse): obstacles.rs.
    pub dyn_c: Vec<(u32, u32)>,
    pub dyn_sub: Vec<(u32, Vector2, Vector2)>,
}

pub struct Cells {
    pub opt: Opt,
    pub bodies: Vec<Body>,
    /// The walls: convex polygons, GooStatics' (add_static_shape()) or add_wall()'s.
    pub statics: Vec<StaticShape>,
    next_wall_id: i64,
    pool: Option<rayon::ThreadPool>,
    pool_threads: usize,
    /// Pools made for other thread counts, kept for the automatic choice to switch back to.
    spare_pools: Vec<rayon::ThreadPool>,
    pub grid_cell: f32,
    pub stats: Stats,
    pub cross: Vec<Cross>,
    /// (kind, creature, uid a, uid b) — EVENT_SPLIT: (kind, parent, new creature, cells).
    pub events: Vec<[i32; 4]>,
    pub next_uid: u32,
    pub frame: u64,
    /// A GooKernel's rings coupled to the creatures (couple.rs; off unless given).
    pub ghosts: crate::couple::Ghosts,
}

#[derive(Default, Clone, Debug)]
pub struct Stats {
    pub total_us: u64,
    pub prep_us: u64,
    pub broad_us: u64,
    pub solve_us: u64,
    pub serial_us: u64,
    pub vel_us: u64,
    pub topo_us: u64,
    pub cross_pairs: usize,
    pub wall_pairs: usize,
    pub self_pairs: usize,
    pub links: usize,
    pub build_us: u64,
}

impl Default for Cells {
    fn default() -> Self {
        Cells { opt: Opt::default(), bodies: Vec::new(), statics: Vec::new(), next_wall_id: -1, pool: None, pool_threads: 1, spare_pools: Vec::new(), grid_cell: 64.0, stats: Stats::default(), cross: Vec::new(), events: Vec::new(), next_uid: 0, frame: 0, ghosts: Default::default() }
    }
}

#[inline]
pub(crate) fn key(x: f32, y: f32, cell: f32) -> (i32, i32) {
    ((x / cell).floor() as i32, (y / cell).floor() as i32)
}
#[inline]
fn pack(k: (i32, i32)) -> u64 {
    ((k.0 as u32 as u64) << 32) | (k.1 as u32 as u64)
}

pub(crate) fn grid_query(grid: &[(u64, u32)], k: (i32, i32), out: &mut Vec<u32>) {
    for dy in -1..=1 {
        for dx in -1..=1 {
            let kk = pack((k.0 + dx, k.1 + dy));
            let start = grid.partition_point(|e| e.0 < kk);
            let mut s = start;
            while s < grid.len() && grid[s].0 == kk {
                out.push(grid[s].1);
                s += 1;
            }
        }
    }
}

/// The signed distance from p to a convex wall (negative: inside) and the outward
/// direction there.
pub fn wall_distance(w: &StaticShape, p: Vector2) -> (f32, Vector2) {
    w.gap(p, 0.0, f32::INFINITY).unwrap_or((f32::INFINITY, Vector2::ZERO))
}

/// The face through which the segment a → b first enters convex wall `w`, when a is
/// outside it and the segment reaches it (Cyrus-Beck); None otherwise. A cell whose centre
/// crossed into a wall within a substep is pushed back out through this face, never
/// through the nearest one: a thin wall (or a convex piece of a concave one) is not
/// tunnelled through at the speed cap.
#[inline]
pub fn entry_face(w: &StaticShape, a: Vector2, b: Vector2) -> Option<usize> {
    let n = w.world.len();
    if n < 3 {
        return None;
    }
    let d = b - a;
    let (mut t0, mut t1) = (0.0f32, 1.0f32);
    let mut face = None;
    for k in 0..n {
        let nk = w.normals[k];
        let sa = dot(nk, a - w.world[k]);
        let sd = dot(nk, d);
        if sd.abs() < 1e-12 {
            if sa > 0.0 {
                return None;
            }
            continue;
        }
        let t = -sa / sd;
        if sd < 0.0 {
            if t > t0 {
                t0 = t;
                face = Some(k);
            }
        } else if t < t1 {
            t1 = t;
        }
        if t0 > t1 {
            return None;
        }
    }
    face
}

/// One cell against one wall: out through the face its centre entered by this substep, or
/// out of any overlap along the nearest direction.
#[inline]
pub(crate) fn push_out_of_wall(w: &StaticShape, prev: Vector2, p: Vector2, r: f32) -> Vector2 {
    if let Some(k) = entry_face(w, prev, p) {
        let s = dot(w.normals[k], p - w.world[k]);
        return p + w.normals[k] * (r - s);
    }
    if let Some((g, dir)) = w.gap(p, r, 0.0) {
        if g < 0.0 {
            return p - dir * g;
        }
    }
    p
}

impl Body {
    pub fn new(centers: &[Vector2], radii: &[f32], types: &[u8], density: f32, uid0: u32) -> Body {
        Body::new_ex(centers, radii, types, &[], &[], density, uid0)
    }

    /// With per-cell groups (regions) and mass factors (× the density; empty: 1).
    pub fn new_ex(centers: &[Vector2], radii: &[f32], types: &[u8], groups: &[u16], masses: &[f32], density: f32, uid0: u32) -> Body {
        let n = centers.len();
        let mut b = Body { alive: true, n, regions_built: u32::MAX, ..Default::default() };
        for i in 0..n {
            let r = radii.get(i).copied().unwrap_or(10.0).max(0.5);
            let m = masses.get(i).copied().unwrap_or(1.0).max(1e-3);
            b.push_cell(centers[i], r, *types.get(i).unwrap_or(&0), density * m, uid0 + i as u32);
            b.group[i] = groups.get(i).copied().unwrap_or(0);
        }
        b.rest_local_from_now(false);
        b
    }

    fn push_cell(&mut self, p: Vector2, r: f32, t: u8, density: f32, uid: u32) {
        let m = density * std::f32::consts::PI * r * r;
        self.pos.push(p);
        self.prev.push(p);
        self.pred.push(p);
        self.vel.push(Vector2::ZERO);
        self.th.push(0.0);
        self.th_prev.push(0.0);
        self.om.push(0.0);
        self.r0.push(r);
        self.scale.push(1.0);
        self.rscale.push(1.0);
        self.r.push(r);
        self.mass.push(m);
        self.w.push(1.0 / m);
        self.iw.push(1.0 / (0.5 * m * r * r));
        self.typ.push(t);
        self.group.push(0);
        self.uid.push(uid);
        self.ease.push(0.0);
        self.force.push(Vector2::ZERO);
        self.user_force.push(Vector2::ZERO);
        self.thrust.push(0.0);
        self.thrust_angle.push(0.0);
        self.muscle.push(1.0);
    }

    /// Links every pair within touch distance (× link_tol), planar.
    pub fn build_links(&mut self, opt: &Opt) {
        let n = self.n;
        self.links.clear();
        let rmax = self.r0.iter().cloned().fold(1.0, f32::max);
        let cell = 2.0 * rmax * opt.link_tol + 1.0;
        let mut grid: Vec<(u64, u32)> = (0..n).map(|i| (pack(key(self.pos[i].x, self.pos[i].y, cell)), i as u32)).collect();
        grid.sort_unstable();
        let mut near = Vec::new();
        for i in 0..n {
            near.clear();
            grid_query(&grid, key(self.pos[i].x, self.pos[i].y, cell), &mut near);
            near.sort_unstable();
            for &j in &near {
                let j = j as usize;
                if j <= i {
                    continue;
                }
                let d = (self.pos[j] - self.pos[i]).length();
                if d <= (self.r[i] + self.r[j]) * opt.link_tol {
                    self.links.push(self.make_link(i, j, d));
                }
            }
        }
        self.planarize();
        self.after_topology();
    }

    /// A link with its rest values from the current geometry (d its rest length at full size).
    fn make_link(&self, i: usize, j: usize, d: f32) -> Link {
        let dv = self.pos[j] - self.pos[i];
        let ang = dv.y.atan2(dv.x);
        let ai = wrap(ang - self.th[i]);
        let aj = wrap(ang + std::f32::consts::PI - self.th[j]);
        Link { i: i as u32, j: j as u32, d0: d, d_base: d, ai_base: ai, aj_base: aj, d_design: d, ai, aj, ai_design: ai, aj_design: aj, rest: d, ..Default::default() }
    }

    /// Neighbour lists, shape-matching clusters, the outline and colliders, after any change.
    pub fn after_topology(&mut self) {
        let n = self.n;
        let mut lists: Vec<Vec<(f32, u32, u32)>> = vec![Vec::new(); n];
        for (li, l) in self.links.iter().enumerate() {
            let (i, j) = (l.i as usize, l.j as usize);
            let d = self.pos[j] - self.pos[i];
            lists[i].push((d.y.atan2(d.x), j as u32, li as u32));
            lists[j].push(((-d.y).atan2(-d.x), i as u32, li as u32));
        }
        self.nb_start.clear();
        self.nb.clear();
        for l in lists.iter_mut() {
            l.sort_by(|a, b| a.0.partial_cmp(&b.0).unwrap_or(std::cmp::Ordering::Equal).then(a.1.cmp(&b.1)));
            self.nb_start.push(self.nb.len() as u32);
            for e in l.iter() {
                self.nb.push((e.1, e.2));
            }
        }
        self.nb_start.push(self.nb.len() as u32);
        // Regions, shape-matching clusters and joints: built at the next frame's start.
        self.regions_built = u32::MAX;
        // Cells within two links of each cell, sorted (the own contacts' exclusions).
        self.near_start.clear();
        self.near_list.clear();
        let mut tmp: Vec<u32> = Vec::new();
        for i in 0..n {
            tmp.clear();
            for q in self.nb_start[i]..self.nb_start[i + 1] {
                let j = self.nb[q as usize].0;
                tmp.push(j);
                for q2 in self.nb_start[j as usize]..self.nb_start[j as usize + 1] {
                    let k = self.nb[q2 as usize].0;
                    if k as usize != i {
                        tmp.push(k);
                    }
                }
            }
            tmp.sort_unstable();
            tmp.dedup();
            self.near_start.push(self.near_list.len() as u32);
            self.near_list.extend_from_slice(&tmp);
        }
        self.near_start.push(self.near_list.len() as u32);
        self.trace_outline();
        // The skin's faces change only with the link graph.
        self.faces = std::sync::Arc::new(crate::cells_draw::walk_faces(self));
        self.topo_dirty = false;
        // Rebuild the creature's own candidates now; stagger later rebuilds by creature.
        self.self_stale = true;
        self.self_age = (self.uid.first().copied().unwrap_or(0).wrapping_mul(2_654_435_761) >> 13) & 0xffff;
    }

    /// Regions (cells of one type and group joined by links), which cells are shape
    /// matched (their type's body mode), which links bend (all but those inside one
    /// shape-matched region), the shape-matching clusters (a cell and its linked
    /// neighbours of its region) and the joints between regions.
    pub fn build_regions(&mut self, opt: &Opt) {
        let n = self.n;
        let key = |b: &Body, i: usize| ((b.typ[i] as u32) << 16) | b.group[i] as u32;
        let mode: Vec<u8> = (0..n).map(|i| opt.types[self.typ[i] as usize].mode(opt.bend_mode)).collect();
        self.cell_shape = mode.iter().map(|&m| m == BEND_SHAPE).collect();
        let mut parent: Vec<usize> = (0..n).collect();
        fn find(p: &mut [usize], x: usize) -> usize {
            let mut x = x;
            while p[x] != x {
                p[x] = p[p[x]];
                x = p[x];
            }
            x
        }
        for l in &self.links {
            let (i, j) = (l.i as usize, l.j as usize);
            if key(self, i) == key(self, j) {
                let (a, b) = (find(&mut parent, i), find(&mut parent, j));
                if a != b {
                    let (lo, hi) = if a < b { (a, b) } else { (b, a) };
                    parent[hi] = lo;
                }
            }
        }
        let mut index = vec![u32::MAX; n];
        self.region = vec![0; n];
        let mut count = 0u32;
        for i in 0..n {
            let r = find(&mut parent, i);
            if index[r] == u32::MAX {
                index[r] = count;
                count += 1;
            }
            self.region[i] = index[r];
        }
        self.regions = count;
        // A shape-matched cell needs two linked neighbours of its region for a fit: with
        // fewer its angle would never be updated, and its links (to another region, or
        // bending ones) would pin the creature's turn to the world. It bends by its links.
        for i in 0..n {
            if !self.cell_shape[i] {
                continue;
            }
            let mut same = 0;
            for q in self.nb_start[i]..self.nb_start[i + 1] {
                if self.region[self.nb[q as usize].0 as usize] == self.region[i] {
                    same += 1;
                }
            }
            if same < 2 {
                self.cell_shape[i] = false;
            }
        }
        // Joints: the links between two regions, grouped by the pair.
        self.joints.clear();
        let design = self.rest_local.len() == n;
        for li in 0..self.links.len() {
            let (i, j) = (self.links[li].i as usize, self.links[li].j as usize);
            let (ri, rj) = (self.region[i], self.region[j]);
            let same = ri == rj;
            let l = &mut self.links[li];
            l.bend = !(same && self.cell_shape[i] && self.cell_shape[j]) && (mode[i] != BEND_NONE || mode[j] != BEND_NONE);
            l.joint = 0;
            l.jflip = false;
            if same {
                continue;
            }
            let (ki, kj) = (key(self, i), key(self, j));
            // The joint's first region: the lower key (the lower region id between equals).
            let flip = ki > kj || (ki == kj && ri > rj);
            let (ra, rb, ka, kb) = if flip { (rj, ri, kj, ki) } else { (ri, rj, ki, kj) };
            let mid = if design { (self.rest_local[i] + self.rest_local[j]) * 0.5 } else { (self.pos[i] + self.pos[j]) * 0.5 };
            let k = match self.joints.iter().position(|jt| jt.ra == ra && jt.rb == rb) {
                Some(k) => k,
                None => {
                    self.joints.push(Joint { ra, rb, ka, kb, pivot: Vector2::ZERO, links: 0 });
                    self.joints.len() - 1
                }
            };
            self.joints[k].pivot += mid;
            self.joints[k].links += 1;
            let l = &mut self.links[li];
            l.joint = k as u32 + 1;
            l.jflip = flip;
        }
        for jt in self.joints.iter_mut() {
            jt.pivot /= jt.links.max(1) as f32;
        }
        // Shape-matching clusters: each shape-matched cell and its linked neighbours of its
        // own region, with their design offsets.
        self.sm_start.clear();
        self.sm.clear();
        self.sm_off.clear();
        for i in 0..n {
            self.sm_start.push(self.sm.len() as u32);
            if !self.cell_shape[i] {
                continue;
            }
            self.sm.push(i as u32);
            self.sm_off.push(Vector2::ZERO);
            for q in self.nb_start[i]..self.nb_start[i + 1] {
                let j = self.nb[q as usize].0 as usize;
                if self.region[j] != self.region[i] {
                    continue;
                }
                self.sm.push(j as u32);
                let off = if design { self.rest_local[j] - self.rest_local[i] } else { self.pos[j] - self.pos[i] };
                self.sm_off.push(off);
            }
        }
        self.sm_start.push(self.sm.len() as u32);
        self.regions_built = opt.types_version;
    }

    /// The joint angle set for regions of keys (ka, kb), ka <= kb (0: none).
    fn joint_angle(&self, ka: u32, kb: u32) -> f32 {
        self.joint_angles.iter().find(|x| x.0 == ka && x.1 == kb).map(|x| x.2).unwrap_or(0.0)
    }

    pub fn linked(&self, a: usize, b: usize) -> bool {
        let (s, e) = (self.nb_start[a] as usize, self.nb_start[a + 1] as usize);
        self.nb[s..e].iter().any(|x| x.0 as usize == b)
    }

    /// Within two links (linked, or sharing a neighbour): the near list, sorted.
    #[inline]
    fn near(&self, a: usize, b: usize) -> bool {
        let (s, e) = (self.near_start[a] as usize, self.near_start[a + 1] as usize);
        self.near_list[s..e].binary_search(&(b as u32)).is_ok()
    }

    fn rest_local_from_now(&mut self, keep_turn: bool) {
        let c = self.center();
        let turn = if keep_turn && self.rest_local.len() == self.n { self.turn_against_rest() } else { 0.0 };
        let (co, si) = (turn.cos(), turn.sin());
        self.rest_local = self.pos.iter().map(|&p| rot(p - c, co, -si)).collect();
    }

    /// Longest first: a link crossing a kept shorter one is dropped (keeps the graph planar).
    fn planarize(&mut self) {
        let m = self.links.len();
        if m == 0 {
            return;
        }
        let rmax = self.r0.iter().cloned().fold(1.0, f32::max);
        let cell = 4.0 * rmax;
        let mid = |l: &Link, p: &[Vector2]| (p[l.i as usize] + p[l.j as usize]) * 0.5;
        let mut grid: Vec<(u64, u32)> = (0..m)
            .map(|k| {
                let c = mid(&self.links[k], &self.pos);
                (pack(key(c.x, c.y, cell)), k as u32)
            })
            .collect();
        grid.sort_unstable();
        let lens: Vec<f32> = self.links.iter().map(|l| (self.pos[l.j as usize] - self.pos[l.i as usize]).length() / (self.r0[l.i as usize] + self.r0[l.j as usize])).collect();
        let mut order: Vec<usize> = (0..m).collect();
        order.sort_by(|&a, &b| lens[a].partial_cmp(&lens[b]).unwrap_or(std::cmp::Ordering::Equal).then(a.cmp(&b)));
        let mut keep = vec![true; m];
        let mut near = Vec::new();
        for &k in order.iter().rev() {
            let b = self.links[k];
            let (p, q) = (self.pos[b.i as usize], self.pos[b.j as usize]);
            let c = (p + q) * 0.5;
            near.clear();
            grid_query(&grid, key(c.x, c.y, cell), &mut near);
            for &o in &near {
                let o = o as usize;
                if o == k || !keep[o] || lens[o] > lens[k] || (lens[o] == lens[k] && o > k) {
                    continue;
                }
                let ob = self.links[o];
                if ob.i == b.i || ob.i == b.j || ob.j == b.i || ob.j == b.j {
                    continue;
                }
                let (r, s) = (self.pos[ob.i as usize], self.pos[ob.j as usize]);
                let d1 = cross(q - p, r - p);
                let d2 = cross(q - p, s - p);
                let d3 = cross(s - r, p - r);
                let d4 = cross(s - r, q - r);
                if d1 * d2 < 0.0 && d3 * d4 < 0.0 {
                    keep[k] = false;
                    break;
                }
            }
        }
        let mut out = Vec::with_capacity(m);
        for k in 0..m {
            if keep[k] {
                out.push(self.links[k]);
            }
        }
        self.links = out;
    }

    /// The outer face of the link graph, walked from the leftmost cell (outside on the left
    /// in math axes, i.e. the walk is clockwise on screen); boundary = on that loop.
    fn trace_outline(&mut self) {
        let n = self.n;
        self.outline.clear();
        self.boundary = vec![false; n];
        if n == 0 {
            self.colliders.clear();
            return;
        }
        let mut s = 0;
        for i in 1..n {
            if self.pos[i].x < self.pos[s].x || (self.pos[i].x == self.pos[s].x && self.pos[i].y < self.pos[s].y) {
                s = i;
            }
        }
        if self.nb_start[s + 1] == self.nb_start[s] {
            self.outline.push(s as u32);
        } else {
            let next = |b: &Body, at: usize, back: f32| -> usize {
                let (st, en) = (b.nb_start[at] as usize, b.nb_start[at + 1] as usize);
                let mut best = usize::MAX;
                let mut best_turn = f32::INFINITY;
                for q in st..en {
                    let j = b.nb[q].0 as usize;
                    let d = b.pos[j] - b.pos[at];
                    let a = d.y.atan2(d.x);
                    let mut turn = back - a;
                    while turn <= 1e-6 {
                        turn += std::f32::consts::TAU;
                    }
                    if turn < best_turn {
                        best_turn = turn;
                        best = j;
                    }
                }
                best
            };
            let first = next(self, s, std::f32::consts::PI);
            let (mut u, mut v) = (s, first);
            self.outline.push(s as u32);
            for _ in 0..(4 * n + 8) {
                if v == s && next(self, s, (self.pos[u] - self.pos[s]).y.atan2((self.pos[u] - self.pos[s]).x)) == first {
                    break;
                }
                self.outline.push(v as u32);
                let d = self.pos[u] - self.pos[v];
                let w = next(self, v, d.y.atan2(d.x));
                u = v;
                v = w;
            }
        }
        for &c in &self.outline {
            self.boundary[c as usize] = true;
        }
        // Cells not connected to the outline's component (a loose cell after a break that
        // was not split yet) count as boundary too.
        self.colliders.clear();
    }

    pub fn set_colliders(&mut self, all: bool) {
        self.colliders = (0..self.n as u32).filter(|&i| all || self.boundary[i as usize]).collect();
    }

    pub fn center(&self) -> Vector2 {
        let mut c = Vector2::ZERO;
        let mut m = 0.0;
        for i in 0..self.n {
            c += self.pos[i] * self.mass[i];
            m += self.mass[i];
        }
        c / if m > 0.0 { m } else { 1.0 }
    }

    pub fn velocity(&self) -> Vector2 {
        let mut c = Vector2::ZERO;
        let mut m = 0.0;
        for i in 0..self.n {
            c += self.vel[i] * self.mass[i];
            m += self.mass[i];
        }
        c / if m > 0.0 { m } else { 1.0 }
    }

    #[allow(dead_code)]
    pub fn total_mass(&self) -> f32 {
        self.mass.iter().sum()
    }

    /// Angular velocity of the cells about the centre of mass (orbit only).
    pub fn spin(&self) -> f32 {
        let c = self.center();
        let v = self.velocity();
        let (mut l, mut i) = (0.0f32, 0.0f32);
        for k in 0..self.n {
            let p = self.pos[k] - c;
            l += self.mass[k] * cross(p, self.vel[k] - v);
            i += self.mass[k] * lsq(p);
        }
        if i > 0.0 { l / i } else { 0.0 }
    }

    /// The best-fit turn of the cells now against rest_local.
    pub fn turn_against_rest(&self) -> f32 {
        let c = self.center();
        let (mut sc, mut ss) = (0.0f32, 0.0f32);
        for i in 0..self.n {
            let p = self.pos[i] - c;
            let q = self.rest_local[i];
            sc += self.mass[i] * dot(q, p);
            ss += self.mass[i] * cross(q, p);
        }
        ss.atan2(sc)
    }

    /// RMS distance of the cells from the best rigid fit of the design, over the mean radius.
    pub fn shape_error(&self) -> f32 {
        if self.n == 0 {
            return 0.0;
        }
        let c = self.center();
        let t = self.turn_against_rest();
        let (co, si) = (t.cos(), t.sin());
        let mut e = 0.0;
        let mut rs = 0.0;
        for i in 0..self.n {
            let g = c + rot(self.rest_local[i], co, si);
            e += lsq(self.pos[i] - g);
            rs += self.r0[i];
        }
        (e / self.n as f32).sqrt() / (rs / self.n as f32)
    }

    /// The outline pushed out by each cell's radius along the loop's normal.
    pub fn outline_surface(&self, out: &mut Vec<Vector2>) {
        out.clear();
        let m = self.outline.len();
        if m < 3 {
            for &c in &self.outline {
                out.push(self.pos[c as usize]);
            }
            return;
        }
        for k in 0..m {
            let a = self.pos[self.outline[(k + m - 1) % m] as usize];
            let c = self.outline[k] as usize;
            let b = self.pos[self.outline[(k + 1) % m] as usize];
            let t = b - a;
            let l = t.length();
            let nrm = if l > 1e-6 { Vector2::new(t.y, -t.x) / l } else { Vector2::ZERO };
            out.push(self.pos[c] - nrm * self.r[c]);
        }
    }
}

impl Body {
    /// Muscles, rest values, compliances, forces, the box and the candidates of a frame.
    fn prepare(&mut self, opt: &Opt, dt: f32, walls: &[StaticShape], cell: f32) {
        let n = self.n;
        let h = dt / opt.substeps as f32;
        self.time += dt;
        if self.regions_built != opt.types_version {
            self.build_regions(opt);
        }
        self.contact = false;
        // Muscles: a wave, or the scales the script set (muscle[]), times the ease.
        let pose = self.wave.mode == WAVE_POSE;
        self.wave.age += dt;
        // The phase integrates the frequency, so a frequency changed every frame (a
        // controller) never makes the wave jump.
        self.wave.phase = (self.wave.phase + self.wave.omega * dt) % std::f32::consts::TAU;
        if self.wave.mode == WAVE_RADIUS || self.wave.mode == WAVE_SQUEEZE {
            let wv = self.wave;
            let across = perp(wv.axis);
            for i in 0..n {
                let u = dot(self.rest_local[i], wv.axis);
                let s = (wv.k * u + wv.phase).sin() * (wv.age / 0.5).min(1.0);
                let f = if wv.mode == WAVE_RADIUS { (dot(self.rest_local[i], across) / wv.half_width.max(1e-3)).clamp(-1.0, 1.0) } else { 1.0 };
                self.muscle[i] = (1.0 + wv.amp * s * f).max(0.2);
            }
        } else if pose {
            self.pose_wave(opt);
        }
        if !self.joints.is_empty() {
            self.joint_rest(pose);
        }
        for i in 0..n {
            let mut e = 1.0;
            if self.ease[i] > 0.0 {
                self.ease[i] = (self.ease[i] - dt).max(0.0);
                let t = 1.0 - self.ease[i] / opt.ease_time.max(1e-6);
                let t = t * t * (3.0 - 2.0 * t);
                e = opt.ease_from + (1.0 - opt.ease_from) * t;
            }
            self.scale[i] = e * self.muscle[i];
            // Rest lengths follow radius muscles, not the ease (a growing cell's links ease
            // from their length when made to their full rest instead: no snap, no kick).
            self.rscale[i] = if pose { 1.0 } else { self.muscle[i] };
            self.r[i] = self.r0[i] * self.scale[i];
        }
        // Rest values, plasticity, compliances.
        let tw = std::f32::consts::TAU;
        let h2 = h * h;
        let ks = (tw * opt.stretch_hz) * (tw * opt.stretch_hz) * h2;
        let kb = (tw * opt.bend_hz) * (tw * opt.bend_hz) * h2;
        let plastic = opt.plastic_rate > 0.0 && opt.plastic_yield.is_finite();
        let creep = (opt.plastic_rate * dt).min(1.0);
        let recover = (opt.plastic_recover * dt).min(1.0);
        for l in self.links.iter_mut() {
            let (i, j) = (l.i as usize, l.j as usize);
            let f = (self.rscale[i] * self.r0[i] + self.rscale[j] * self.r0[j]) / (self.r0[i] + self.r0[j]);
            if recover > 0.0 {
                l.d_plastic *= 1.0 - recover;
                l.ai_plastic *= 1.0 - recover;
                l.aj_plastic *= 1.0 - recover;
            }
            if plastic {
                let d = self.pos[j] - self.pos[i];
                let len = d.length().max(1e-6);
                let rest = (l.d_design + l.d_plastic) * f;
                let e = len / rest - 1.0;
                if e.abs() > opt.plastic_yield {
                    let target = len / f * (1.0 - opt.plastic_yield * e.signum() * 0.5);
                    l.d_plastic += (target - (l.d_design + l.d_plastic)) * creep;
                }
                let ang = d.y.atan2(d.x);
                let ci = wrap(ang - self.th[i] - (l.ai_design + l.ai_plastic));
                if ci.abs() > opt.plastic_yield {
                    l.ai_plastic += ci * creep;
                }
                let cj = wrap(ang + std::f32::consts::PI - self.th[j] - (l.aj_design + l.aj_plastic));
                if cj.abs() > opt.plastic_yield {
                    l.aj_plastic += cj * creep;
                }
            }
            l.d0 = l.d_design + l.d_plastic;
            l.ai = l.ai_design + l.ai_plastic;
            l.aj = l.aj_design + l.aj_plastic;
            l.rest = l.d0 * f;
            let (ei, ej) = (self.ease[i], self.ease[j]);
            if ei > 0.0 || ej > 0.0 {
                let t = 1.0 - ei.max(ej) / opt.ease_time.max(1e-6);
                let t = t * t * (3.0 - 2.0 * t);
                l.rest = l.d_from + (l.rest - l.d_from) * t;
            }
            l.ui = Vector2::new(l.ai.cos(), l.ai.sin());
            l.uj = Vector2::new(l.aj.cos(), l.aj.sin());
            let (ti, tj) = (&opt.types[self.typ[i] as usize], &opt.types[self.typ[j] as usize]);
            let ws = self.w[i] + self.w[j];
            l.alpha = ws / (ks * (ti.stretch * tj.stretch).sqrt()).max(1e-12);
            let w0 = ws / (l.rest * l.rest).max(1e-6) + 0.5 * (self.iw[i] + self.iw[j]);
            l.alpha_ang = w0 / (kb * (ti.bend * tj.bend).sqrt()).max(1e-12);
        }
        // Box and speed.
        let mut lo = Vector2::new(f32::INFINITY, f32::INFINITY);
        let mut hi = -lo;
        let mut vmax = 0.0f32;
        for i in 0..n {
            let p = self.pos[i];
            let r = self.r[i];
            lo = Vector2::new(lo.x.min(p.x - r), lo.y.min(p.y - r));
            hi = Vector2::new(hi.x.max(p.x + r), hi.y.max(p.y + r));
            vmax = vmax.max(lsq(self.vel[i]));
        }
        self.lo = lo;
        self.hi = hi;
        self.vmax = vmax.sqrt();
        // Frame forces (and the one-step ones, used up here).
        let once = self.force_once.len() == n;
        for i in 0..n {
            let mut f = self.user_force[i];
            if once {
                f += self.force_once[i];
            }
            if f != Vector2::ZERO {
                self.contact = true;
            }
            if self.thrust[i] != 0.0 {
                let a = self.th[i] + self.thrust_angle[i];
                f += Vector2::new(a.cos(), a.sin()) * self.thrust[i];
            }
            self.force[i] = f;
        }
        self.force_once.clear();
        if self.swim.acc != 0.0 {
            self.swim_forces(opt);
        }
        self.push_frame = self.push + self.push_once;
        self.push_once = Vector2::ZERO;
        let twist = self.twist + self.twist_once;
        self.twist_once = 0.0;
        if twist != 0.0 {
            let c = self.center();
            for i in 0..n {
                self.force[i] += perp(self.pos[i] - c) * (self.mass[i] * twist);
            }
        }
        if opt.tension != 0.0 {
            let m = self.outline.len();
            if m >= 3 {
                for e in 0..m {
                    let (a, b) = (self.outline[e] as usize, self.outline[(e + 1) % m] as usize);
                    if a == b {
                        continue;
                    }
                    let d = self.pos[b] - self.pos[a];
                    let l = d.length();
                    if l < 1e-6 {
                        continue;
                    }
                    let f = d * (opt.tension / l);
                    self.force[a] += f;
                    self.force[b] -= f;
                }
            }
        }
        if self.drag_f.len() != n {
            self.drag_f = vec![Vector2::ZERO; n];
        }
        if opt.drag.enabled && !opt.drag_substep {
            self.apply_drag(&opt.drag, opt.current, dt);
        } else if !opt.drag.enabled {
            for f in self.drag_f.iter_mut() {
                *f = Vector2::ZERO;
            }
        }
        // Colliders' grid (and the outline's edges).
        if self.colliders.is_empty() && n > 0 {
            self.set_colliders(opt.collide_all);
        }
        self.grid.clear();
        for (k, &c) in self.colliders.iter().enumerate() {
            let p = self.pos[c as usize];
            self.grid.push((pack(key(p.x, p.y, cell)), k as u32));
        }
        self.grid.sort_unstable();
        self.egrid.clear();
        if opt.capsules {
            let m = self.outline.len();
            for e in 0..m {
                let (a, b) = (self.outline[e] as usize, self.outline[(e + 1) % m] as usize);
                if a == b {
                    continue;
                }
                let c = (self.pos[a] + self.pos[b]) * 0.5;
                self.egrid.push((pack(key(c.x, c.y, cell)), e as u32));
            }
            self.egrid.sort_unstable();
        }
        let margin = opt.margin + self.vmax * dt;
        self.wall_c.clear();
        for (wi, w) in walls.iter().enumerate() {
            if w.dynamic {
                continue;
            }
            let (wlo, whi) = (w.aabb.pos, w.aabb.pos + w.aabb.size);
            if whi.x < lo.x - margin || wlo.x > hi.x + margin || whi.y < lo.y - margin || wlo.y > hi.y + margin {
                continue;
            }
            for c in 0..n as u32 {
                if !opt.types[self.typ[c as usize] as usize].walls {
                    continue;
                }
                let p = self.pos[c as usize];
                let r = self.r[c as usize] + margin;
                if p.x + r < wlo.x || p.x - r > whi.x || p.y + r < wlo.y || p.y - r > whi.y {
                    continue;
                }
                if w.gap(p, self.r[c as usize], margin).is_some() {
                    self.wall_c.push((c, wi as u32));
                }
            }
        }
        let every = opt.self_every.max(1);
        let rebuild = self.self_age % every == 0 || self.self_stale;
        self.self_stale = false;
        self.self_age = self.self_age.wrapping_add(1);
        if opt.self_mode == SELF_NONE {
            self.self_c.clear();
        } else if rebuild {
            self.self_c.clear();
            // Two cells may close at twice the fastest speed: the margin covers that.
            let margin = opt.margin + 2.0 * self.vmax * dt * every as f32;
            let rmax = self.r.iter().cloned().fold(1.0, f32::max);
            let sc = 2.0 * rmax + margin;
            let mut g: Vec<(u64, u32)> = (0..n).map(|i| (pack(key(self.pos[i].x, self.pos[i].y, sc)), i as u32)).collect();
            g.sort_unstable();
            let mut near = Vec::new();
            for a in 0..n {
                let ta = opt.types[self.typ[a] as usize].self_collide;
                let p = self.pos[a];
                near.clear();
                grid_query(&g, key(p.x, p.y, sc), &mut near);
                near.sort_unstable();
                for &b in &near {
                    let b = b as usize;
                    if b <= a {
                        continue;
                    }
                    if opt.self_mode == SELF_TYPES && !ta && !opt.types[self.typ[b] as usize].self_collide {
                        continue;
                    }
                    let reach = self.r[a] + self.r[b] + margin;
                    if lsq(self.pos[b] - p) >= reach * reach {
                        continue;
                    }
                    if if opt.self_mode == SELF_FAR { self.near(a, b) } else { self.linked(a, b) } {
                        continue;
                    }
                    self.self_c.push((a as u32, b as u32));
                }
            }
        }
        for l in self.links.iter_mut() {
            l.f_frame = 0.0;
            l.t_frame = 0.0;
        }
    }

    /// The swim drive's forces (see `Swim`), added to `force`.
    fn swim_forces(&mut self, opt: &Opt) {
        let n = self.n;
        let sw = self.swim;
        let wv = self.wave;
        let pulse = if wv.mode == WAVE_POSE && wv.omega != 0.0 && self.rest_local.len() == n { sw.pulse.clamp(0.0, 1.0) * (wv.age / 0.5).min(1.0) } else { 0.0 };
        if self.cs.len() < n {
            self.cs.resize(n, (0.0, 0.0));
        }
        // Each cell's weight × its pulse in cs.0 (cs is scratch until the substeps).
        let (mut mass, mut sum) = (0.0f32, 0.0f32);
        for i in 0..n {
            let w = opt.types[self.typ[i] as usize].swim.max(0.0);
            let p = if pulse != 0.0 { 1.0 + pulse * (wv.k * dot(self.rest_local[i], wv.axis) + wv.phase).sin() } else { 1.0 };
            let x = self.mass[i] * w * p;
            self.cs[i].0 = x;
            mass += self.mass[i];
            sum += x;
        }
        if sum <= 0.0 {
            return;
        }
        let scale = sw.acc * mass / sum;
        let base = sw.axis.y.atan2(sw.axis.x);
        for i in 0..n {
            let x = self.cs[i].0;
            if x == 0.0 {
                continue;
            }
            let a = base + self.th[i];
            self.force[i] += Vector2::new(a.cos(), a.sin()) * (scale * x);
        }
    }

    /// Damps the mean velocity and the rigid spin about the centre of mass relative to the
    /// water by exp(−rate × h) (damp_lin, damp_ang); the rest of each cell's motion is kept.
    fn damp_rigid(&mut self, current: Vector2, h: f32) {
        let n = self.n;
        if n == 0 {
            return;
        }
        let c = self.center();
        let (mut m, mut v) = (0.0f32, Vector2::ZERO);
        for i in 0..n {
            m += self.mass[i];
            v += (self.vel[i] - self.water_at(i, current)) * self.mass[i];
        }
        if m <= 0.0 {
            return;
        }
        let v = v / m;
        let (mut l, mut inertia) = (0.0f32, 0.0f32);
        for i in 0..n {
            let p = self.pos[i] - c;
            l += self.mass[i] * cross(p, self.vel[i] - self.water_at(i, current) - v);
            inertia += self.mass[i] * lsq(p);
        }
        let spin = if inertia > 0.0 { l / inertia } else { 0.0 };
        let el = 1.0 - (-self.damp_lin.max(0.0) * h).exp();
        let ea = 1.0 - (-self.damp_ang.max(0.0) * h).exp();
        let (dv, dw) = (v * el, spin * ea);
        for i in 0..n {
            self.vel[i] -= dv + perp(self.pos[i] - c) * dw;
            self.om[i] -= dw;
        }
    }

    /// WAVE_POSE: the design bent along a travelling curvature wave; sets the links' design
    /// lengths and anchors and the cells' radius muscles (the stretch along the centreline).
    fn pose_wave(&mut self, _opt: &Opt) {
        const G: usize = 64;
        let n = self.n;
        let wv = self.wave;
        let across = perp(wv.axis);
        let (mut umin, mut umax) = (f32::INFINITY, f32::NEG_INFINITY);
        for i in 0..n {
            let u = dot(self.rest_local[i], wv.axis);
            umin = umin.min(u);
            umax = umax.max(u);
        }
        let span = (umax - umin).max(1e-3);
        let du = span / (G - 1) as f32;
        let ramp = (wv.age / 0.5).min(1.0);
        // A curvature that would squeeze the inner side below half its length (or stretch
        // the outer past 1.5) is not drawable: clamped, per sample along the axis, by the
        // body's half width there (a tadpole's tail may bend more than its head).
        let mut hw = [1e-3f32; G];
        for i in 0..n {
            let u = dot(self.rest_local[i], wv.axis);
            let v = dot(self.rest_local[i], across).abs() + self.r0[i];
            let g = (((u - umin) / du).round() as usize).min(G - 1);
            hw[g] = hw[g].max(v);
        }
        // Spread each sample's width a cell radius either way (no gaps between samples).
        let reach = (self.r0.iter().cloned().fold(0.0, f32::max) * 2.0 / du).ceil() as usize;
        let mut kmax = [0.0f32; G];
        for g in 0..G {
            let lo = g.saturating_sub(reach);
            let hi = (g + reach).min(G - 1);
            let w = hw[lo..=hi].iter().cloned().fold(1e-3, f32::max);
            kmax[g] = 0.5 / w;
        }
        let kappa = |u: f32, g: usize| -> f32 {
            let tail = (umax - u) / span;
            let env = (1.0 - wv.envelope) + wv.envelope * tail;
            (ramp * (wv.bias + wv.amp * wv.k * env * (wv.k * u + wv.phase).sin())).clamp(-kmax[g], kmax[g])
        };
        // Integrate from the sample nearest u = 0 both ways.
        let mut psi = [0.0f32; G];
        let mut cx = [0.0f32; G];
        let mut cy = [0.0f32; G];
        let mut kap = [0.0f32; G];
        for g in 0..G {
            kap[g] = kappa(umin + du * g as f32, g);
        }
        let g0 = ((-umin / du).round() as isize).clamp(0, G as isize - 1) as usize;
        let u0 = umin + du * g0 as f32;
        cx[g0] = u0;
        for g in (g0 + 1)..G {
            psi[g] = psi[g - 1] + 0.5 * (kap[g] + kap[g - 1]) * du;
            let a = 0.5 * (psi[g] + psi[g - 1]);
            cx[g] = cx[g - 1] + a.cos() * du;
            cy[g] = cy[g - 1] + a.sin() * du;
        }
        for g in (0..g0).rev() {
            psi[g] = psi[g + 1] - 0.5 * (kap[g] + kap[g + 1]) * du;
            let a = 0.5 * (psi[g] + psi[g + 1]);
            cx[g] = cx[g + 1] - a.cos() * du;
            cy[g] = cy[g + 1] - a.sin() * du;
        }
        if self.cs.len() < n {
            self.cs.resize(n, (0.0, 0.0));
        }
        // Bent design positions (in cs as x, y) and the frame turns (in surf, reused).
        let mut bent: Vec<Vector2> = Vec::with_capacity(n);
        let mut turn: Vec<f32> = Vec::with_capacity(n);
        for i in 0..n {
            let u = dot(self.rest_local[i], wv.axis);
            let v = dot(self.rest_local[i], across);
            let t = ((u - umin) / du).clamp(0.0, (G - 1) as f32);
            let g = (t.floor() as usize).min(G - 2);
            let f = t - g as f32;
            let ps = psi[g] + (psi[g + 1] - psi[g]) * f;
            let x = cx[g] + (cx[g + 1] - cx[g]) * f;
            let y = cy[g] + (cy[g + 1] - cy[g]) * f;
            let k = kap[g] + (kap[g + 1] - kap[g]) * f;
            let (c, s) = (ps.cos(), ps.sin());
            // Centreline point + v along the normal, in (axis, across) coordinates.
            let ax = x - v * s;
            let ay = y + v * c;
            bent.push(wv.axis * ax + across * ay);
            turn.push(ps);
            self.muscle[i] = (1.0 - v * k).clamp(0.6, 1.5);
        }
        self.bent = bent;
        self.bent_turn = turn;
        let bent = &self.bent;
        let turn = &self.bent_turn;
        for l in self.links.iter_mut() {
            let (i, j) = (l.i as usize, l.j as usize);
            let rd = self.rest_local[j] - self.rest_local[i];
            let bd = bent[j] - bent[i];
            let rl = rd.length().max(1e-6);
            l.d_design = l.d_base * bd.length() / rl;
            let dang = wrap(bd.y.atan2(bd.x) - rd.y.atan2(rd.x));
            l.ai_design = l.ai_base + dang - turn[i];
            l.aj_design = l.aj_base + dang - turn[j];
        }
    }

    /// The joints' rest values: each joint's second region turned by its angle about the
    /// joint's pivot in the design; on top of the pose wave's when it runs.
    fn joint_rest(&mut self, pose: bool) {
        let design = self.rest_local.len() == self.n;
        for li in 0..self.links.len() {
            let l = self.links[li];
            if l.joint == 0 {
                continue;
            }
            let jt = self.joints[l.joint as usize - 1];
            let delta = self.joint_angle(jt.ka, jt.kb);
            let l = &mut self.links[li];
            if !pose {
                l.d_design = l.d_base;
                l.ai_design = l.ai_base;
                l.aj_design = l.aj_base;
            }
            if delta == 0.0 || !design {
                continue;
            }
            let (ri, rj) = (self.rest_local[l.i as usize], self.rest_local[l.j as usize]);
            let (c, s) = (delta.cos(), delta.sin());
            let turned = |p: Vector2| jt.pivot + rot(p - jt.pivot, c, s);
            let (bi, bj) = if l.jflip { (turned(ri), rj) } else { (ri, turned(rj)) };
            let rd = rj - ri;
            let bd = bj - bi;
            let rl = rd.length().max(1e-6);
            l.d_design *= bd.length() / rl;
            let dang = wrap(bd.y.atan2(bd.x) - rd.y.atan2(rd.x));
            let (ti, tj) = if l.jflip { (delta, 0.0) } else { (0.0, delta) };
            l.ai_design += dang - ti;
            l.aj_design += dang - tj;
        }
    }

    /// The water's velocity at cell i.
    #[inline]
    fn water_at(&self, i: usize, current: Vector2) -> Vector2 {
        if self.water.len() == self.n {
            self.water[i]
        } else if self.has_current {
            self.current
        } else {
            current
        }
    }

    fn apply_drag(&mut self, d: &Drag, current: Vector2, dt: f32) {
        let m = self.outline.len();
        for f in self.drag_f.iter_mut() {
            *f = Vector2::ZERO;
        }
        if m < 2 {
            return;
        }
        let mut surf = std::mem::take(&mut self.surf);
        self.outline_surface(&mut surf);
        let share = 0.5 * d.density;
        for e in 0..m {
            let (ia, ib) = (self.outline[e] as usize, self.outline[(e + 1) % m] as usize);
            if ia == ib {
                continue;
            }
            let (p0, p1) = (surf[e], surf[(e + 1) % m]);
            let ex = p1 - p0;
            let length = ex.length();
            if length < 1e-6 {
                continue;
            }
            let t = ex / length;
            let v = (self.vel[ia] + self.vel[ib] - self.water_at(ia, current) - self.water_at(ib, current)) * 0.5;
            let vn = v.y * t.x - v.x * t.y;
            let vt = v.x * t.x + v.y * t.y;
            // The outside is on the walk's left in math axes: normal (t.y, -t.x) points out.
            // vn > 0 means moving along (-t.y, t.x), i.e. inward: that face trails.
            let mut fnrm = -(d.normal * vn.abs() + d.linear_normal) * vn;
            if d.facing_only && vn > 0.0 {
                fnrm = 0.0;
            }
            let ftan = -(d.tangent * vt.abs() + d.linear_tangent) * vt;
            let f = Vector2::new(-t.y * fnrm + t.x * ftan, t.x * fnrm + t.y * ftan) * (share * length);
            self.drag_f[ia] += f;
            self.drag_f[ib] += f;
        }
        self.surf = surf;
        let lim = d.max_step / dt;
        for i in 0..self.n {
            let f = self.drag_f[i];
            let limit = lim * self.mass[i] * (self.vel[i] - self.water_at(i, current)).length();
            let s = lsq(f);
            if s > limit * limit {
                self.drag_f[i] = if s > 0.0 { f * (limit / s.sqrt()) } else { Vector2::ZERO };
            }
        }
    }

    fn predict(&mut self, opt: &Opt, h: f32, first: bool) {
        if !first {
            self.finish_substep(opt, h);
        }
        if opt.drag.enabled && opt.drag_substep {
            self.apply_drag(&opt.drag, opt.current, h);
        }
        if self.damp_lin > 0.0 || self.damp_ang > 0.0 {
            self.damp_rigid(opt.current, h);
        }
        let g = opt.gravity + self.push_frame;
        for i in 0..self.n {
            let v = self.vel[i] + (g + (self.force[i] + self.drag_f[i]) * self.w[i]) * h;
            self.vel[i] = v;
            self.prev[i] = self.pos[i];
            self.pos[i] += v * h;
            self.pred[i] = self.pos[i];
            self.th_prev[i] = self.th[i];
            self.th[i] += self.om[i] * h;
        }
    }

    fn finish_substep(&mut self, opt: &Opt, h: f32) {
        let ih = 1.0 / h;
        let vmax2 = opt.max_speed * opt.max_speed;
        for i in 0..self.n {
            let mut v = self.vel[i] + (self.pos[i] - self.pred[i]) * ih;
            let s = lsq(v);
            if s > vmax2 {
                v *= opt.max_speed / s.sqrt();
            }
            self.vel[i] = v;
            self.om[i] = (self.th[i] - self.th_prev[i]) * ih;
        }
    }

    fn solve(&mut self, opt: &Opt, walls: &[StaticShape], h: f32) {
        let n = self.n;
        let inv_s = 1.0 / (opt.substeps as f32 * h * h);
        let g = opt.link_damp;
        let gb = opt.bend_damp;
        let bend_link = self.links.iter().any(|l| l.bend);
        let any_shape = self.cell_shape.iter().any(|&x| x);
        if bend_link {
            self.cs.clear();
            for i in 0..n {
                self.cs.push((self.th[i].cos(), self.th[i].sin()));
            }
        }
        {
            // The hot loop: indices come from links built over these cells, so they are in
            // range (checked once here); unchecked access saves the bounds tests.
            let pos = &mut self.pos[..];
            let prev = &self.prev[..];
            let w = &self.w[..];
            let iw = &self.iw[..];
            let th = &mut self.th[..];
            let th_prev = &self.th_prev[..];
            let cs = &mut self.cs[..];
            let shaped = &self.cell_shape[..];
            for l in self.links.iter() {
                assert!((l.i as usize) < n && (l.j as usize) < n);
            }
            for l in self.links.iter_mut() {
                let (i, j) = (l.i as usize, l.j as usize);
                unsafe {
                    // Stretch.
                    let (pi, pj) = (*pos.get_unchecked(i), *pos.get_unchecked(j));
                    let (wi, wj) = (*w.get_unchecked(i), *w.get_unchecked(j));
                    let d = pj - pi;
                    let len = d.length();
                    if len < 1e-7 {
                        continue;
                    }
                    let c = len - l.rest;
                    let ws = wi + wj;
                    let rel = dot(d, (pj - *prev.get_unchecked(j)) - (pi - *prev.get_unchecked(i))) / len;
                    let dl = -(c + g * rel) / ((1.0 + g) * ws + l.alpha);
                    let p = d * (dl / len);
                    *pos.get_unchecked_mut(j) = pj + p * wj;
                    *pos.get_unchecked_mut(i) = pi - p * wi;
                    l.f_frame += dl.abs() * inv_s;
                    if !l.bend {
                        continue;
                    }
                    // Bend: the link's angle in each end's frame.
                    for end in 0..2 {
                        let (a, b, u) = if end == 0 { (i, j, l.ui) } else { (j, i, l.uj) };
                        let (pa, pb) = (*pos.get_unchecked(a), *pos.get_unchecked(b));
                        let d = pb - pa;
                        let l2 = lsq(d);
                        if l2 < 1e-10 {
                            continue;
                        }
                        let len = l2.sqrt();
                        let (ca, sa) = *cs.get_unchecked(a);
                        let uw = rot(u, ca, sa);
                        let cerr = angle_to(uw, d, len);
                        let gp = perp(d) / l2;
                        let rel = dot(gp, (pb - *prev.get_unchecked(b)) - (pa - *prev.get_unchecked(a))) - (*th.get_unchecked(a) - *th_prev.get_unchecked(a));
                        // A shape-matched end takes its frame from its region's fit: the
                        // constraint moves the cells only (its own turn is not kept).
                        let iwa = if *shaped.get_unchecked(a) { 0.0 } else { *iw.get_unchecked(a) };
                        let (wa, wb) = (*w.get_unchecked(a), *w.get_unchecked(b));
                        let wsum = (wa + wb) / l2 + iwa;
                        let dl = -(cerr + gb * rel) / ((1.0 + gb) * wsum + l.alpha_ang);
                        *pos.get_unchecked_mut(b) = pb + gp * (dl * wb);
                        *pos.get_unchecked_mut(a) = pa - gp * (dl * wa);
                        let dth = -iwa * dl;
                        *th.get_unchecked_mut(a) += dth;
                        *cs.get_unchecked_mut(a) = (ca - sa * dth, sa + ca * dth);
                        l.t_frame += dl.abs() * inv_s;
                    }
                }
            }
        }
        if any_shape {
            let kk = opt.shape_k;
            let posed = self.wave.mode == WAVE_POSE && self.bent.len() == n;
            let mut goal: [Vector2; 32] = [Vector2::ZERO; 32];
            for ci in 0..n {
                let (s, e) = (self.sm_start[ci] as usize, self.sm_start[ci + 1] as usize);
                let m = (e - s).min(32);
                if m < 3 {
                    continue;
                }
                let centre = self.sm[s] as usize;
                // Positions relative to the cluster's own cell: in world coordinates the
                // fit's rounding (f32, sums of mass × position) drags a moving creature
                // (a blob lost a quarter of its speed in 10 s).
                let base = self.pos[centre];
                let mut qc = Vector2::ZERO;
                let mut xc = Vector2::ZERO;
                let mut ms = 0.0;
                for q in 0..m {
                    let c = self.sm[s + q] as usize;
                    let f = (self.rscale[c] * self.r0[c] + self.rscale[centre] * self.r0[centre]) / (self.r0[c] + self.r0[centre]);
                    goal[q] = if posed { (self.bent[c] - self.bent[centre]) * (self.sm_off[s + q].length() / (self.rest_local[c] - self.rest_local[centre]).length().max(1e-6)).min(4.0) } else { self.sm_off[s + q] * f };
                    qc += goal[q] * self.mass[c];
                    xc += (self.pos[c] - base) * self.mass[c];
                    ms += self.mass[c];
                }
                qc /= ms;
                xc /= ms;
                let (mut sc, mut ss) = (0.0f32, 0.0f32);
                for q in 0..m {
                    let c = self.sm[s + q] as usize;
                    goal[q] -= qc;
                    let p = self.pos[c] - base - xc;
                    sc += self.mass[c] * dot(goal[q], p);
                    ss += self.mass[c] * cross(goal[q], p);
                }
                let ll = (sc * sc + ss * ss).sqrt();
                if ll < 1e-9 {
                    continue;
                }
                let (co, si) = (sc / ll, ss / ll);
                // The cell's heading follows its neighbourhood's best-fit turn (thrust and
                // types read it; shape matching has no spin of its own); under the pose wave
                // the fit is against the bent pose, whose own turn at the cell is added (the
                // links' rest angles expect it).
                // Kept continuous: a jump of a whole turn would read as a spin in the bend
                // constraints' damping.
                let target = ss.atan2(sc) + if posed && self.bent_turn.len() == n { self.bent_turn[centre] } else { 0.0 };
                self.th[centre] += wrap(target - self.th[centre]);
                for q in 0..m {
                    let c = self.sm[s + q] as usize;
                    let gp = xc + rot(goal[q], co, si);
                    let here = self.pos[c] - base;
                    self.pos[c] += (gp - here) * kk;
                }
            }
        }
        for &(c, wi) in &self.wall_c {
            let c = c as usize;
            let p = push_out_of_wall(&walls[wi as usize], self.prev[c], self.pos[c], self.r[c]);
            if p != self.pos[c] {
                self.pos[c] = p;
                self.contact = true;
            }
        }
        for &(a, b) in &self.self_c {
            let (a, b) = (a as usize, b as usize);
            let d = self.pos[b] - self.pos[a];
            let l2 = lsq(d);
            let reach = self.r[a] + self.r[b];
            if l2 >= reach * reach || l2 < 1e-12 {
                continue;
            }
            let l = l2.sqrt();
            let pen = reach - l;
            let ws = self.w[a] + self.w[b];
            let p = d * (pen / (l * ws));
            self.pos[a] -= p * self.w[a];
            self.pos[b] += p * self.w[b];
        }
    }

    /// The frame's end: velocities, link loads and the links that break.
    fn finish(&mut self, opt: &Opt, h: f32, dt: f32) {
        self.finish_substep(opt, h);
        self.broken.clear();
        let a = (dt / opt.break_smooth.max(1e-6)).min(1.0);
        let decay = (-dt / opt.break_envelope_time.max(1e-6)).exp();
        let free = !self.contact;
        for (k, l) in self.links.iter_mut().enumerate() {
            let f = l.f_frame + opt.break_torque * l.t_frame / l.rest.max(1e-3);
            l.load += (f - l.load) * a;
            // The creature's own share: the envelope of the loads while it touched nothing.
            if free {
                l.env = l.load.max(l.env * decay);
            }
            if opt.break_force.is_finite() {
                let (ti, tj) = (&opt.types[self.typ[l.i as usize] as usize], &opt.types[self.typ[l.j as usize] as usize]);
                let test = if opt.break_excess { l.load - opt.break_envelope_scale * l.env } else { l.load };
                if test > opt.break_force * ti.brk.min(tj.brk) {
                    self.broken.push(k as u32);
                }
            }
        }
    }
}

fn par_bodies<F: Fn(&mut Body) + Sync + Send>(pool: &Option<rayon::ThreadPool>, bodies: &mut [Body], f: F) {
    match pool {
        Some(pool) => pool.install(|| bodies.par_iter_mut().filter(|b| b.alive).for_each(|b| f(b))),
        None => bodies.iter_mut().filter(|b| b.alive).for_each(|b| f(b)),
    }
}

fn two_mut<T>(v: &mut [T], a: usize, b: usize) -> (&mut T, &mut T) {
    assert!(a != b);
    if a < b {
        let (l, r) = v.split_at_mut(b);
        (&mut l[a], &mut r[0])
    } else {
        let (l, r) = v.split_at_mut(a);
        (&mut r[0], &mut l[b])
    }
}

/// The contact radius of cell i of a body against other creatures.
#[inline]
fn contact_radius(b: &Body, i: usize, opt: &Opt) -> f32 {
    let r = b.r[i];
    let pad = if b.boundary[i] { opt.contact_pad * r } else { 0.0 };
    r + pad + opt.types[b.typ[i] as usize].pad
}

fn solve_cross(bodies: &mut [Body], cr: &[Cross], opt: &Opt, h: f32) {
    let kc = if opt.contact_hz > 0.0 {
        let w = std::f32::consts::TAU * opt.contact_hz * h;
        1.0 / (w * w)
    } else {
        0.0
    };
    for x in cr {
        let (a, b) = two_mut(bodies, x.a as usize, x.b as usize);
        let ai = x.ai as usize;
        if !x.edge {
            let bi = x.bi as usize;
            let d = b.pos[bi] - a.pos[ai];
            let l2 = lsq(d);
            let reach = contact_radius(a, ai, opt) + contact_radius(b, bi, opt);
            if l2 >= reach * reach || l2 < 1e-12 {
                continue;
            }
            let l = l2.sqrt();
            let pen = reach - l;
            let ws = a.w[ai] + b.w[bi];
            let p = d * (pen / (l * ws * (1.0 + kc)));
            a.pos[ai] -= p * a.w[ai];
            b.pos[bi] += p * b.w[bi];
            a.contact = true;
            b.contact = true;
        } else {
            let m = b.outline.len();
            let e = x.bi as usize;
            let (p, q) = (b.outline[e] as usize, b.outline[(e + 1) % m] as usize);
            let (pp, pq) = (b.pos[p], b.pos[q]);
            let ab = pq - pp;
            let t = (dot(a.pos[ai] - pp, ab) / lsq(ab).max(1e-9)).clamp(0.0, 1.0);
            let cpt = pp + ab * t;
            let rr = b.r[p] + (b.r[q] - b.r[p]) * t;
            let d = a.pos[ai] - cpt;
            let l2 = lsq(d);
            let reach = contact_radius(a, ai, opt) + rr;
            if l2 >= reach * reach || l2 < 1e-12 {
                continue;
            }
            let l = l2.sqrt();
            let nrm = d / l;
            let pen = reach - l;
            let we = (1.0 - t) * (1.0 - t) * b.w[p] + t * t * b.w[q];
            let dl = pen / ((a.w[ai] + we) * (1.0 + kc));
            a.pos[ai] += nrm * (dl * a.w[ai]);
            b.pos[p] -= nrm * (dl * (1.0 - t) * b.w[p]);
            b.pos[q] -= nrm * (dl * t * b.w[q]);
            a.contact = true;
            b.contact = true;
        }
    }
}

impl Body {
    /// A new body from some of this one's cells (in order), with the links among them.
    fn extract(&self, cells: &[usize]) -> Body {
        let mut map = vec![u32::MAX; self.n];
        for (k, &c) in cells.iter().enumerate() {
            map[c] = k as u32;
        }
        let mut b = Body { alive: true, n: cells.len(), wave: self.wave, time: self.time, swim: self.swim, damp_lin: self.damp_lin, damp_ang: self.damp_ang, ..Default::default() };
        macro_rules! take {
            ($f:ident) => {
                b.$f = cells.iter().map(|&c| self.$f[c]).collect();
            };
        }
        take!(pos);
        take!(prev);
        take!(pred);
        take!(vel);
        take!(th);
        take!(th_prev);
        take!(om);
        take!(r0);
        take!(scale);
        take!(rscale);
        take!(r);
        take!(mass);
        take!(w);
        take!(iw);
        take!(typ);
        take!(group);
        take!(uid);
        take!(ease);
        take!(force);
        take!(user_force);
        take!(thrust);
        take!(thrust_angle);
        take!(muscle);
        take!(rest_local);
        b.drag_f = vec![Vector2::ZERO; b.n];
        b.muscles_set = self.muscles_set;
        if self.water.len() == self.n {
            take!(water);
        }
        b.current = self.current;
        b.has_current = self.has_current;
        b.joint_angles = self.joint_angles.clone();
        b.regions_built = u32::MAX;
        for l in &self.links {
            let (i, j) = (map[l.i as usize], map[l.j as usize]);
            if i != u32::MAX && j != u32::MAX {
                let mut nl = *l;
                nl.i = i;
                nl.j = j;
                b.links.push(nl);
            }
        }
        b
    }

    /// Connected parts by links, each a sorted list of cells, the one holding cell 0 first.
    fn components(&self) -> Vec<Vec<usize>> {
        let n = self.n;
        let mut parent: Vec<usize> = (0..n).collect();
        fn find(p: &mut [usize], x: usize) -> usize {
            let mut x = x;
            while p[x] != x {
                p[x] = p[p[x]];
                x = p[x];
            }
            x
        }
        for l in &self.links {
            let (a, b) = (find(&mut parent, l.i as usize), find(&mut parent, l.j as usize));
            if a != b {
                let (lo, hi) = if a < b { (a, b) } else { (b, a) };
                parent[hi] = lo;
            }
        }
        let mut groups: Vec<Vec<usize>> = Vec::new();
        let mut index = vec![usize::MAX; n];
        for i in 0..n {
            let r = find(&mut parent, i);
            if index[r] == usize::MAX {
                index[r] = groups.len();
                groups.push(Vec::new());
            }
            groups[index[r]].push(i);
        }
        groups
    }

    /// The design position of a world point, in this body's design frame (its pose now).
    fn design_of(&self, p: Vector2) -> Vector2 {
        self.design_map()(p)
    }

    /// The map from world points to this body's design frame (its pose now), built once.
    fn design_map(&self) -> impl Fn(Vector2) -> Vector2 {
        let c = self.center();
        let t = self.turn_against_rest();
        let rc = {
            let mut m = 0.0;
            let mut s = Vector2::ZERO;
            for i in 0..self.n {
                s += self.rest_local[i] * self.mass[i];
                m += self.mass[i];
            }
            s / if m > 0.0 { m } else { 1.0 }
        };
        let (co, si) = (t.cos(), t.sin());
        move |p: Vector2| rc + rot(p - c, co, -si)
    }

    fn recentre_design(&mut self) {
        let mut m = 0.0;
        let mut s = Vector2::ZERO;
        for i in 0..self.n {
            s += self.rest_local[i] * self.mass[i];
            m += self.mass[i];
        }
        let s = s / if m > 0.0 { m } else { 1.0 };
        for p in self.rest_local.iter_mut() {
            *p -= s;
        }
    }
}

impl Cells {
    /// The threads the step uses; 0: chosen every step from the live cells and creatures
    /// (auto_threads()).
    pub fn set_threads(&mut self, threads: usize) {
        self.opt.threads = threads;
        if threads > 0 {
            self.use_threads(threads);
        }
    }

    /// The threads the step runs on now.
    pub fn threads_in_use(&self) -> usize {
        self.pool_threads
    }

    fn use_threads(&mut self, threads: usize) {
        let threads = threads.max(1);
        if threads == self.pool_threads {
            return;
        }
        if let Some(p) = self.pool.take() {
            self.spare_pools.push(p);
        }
        self.pool_threads = threads;
        self.pool = if threads > 1 {
            match self.spare_pools.iter().position(|p| p.current_num_threads() == threads) {
                Some(k) => Some(self.spare_pools.swap_remove(k)),
                None => rayon::ThreadPoolBuilder::new().num_threads(threads).build().ok(),
            }
        } else {
            None
        };
    }

    /// threads = 0's choice: by the live cells (AUTO_THREADS, measured: docs/cells.md,
    /// "Threads"), at most one per live creature (creatures are what run in parallel) and
    /// the machine's cores.
    pub fn auto_threads(cells: usize, creatures: usize, cores: usize) -> usize {
        let mut t = 1;
        for &(at, threads) in AUTO_THREADS.iter() {
            if cells >= at {
                t = threads;
            }
        }
        t.min(creatures.max(1)).min(cores.max(1))
    }

    fn for_each<F: Fn(&mut Body) + Sync + Send>(&mut self, f: F) {
        par_bodies(&self.pool, &mut self.bodies, f);
    }

    pub fn add_creature(&mut self, centers: &[Vector2], radii: &[f32], types: &[u8]) -> usize {
        self.add_creature_ex(centers, radii, types, &[], &[])
    }

    /// A creature from a design: cells, radii, types, groups (regions) and mass factors.
    pub fn add_creature_ex(&mut self, centers: &[Vector2], radii: &[f32], types: &[u8], groups: &[u16], masses: &[f32]) -> usize {
        let t = Instant::now();
        let mut b = Body::new_ex(centers, radii, types, groups, masses, self.opt.density, self.next_uid);
        self.next_uid += b.n as u32;
        b.build_links(&self.opt);
        b.set_colliders(self.opt.collide_all);
        self.stats.build_us = t.elapsed().as_micros() as u64;
        self.bodies.push(b);
        self.update_grid_cell();
        self.bodies.len() - 1
    }

    fn update_grid_cell(&mut self) {
        let mut rmax = 1.0f32;
        for b in self.bodies.iter().filter(|b| b.alive) {
            for &r in &b.r0 {
                rmax = rmax.max(r);
            }
        }
        // A disc's neighbours within reach (muscles up to 1.5×, pads).
        self.grid_cell = rmax * (3.0 + 2.0 * self.opt.contact_pad) + self.opt.margin;
    }

    pub fn refresh_colliders(&mut self) {
        let all = self.opt.collide_all;
        for b in self.bodies.iter_mut() {
            b.set_colliders(all);
        }
        self.update_grid_cell();
    }

    /// A convex wall in global space (an id of its own, negative).
    pub fn add_wall(&mut self, pts: &[Vector2]) {
        if pts.len() < 3 {
            return;
        }
        let id = self.next_wall_id;
        self.next_wall_id -= 1;
        self.statics.push(StaticShape::new(id, Transform2D::IDENTITY, pts.to_vec(), 0.0, 0.0, false));
    }

    /// GooStatics' interface (as GooKernel's): a convex polygon in `xform`'s space.
    pub fn add_static_shape(&mut self, id: i64, xform: Transform2D, pts: Vec<Vector2>, friction: f32, bounce: f32, grip: bool) {
        self.statics.retain(|s| s.id != id);
        self.statics.push(StaticShape::new(id, xform, pts, friction, bounce, grip));
    }

    pub fn set_static_transform(&mut self, id: i64, xform: Transform2D) {
        for s in self.statics.iter_mut().filter(|s| s.id == id) {
            s.set_transform(xform);
        }
    }

    pub fn remove_static_shape(&mut self, id: i64) {
        self.statics.retain(|s| s.id != id);
    }

    pub fn clear_static_shapes(&mut self) {
        self.statics.clear();
    }

    pub fn step(&mut self, dt: f32) {
        let t0 = Instant::now();
        if self.opt.threads == 0 {
            let live = self.bodies.iter().filter(|b| b.alive);
            let (cells, creatures) = live.fold((0, 0), |(c, k), b| (c + b.n, k + 1));
            let cores = std::thread::available_parallelism().map(|x| x.get()).unwrap_or(1);
            self.use_threads(Cells::auto_threads(cells, creatures, cores));
        }
        let opt = self.opt.clone();
        let cell = self.grid_cell;
        {
            let walls = &self.statics;
            par_bodies(&self.pool, &mut self.bodies, |b| {
                b.prepare(&opt, dt, walls, cell);
                b.prepare_dynamic(&opt, dt, walls);
            });
        }
        let t1 = Instant::now();
        let nb = self.bodies.len();
        let mut pairs: Vec<(u32, u32)> = Vec::new();
        let pad = 1.0 + opt.contact_pad;
        for a in 0..nb {
            if !self.bodies[a].alive {
                continue;
            }
            for b in (a + 1)..nb {
                let (x, y) = (&self.bodies[a], &self.bodies[b]);
                if !y.alive {
                    continue;
                }
                let m = opt.margin + (x.vmax + y.vmax) * dt + 32.0 * opt.contact_pad;
                if x.hi.x + m < y.lo.x || y.hi.x + m < x.lo.x || x.hi.y + m < y.lo.y || y.hi.y + m < x.lo.y {
                    continue;
                }
                pairs.push((a as u32, b as u32));
            }
        }
        let bodies = &self.bodies;
        let find = |&(a, b): &(u32, u32)| -> Vec<Cross> {
            let mut out = Vec::new();
            let mut near = Vec::new();
            let m = opt.margin + (bodies[a as usize].vmax + bodies[b as usize].vmax) * dt;
            for (sa, sb) in [(a, b), (b, a)] {
                if !opt.capsules && sa != a {
                    break;
                }
                let (x, y) = (&bodies[sa as usize], &bodies[sb as usize]);
                for &c in &x.colliders {
                    if !opt.types[x.typ[c as usize] as usize].collide {
                        continue;
                    }
                    let p = x.pos[c as usize];
                    let rc = x.r[c as usize] * pad;
                    if p.x + rc + m < y.lo.x || p.x - rc - m > y.hi.x || p.y + rc + m < y.lo.y || p.y - rc - m > y.hi.y {
                        continue;
                    }
                    near.clear();
                    if opt.capsules {
                        grid_query(&y.egrid, key(p.x, p.y, cell), &mut near);
                        near.sort_unstable();
                        let ml = y.outline.len();
                        for &e in &near {
                            let (q0, q1) = (y.outline[e as usize] as usize, y.outline[(e as usize + 1) % ml] as usize);
                            let (pp, pq) = (y.pos[q0], y.pos[q1]);
                            let ab = pq - pp;
                            let t = (dot(p - pp, ab) / lsq(ab).max(1e-9)).clamp(0.0, 1.0);
                            let rr = y.r[q0].max(y.r[q1]);
                            let reach = rc + rr + m;
                            if lsq(p - (pp + ab * t)) < reach * reach {
                                out.push(Cross { a: sa, ai: c, b: sb, bi: e, edge: true });
                            }
                        }
                    } else {
                        grid_query(&y.grid, key(p.x, p.y, cell), &mut near);
                        near.sort_unstable();
                        for &o in &near {
                            let d = y.colliders[o as usize];
                            if !opt.types[y.typ[d as usize] as usize].collide {
                                continue;
                            }
                            let reach = rc + y.r[d as usize] * pad + m;
                            if lsq(y.pos[d as usize] - p) < reach * reach {
                                out.push(Cross { a: sa, ai: c, b: sb, bi: d, edge: false });
                            }
                        }
                    }
                }
            }
            out
        };
        let lists: Vec<Vec<Cross>> = match &self.pool {
            Some(pool) => pool.install(|| pairs.par_iter().map(find).collect()),
            None => pairs.iter().map(find).collect(),
        };
        self.cross.clear();
        for l in lists {
            self.cross.extend(l);
        }
        if self.ghosts.on {
            self.ghosts.broad(&self.bodies, &opt, dt, cell);
        }
        let t2 = Instant::now();
        let h = dt / opt.substeps as f32;
        let mut solve_us = 0u64;
        let mut serial_us = 0u64;
        self.begin_dynamic();
        for s in 0..opt.substeps {
            let ta = Instant::now();
            self.move_dynamic(s, opt.substeps, h);
            {
                let walls = &self.statics;
                par_bodies(&self.pool, &mut self.bodies, |b| {
                    b.predict(&opt, h, s == 0);
                    b.solve(&opt, walls, h);
                    b.solve_dynamic(walls, h);
                });
            }
            let tb = Instant::now();
            for _ in 0..opt.contact_iters.max(1) {
                solve_cross(&mut self.bodies, &self.cross, &opt, h);
            }
            if self.ghosts.on {
                self.ghosts.substep(&mut self.bodies, &opt, &self.statics, h);
            }
            solve_us += (tb - ta).as_micros() as u64;
            serial_us += tb.elapsed().as_micros() as u64;
        }
        self.end_dynamic();
        let t3 = Instant::now();
        self.for_each(|b| b.finish(&opt, h, dt));
        let t4 = Instant::now();
        self.apply_breaks();
        let t5 = Instant::now();
        self.frame += 1;
        self.stats.prep_us = (t1 - t0).as_micros() as u64;
        self.stats.broad_us = (t2 - t1).as_micros() as u64;
        self.stats.solve_us = solve_us;
        self.stats.serial_us = serial_us;
        self.stats.vel_us = (t4 - t3).as_micros() as u64;
        self.stats.topo_us = (t5 - t4).as_micros() as u64;
        self.stats.total_us = (t5 - t0).as_micros() as u64;
        self.stats.cross_pairs = self.cross.len();
        self.stats.wall_pairs = self.bodies.iter().map(|b| b.wall_c.len()).sum();
        self.stats.self_pairs = self.bodies.iter().map(|b| b.self_c.len()).sum();
        self.stats.links = self.bodies.iter().filter(|b| b.alive).map(|b| b.links.len()).sum();
    }

    /// Links past their break force removed (parted events), broken creatures split.
    fn apply_breaks(&mut self) {
        let nb = self.bodies.len();
        for c in 0..nb {
            if !self.bodies[c].alive || self.bodies[c].broken.is_empty() {
                continue;
            }
            let b = &mut self.bodies[c];
            let mut gone = vec![false; b.links.len()];
            for &k in &b.broken {
                gone[k as usize] = true;
            }
            let mut kept = Vec::with_capacity(b.links.len());
            for (k, l) in b.links.iter().enumerate() {
                if gone[k] {
                    self.events.push([EVENT_PARTED, c as i32, b.uid[l.i as usize] as i32, b.uid[l.j as usize] as i32]);
                } else {
                    kept.push(*l);
                }
            }
            b.links = kept;
            b.broken.clear();
            self.split_if_needed(c);
        }
    }

    /// Splits creature c into its connected parts: the part holding cell 0 stays.
    pub fn split_if_needed(&mut self, c: usize) {
        let groups = self.bodies[c].components();
        if groups.len() <= 1 {
            let all = self.opt.collide_all;
            let b = &mut self.bodies[c];
            b.after_topology();
            b.set_colliders(all);
            return;
        }
        let parent = std::mem::take(&mut self.bodies[c]);
        let all = self.opt.collide_all;
        for (gi, g) in groups.iter().enumerate() {
            let mut nb = parent.extract(g);
            nb.recentre_design();
            nb.after_topology();
            nb.set_colliders(all);
            if gi == 0 {
                self.bodies[c] = nb;
            } else {
                self.bodies.push(nb);
                self.events.push([EVENT_SPLIT, c as i32, (self.bodies.len() - 1) as i32, g.len() as i32]);
            }
        }
    }

    /// Pairs of cells within `capture` px of touching that may join: (a, ia, b, ib), sorted;
    /// across creatures, and within one when `same` (unlinked, sharing no neighbour).
    pub fn find_captures(&self, capture: f32, same: bool) -> Vec<[u32; 4]> {
        let opt = &self.opt;
        let mut out = Vec::new();
        let nb = self.bodies.len();
        let ok = |ta: u8, tb: u8| (opt.types[ta as usize].join_mask >> tb) & 1 == 1 && (opt.types[tb as usize].join_mask >> ta) & 1 == 1;
        let cell = self.grid_cell + capture;
        let grids: Vec<Vec<(u64, u32)>> = self
            .bodies
            .iter()
            .map(|b| {
                let mut g: Vec<(u64, u32)> = if b.alive { (0..b.n).filter(|&i| b.boundary[i]).map(|i| (pack(key(b.pos[i].x, b.pos[i].y, cell)), i as u32)).collect() } else { Vec::new() };
                g.sort_unstable();
                g
            })
            .collect();
        let mut near = Vec::new();
        for a in 0..nb {
            let x = &self.bodies[a];
            if !x.alive {
                continue;
            }
            for b in a..nb {
                let y = &self.bodies[b];
                if !y.alive || (b == a && !same) {
                    continue;
                }
                if b != a && (x.hi.x + capture < y.lo.x || y.hi.x + capture < x.lo.x || x.hi.y + capture < y.lo.y || y.hi.y + capture < x.lo.y) {
                    continue;
                }
                for i in 0..x.n {
                    if !x.boundary[i] {
                        continue;
                    }
                    near.clear();
                    grid_query(&grids[b], key(x.pos[i].x, x.pos[i].y, cell), &mut near);
                    near.sort_unstable();
                    for &j in &near {
                        let j = j as usize;
                        if b == a && (j <= i || x.near(i, j)) {
                            continue;
                        }
                        let gap = (y.pos[j] - x.pos[i]).length() - x.r[i] - y.r[j];
                        if gap < capture && ok(x.typ[i], y.typ[j]) {
                            out.push([a as u32, i as u32, b as u32, j as u32]);
                        }
                    }
                }
            }
        }
        out
    }

    /// Joins pairs (as find_captures gives them): a link at the current geometry each,
    /// creatures merged (the second into the first; its slot dies). Returns links made.
    pub fn join(&mut self, pairs: &[[u32; 4]]) -> usize {
        let nb = self.bodies.len();
        // Where each creature's cells live now: (creature, offset).
        let mut home: Vec<(usize, usize)> = (0..nb).map(|c| (c, 0)).collect();
        let mut touched = Vec::new();
        let mut made = 0;
        for p in pairs {
            let (a0, ia0, b0, ib0) = (p[0] as usize, p[1] as usize, p[2] as usize, p[3] as usize);
            if a0 >= nb || b0 >= nb {
                continue;
            }
            let (a, oa) = home[a0];
            let (b, ob) = home[b0];
            let (ia, mut ib) = (ia0 + oa, ib0 + ob);
            if !self.bodies[a].alive || !self.bodies[b].alive || ia >= self.bodies[a].n || ib >= self.bodies[b].n {
                continue;
            }
            if a != b {
                // Merge b into a.
                let other = std::mem::take(&mut self.bodies[b]);
                let off = self.bodies[a].n;
                let map = self.bodies[a].design_map();
                let design: Vec<Vector2> = other.pos.iter().map(|&q| map(q)).collect();
                let all: Vec<usize> = (0..other.n).collect();
                let mut ex = other.extract(&all);
                ex.rest_local = design;
                let x = &mut self.bodies[a];
                macro_rules! app {
                    ($f:ident) => {
                        x.$f.extend(ex.$f.iter().cloned());
                    };
                }
                app!(pos);
                app!(prev);
                app!(pred);
                app!(vel);
                app!(th);
                app!(th_prev);
                app!(om);
                app!(r0);
                app!(scale);
                app!(rscale);
                app!(r);
                app!(mass);
                app!(w);
                app!(iw);
                app!(typ);
                app!(group);
                app!(uid);
                app!(ease);
                app!(force);
                app!(user_force);
                app!(thrust);
                app!(thrust_angle);
                app!(muscle);
                app!(rest_local);
                for l in &ex.links {
                    let mut nl = *l;
                    nl.i += off as u32;
                    nl.j += off as u32;
                    x.links.push(nl);
                }
                x.n += ex.n;
                x.drag_f = vec![Vector2::ZERO; x.n];
                // Water per cell is the game's to feed again (each frame); joint angles
                // of the creature merged in join the first's where it has none.
                x.water.clear();
                for ja in &ex.joint_angles {
                    if !x.joint_angles.iter().any(|y| y.0 == ja.0 && y.1 == ja.1) {
                        x.joint_angles.push(*ja);
                    }
                }
                for h in home.iter_mut() {
                    if h.0 == b {
                        *h = (a, h.1 + off);
                    }
                }
                self.bodies[b].alive = false;
                ib += off;
            }
            let x = &mut self.bodies[a];
            if ia == ib || x.links.iter().any(|l| (l.i as usize == ia && l.j as usize == ib) || (l.i as usize == ib && l.j as usize == ia)) {
                continue;
            }
            let d = (x.pos[ib] - x.pos[ia]).length();
            let l = x.make_link(ia, ib, d);
            x.links.push(l);
            made += 1;
            self.events.push([EVENT_JOINED, a as i32, x.uid[ia] as i32, x.uid[ib] as i32]);
            if !touched.contains(&a) {
                touched.push(a);
            }
        }
        let all = self.opt.collide_all;
        for &a in &touched {
            let x = &mut self.bodies[a];
            x.planarize();
            x.recentre_design();
            x.after_topology();
            x.set_colliders(all);
        }
        self.update_grid_cell();
        made
    }

    /// A cell added to creature c at a world point, linked to the cells it would touch at its
    /// full size, growing in over ease_time. Returns its index.
    pub fn add_cell(&mut self, c: usize, at: Vector2, radius: f32, typ: u8) -> usize {
        self.add_cell_ex(c, at, radius, typ, 0, 1.0)
    }

    /// add_cell() with the cell's group and mass factor.
    pub fn add_cell_ex(&mut self, c: usize, at: Vector2, radius: f32, typ: u8, group: u16, mass: f32) -> usize {
        let opt = self.opt.clone();
        let uid = self.next_uid;
        self.next_uid += 1;
        let b = &mut self.bodies[c];
        let design = b.design_of(at);
        b.push_cell(at, radius.max(0.5), typ, opt.density * mass.max(1e-3), uid);
        let last = b.group.len() - 1;
        b.group[last] = group;
        b.rest_local.push(design);
        b.drag_f.push(Vector2::ZERO);
        b.n += 1;
        b.water.clear();
        let k = b.n - 1;
        b.ease[k] = opt.ease_time;
        b.scale[k] = opt.ease_from;
        b.r[k] = b.r0[k] * opt.ease_from;
        b.th[k] = b.turn_against_rest();
        b.th_prev[k] = b.th[k];
        // Its velocity: its neighbours' mean, so it arrives without a kick.
        let mut vs = Vector2::ZERO;
        let mut cnt = 0.0;
        for j in 0..k {
            let d = (b.pos[j] - at).length();
            if d <= (b.r0[j] + radius) * opt.link_tol {
                let mut l = b.make_link(j, k, b.r0[j] + radius);
                l.d_base = b.r0[j] + radius;
                l.d_design = l.d_base;
                l.d_from = d;
                b.links.push(l);
                vs += b.vel[j];
                cnt += 1.0;
            }
        }
        if cnt > 0.0 {
            b.vel[k] = vs / cnt;
        }
        b.planarize();
        b.after_topology();
        b.set_colliders(opt.collide_all);
        self.update_grid_cell();
        k
    }

    /// Removes creature c (its slot stays, dead); no events.
    pub fn remove_creature(&mut self, c: usize) {
        if let Some(b) = self.bodies.get_mut(c) {
            *b = Body::default();
        }
    }

    /// Removes cell i of creature c (its links' parted events), splitting what falls apart.
    pub fn remove_cell(&mut self, c: usize, i: usize) {
        let b = &mut self.bodies[c];
        if i >= b.n {
            return;
        }
        let keep: Vec<usize> = (0..b.n).filter(|&k| k != i).collect();
        for l in &b.links {
            if l.i as usize == i || l.j as usize == i {
                self.events.push([EVENT_PARTED, c as i32, b.uid[l.i as usize] as i32, b.uid[l.j as usize] as i32]);
            }
        }
        let mut nb = b.extract(&keep);
        nb.push = b.push;
        nb.twist = b.twist;
        *b = nb;
        if b.n == 0 {
            b.alive = false;
            return;
        }
        self.split_if_needed(c);
    }

    /// Linear momentum (x, y) and angular momentum about the origin (orbits and spins).
    pub fn momentum(&self) -> [f64; 3] {
        let (mut px, mut py, mut l) = (0.0f64, 0.0f64, 0.0f64);
        for b in self.bodies.iter().filter(|b| b.alive) {
            for i in 0..b.n {
                let m = b.mass[i] as f64;
                px += m * b.vel[i].x as f64;
                py += m * b.vel[i].y as f64;
                l += m * (b.pos[i].x as f64 * b.vel[i].y as f64 - b.pos[i].y as f64 * b.vel[i].x as f64) + (0.5 * b.mass[i] * b.r0[i] * b.r0[i]) as f64 * b.om[i] as f64;
            }
        }
        [px, py, l]
    }

    pub fn state_hash(&self) -> i64 {
        let mut h: u64 = 0xcbf29ce484222325;
        for b in self.bodies.iter().filter(|b| b.alive) {
            for i in 0..b.n {
                for v in [b.pos[i].x, b.pos[i].y, b.vel[i].x, b.vel[i].y, b.th[i]] {
                    h ^= v.to_bits() as u64;
                    h = h.wrapping_mul(0x100000001b3);
                }
            }
            h ^= b.links.len() as u64;
            h = h.wrapping_mul(0x100000001b3);
        }
        h as i64
    }

    /// [cross overlap max (px, any two cells of different creatures), cells whose centre is
    /// inside another creature's outline, self overlap max (unlinked cells of one creature),
    /// strain max, shape err max, shape err mean, wall overlap max, not finite count]
    pub fn health(&self) -> [f32; 8] {
        let mut cross_max = 0.0f32;
        let mut inside = 0.0f32;
        let mut self_max = 0.0f32;
        let mut strain_max = 0.0f32;
        let mut err_max = 0.0f32;
        let mut err_sum = 0.0f32;
        let mut wall_max = 0.0f32;
        let mut bad = 0.0f32;
        let nb = self.bodies.len();
        let cell = self.grid_cell;
        let grids: Vec<Vec<(u64, u32)>> = self
            .bodies
            .iter()
            .map(|b| {
                let mut g: Vec<(u64, u32)> = if b.alive { (0..b.n).map(|i| (pack(key(b.pos[i].x, b.pos[i].y, cell)), i as u32)).collect() } else { Vec::new() };
                g.sort_unstable();
                g
            })
            .collect();
        let polys: Vec<Vec<Vector2>> = self.bodies.iter().map(|b| b.outline.iter().map(|&c| b.pos[c as usize]).collect()).collect();
        let mut near = Vec::new();
        let mut alive_n = 0;
        for a in 0..nb {
            let x = &self.bodies[a];
            if !x.alive {
                continue;
            }
            alive_n += 1;
            for l in &x.links {
                let len = (x.pos[l.j as usize] - x.pos[l.i as usize]).length();
                strain_max = strain_max.max((len / l.rest.max(1e-3) - 1.0).abs());
            }
            let e = x.shape_error();
            err_max = err_max.max(e);
            err_sum += e;
            for i in 0..x.n {
                let p = x.pos[i];
                if !p.x.is_finite() || !p.y.is_finite() {
                    bad += 1.0;
                    continue;
                }
                near.clear();
                grid_query(&grids[a], key(p.x, p.y, cell), &mut near);
                for &o in &near {
                    let o = o as usize;
                    if o <= i || x.linked(i, o) {
                        continue;
                    }
                    let d = x.r[i] + x.r[o] - (x.pos[o] - p).length();
                    self_max = self_max.max(d);
                }
                for w in &self.statics {
                    let (d, _) = wall_distance(w, p);
                    wall_max = wall_max.max(x.r[i] - d);
                }
            }
            for b in 0..nb {
                let y = &self.bodies[b];
                if b == a || !y.alive {
                    continue;
                }
                if x.hi.x < y.lo.x || y.hi.x < x.lo.x || x.hi.y < y.lo.y || y.hi.y < x.lo.y {
                    continue;
                }
                for i in 0..x.n {
                    let p = x.pos[i];
                    if b > a {
                        near.clear();
                        grid_query(&grids[b], key(p.x, p.y, cell), &mut near);
                        for &o in &near {
                            let d = x.r[i] + y.r[o as usize] - (y.pos[o as usize] - p).length();
                            cross_max = cross_max.max(d);
                        }
                    }
                    if polys[b].len() >= 3 && point_in_polygon(p, &polys[b]) {
                        inside += 1.0;
                    }
                }
            }
        }
        [cross_max, inside, self_max, strain_max, err_max, err_sum / alive_n.max(1) as f32, wall_max, bad]
    }

    /// The creature whose outline (its boundary cells pushed out by their radii) holds
    /// `p`, the last such slot (drawn on top); -1 for none.
    pub fn creature_at(&self, p: Vector2) -> i64 {
        let mut found = -1;
        let mut surf = Vec::new();
        for (c, b) in self.bodies.iter().enumerate() {
            if !b.alive || b.n == 0 {
                continue;
            }
            let rmax = b.r.iter().cloned().fold(0.0, f32::max);
            let (mut lo, mut hi) = (b.pos[0], b.pos[0]);
            for &q in &b.pos {
                lo = Vector2::new(lo.x.min(q.x), lo.y.min(q.y));
                hi = Vector2::new(hi.x.max(q.x), hi.y.max(q.y));
            }
            if p.x < lo.x - rmax || p.x > hi.x + rmax || p.y < lo.y - rmax || p.y > hi.y + rmax {
                continue;
            }
            b.outline_surface(&mut surf);
            let inside = if surf.len() >= 3 { point_in_polygon(p, &surf) } else { false };
            if inside || (0..b.n).any(|i| lsq(b.pos[i] - p) <= b.r[i] * b.r[i]) {
                found = c as i64;
            }
        }
        found
    }

    /// The cell of creature c nearest `p` within `reach` px of its disc; -1 for none.
    pub fn cell_at(&self, c: usize, p: Vector2, reach: f32) -> i64 {
        let Some(b) = self.bodies.get(c) else { return -1 };
        let mut best = -1;
        let mut bd = f32::INFINITY;
        for i in 0..b.n {
            let d = (b.pos[i] - p).length() - b.r[i];
            if d < bd && d <= reach {
                bd = d;
                best = i as i64;
            }
        }
        best
    }

    /// Every live creature's cell centres, in slot order: (points, cells per slot).
    pub fn centers_all(&self) -> (Vec<Vector2>, Vec<i32>) {
        let mut p = Vec::new();
        let mut counts = Vec::with_capacity(self.bodies.len());
        for b in &self.bodies {
            if b.alive {
                p.extend_from_slice(&b.pos);
                counts.push(b.n as i32);
            } else {
                counts.push(0);
            }
        }
        (p, counts)
    }

    /// The water's velocity per cell for every live creature, in centers_all()'s order:
    /// empty clears it (each creature's own current or the options'), one value is a
    /// current for all, else one per cell.
    pub fn set_water_all(&mut self, w: &[Vector2]) {
        let mut at = 0;
        for b in self.bodies.iter_mut() {
            if !b.alive {
                continue;
            }
            b.water.clear();
            if w.len() == 1 {
                b.water.resize(b.n, w[0]);
            } else if w.len() > 1 && at + b.n <= w.len() {
                b.water.extend_from_slice(&w[at..at + b.n]);
            }
            at += b.n;
        }
    }

    /// Every live creature's mesh (cells_draw.rs), threaded, concatenated.
    pub fn meshes_all(&self, border: bool) -> crate::cells_draw::Mesh {
        let n = self.bodies.len();
        let types = &self.opt.types;
        let f = |c: usize| if self.bodies[c].alive { crate::cells_draw::creature_mesh(&self.bodies[c], types, border) } else { crate::cells_draw::Mesh::default() };
        let parts: Vec<crate::cells_draw::Mesh> = match &self.pool {
            Some(pool) => pool.install(|| (0..n).into_par_iter().map(f).collect()),
            None => (0..n).map(f).collect(),
        };
        let mut out = crate::cells_draw::Mesh::default();
        out.reserve(parts.iter().map(|p| p.points.len()).sum(), parts.iter().map(|p| p.indices.len()).sum());
        out.lines.reserve(parts.iter().map(|p| p.lines.len()).sum());
        for part in parts {
            out.append(part);
        }
        out
    }

    /// One creature's skin: its outline surface smoothed (Chaikin, `iterations`).
    pub fn skin(&self, c: usize, iterations: usize) -> Vec<Vector2> {
        let mut s = Vec::new();
        self.bodies[c].outline_surface(&mut s);
        if s.len() < 3 {
            return s;
        }
        chaikin(&s, iterations)
    }

    /// Every creature's skin, threaded: (points, counts per creature).
    pub fn skins_all(&self, iterations: usize) -> (Vec<Vector2>, Vec<i32>) {
        let n = self.bodies.len();
        let f = |c: usize| if self.bodies[c].alive { self.skin(c, iterations) } else { Vec::new() };
        let parts: Vec<Vec<Vector2>> = match &self.pool {
            Some(pool) => pool.install(|| (0..n).into_par_iter().map(f).collect()),
            None => (0..n).map(f).collect(),
        };
        let mut p = Vec::new();
        let mut counts = Vec::new();
        for part in parts {
            counts.push(part.len() as i32);
            p.extend(part);
        }
        (p, counts)
    }
}

/// The links a design gets (pairs of cell indices): cells closer than (r_a + r_b) × tol,
/// crossing links dropped (longest first).
pub fn design_links(centers: &[Vector2], radii: &[f32], tol: f32) -> Vec<(u32, u32)> {
    let mut opt = Opt::default();
    opt.link_tol = tol;
    let mut b = Body::new(centers, radii, &[], 1.0, 0);
    b.build_links(&opt);
    b.links.iter().map(|l| (l.i, l.j)).collect()
}

#[allow(dead_code)]
/// A hex patch of `rings` rings (rings 0: one cell) of radius r, centred at `at`.
pub fn hex_design(rings: i32, r: f32, at: Vector2) -> Vec<Vector2> {
    let mut c = Vec::new();
    for q in -rings..=rings {
        for s in -rings..=rings {
            if (-q - s).abs() > rings {
                continue;
            }
            c.push(at + Vector2::new(2.0 * r * (q as f32 + s as f32 * 0.5), 2.0 * r * s as f32 * 0.866_025_4));
        }
    }
    c
}

#[allow(dead_code)]
/// A hex worm `long` cells by `wide` rows along +x, centred at `at`.
pub fn worm_design(long: i32, wide: i32, r: f32, at: Vector2) -> Vec<Vector2> {
    let mut c = Vec::new();
    for row in 0..wide {
        let y = (row as f32 - (wide - 1) as f32 * 0.5) * 2.0 * r * 0.866_025_4;
        let shift = if row % 2 == 1 { r } else { 0.0 };
        for k in 0..long {
            let x = (k as f32 - (long - 1) as f32 * 0.5) * 2.0 * r + shift;
            c.push(at + Vector2::new(x, y));
        }
    }
    c
}

#[cfg(test)]
mod tests {
    use super::*;

    fn add(cl: &mut Cells, c: Vec<Vector2>, r: f32) -> usize {
        let n = c.len();
        cl.add_creature(&c, &vec![r; n], &vec![0; n])
    }

    #[test]
    fn hex_links_and_outline() {
        let mut cl = Cells::default();
        add(&mut cl, hex_design(2, 10.0, Vector2::ZERO), 10.0);
        let b = &cl.bodies[0];
        assert_eq!(b.n, 19);
        assert_eq!(b.links.len(), 42);
        assert_eq!(b.outline.len(), 12);
    }

    #[test]
    fn rest_stays_put() {
        let mut cl = Cells::default();
        add(&mut cl, worm_design(12, 3, 7.0, Vector2::ZERO), 7.0);
        for _ in 0..120 {
            cl.step(1.0 / 60.0);
        }
        let h = cl.health();
        assert!(h[3] < 1e-3, "strain {}", h[3]);
        assert!(h[4] < 1e-3, "shape {}", h[4]);
    }

    pub fn crash_world(threads: usize) -> Cells {
        let mut cl = Cells::default();
        cl.set_threads(threads);
        cl.opt.drag.enabled = false;
        cl.opt.self_mode = SELF_FAR;
        for k in 0..6 {
            let at = Vector2::new((k % 3) as f32 * 190.0, (k / 3) as f32 * 190.0);
            let i = add(&mut cl, hex_design(3, 7.0 + k as f32, at), 7.0 + k as f32);
            let v = Vector2::new(if k % 2 == 0 { 300.0 } else { -300.0 }, 40.0 * k as f32 - 100.0);
            for c in 0..cl.bodies[i].n {
                cl.bodies[i].vel[c] = v;
            }
        }
        cl
    }

    #[test]
    fn momentum_conserved() {
        let mut cl = crash_world(1);
        cl.opt.bend_damp = 0.0;
        cl.opt.link_damp = 0.0;
        for b in cl.bodies.iter_mut() {
            b.wave = Wave { mode: WAVE_POSE, amp: 0.4, k: 0.03, omega: 6.0, axis: Vector2::new(1.0, 0.0), half_width: 20.0, bias: 0.002, envelope: 0.5, phase: 0.0, age: 1.0 };
        }
        cl.opt.tension = 2000.0;
        let m0 = cl.momentum();
        for _ in 0..240 {
            cl.step(1.0 / 60.0);
        }
        let m1 = cl.momentum();
        let vmax = cl.bodies.iter().map(|b| b.vmax).fold(0.0f32, f32::max);
        println!("momentum {:?} -> {:?}, fastest {}, health {:?}", m0, m1, vmax, cl.health());
        let scale = m0[0].abs().max(m0[1].abs()).max(1.0);
        // Linear momentum: exact up to f32 rounding (positions ~400 px); angular: position
        // based dynamics conserves it only to first order in the substep (and f32).
        assert!((m1[0] - m0[0]).abs() < 5e-3 * scale, "px {} -> {}", m0[0], m1[0]);
        assert!((m1[1] - m0[1]).abs() < 5e-3 * scale, "py {} -> {}", m0[1], m1[1]);
        assert!((m1[2] - m0[2]).abs() < 2e-2 * m0[2].abs().max(1e6), "L {} -> {}", m0[2], m1[2]);
    }

    #[test]
    fn undulation_alone_does_not_translate_without_water() {
        let mut cl = Cells::default();
        cl.opt.drag.enabled = false;
        add(&mut cl, worm_design(16, 3, 7.0, Vector2::ZERO), 7.0);
        cl.bodies[0].wave = Wave { mode: WAVE_POSE, amp: 0.8, k: std::f32::consts::TAU / 220.0, omega: std::f32::consts::TAU, axis: Vector2::new(1.0, 0.0), half_width: 10.0, bias: 0.0, envelope: 0.5, phase: 0.0, age: 1.0 };
        let c0 = cl.bodies[0].center();
        for _ in 0..240 {
            cl.step(1.0 / 60.0);
        }
        let moved = (cl.bodies[0].center() - c0).length();
        assert!(moved < 1.0, "moved {}", moved);
    }

    #[test]
    fn shape_matched_regions_swim_by_the_pose_wave() {
        // A worm 24 × 5, shape matched: one region, then a spine row of another type
        // between two strips (three regions, joint links along the worm). Both swim ahead
        // alike; a shape-matched cell's angle once left out the bent pose's turn, so the
        // joint links fought the stroke and the worm crabbed sideways.
        let swim = |strips: bool| {
            let mut cl = Cells::default();
            // GooCellWorld2D's stiffnesses.
            cl.opt.bend_mode = BEND_SHAPE;
            cl.opt.stretch_hz = 60.0;
            cl.opt.bend_hz = 40.0;
            let d = worm_design(24, 5, 7.0, Vector2::ZERO);
            let t: Vec<u8> = d.iter().map(|p| (strips && p.y.abs() < 1.0) as u8).collect();
            let c = cl.add_creature(&d, &vec![7.0; d.len()], &t);
            let length = 24.0 * 14.0;
            cl.bodies[c].wave = Wave { mode: WAVE_POSE, amp: 1.0, k: std::f32::consts::TAU / length, omega: std::f32::consts::TAU, axis: Vector2::new(1.0, 0.0), half_width: 17.0, bias: 0.0, envelope: 0.6, phase: 0.0, age: 0.0 };
            for _ in 0..120 {
                cl.step(1.0 / 60.0);
            }
            let c0 = cl.bodies[c].center();
            for _ in 0..240 {
                cl.step(1.0 / 60.0);
            }
            if strips {
                assert_eq!(cl.bodies[c].regions, 3);
            }
            cl.bodies[c].center() - c0
        };
        let (one, three) = (swim(false), swim(true));
        assert!(one.x.abs() > 40.0, "one region {:?}", one);
        assert!(three.x.abs() > 0.8 * one.x.abs(), "one {:?} three {:?}", one, three);
        assert!(three.y.abs() < 0.3 * three.x.abs(), "three regions crab: {:?}", three);
    }

    #[test]
    fn threaded_equals_serial_with_topology() {
        let run = |threads: usize| {
            let mut cl = crash_world(threads);
            cl.opt.break_force = 4.0e5;
            cl.opt.tension = 1000.0;
            for f in 0..180 {
                cl.step(1.0 / 60.0);
                if f == 60 {
                    let caps = cl.find_captures(2.0, false);
                    cl.join(&caps);
                    cl.add_cell(0, cl.bodies[0].pos[0] + Vector2::new(-14.0, 0.0), 7.0, 1);
                }
                if f == 90 {
                    cl.remove_cell(1, 3);
                }
            }
            (cl.state_hash(), cl.events.len())
        };
        let a = run(1);
        assert_eq!(a, run(4));
        assert_eq!(a, run(3));
    }

    #[test]
    fn breaking_splits() {
        let mut cl = Cells::default();
        cl.opt.drag.enabled = false;
        cl.opt.break_force = 2.0e4;
        let i = add(&mut cl, worm_design(10, 1, 7.0, Vector2::ZERO), 7.0);
        let n = cl.bodies[i].n;
        cl.bodies[i].user_force[0] = Vector2::new(-3.0e5, 0.0);
        cl.bodies[i].user_force[n - 1] = Vector2::new(3.0e5, 0.0);
        for _ in 0..30 {
            cl.step(1.0 / 60.0);
        }
        assert!(cl.events.iter().any(|e| e[0] == EVENT_PARTED));
        assert!(cl.bodies.iter().filter(|b| b.alive).count() >= 2);
        let total: usize = cl.bodies.iter().filter(|b| b.alive).map(|b| b.n).sum();
        assert_eq!(total, n);
    }

    #[test]
    fn tension_is_momentum_free_and_rounds() {
        let mut cl = Cells::default();
        cl.opt.drag.enabled = false;
        // Fixed stiff links do not round under a slight pull: the links must flow (plastic,
        // no yield), and the pull be a few % of their stiffness.
        cl.opt.tension = 3.0e5;
        cl.opt.bend_mode = BEND_NONE;
        cl.opt.plastic_yield = 0.0;
        cl.opt.plastic_rate = 2.0;
        // An L shape.
        let mut c = worm_design(12, 3, 7.0, Vector2::ZERO);
        c.extend(worm_design(3, 8, 7.0, Vector2::new(-60.0, 70.0)));
        let i = add(&mut cl, c, 7.0);
        let round = |b: &Body| {
            let p: Vec<Vector2> = b.outline.iter().map(|&k| b.pos[k as usize]).collect();
            let per = crate::geom::perimeter(&p);
            let ar = crate::geom::area(&p);
            per * per / (4.0 * std::f64::consts::PI * ar)
        };
        let r0 = round(&cl.bodies[i]);
        for _ in 0..300 {
            cl.step(1.0 / 60.0);
        }
        let r1 = round(&cl.bodies[i]);
        let m = cl.momentum();
        let mass: f32 = cl.bodies.iter().map(|b| b.total_mass()).sum();
        // Float noise only: the mean velocity stays under 0.05 px/s.
        assert!((m[0].abs() + m[1].abs()) / (mass as f64) < 0.05, "{:?}", m);
        assert!(r1 < 0.9 * r0, "roundness {} -> {}", r0, r1);
    }

    fn wall(cl: &mut Cells, pts: &[Vector2]) {
        let id = cl.statics.len() as i64 + 1;
        cl.add_static_shape(id, Transform2D::IDENTITY, pts.to_vec(), 0.0, 0.0, false);
    }

    fn rect(x: f32, y: f32, w: f32, h: f32) -> Vec<Vector2> {
        vec![Vector2::new(x, y), Vector2::new(x + w, y), Vector2::new(x + w, y + h), Vector2::new(x, y + h)]
    }

    #[test]
    fn thin_walls_and_concave_seams_are_not_tunnelled() {
        // A 4 px wall, and an L of two convex pieces whose inner corner is a seam.
        let mut crossed = 0;
        for k in 0..12 {
            let mut cl = Cells::default();
            cl.opt.drag.enabled = false;
            wall(&mut cl, &rect(100.0, -500.0, 4.0, 1000.0));
            wall(&mut cl, &rect(-300.0, 200.0, 400.0, 30.0));
            wall(&mut cl, &rect(70.0, -100.0, 30.0, 300.0));
            let c = add(&mut cl, hex_design(1, 7.0, Vector2::ZERO), 7.0);
            let a = -1.2 + 0.2 * k as f32;
            let v = Vector2::new(a.cos(), a.sin() + 0.6) * 3000.0;
            for i in 0..cl.bodies[c].n {
                cl.bodies[c].vel[i] = v;
            }
            for _ in 0..30 {
                cl.step(1.0 / 60.0);
                let b = &cl.bodies[c];
                crossed += (0..b.n).filter(|&i| b.pos[i].x > 104.0 || b.pos[i].y > 230.0).count();
            }
            assert!(cl.health()[6] < 1.0, "wall overlap {}", cl.health()[6]);
        }
        assert_eq!(crossed, 0);
    }

    #[test]
    fn a_moving_wall_pushes_cells() {
        let mut cl = Cells::default();
        wall(&mut cl, &rect(-100.0, -100.0, 20.0, 200.0));
        let c = add(&mut cl, hex_design(1, 7.0, Vector2::ZERO), 7.0);
        for f in 0..60 {
            cl.set_static_transform(1, Transform2D::IDENTITY.translated(Vector2::new(3.0 * f as f32, 0.0)));
            cl.step(1.0 / 60.0);
        }
        assert!(cl.bodies[c].center().x > 70.0, "{}", cl.bodies[c].center().x);
        assert!(cl.health()[6] < 1.0);
    }

    #[test]
    fn water_per_cell_carries_a_creature_far_from_the_origin() {
        // Velocities from the correction, not from f32 positions: exact at x = 5000.
        let mut cl = Cells::default();
        let c = add(&mut cl, hex_design(3, 7.0, Vector2::new(5000.0, 0.0)), 7.0);
        for f in 0..900 {
            let n = cl.bodies[c].n;
            cl.set_water_all(&vec![Vector2::new(60.0, 0.0); n]);
            if f == 0 {
                assert_eq!(cl.bodies[c].water.len(), n);
            }
            cl.step(1.0 / 60.0);
        }
        let v = cl.bodies[c].velocity();
        assert!((v.x - 60.0).abs() < 0.1 && v.y.abs() < 0.1, "{:?}", v);
    }

    #[test]
    fn regions_joints_and_bending_links() {
        let mut cl = Cells::default();
        cl.opt.types[1].body = BEND_SHAPE;
        // A worm 12 × 3, columns in three groups of four; type 1 (shape matched).
        let d = worm_design(12, 3, 7.0, Vector2::ZERO);
        let n = d.len();
        let groups: Vec<u16> = (0..n).map(|i| ((i % 12) / 4) as u16).collect();
        let c = cl.add_creature_ex(&d, &vec![7.0; n], &vec![1; n], &groups, &[]);
        cl.step(1.0 / 60.0);
        let b = &cl.bodies[c];
        assert_eq!(b.regions, 3);
        assert_eq!(b.joints.len(), 2);
        assert!(b.cell_shape.iter().all(|&x| x));
        let joint_links = b.links.iter().filter(|l| l.joint != 0).count();
        assert_eq!(joint_links, b.links.iter().filter(|l| l.bend).count());
        assert!(joint_links > 0 && joint_links < b.links.len());
        // The type made oriented: every link bends, after the version changes.
        cl.opt.types[1].body = BEND_LINK;
        cl.opt.types_version += 1;
        cl.step(1.0 / 60.0);
        assert!(cl.bodies[c].links.iter().all(|l| l.bend));
        assert!(cl.bodies[c].cell_shape.iter().all(|&x| !x));
    }

    #[test]
    fn a_thin_region_does_not_pin_the_turn() {
        // A hex blob twisted: one shape-matched type, then with an arc of rim cells of a
        // second shape-matched type (its end cells have one neighbour of their region). Both turn
        // alike; a cell too thin to fit used to keep its angle and pin the creature.
        let turn = |rim: bool| {
            let mut cl = Cells::default();
            cl.opt.types[0].body = BEND_SHAPE;
            cl.opt.types[1].body = BEND_SHAPE;
            let d = hex_design(4, 7.0, Vector2::ZERO);
            let reach = d.iter().map(|p| p.length()).fold(0.0f32, f32::max);
            let t: Vec<u8> = d.iter().map(|p| (rim && p.length() > 0.85 * reach && p.x < -7.0) as u8).collect();
            let c = cl.add_creature(&d, &vec![7.0; d.len()], &t);
            cl.bodies[c].twist = 5.0;
            for _ in 0..120 {
                cl.step(1.0 / 60.0);
            }
            if rim {
                assert!(cl.bodies[c].regions >= 2);
                assert!(cl.bodies[c].cell_shape.iter().any(|&x| !x), "the thin rim cells are not shape matched");
            }
            cl.bodies[c].spin()
        };
        let (plain, rim) = (turn(false), turn(true));
        assert!(plain > 3.0, "{}", plain);
        assert!(rim > 0.8 * plain, "plain {} rim {}", plain, rim);
    }

    #[test]
    fn the_break_leaves_out_the_creatures_own_share() {
        let run = |excess: bool| {
            let mut cl = Cells::default();
            cl.opt.stretch_hz = 60.0;
            cl.opt.bend_hz = 40.0;
            cl.opt.break_force = 2.0e6;
            cl.opt.break_excess = excess;
            let c = add(&mut cl, worm_design(20, 4, 7.0, Vector2::ZERO), 7.0);
            cl.bodies[c].wave = Wave { mode: WAVE_POSE, amp: 1.0, k: std::f32::consts::TAU / 280.0, omega: std::f32::consts::TAU, axis: Vector2::new(1.0, 0.0), half_width: 14.0, bias: 0.0, envelope: 0.6, phase: 0.0, age: 0.0 };
            for _ in 0..240 {
                cl.step(1.0 / 60.0);
            }
            cl.events.iter().filter(|e| e[0] == EVENT_PARTED).count()
        };
        assert_eq!(run(true), 0);
        assert!(run(false) > 0);
    }

    /// A 12 × 3 worm along +x in still water, drag and gravity off, at GooCellWorld2D's
    /// stiffnesses.
    fn open_worm(cl: &mut Cells, types: &[u8]) -> usize {
        cl.opt.drag.enabled = false;
        cl.opt.bend_mode = BEND_SHAPE;
        cl.opt.stretch_hz = 60.0;
        cl.opt.bend_hz = 40.0;
        let d = worm_design(12, 3, 7.0, Vector2::ZERO);
        let t: Vec<u8> = (0..d.len()).map(|i| types.get(i % types.len().max(1)).copied().unwrap_or(0)).collect();
        cl.add_creature(&d, &vec![7.0; d.len()], &t)
    }

    #[test]
    fn the_swim_drive_sums_to_the_commanded_acceleration() {
        // Straight, steady: every cell pushed along +x, a × its mass; one step's momentum.
        let mut cl = Cells::default();
        let c = open_worm(&mut cl, &[0]);
        cl.bodies[c].swim = Swim { acc: 300.0, pulse: 0.3, axis: Vector2::new(1.0, 0.0) };
        cl.step(1.0 / 60.0);
        let v = cl.bodies[c].velocity();
        assert!((v.x - 5.0).abs() < 0.01 && v.y.abs() < 0.01, "a step at 300 px/s²: {:?}", v);
        // Under a pose wave with a pulse: the forces' magnitudes still sum to a × M, and
        // the pulse moves the push along the body (cells differ by more than 1.3:1).
        cl.bodies[c].wave = Wave { mode: WAVE_POSE, amp: 0.3, k: std::f32::consts::TAU / 168.0, omega: std::f32::consts::TAU, axis: Vector2::new(1.0, 0.0), half_width: 10.0, bias: 0.0, envelope: 0.6, phase: 0.0, age: 1.0 };
        for f in 0..40 {
            cl.step(1.0 / 60.0);
            let b = &cl.bodies[c];
            let total: f32 = b.force.iter().map(|f| f.length()).sum();
            let want = 300.0 * b.total_mass();
            assert!((total - want).abs() < 1e-3 * want, "frame {}: Σ|f| {} against {}", f, total, want);
            let per: Vec<f32> = (0..b.n).map(|i| b.force[i].length() / b.mass[i]).collect();
            let (lo, hi) = per.iter().fold((f32::INFINITY, 0.0f32), |(a, z), &x| (a.min(x), z.max(x)));
            assert!(hi > 1.3 * lo, "the pulse ripples: {} .. {}", lo, hi);
        }
        // Backward.
        let mut cl = Cells::default();
        let c = open_worm(&mut cl, &[0]);
        cl.bodies[c].swim = Swim { acc: -120.0, pulse: 0.0, axis: Vector2::new(1.0, 0.0) };
        cl.step(1.0 / 60.0);
        assert!((cl.bodies[c].velocity().x + 2.0).abs() < 0.01);
    }

    #[test]
    fn swim_weights_share_the_drive_and_a_turned_cell_pushes_its_own_way() {
        let mut cl = Cells::default();
        cl.opt.types[1].swim = 3.0;
        cl.opt.types[2].swim = 0.0;
        let c = open_worm(&mut cl, &[0, 1, 2]);
        cl.bodies[c].swim = Swim { acc: 100.0, pulse: 0.0, axis: Vector2::new(1.0, 0.0) };
        cl.step(1.0 / 60.0);
        let b = &cl.bodies[c];
        let per = |t: u8| -> f32 { (0..b.n).filter(|&i| b.typ[i] == t).map(|i| b.force[i].x / b.mass[i]).sum::<f32>() / (0..b.n).filter(|&i| b.typ[i] == t).count() as f32 };
        assert!((per(1) / per(0) - 3.0).abs() < 1e-4, "weights {} {}", per(0), per(1));
        assert_eq!(per(2), 0.0);
        // The mean is still the commanded acceleration.
        assert!((b.velocity().x - 100.0 / 60.0).abs() < 0.01, "{:?}", b.velocity());
        // A cell's push follows its angle.
        let mut cl = Cells::default();
        let c = open_worm(&mut cl, &[0]);
        cl.bodies[c].swim = Swim { acc: 100.0, pulse: 0.0, axis: Vector2::new(1.0, 0.0) };
        cl.bodies[c].th[0] = 0.5;
        cl.bodies[c].prepare(&cl.opt.clone(), 1.0 / 60.0, &[], 64.0);
        let f = cl.bodies[c].force[0];
        assert!((f.y.atan2(f.x) - 0.5).abs() < 1e-4, "{:?}", f);
    }

    #[test]
    fn one_step_forces_clear_themselves() {
        let mut cl = Cells::default();
        let c = open_worm(&mut cl, &[0]);
        cl.bodies[c].push_once = Vector2::new(600.0, 0.0);
        cl.step(1.0 / 60.0);
        let v1 = cl.bodies[c].velocity();
        assert!((v1.x - 10.0).abs() < 0.01, "{:?}", v1);
        cl.step(1.0 / 60.0);
        let v2 = cl.bodies[c].velocity();
        assert!((v2.x - v1.x).abs() < 1e-3, "gone after one step: {:?} {:?}", v1, v2);
        assert_eq!(cl.bodies[c].push_once, Vector2::ZERO);
        // A twist for one step: spin, then no more angular acceleration.
        cl.bodies[c].twist_once = 3.0;
        cl.step(1.0 / 60.0);
        let s1 = cl.bodies[c].spin();
        assert!(s1 > 0.03, "spin {}", s1);
        cl.step(1.0 / 60.0);
        let s2 = cl.bodies[c].spin();
        assert!(s2 <= s1 * 1.01, "no more twist {} -> {}", s1, s2);
        // Per-cell forces: added to the kept ones, one step, counted as contact.
        let n = cl.bodies[c].n;
        let m = cl.bodies[c].total_mass();
        cl.bodies[c].force_once = vec![Vector2::new(0.0, 60.0 * m / n as f32); n];
        let vy = cl.bodies[c].velocity().y;
        cl.step(1.0 / 60.0);
        assert!((cl.bodies[c].velocity().y - vy - 1.0).abs() < 0.01);
        assert!(cl.bodies[c].contact);
        assert!(cl.bodies[c].force_once.is_empty());
        cl.step(1.0 / 60.0);
        assert!(!cl.bodies[c].contact);
    }

    #[test]
    fn damping_decays_the_rigid_motion_exactly_and_leaves_the_stroke() {
        let dt = 1.0 / 60.0;
        let mut cl = Cells::default();
        let c = open_worm(&mut cl, &[0]);
        for i in 0..cl.bodies[c].n {
            cl.bodies[c].vel[i] = Vector2::new(300.0, 0.0);
        }
        cl.bodies[c].damp_lin = 2.0;
        for _ in 0..60 {
            cl.step(dt);
        }
        let v = cl.bodies[c].velocity().x;
        let want = 300.0 * (-2.0f32).exp();
        assert!((v - want).abs() < 0.01 * want, "linear: {} against {}", v, want);
        // Spin.
        let mut cl = Cells::default();
        let c = open_worm(&mut cl, &[0]);
        let ctr = cl.bodies[c].center();
        for i in 0..cl.bodies[c].n {
            let p = cl.bodies[c].pos[i] - ctr;
            cl.bodies[c].vel[i] = perp(p) * 1.5;
            cl.bodies[c].om[i] = 1.5;
        }
        cl.bodies[c].damp_ang = 1.0;
        for _ in 0..60 {
            cl.step(dt);
        }
        let s = cl.bodies[c].spin();
        let want = 1.5 * (-1.0f32).exp();
        assert!((s - want).abs() < 0.03 * want, "angular: {} against {}", s, want);
        // Moving with the water: nothing to damp.
        let mut cl = Cells::default();
        let c = open_worm(&mut cl, &[0]);
        cl.bodies[c].current = Vector2::new(80.0, 0.0);
        cl.bodies[c].has_current = true;
        for i in 0..cl.bodies[c].n {
            cl.bodies[c].vel[i] = Vector2::new(80.0, 0.0);
        }
        cl.bodies[c].damp_lin = 5.0;
        cl.bodies[c].damp_ang = 5.0;
        for _ in 0..60 {
            cl.step(dt);
        }
        assert!((cl.bodies[c].velocity().x - 80.0).abs() < 0.01);
        // The stroke: a pose wave's shape change is the same with heavy damping (no water,
        // so the wave alone moves nothing; only its rigid wobble is damped).
        let shape = |damp: f32| -> f32 {
            let mut cl = Cells::default();
            let c = open_worm(&mut cl, &[0]);
            cl.bodies[c].wave = Wave { mode: WAVE_POSE, amp: 0.8, k: std::f32::consts::TAU / 168.0, omega: std::f32::consts::TAU, axis: Vector2::new(1.0, 0.0), half_width: 10.0, bias: 0.0, envelope: 0.6, phase: 0.0, age: 1.0 };
            cl.bodies[c].damp_lin = damp;
            cl.bodies[c].damp_ang = damp;
            let mut e = 0.0;
            for _ in 0..120 {
                cl.step(dt);
                e += cl.bodies[c].shape_error();
            }
            e
        };
        let (free, damped) = (shape(0.0), shape(10.0));
        assert!((damped - free).abs() < 0.1 * free, "the stroke's bend: free {} damped {}", free, damped);
    }

    #[test]
    fn automatic_threads_by_size() {
        assert_eq!(Cells::auto_threads(150, 1, 4), 1);
        assert_eq!(Cells::auto_threads(4500, 30, 4), 4);
        assert_eq!(Cells::auto_threads(4500, 2, 4), 2, "no more than the creatures");
        assert_eq!(Cells::auto_threads(4500, 30, 1), 1, "no more than the cores");
        let mut cl = crash_world(0);
        cl.step(1.0 / 60.0);
        let n: usize = cl.bodies.iter().map(|b| b.n).sum();
        let cores = std::thread::available_parallelism().map(|x| x.get()).unwrap_or(1);
        assert_eq!(cl.threads_in_use(), Cells::auto_threads(n, 6, cores));
        cl.set_threads(3);
        assert_eq!(cl.threads_in_use(), 3);
    }

    #[test]
    fn threaded_equals_serial_with_swimming_damping_and_one_step_forces() {
        let run = |threads: usize| {
            let mut cl = crash_world(threads);
            cl.opt.drag.enabled = true;
            cl.opt.types[1].swim = 2.0;
            for (k, b) in cl.bodies.iter_mut().enumerate() {
                b.swim = Swim { acc: 200.0, pulse: 0.3, axis: Vector2::new(1.0, 0.0) };
                b.wave = Wave { mode: WAVE_POSE, amp: 0.3, k: 0.03, omega: 6.0, axis: Vector2::new(1.0, 0.0), half_width: 20.0, bias: 0.002, envelope: 0.5, phase: 0.0, age: 0.0 };
                b.damp_lin = 0.5 * k as f32;
                b.damp_ang = 0.3 * k as f32;
            }
            for f in 0..120 {
                if f % 7 == 0 {
                    for b in cl.bodies.iter_mut() {
                        b.push_once = Vector2::new(0.0, 500.0);
                        b.twist_once = 2.0;
                        b.force_once = vec![Vector2::new(-1.0e4, 0.0); b.n];
                    }
                }
                cl.step(1.0 / 60.0);
                if f == 60 {
                    cl.add_cell(0, cl.bodies[0].pos[0] + Vector2::new(-14.0, 0.0), 7.0, 1);
                }
            }
            cl.state_hash()
        };
        let a = run(1);
        assert_eq!(a, run(4));
        assert_eq!(a, run(0));
        assert_eq!(a, run(1), "a replay");
    }

    #[test]
    fn mesh_of_a_hex_blob() {
        let mut cl = Cells::default();
        let c = add(&mut cl, hex_design(2, 7.0, Vector2::ZERO), 7.0);
        let faces = crate::cells_draw::inner_faces(&cl.bodies[c]);
        assert_eq!(faces.len(), 24);
        assert!(faces.iter().all(|f| f.len() == 3));
        let m = crate::cells_draw::creature_mesh(&cl.bodies[c], &cl.opt.types, true);
        // One triangle per face, the 12 faces on the rim split at their outline link
        // (two triangles), and 6 per outline cell; no borders in one type.
        assert_eq!(m.indices.len(), 3 * (12 + 2 * 12 + 6 * 12));
        assert!(m.lines.is_empty());
        // Mixed types: borders, and the area kept.
        let mut cl2 = Cells::default();
        let d = hex_design(2, 7.0, Vector2::ZERO);
        let t: Vec<u8> = d.iter().map(|p| (p.x > 0.0) as u8).collect();
        let c2 = cl2.add_creature(&d, &vec![7.0; d.len()], &t);
        let m2 = crate::cells_draw::creature_mesh(&cl2.bodies[c2], &cl2.opt.types, true);
        assert!(!m2.lines.is_empty());
        let area = |m: &crate::cells_draw::Mesh| m.triangles().chunks(3).map(|t| 0.5 * cross(t[1] - t[0], t[2] - t[0]).abs()).sum::<f32>();
        assert!((area(&m) - area(&m2)).abs() < 1.0, "{} {}", area(&m), area(&m2));
        // No T-junction: no vertex lies inside another triangle's edge (it would leave a
        // pinhole once rasterised), with one type and with two.
        for mesh in [&m, &m2] {
            let p = mesh.triangles();
            for t in p.chunks(3) {
                for e in 0..3 {
                    let (a, c) = (t[e], t[(e + 1) % 3]);
                    let ac = c - a;
                    let l2 = lsq(ac);
                    for &v in p.iter() {
                        let s = (v - a).dot(ac) / l2;
                        if s > 1e-3 && s < 1.0 - 1e-3 {
                            let off = cross(ac, v - a).abs() / l2.sqrt();
                            assert!(off > 1e-3, "a vertex {:?} inside the edge {:?} {:?}", v, a, c);
                        }
                    }
                }
            }
        }
    }
}

#[cfg(test)]
mod mesh_bench {
    use super::*;
    #[test]
    #[ignore]
    fn mesh_cost() {
        let mut cl = Cells::default();
        let d = hex_design(7, 7.0, Vector2::ZERO);
        let n = d.len();
        let c = cl.add_creature(&d, &vec![7.0; n], &vec![0; n]);
        cl.step(1.0 / 60.0);
        let b = &cl.bodies[c];
        let t = std::time::Instant::now();
        for _ in 0..1000 { std::hint::black_box(crate::cells_draw::walk_faces(b)); }
        let w = t.elapsed().as_micros() as f64 / 1000.0;
        let t = std::time::Instant::now();
        let mut v = 0;
        for _ in 0..1000 { v = std::hint::black_box(crate::cells_draw::creature_mesh(b, &cl.opt.types, true)).points.len(); }
        let m = t.elapsed().as_micros() as f64 / 1000.0;
        println!("cells {} walk {:.1} us, mesh {:.1} us, {} vertices", b.n, w, m, v);
    }
}
