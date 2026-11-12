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
use godot::builtin::Vector2;
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
}

impl Default for TypeParams {
    fn default() -> Self {
        TypeParams { stretch: 1.0, bend: 1.0, brk: 1.0, self_collide: false, join_mask: 0xffff, pad: 0.0 }
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

#[derive(Clone, Copy)]
pub struct Wall {
    pub pts: [Vector2; 8],
    pub nrm: [Vector2; 8],
    pub n: usize,
    pub lo: Vector2,
    pub hi: Vector2,
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
    pub self_age: u32,
    pub self_stale: bool,
    pub near_start: Vec<u32>,
    pub near_list: Vec<u32>,
}

pub struct Cells {
    pub opt: Opt,
    pub bodies: Vec<Body>,
    pub walls: Vec<Wall>,
    pool: Option<rayon::ThreadPool>,
    pool_threads: usize,
    pub grid_cell: f32,
    pub stats: Stats,
    pub cross: Vec<Cross>,
    /// (kind, creature, uid a, uid b) — EVENT_SPLIT: (kind, parent, new creature, cells).
    pub events: Vec<[i32; 4]>,
    pub next_uid: u32,
    pub frame: u64,
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
        Cells { opt: Opt::default(), bodies: Vec::new(), walls: Vec::new(), pool: None, pool_threads: 1, grid_cell: 64.0, stats: Stats::default(), cross: Vec::new(), events: Vec::new(), next_uid: 0, frame: 0 }
    }
}

#[inline]
fn key(x: f32, y: f32, cell: f32) -> (i32, i32) {
    ((x / cell).floor() as i32, (y / cell).floor() as i32)
}
#[inline]
fn pack(k: (i32, i32)) -> u64 {
    ((k.0 as u32 as u64) << 32) | (k.1 as u32 as u64)
}

fn grid_query(grid: &[(u64, u32)], k: (i32, i32), out: &mut Vec<u32>) {
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

/// The signed distance from p to a convex wall and the outward normal there.
pub fn wall_distance(w: &Wall, p: Vector2) -> (f32, Vector2) {
    let mut best_s = f32::NEG_INFINITY;
    let mut best_n = Vector2::ZERO;
    for e in 0..w.n {
        let s = dot(p - w.pts[e], w.nrm[e]);
        if s > best_s {
            best_s = s;
            best_n = w.nrm[e];
        }
    }
    if best_s <= 0.0 {
        return (best_s, best_n);
    }
    let mut best = f32::INFINITY;
    let mut bn = best_n;
    for e in 0..w.n {
        let a = w.pts[e];
        let b = w.pts[(e + 1) % w.n];
        let ab = b - a;
        let t = (dot(p - a, ab) / lsq(ab).max(1e-9)).clamp(0.0, 1.0);
        let q = a + ab * t;
        let d = lsq(p - q);
        if d < best {
            best = d;
            bn = p - q;
        }
    }
    let d = best.sqrt();
    (d, if d > 1e-9 { bn / d } else { best_n })
}

impl Body {
    pub fn new(centers: &[Vector2], radii: &[f32], types: &[u8], density: f32, uid0: u32) -> Body {
        let n = centers.len();
        let mut b = Body { alive: true, n, ..Default::default() };
        for i in 0..n {
            let r = radii.get(i).copied().unwrap_or(10.0).max(0.5);
            b.push_cell(centers[i], r, *types.get(i).unwrap_or(&0), density, uid0 + i as u32);
        }
        b.rest_local_from_now(false);
        b
    }

    fn push_cell(&mut self, p: Vector2, r: f32, t: u8, density: f32, uid: u32) {
        let m = density * std::f32::consts::PI * r * r;
        self.pos.push(p);
        self.prev.push(p);
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
        self.sm_start.clear();
        self.sm.clear();
        self.sm_off.clear();
        for i in 0..n {
            self.sm_start.push(self.sm.len() as u32);
            self.sm.push(i as u32);
            self.sm_off.push(Vector2::ZERO);
            for q in self.nb_start[i]..self.nb_start[i + 1] {
                let j = self.nb[q as usize].0 as usize;
                self.sm.push(j as u32);
                // The design offset, turned into the frame of the design (rest_local).
                let off = if self.rest_local.len() == n { self.rest_local[j] - self.rest_local[i] } else { self.pos[j] - self.pos[i] };
                self.sm_off.push(off);
            }
        }
        self.sm_start.push(self.sm.len() as u32);
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
        self.topo_dirty = false;
        // Rebuild the creature's own candidates now; stagger later rebuilds by creature.
        self.self_stale = true;
        self.self_age = (self.uid.first().copied().unwrap_or(0).wrapping_mul(2_654_435_761) >> 13) & 0xffff;
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
    fn prepare(&mut self, opt: &Opt, dt: f32, walls: &[Wall], cell: f32) {
        let n = self.n;
        let h = dt / opt.substeps as f32;
        self.time += dt;
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
        // Frame forces.
        for i in 0..n {
            let mut f = self.user_force[i];
            if self.thrust[i] != 0.0 {
                let a = self.th[i] + self.thrust_angle[i];
                f += Vector2::new(a.cos(), a.sin()) * self.thrust[i];
            }
            self.force[i] = f;
        }
        if self.twist != 0.0 {
            let c = self.center();
            for i in 0..n {
                self.force[i] += perp(self.pos[i] - c) * (self.mass[i] * self.twist);
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
            if w.hi.x < lo.x - margin || w.lo.x > hi.x + margin || w.hi.y < lo.y - margin || w.lo.y > hi.y + margin {
                continue;
            }
            for c in 0..n as u32 {
                let p = self.pos[c as usize];
                let r = self.r[c as usize] + margin;
                if p.x + r < w.lo.x || p.x - r > w.hi.x || p.y + r < w.lo.y || p.y - r > w.hi.y {
                    continue;
                }
                let (d, _) = wall_distance(w, p);
                if d < r {
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
        let bent = &self.bent;
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
            let v = (self.vel[ia] + self.vel[ib]) * 0.5 - current;
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
            let limit = lim * self.mass[i] * (self.vel[i] - current).length();
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
        let g = opt.gravity + self.push;
        for i in 0..self.n {
            let v = self.vel[i] + (g + (self.force[i] + self.drag_f[i]) * self.w[i]) * h;
            self.vel[i] = v;
            self.prev[i] = self.pos[i];
            self.pos[i] += v * h;
            self.th_prev[i] = self.th[i];
            self.th[i] += self.om[i] * h;
        }
    }

    fn finish_substep(&mut self, opt: &Opt, h: f32) {
        let ih = 1.0 / h;
        let vmax2 = opt.max_speed * opt.max_speed;
        for i in 0..self.n {
            let mut v = (self.pos[i] - self.prev[i]) * ih;
            let s = lsq(v);
            if s > vmax2 {
                v *= opt.max_speed / s.sqrt();
            }
            self.vel[i] = v;
            self.om[i] = (self.th[i] - self.th_prev[i]) * ih;
        }
    }

    fn solve(&mut self, opt: &Opt, walls: &[Wall], h: f32) {
        let n = self.n;
        let inv_s = 1.0 / (opt.substeps as f32 * h * h);
        let g = opt.link_damp;
        let gb = opt.bend_damp;
        let bend_link = opt.bend_mode == BEND_LINK;
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
                    if !bend_link {
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
                        let (wa, wb, iwa) = (*w.get_unchecked(a), *w.get_unchecked(b), *iw.get_unchecked(a));
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
        if opt.bend_mode == BEND_SHAPE {
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
                let mut qc = Vector2::ZERO;
                let mut xc = Vector2::ZERO;
                let mut ms = 0.0;
                for q in 0..m {
                    let c = self.sm[s + q] as usize;
                    let f = (self.rscale[c] * self.r0[c] + self.rscale[centre] * self.r0[centre]) / (self.r0[c] + self.r0[centre]);
                    goal[q] = if posed { (self.bent[c] - self.bent[centre]) * (self.sm_off[s + q].length() / (self.rest_local[c] - self.rest_local[centre]).length().max(1e-6)).min(4.0) } else { self.sm_off[s + q] * f };
                    qc += goal[q] * self.mass[c];
                    xc += self.pos[c] * self.mass[c];
                    ms += self.mass[c];
                }
                qc /= ms;
                xc /= ms;
                let (mut sc, mut ss) = (0.0f32, 0.0f32);
                for q in 0..m {
                    let c = self.sm[s + q] as usize;
                    goal[q] -= qc;
                    let p = self.pos[c] - xc;
                    sc += self.mass[c] * dot(goal[q], p);
                    ss += self.mass[c] * cross(goal[q], p);
                }
                let ll = (sc * sc + ss * ss).sqrt();
                if ll < 1e-9 {
                    continue;
                }
                let (co, si) = (sc / ll, ss / ll);
                // The cell's heading follows its neighbourhood's best-fit turn (thrust and
                // types read it; shape matching has no spin of its own).
                self.th[centre] = ss.atan2(sc);
                for q in 0..m {
                    let c = self.sm[s + q] as usize;
                    let gp = xc + rot(goal[q], co, si);
                    let here = self.pos[c];
                    self.pos[c] = here + (gp - here) * kk;
                }
            }
        }
        for &(c, wi) in &self.wall_c {
            let c = c as usize;
            let (d, nrm) = wall_distance(&walls[wi as usize], self.pos[c]);
            let pen = self.r[c] - d;
            if pen > 0.0 {
                self.pos[c] += nrm * pen;
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
        for (k, l) in self.links.iter_mut().enumerate() {
            let f = l.f_frame + opt.break_torque * l.t_frame / l.rest.max(1e-3);
            l.load += (f - l.load) * a;
            if opt.break_force.is_finite() {
                let (ti, tj) = (&opt.types[self.typ[l.i as usize] as usize], &opt.types[self.typ[l.j as usize] as usize]);
                if l.load > opt.break_force * ti.brk.min(tj.brk) {
                    self.broken.push(k as u32);
                }
            }
        }
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
        let mut b = Body { alive: true, n: cells.len(), wave: self.wave, time: self.time, ..Default::default() };
        macro_rules! take {
            ($f:ident) => {
                b.$f = cells.iter().map(|&c| self.$f[c]).collect();
            };
        }
        take!(pos);
        take!(prev);
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
    pub fn set_threads(&mut self, threads: usize) {
        let threads = threads.max(1);
        self.opt.threads = threads;
        if threads == self.pool_threads {
            return;
        }
        self.pool_threads = threads;
        self.pool = if threads > 1 { rayon::ThreadPoolBuilder::new().num_threads(threads).build().ok() } else { None };
    }

    fn for_each<F: Fn(&mut Body) + Sync + Send>(&mut self, f: F) {
        let bodies = &mut self.bodies;
        match &self.pool {
            Some(pool) => pool.install(|| bodies.par_iter_mut().filter(|b| b.alive).for_each(|b| f(b))),
            None => bodies.iter_mut().filter(|b| b.alive).for_each(|b| f(b)),
        }
    }

    pub fn add_creature(&mut self, centers: &[Vector2], radii: &[f32], types: &[u8]) -> usize {
        let t = Instant::now();
        let mut b = Body::new(centers, radii, types, self.opt.density, self.next_uid);
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

    pub fn add_wall(&mut self, pts: &[Vector2]) {
        let n = pts.len().min(8);
        if n < 3 {
            return;
        }
        let mut w = Wall { pts: [Vector2::ZERO; 8], nrm: [Vector2::ZERO; 8], n, lo: pts[0], hi: pts[0] };
        let mut area = 0.0;
        for k in 0..n {
            area += cross(pts[k], pts[(k + 1) % n]);
        }
        for k in 0..n {
            w.pts[k] = pts[k];
            let e = pts[(k + 1) % n] - pts[k];
            let nr = if area > 0.0 { Vector2::new(e.y, -e.x) } else { Vector2::new(-e.y, e.x) };
            w.nrm[k] = nr.normalized();
            w.lo = Vector2::new(w.lo.x.min(pts[k].x), w.lo.y.min(pts[k].y));
            w.hi = Vector2::new(w.hi.x.max(pts[k].x), w.hi.y.max(pts[k].y));
        }
        self.walls.push(w);
    }

    pub fn step(&mut self, dt: f32) {
        let t0 = Instant::now();
        let opt = self.opt.clone();
        let cell = self.grid_cell;
        {
            let walls = self.walls.clone();
            self.for_each(|b| b.prepare(&opt, dt, &walls, cell));
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
        let t2 = Instant::now();
        let h = dt / opt.substeps as f32;
        let walls = self.walls.clone();
        let mut solve_us = 0u64;
        let mut serial_us = 0u64;
        for s in 0..opt.substeps {
            let ta = Instant::now();
            {
                let walls = &walls;
                self.for_each(|b| {
                    b.predict(&opt, h, s == 0);
                    b.solve(&opt, walls, h);
                });
            }
            let tb = Instant::now();
            for _ in 0..opt.contact_iters.max(1) {
                solve_cross(&mut self.bodies, &self.cross, &opt, h);
            }
            solve_us += (tb - ta).as_micros() as u64;
            serial_us += tb.elapsed().as_micros() as u64;
        }
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
        let opt = self.opt.clone();
        let uid = self.next_uid;
        self.next_uid += 1;
        let b = &mut self.bodies[c];
        let design = b.design_of(at);
        b.push_cell(at, radius.max(0.5), typ, opt.density, uid);
        b.rest_local.push(design);
        b.drag_f.push(Vector2::ZERO);
        b.n += 1;
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
                for w in &self.walls {
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
}
