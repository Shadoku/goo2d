//! A colony: creatures made of many goo cells, the measured spike of the colony plan's
//! milestone 0 (docs/colony-spike.md). Nothing in the rest of the addon uses it: a
//! `GooColony` (lib.rs) owns one `Colony`, and only tools/colony_bench.gd and its tests
//! drive it.
//!
//! What it prototypes, against the per-body `Kernel` (kernel.rs):
//! - A: core cells. A cell whose beads are all enclosed by neighbours is one particle
//!   with the cell's radius and mass (a disc), colliding with beads and other cores.
//!   `promote()` turns a core back into a ring fitted to the pocket its neighbours leave,
//!   `demote()` a ring into a core.
//! - The fake adhesion that holds a creature together: bonds set up once
//!   (`build_bonds()`), each a bead held at zero gap to the nearest point on a
//!   neighbouring ring's edge (or to a core's rim), and core to core; XPBD distance
//!   constraints solved every substep, as real adhesion will be.
//! - B: cells that are not nodes. Per creature, one triangle-fan mesh (`mesh_arrays()`
//!   once, `write_positions()` every frame) and optionally its cores as MultiMesh
//!   instances (`write_core_instances()`).
//! - C: threads. Each creature's own work (frame forces, prediction, ring constraints,
//!   bonds, the contacts within it, velocities) runs on its own data, in parallel on a
//!   rayon pool; contacts between creatures are solved after it, serially, in a fixed
//!   order. The serial path runs the very same per-creature code in creature order,
//!   so a threaded step gives bit-identical results to a serial one.
//!   A creature may sleep (`asleep`: not stepped, immovable to others) or be stepped
//!   every `every` frames with that much time per step.
//!
//! The ring constraints are the kernel's (`kernel::distances`, the same shape matching,
//! stretch limit, pressure and internal damping). What the spike leaves out: static
//! shapes, restitution and friction (water, e = 0), settling, splits, skins.

use crate::consts::{MAX_PRESSURE_RATIO, MAX_STRETCH, MIN_AREA_RATIO};
use crate::geom::*;
use crate::grid::Grid;
use crate::kernel::distances;
use godot::builtin::Vector2;
use rayon::prelude::*;
use std::time::Instant;

/// Floats per cell in `Colony::add_creature()`'s input: x, y, radius, kind (0 ring,
/// 1 core), beads, ring_radius, bead_radius, bead_mass, pressure_k, shape_k, skin_k,
/// skin_d, bend_k, bend_d, internal_damp, linear_damp, target_area, r, g, b.
pub const CELL_STRIDE: usize = 20;
/// Rim vertices of a core's disc in the mesh.
pub const CORE_SIDES: usize = 12;
/// Floats per core instance in `write_core_instances()`: a 2D transform (8), colour (4),
/// custom data (4), MultiMesh's layout with colours and custom data.
pub const INSTANCE_FLOATS: usize = 16;
const PAIR_SLACK: f32 = 1.5;
const PAIR_PAD: f32 = 1.0;

#[derive(Clone, Copy, Debug, Default)]
pub struct CellTuning {
    pub radius: f32,
    pub beads: usize,
    pub ring_radius: f32,
    pub bead_radius: f32,
    pub bead_mass: f32,
    pub pressure_k: f32,
    pub shape_k: f32,
    pub skin_k: f32,
    pub skin_d: f32,
    pub bend_k: f32,
    pub bend_d: f32,
    pub internal_damp: f32,
    pub linear_damp: f32,
    pub target_area: f32,
    pub color: [f32; 3],
}

impl CellTuning {
    fn from_floats(f: &[f32]) -> CellTuning {
        CellTuning {
            radius: f[2],
            beads: (f[4] as usize).max(3),
            ring_radius: f[5],
            bead_radius: f[6],
            bead_mass: f[7],
            pressure_k: f[8],
            shape_k: f[9],
            skin_k: f[10],
            skin_d: f[11],
            bend_k: f[12],
            bend_d: f[13],
            internal_damp: f[14],
            linear_damp: f[15],
            target_area: f[16],
            color: [f[17], f[18], f[19]],
        }
    }

    fn mass(&self) -> f32 {
        self.bead_mass * self.beads as f32
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Kind {
    Ring(usize),
    Core(usize),
}

#[derive(Clone, Debug)]
pub struct Cell {
    pub kind: Kind,
    pub t: CellTuning,
}

pub struct CRing {
    pub cell: usize,
    pub start: usize,
    pub n: usize,
    pub rest: Vec<Vector2>,
    rest_edges: Vec<f32>,
    rest_bend: Vec<f32>,
    w: f32,
}

/// One end of a bond (indices local to the creature).
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum End {
    Bead(u32),
    /// The point `t` of the way along the edge from bead a to bead b.
    Edge(u32, u32, f32),
    Core(u32),
}

#[derive(Clone, Copy, Debug)]
pub struct Bond {
    pub a: End,
    pub b: End,
    pub rest: f32,
    /// Compliance, 1 / stiffness.
    pub alpha: f32,
}

/// A contact candidate between two creatures: (creature, index, is a core) twice.
#[derive(Clone, Copy, Debug)]
struct Cross {
    ca: u32,
    ia: u32,
    a_core: bool,
    cb: u32,
    ib: u32,
    b_core: bool,
}

#[derive(Default)]
pub struct Creature {
    pub cells: Vec<Cell>,
    pub rings: Vec<CRing>,
    // Beads, ring after ring.
    pub pos: Vec<Vector2>,
    pub prev: Vec<Vector2>,
    pub vel: Vec<Vector2>,
    force: Vec<Vector2>,
    pub r: Vec<f32>,
    w: Vec<f32>,
    damp: Vec<f32>,
    pub bead_ring: Vec<u32>,
    /// Bonds holding each bead (0: an exposed bead).
    pub bonded: Vec<u8>,
    // Cores.
    pub cpos: Vec<Vector2>,
    pub cprev: Vec<Vector2>,
    pub cvel: Vec<Vector2>,
    cforce: Vec<Vector2>,
    pub cr: Vec<f32>,
    cw: Vec<f32>,
    cdamp: Vec<f32>,
    pub ccell: Vec<u32>,
    pub bonds: Vec<Bond>,
    // This frame's contact candidates within the creature (local indices), and with
    // later creatures (or with any other for a bead against a core).
    bb: Vec<(u32, u32)>,
    bc: Vec<(u32, u32)>,
    cc: Vec<(u32, u32)>,
    // Each bead's and core's reach this step against the creature's mean motion, and in
    // absolute terms; the box of every particle grown by its absolute reach.
    reach: Vec<f32>,
    creach: Vec<f32>,
    abs_reach: Vec<f32>,
    cabs_reach: Vec<f32>,
    pub aabb: Rect,
    grid: Grid,
    cgrid: Grid,
    /// The push for every step until changed: an acceleration, px/s².
    pub push: Vector2,
    pub asleep: bool,
    pub every: u32,
    pub phase: u32,
    /// Bumped whenever the mesh's topology changes (promote, demote).
    pub topology: u64,
    active: bool,
    h: f32,
    dt: f32,
    // Nanoseconds spent this step (summed over substeps) in its rings, bonds and own
    // contacts.
    ns_rings: u64,
    ns_bonds: u64,
    ns_intra: u64,
}

#[derive(Clone, Copy, Debug)]
pub struct Options {
    pub threads: usize,
    pub substeps: usize,
    pub gravity: Vector2,
    pub max_speed: f32,
    pub cell_scale: f32,
    pub intra_contacts: bool,
    /// With intra_contacts off: still the contacts of a creature's cores with its own
    /// beads and cores (a core must not slip through the ring cells around it).
    pub core_contacts: bool,
    pub slop: f32,
    /// Bond stiffness as a multiple of the cells' skin stiffness.
    pub bond_scale: f32,
}

impl Default for Options {
    fn default() -> Self {
        Options {
            threads: 1,
            substeps: 6,
            gravity: Vector2::ZERO,
            max_speed: 1500.0,
            cell_scale: 1.0,
            intra_contacts: true,
            core_contacts: false,
            slop: 0.5,
            bond_scale: 1.0,
        }
    }
}

/// The last step's timing (wall-clock microseconds unless named cpu) and counts.
#[derive(Clone, Copy, Debug, Default)]
pub struct Stats {
    pub total_us: u64,
    pub forces_us: u64,
    pub pairs_us: u64,
    /// The parallel region of each substep (prediction, rings, bonds, own contacts).
    pub solve_us: u64,
    pub cross_us: u64,
    pub vel_us: u64,
    /// Summed over creatures (and threads): CPU time, not wall.
    pub rings_cpu_us: u64,
    pub bonds_cpu_us: u64,
    pub intra_cpu_us: u64,
    pub intra_pairs: usize,
    pub cross_pairs: usize,
    /// Contacts between creatures that overlapped in the last substep.
    pub cross_hits: usize,
    pub draw_build_us: u64,
}

pub struct Colony {
    pub creatures: Vec<Creature>,
    pub opt: Options,
    pool: Option<rayon::ThreadPool>,
    pool_threads: usize,
    cross: Vec<Cross>,
    frame: u64,
    pub stats: Stats,
}

impl Default for Colony {
    fn default() -> Self {
        Colony {
            creatures: Vec::new(),
            opt: Options::default(),
            pool: None,
            pool_threads: 1,
            cross: Vec::new(),
            frame: 0,
            stats: Stats::default(),
        }
    }
}

fn circle(center: Vector2, radius: f32, n: usize) -> Vec<Vector2> {
    (0..n)
        .map(|i| {
            let a = -std::f32::consts::TAU * i as f32 / n as f32;
            center + Vector2::new(a.cos(), a.sin()) * radius
        })
        .collect()
}

fn ns(since: Instant) -> u64 {
    since.elapsed().as_nanos() as u64
}

/// Two distinct elements of a slice, mutably.
fn two_mut<T>(v: &mut [T], a: usize, b: usize) -> (&mut T, &mut T) {
    debug_assert!(a != b);
    if a < b {
        let (l, r) = v.split_at_mut(b);
        (&mut l[a], &mut r[0])
    } else {
        let (l, r) = v.split_at_mut(a);
        (&mut r[0], &mut l[b])
    }
}

impl Creature {
    pub fn bead_count(&self) -> usize {
        self.pos.len()
    }

    pub fn core_count(&self) -> usize {
        self.cpos.len()
    }

    pub fn center(&self) -> Vector2 {
        let mut total = Vector2::ZERO;
        let mut mass = 0.0f32;
        for (i, &p) in self.pos.iter().enumerate() {
            let m = if self.w[i] > 0.0 { 1.0 / self.w[i] } else { 0.0 };
            total += p * m;
            mass += m;
        }
        for (k, &p) in self.cpos.iter().enumerate() {
            let m = if self.cw[k] > 0.0 { 1.0 / self.cw[k] } else { 0.0 };
            total += p * m;
            mass += m;
        }
        if mass > 0.0 {
            total / mass
        } else {
            Vector2::ZERO
        }
    }

    pub fn velocity(&self) -> Vector2 {
        let mut total = Vector2::ZERO;
        let mut mass = 0.0f32;
        for (i, &v) in self.vel.iter().enumerate() {
            let m = if self.w[i] > 0.0 { 1.0 / self.w[i] } else { 0.0 };
            total += v * m;
            mass += m;
        }
        for (k, &v) in self.cvel.iter().enumerate() {
            let m = if self.cw[k] > 0.0 { 1.0 / self.cw[k] } else { 0.0 };
            total += v * m;
            mass += m;
        }
        if mass > 0.0 {
            total / mass
        } else {
            Vector2::ZERO
        }
    }

    /// Where cell `i` is: its ring's bead centroid or its core.
    pub fn cell_center(&self, i: usize) -> Vector2 {
        match self.cells[i].kind {
            Kind::Ring(r) => {
                let ring = &self.rings[r];
                centroid(&self.pos[ring.start..ring.start + ring.n])
            }
            Kind::Core(k) => self.cpos[k],
        }
    }

    fn cell_velocity(&self, i: usize) -> Vector2 {
        match self.cells[i].kind {
            Kind::Ring(r) => {
                let ring = &self.rings[r];
                centroid(&self.vel[ring.start..ring.start + ring.n])
            }
            Kind::Core(k) => self.cvel[k],
        }
    }

    // ---- Building ----

    /// Appends a ring for cell `cell` with its beads at `points` (moving at `vel`).
    fn push_ring(&mut self, cell: usize, points: &[Vector2], vel: Vector2) -> usize {
        let t = self.cells[cell].t;
        let n = points.len();
        let start = self.pos.len();
        let idx = self.rings.len();
        let rest = circle(Vector2::ZERO, t.ring_radius, n);
        let rest_edges: Vec<f32> = (0..n).map(|i| dist(rest[i], rest[(i + 1) % n])).collect();
        let rest_bend: Vec<f32> = (0..n).map(|i| dist(rest[i], rest[(i + 2) % n])).collect();
        let w = if t.bead_mass > 0.0 { 1.0 / t.bead_mass } else { 0.0 };
        self.pos.extend_from_slice(points);
        self.prev.extend_from_slice(points);
        self.vel.extend(std::iter::repeat(vel).take(n));
        self.force.extend(std::iter::repeat(Vector2::ZERO).take(n));
        self.r.extend(std::iter::repeat(t.bead_radius).take(n));
        self.w.extend(std::iter::repeat(w).take(n));
        self.damp.extend(std::iter::repeat(t.linear_damp).take(n));
        self.bead_ring.extend(std::iter::repeat(idx as u32).take(n));
        self.bonded.extend(std::iter::repeat(0u8).take(n));
        self.rings.push(CRing { cell, start, n, rest, rest_edges, rest_bend, w });
        self.cells[cell].kind = Kind::Ring(idx);
        idx
    }

    fn push_core(&mut self, cell: usize, at: Vector2, vel: Vector2) -> usize {
        let t = self.cells[cell].t;
        let k = self.cpos.len();
        let m = t.mass();
        self.cpos.push(at);
        self.cprev.push(at);
        self.cvel.push(vel);
        self.cforce.push(Vector2::ZERO);
        self.cr.push(t.radius);
        self.cw.push(if m > 0.0 { 1.0 / m } else { 0.0 });
        self.cdamp.push(t.linear_damp);
        self.ccell.push(cell as u32);
        self.cells[cell].kind = Kind::Core(k);
        k
    }

    /// Holds the creature together: every ring bead within `capture` px (gap between
    /// outlines) of a neighbouring cell's outline is bonded to its nearest point there
    /// (an edge of a ring, or a core's rim), and touching cores to each other.
    pub fn build_bonds(&mut self, capture: f32, bond_scale: f32) -> usize {
        self.bonds.clear();
        self.bonded.iter_mut().for_each(|b| *b = 0);
        let centers: Vec<Vector2> = (0..self.cells.len()).map(|i| self.cell_center(i)).collect();
        let reach: Vec<f32> = self.cells.iter().map(|c| c.t.radius * 1.3).collect();
        // Neighbouring cells, by a plain sweep over x.
        let mut order: Vec<usize> = (0..self.cells.len()).collect();
        order.sort_by(|&a, &b| centers[a].x.partial_cmp(&centers[b].x).unwrap_or(std::cmp::Ordering::Equal).then(a.cmp(&b)));
        let rmax = reach.iter().copied().fold(0.0f32, f32::max);
        let mut near: Vec<Vec<usize>> = vec![Vec::new(); self.cells.len()];
        for (oi, &a) in order.iter().enumerate() {
            for &b in &order[oi + 1..] {
                if centers[b].x - centers[a].x > reach[a] + rmax + capture {
                    break;
                }
                if dist(centers[a], centers[b]) <= reach[a] + reach[b] + capture {
                    near[a].push(b);
                    near[b].push(a);
                }
            }
        }
        for list in near.iter_mut() {
            list.sort_unstable();
        }
        let mut bonds = Vec::new();
        for a in 0..self.cells.len() {
            let ta = self.cells[a].t;
            match self.cells[a].kind {
                Kind::Ring(ra) => {
                    let ring = &self.rings[ra];
                    for i in ring.start..ring.start + ring.n {
                        let p = self.pos[i];
                        let mut best: Option<(f32, End, f32, f32)> = None;
                        for &b in &near[a] {
                            let tb = self.cells[b].t;
                            match self.cells[b].kind {
                                Kind::Ring(rb) => {
                                    let other = &self.rings[rb];
                                    for e in 0..other.n {
                                        let j = other.start + e;
                                        let k = other.start + (e + 1) % other.n;
                                        let (pj, pk) = (self.pos[j], self.pos[k]);
                                        let seg = pk - pj;
                                        let l2 = len_sq(seg);
                                        let t = if l2 > 0.0 { (dot(p - pj, seg) / l2).clamp(0.0, 1.0) } else { 0.0 };
                                        let q = pj + seg * t;
                                        let rest = ta.bead_radius + tb.bead_radius;
                                        let gap = dist(p, q) - rest;
                                        if gap < capture && best.is_none_or(|bb| gap < bb.0) {
                                            best = Some((gap, End::Edge(j as u32, k as u32, t), rest, ta.skin_k.min(tb.skin_k)));
                                        }
                                    }
                                }
                                Kind::Core(kb) => {
                                    let rest = ta.bead_radius + self.cr[kb];
                                    let gap = dist(p, self.cpos[kb]) - rest;
                                    if gap < capture && best.is_none_or(|bb| gap < bb.0) {
                                        best = Some((gap, End::Core(kb as u32), rest, ta.skin_k.min(tb.skin_k)));
                                    }
                                }
                            }
                        }
                        if let Some((_, end, rest, k)) = best {
                            bonds.push(Bond { a: End::Bead(i as u32), b: end, rest, alpha: 1.0 / (k * bond_scale).max(1e-6) });
                            self.bonded[i] = self.bonded[i].saturating_add(1);
                            match end {
                                End::Edge(j, k, _) => {
                                    self.bonded[j as usize] = self.bonded[j as usize].saturating_add(1);
                                    self.bonded[k as usize] = self.bonded[k as usize].saturating_add(1);
                                }
                                _ => {}
                            }
                        }
                    }
                }
                Kind::Core(ka) => {
                    for &b in &near[a] {
                        if b <= a {
                            continue;
                        }
                        if let Kind::Core(kb) = self.cells[b].kind {
                            let tb = self.cells[b].t;
                            let rest = self.cr[ka] + self.cr[kb];
                            if dist(self.cpos[ka], self.cpos[kb]) - rest < capture {
                                bonds.push(Bond {
                                    a: End::Core(ka as u32),
                                    b: End::Core(kb as u32),
                                    rest,
                                    alpha: 1.0 / (ta.skin_k.min(tb.skin_k) * bond_scale).max(1e-6),
                                });
                            }
                        }
                    }
                }
            }
        }
        self.bonds = bonds;
        self.bonds.len()
    }

    // ---- Stepping (each creature on its own data) ----

    fn frame_forces(&mut self, gravity: Vector2) {
        let push = self.push;
        for ring in &self.rings {
            let t = &self.cells[ring.cell].t;
            let (start, n) = (ring.start, ring.n);
            let pts = &self.pos[start..start + n];
            if t.pressure_k > 0.0 && t.target_area > 0.0 && is_ccw(pts) {
                let target = t.target_area as f64;
                let current = outline_area(pts, t.bead_radius as f64).max(MIN_AREA_RATIO * target);
                let pk = t.pressure_k as f64;
                let max_p = MAX_PRESSURE_RATIO * pk;
                let pressure = (pk * (target / current - 1.0)).clamp(-max_p, max_p);
                let half = (0.5 * pressure) as f32;
                for k in 0..n {
                    let e = self.pos[start + (k + 1) % n] - self.pos[start + k];
                    let f = Vector2::new(-e.y, e.x) * half;
                    self.force[start + k] += f;
                    self.force[start + (k + 1) % n] += f;
                }
            }
            let mean = centroid(&self.vel[start..start + n]);
            let drag = t.internal_damp * t.bead_mass;
            for i in start..start + n {
                let f = (self.vel[i] - mean) * -drag + (push + gravity) * t.bead_mass;
                self.force[i] += f;
            }
        }
        for k in 0..self.cpos.len() {
            let m = if self.cw[k] > 0.0 { 1.0 / self.cw[k] } else { 0.0 };
            self.cforce[k] += (push + gravity) * m;
        }
    }

    fn predict(&mut self) {
        let h = self.h;
        for i in 0..self.pos.len() {
            let mut v = self.vel[i] + self.force[i] * (self.w[i] * h);
            v = v / (1.0 + h * self.damp[i]);
            self.prev[i] = self.pos[i];
            self.pos[i] = self.prev[i] + v * h;
            self.vel[i] = v;
        }
        for k in 0..self.cpos.len() {
            let mut v = self.cvel[k] + self.cforce[k] * (self.cw[k] * h);
            v = v / (1.0 + h * self.cdamp[k]);
            self.cprev[k] = self.cpos[k];
            self.cpos[k] = self.cprev[k] + v * h;
            self.cvel[k] = v;
        }
    }

    /// kernel.rs's solve_ring() on each ring: skin and bending distances, shape matching,
    /// the stretch limit.
    fn solve_rings(&mut self) {
        let h = self.h;
        let h2 = h * h;
        for ring in &self.rings {
            let t = &self.cells[ring.cell].t;
            let n = ring.n;
            if n < 3 {
                continue;
            }
            let pos = &mut self.pos[ring.start..ring.start + n];
            let prev = &self.prev[ring.start..ring.start + n];
            let w = ring.w;
            distances(pos, prev, &ring.rest_edges, 1, t.skin_k, t.skin_d, w, h);
            distances(pos, prev, &ring.rest_bend, 2, t.bend_k, t.bend_d, w, h);
            if t.shape_k > 0.0 {
                let cc = centroid(pos);
                let (mut cs, mut dt) = (0.0f32, 0.0f32);
                for i in 0..n {
                    let (q, p) = (ring.rest[i], pos[i] - cc);
                    cs += cross(q, p);
                    dt += dot(q, p);
                }
                let norm_len = (cs * cs + dt * dt).sqrt();
                let (c, sn) = if norm_len > 0.0 { (dt / norm_len, cs / norm_len) } else { (1.0, 0.0) };
                let k = (t.shape_k * h2) / (1.0 + t.shape_k * h2);
                for i in 0..n {
                    let q = ring.rest[i];
                    let goal = cc + Vector2::new(q.x * c - q.y * sn, q.x * sn + q.y * c);
                    pos[i] += (goal - pos[i]) * k;
                }
            }
            for i in 0..n {
                let j = (i + 1) % n;
                let e = pos[j] - pos[i];
                let length = len(e);
                let limit = MAX_STRETCH as f32 * ring.rest_edges[i];
                if length > limit && length > 0.0 {
                    let corr = e * (0.5 * (length - limit) / length);
                    pos[i] += corr;
                    pos[j] -= corr;
                }
            }
        }
    }

    #[inline]
    fn end_point(&self, e: End) -> (Vector2, f32) {
        match e {
            End::Bead(i) => (self.pos[i as usize], self.w[i as usize]),
            End::Core(k) => (self.cpos[k as usize], self.cw[k as usize]),
            End::Edge(j, k, t) => {
                let (j, k) = (j as usize, k as usize);
                let p = self.pos[j] * (1.0 - t) + self.pos[k] * t;
                (p, self.w[j] * (1.0 - t) * (1.0 - t) + self.w[k] * t * t)
            }
        }
    }

    #[inline]
    fn end_move(&mut self, e: End, d: Vector2) {
        match e {
            End::Bead(i) => self.pos[i as usize] += d * self.w[i as usize],
            End::Core(k) => self.cpos[k as usize] += d * self.cw[k as usize],
            End::Edge(j, k, t) => {
                let (j, k) = (j as usize, k as usize);
                self.pos[j] += d * (self.w[j] * (1.0 - t));
                self.pos[k] += d * (self.w[k] * t);
            }
        }
    }

    fn solve_bonds(&mut self) {
        let inv_h2 = 1.0 / (self.h * self.h);
        for b in 0..self.bonds.len() {
            let bond = self.bonds[b];
            let (pa, wa) = self.end_point(bond.a);
            let (pb, wb) = self.end_point(bond.b);
            let d = pa - pb;
            let l = len(d);
            if l < 1e-6 {
                continue;
            }
            let n = d / l;
            let c = l - bond.rest;
            let denom = wa + wb + bond.alpha * inv_h2;
            if denom <= 0.0 {
                continue;
            }
            let dl = -c / denom;
            self.end_move(bond.a, n * dl);
            self.end_move(bond.b, n * -dl);
        }
    }

    fn solve_intra(&mut self) {
        for k in 0..self.bb.len() {
            let (i, j) = (self.bb[k].0 as usize, self.bb[k].1 as usize);
            let reach = self.r[i] + self.r[j];
            let d = self.pos[i] - self.pos[j];
            let dsq = len_sq(d);
            if dsq >= reach * reach {
                continue;
            }
            let dist = dsq.sqrt();
            let n = if dist > 1e-6 { d / dist } else { Vector2::new(0.0, -1.0) };
            let (wa, wb) = (self.w[i], self.w[j]);
            let s = (reach - dist) / (wa + wb);
            self.pos[i] += n * (s * wa);
            self.pos[j] -= n * (s * wb);
        }
        for k in 0..self.bc.len() {
            let (i, c) = (self.bc[k].0 as usize, self.bc[k].1 as usize);
            let reach = self.r[i] + self.cr[c];
            let d = self.pos[i] - self.cpos[c];
            let dsq = len_sq(d);
            if dsq >= reach * reach {
                continue;
            }
            let dist = dsq.sqrt();
            let n = if dist > 1e-6 { d / dist } else { Vector2::new(0.0, -1.0) };
            let (wa, wb) = (self.w[i], self.cw[c]);
            let s = (reach - dist) / (wa + wb);
            self.pos[i] += n * (s * wa);
            self.cpos[c] -= n * (s * wb);
        }
        for k in 0..self.cc.len() {
            let (a, b) = (self.cc[k].0 as usize, self.cc[k].1 as usize);
            let reach = self.cr[a] + self.cr[b];
            let d = self.cpos[a] - self.cpos[b];
            let dsq = len_sq(d);
            if dsq >= reach * reach {
                continue;
            }
            let dist = dsq.sqrt();
            let n = if dist > 1e-6 { d / dist } else { Vector2::new(0.0, -1.0) };
            let (wa, wb) = (self.cw[a], self.cw[b]);
            let s = (reach - dist) / (wa + wb);
            self.cpos[a] += n * (s * wa);
            self.cpos[b] -= n * (s * wb);
        }
    }

    fn substep_own(&mut self) {
        if !self.active {
            return;
        }
        self.predict();
        let t = Instant::now();
        self.solve_rings();
        self.ns_rings += ns(t);
        let t = Instant::now();
        self.solve_bonds();
        self.ns_bonds += ns(t);
        let t = Instant::now();
        self.solve_intra();
        self.ns_intra += ns(t);
    }

    fn velocities(&mut self, cap: f32) {
        if !self.active {
            return;
        }
        let inv_h = 1.0 / self.h;
        let cap_sq = cap * cap;
        for i in 0..self.pos.len() {
            let mut v = (self.pos[i] - self.prev[i]) * inv_h;
            let sq = len_sq(v);
            if cap > 0.0 && sq > cap_sq {
                v = v * (cap / sq.sqrt());
            }
            self.vel[i] = v;
        }
        for k in 0..self.cpos.len() {
            let mut v = (self.cpos[k] - self.cprev[k]) * inv_h;
            let sq = len_sq(v);
            if cap > 0.0 && sq > cap_sq {
                v = v * (cap / sq.sqrt());
            }
            self.cvel[k] = v;
        }
    }

    /// This step's candidates within the creature (see Colony::build_pairs()).
    fn build_own_pairs(&mut self, opt: Options) {
        self.bb.clear();
        self.bc.clear();
        self.cc.clear();
        let (n, nc) = (self.pos.len(), self.cpos.len());
        let dt = self.dt;
        let mut mean = Vector2::ZERO;
        for &v in self.vel.iter().chain(self.cvel.iter()) {
            mean += v;
        }
        mean = mean / (n + nc).max(1) as f32;
        let common = self.push + opt.gravity;
        let active = self.active;
        let margin = |v: Vector2, a: Vector2| PAIR_SLACK * (len(v) * dt + 0.5 * len(a) * dt * dt) + PAIR_PAD;
        self.reach.clear();
        self.abs_reach.clear();
        self.creach.clear();
        self.cabs_reach.clear();
        let mut bounds: Option<Rect> = None;
        for i in 0..n {
            let a = self.force[i] * self.w[i];
            let (rel, abs) = if active { (margin(self.vel[i] - mean, a - common), margin(self.vel[i], a)) } else { (0.0, 0.0) };
            self.reach.push(self.r[i] + rel);
            self.abs_reach.push(self.r[i] + abs);
            let q = self.r[i] + abs;
            let b = Rect::new(self.pos[i] - Vector2::new(q, q), Vector2::new(2.0 * q, 2.0 * q));
            bounds = Some(match bounds { Some(r) => r.expand(b.pos).expand(b.pos + b.size), None => b });
        }
        for k in 0..nc {
            let a = self.cforce[k] * self.cw[k];
            let (rel, abs) = if active { (margin(self.cvel[k] - mean, a - common), margin(self.cvel[k], a)) } else { (0.0, 0.0) };
            self.creach.push(self.cr[k] + rel);
            self.cabs_reach.push(self.cr[k] + abs);
            let q = self.cr[k] + abs;
            let b = Rect::new(self.cpos[k] - Vector2::new(q, q), Vector2::new(2.0 * q, 2.0 * q));
            bounds = Some(match bounds { Some(r) => r.expand(b.pos).expand(b.pos + b.size), None => b });
        }
        self.aabb = bounds.unwrap_or_default();
        // Without contacts between its own cells (the bonds keep them apart) a creature
        // needs no grid of its own: a pressurised cell does not fold onto itself.
        let cores_only = !opt.intra_contacts && opt.core_contacts && nc > 0;
        if !active || !(opt.intra_contacts || cores_only) {
            return;
        }
        let slop = opt.slop;
        let intra = true;
        let qmax = self.reach.iter().copied().fold(0.0f32, f32::max);
        let cell = ((2.0 * qmax + slop) * opt.cell_scale).max(1.0);
        if !cores_only {
            self.grid.build(&self.pos, cell);
        }
        let cqmax = self.creach.iter().copied().fold(0.0f32, f32::max);
        let ccell = (2.0 * cqmax + slop).max(1.0);
        if nc > 0 {
            self.cgrid.build(&self.cpos, ccell);
        }
        let grid = &self.grid;
        let cgrid = &self.cgrid;
        for li in 0..n {
            let qi = self.reach[li];
            let pi = self.pos[li];
            let ra = self.bead_ring[li];
            let span = if cores_only { -1 } else { ((qi + qmax + slop) / cell).ceil() as i32 };
            let (cx, cy) = if cores_only { (0, 0) } else { grid.cells[li] };
            for dy in -span..=span {
                for dx in -span..=span {
                    let (tx, ty) = (cx + dx, cy + dy);
                    let bkt = grid.bucket(tx, ty);
                    for kk in grid.start[bkt] as usize..grid.start[bkt + 1] as usize {
                        let lj = grid.items[kk] as usize;
                        if lj <= li || grid.cells[lj] != (tx, ty) {
                            continue;
                        }
                        let rb = self.bead_ring[lj];
                        if ra == rb {
                            let ring = &self.rings[ra as usize];
                            let hop = (li - ring.start).abs_diff(lj - ring.start);
                            if hop.min(ring.n - hop) <= 2 {
                                continue;
                            }
                        } else if !intra {
                            continue;
                        }
                        let within = qi + self.reach[lj] + slop;
                        if dist_sq(pi, self.pos[lj]) < within * within {
                            self.bb.push((li as u32, lj as u32));
                        }
                    }
                }
            }
            if nc == 0 || !intra {
                continue;
            }
            let span = ((qi + cqmax + slop) / ccell).ceil() as i32;
            let (cx, cy) = cgrid.cell_of(pi);
            for dy in -span..=span {
                for dx in -span..=span {
                    let (tx, ty) = (cx + dx, cy + dy);
                    let bkt = cgrid.bucket(tx, ty);
                    for kk in cgrid.start[bkt] as usize..cgrid.start[bkt + 1] as usize {
                        let lk = cgrid.items[kk] as usize;
                        if cgrid.cells[lk] != (tx, ty) {
                            continue;
                        }
                        let within = qi + self.creach[lk] + slop;
                        if dist_sq(pi, self.cpos[lk]) < within * within {
                            self.bc.push((li as u32, lk as u32));
                        }
                    }
                }
            }
        }
        if !intra {
            return;
        }
        for lk in 0..nc {
            let qk = self.creach[lk];
            let pk = self.cpos[lk];
            let span = ((qk + cqmax + slop) / ccell).ceil() as i32;
            let (cx, cy) = cgrid.cells[lk];
            for dy in -span..=span {
                for dx in -span..=span {
                    let (tx, ty) = (cx + dx, cy + dy);
                    let bkt = cgrid.bucket(tx, ty);
                    for kk in cgrid.start[bkt] as usize..cgrid.start[bkt + 1] as usize {
                        let lj = cgrid.items[kk] as usize;
                        if lj <= lk || cgrid.cells[lj] != (tx, ty) {
                            continue;
                        }
                        let within = qk + self.creach[lj] + slop;
                        if dist_sq(pk, self.cpos[lj]) < within * within {
                            self.cc.push((lk as u32, lj as u32));
                        }
                    }
                }
            }
        }
    }

    // ---- Promotion and demotion ----

    /// Removes core `k`, renumbering the later ones.
    fn remove_core(&mut self, k: usize) {
        self.cpos.remove(k);
        self.cprev.remove(k);
        self.cvel.remove(k);
        self.cforce.remove(k);
        self.cr.remove(k);
        self.cw.remove(k);
        self.cdamp.remove(k);
        self.ccell.remove(k);
        for c in self.cells.iter_mut() {
            if let Kind::Core(j) = c.kind {
                if j > k {
                    c.kind = Kind::Core(j - 1);
                }
            }
        }
    }

    /// Removes ring `r` and its beads, renumbering the later ones.
    fn remove_ring(&mut self, r: usize) {
        let ring = self.rings.remove(r);
        let range = ring.start..ring.start + ring.n;
        self.pos.drain(range.clone());
        self.prev.drain(range.clone());
        self.vel.drain(range.clone());
        self.force.drain(range.clone());
        self.r.drain(range.clone());
        self.w.drain(range.clone());
        self.damp.drain(range.clone());
        self.bead_ring.drain(range.clone());
        self.bonded.drain(range);
        for later in self.rings.iter_mut().skip(r) {
            later.start -= ring.n;
        }
        for owner in self.bead_ring.iter_mut() {
            if *owner as usize > r {
                *owner -= 1;
            }
        }
        for c in self.cells.iter_mut() {
            if let Kind::Ring(j) = c.kind {
                if j > r {
                    c.kind = Kind::Ring(j - 1);
                }
            }
        }
    }

    /// Core cell `cell` becomes a ring: its beads on the circle it rests on, each pulled
    /// in along its ray until it clears every neighbouring bead and core, moving with the
    /// core. Returns the deepest overlap left with a neighbour (0: none), or -1 when the
    /// cell is not a core.
    pub fn promote(&mut self, cell: usize, capture: f32, bond_scale: f32) -> f32 {
        let Kind::Core(k) = self.cells[cell].kind else { return -1.0 };
        let t = self.cells[cell].t;
        let (c, v) = (self.cpos[k], self.cvel[k]);
        let n = t.beads;
        let br = t.bead_radius;
        let reach = t.radius * 2.5;
        // The obstacles: discs of neighbouring beads and cores (not this core).
        let mut discs: Vec<(Vector2, f32)> = Vec::new();
        for (i, &p) in self.pos.iter().enumerate() {
            if dist_sq(p, c) < reach * reach {
                discs.push((p, self.r[i]));
            }
        }
        for (j, &p) in self.cpos.iter().enumerate() {
            if j != k && dist_sq(p, c) < reach * reach {
                discs.push((p, self.cr[j]));
            }
        }
        let dirs = circle(Vector2::ZERO, 1.0, n);
        let mut points = Vec::with_capacity(n);
        for &dir in &dirs {
            let mut s = t.ring_radius;
            for &(o, ro) in &discs {
                let rel = o - c;
                let along = dot(rel, dir);
                if along <= 0.0 {
                    continue;
                }
                let rr = br + ro;
                let off = len_sq(rel) - along * along;
                if off >= rr * rr {
                    continue;
                }
                let enter = along - (rr * rr - off).sqrt();
                s = s.min(enter.max(0.5 * t.ring_radius));
            }
            points.push(c + dir * s);
        }
        self.remove_core(k);
        let ring = self.push_ring(cell, &points, v);
        self.build_bonds(capture, bond_scale);
        self.topology += 1;
        let start = self.rings[ring].start;
        let mut worst = 0.0f32;
        for i in start..start + n {
            for &(o, ro) in &discs {
                worst = worst.max(br + ro - dist(self.pos[i], o));
            }
        }
        worst.max(0.0)
    }

    /// Ring cell `cell` becomes a core at its beads' centroid, moving with their mean
    /// velocity. Returns the deepest overlap of the new core with a neighbouring bead or
    /// core (what the contacts will push out), or -1 when the cell is not a ring.
    pub fn demote(&mut self, cell: usize, capture: f32, bond_scale: f32) -> f32 {
        let Kind::Ring(r) = self.cells[cell].kind else { return -1.0 };
        let c = self.cell_center(cell);
        let v = self.cell_velocity(cell);
        self.remove_ring(r);
        let k = self.push_core(cell, c, v);
        self.build_bonds(capture, bond_scale);
        self.topology += 1;
        let rc = self.cr[k];
        let mut worst = 0.0f32;
        for (i, &p) in self.pos.iter().enumerate() {
            worst = worst.max(rc + self.r[i] - dist(p, c));
        }
        for (j, &p) in self.cpos.iter().enumerate() {
            if j != k {
                worst = worst.max(rc + self.cr[j] - dist(p, c));
            }
        }
        worst.max(0.0)
    }

    // ---- Drawing ----

    /// Vertices of the creature's mesh: per ring cell its centre and one per bead, per
    /// core (unless `rings_only`) its centre and CORE_SIDES around.
    pub fn vertex_count(&self, rings_only: bool) -> usize {
        let rings: usize = self.rings.iter().map(|r| r.n + 1).sum();
        rings + if rings_only { 0 } else { self.cpos.len() * (CORE_SIDES + 1) }
    }

    /// The mesh's attributes, once (they change only with the topology): per vertex a
    /// colour, a UV (the point's place in its cell's rest frame over the cell's radius:
    /// length 1 on the outline) and a custom vec4 (cell radius px, exposed weight 0..1,
    /// cell index, 0), and the fans' indices.
    pub fn mesh_static(&self, rings_only: bool) -> (Vec<[f32; 4]>, Vec<Vector2>, Vec<[f32; 4]>, Vec<i32>) {
        let mut colors = Vec::new();
        let mut uvs = Vec::new();
        let mut custom = Vec::new();
        let mut indices = Vec::new();
        let mut base = 0i32;
        for ring in &self.rings {
            let t = &self.cells[ring.cell].t;
            let col = [t.color[0], t.color[1], t.color[2], 1.0];
            let grow = (t.ring_radius + t.bead_radius) / t.ring_radius.max(1e-3) / t.radius.max(1e-3);
            colors.push(col);
            uvs.push(Vector2::ZERO);
            custom.push([t.radius, 0.0, ring.cell as f32, 0.0]);
            for i in 0..ring.n {
                colors.push(col);
                uvs.push(ring.rest[i] * grow);
                let exposed = if self.bonded[ring.start + i] == 0 { 1.0 } else { 0.0 };
                custom.push([t.radius, exposed, ring.cell as f32, 0.0]);
                indices.extend_from_slice(&[base, base + 1 + i as i32, base + 1 + ((i + 1) % ring.n) as i32]);
            }
            base += ring.n as i32 + 1;
        }
        if !rings_only {
            let dirs = circle(Vector2::ZERO, 1.0, CORE_SIDES);
            for k in 0..self.cpos.len() {
                let cell = self.ccell[k] as usize;
                let t = &self.cells[cell].t;
                let col = [t.color[0], t.color[1], t.color[2], 1.0];
                colors.push(col);
                uvs.push(Vector2::ZERO);
                custom.push([t.radius, 0.0, cell as f32, 0.0]);
                for (s, &d) in dirs.iter().enumerate() {
                    colors.push(col);
                    uvs.push(d);
                    custom.push([t.radius, 0.0, cell as f32, 0.0]);
                    indices.extend_from_slice(&[base, base + 1 + s as i32, base + 1 + ((s + 1) % CORE_SIDES) as i32]);
                }
                base += CORE_SIDES as i32 + 1;
            }
        }
        (colors, uvs, custom, indices)
    }

    /// The mesh's vertex positions now (vertex_count() of them), as `emit` receives them.
    fn each_position<F: FnMut(Vector2)>(&self, rings_only: bool, mut emit: F) {
        for ring in &self.rings {
            let br = self.cells[ring.cell].t.bead_radius;
            let pts = &self.pos[ring.start..ring.start + ring.n];
            let c = centroid(pts);
            emit(c);
            let n = ring.n;
            for i in 0..n {
                let e = pts[(i + 1) % n] - pts[(i + n - 1) % n];
                let mut nrm = norm(Vector2::new(-e.y, e.x));
                if dot(nrm, pts[i] - c) < 0.0 {
                    nrm = -nrm;
                }
                emit(pts[i] + nrm * br);
            }
        }
        if !rings_only {
            let dirs = circle(Vector2::ZERO, 1.0, CORE_SIDES);
            for k in 0..self.cpos.len() {
                let c = self.cpos[k];
                let r = self.cr[k];
                emit(c);
                for &d in &dirs {
                    emit(c + d * r);
                }
            }
        }
    }

    /// Writes the positions as Godot's 2D vertex buffer wants them (two little-endian
    /// f32 per vertex) into `out` (at least vertex_count() × 8 bytes).
    pub fn write_positions(&self, rings_only: bool, out: &mut [u8]) {
        let mut o = 0usize;
        self.each_position(rings_only, |p| {
            out[o..o + 4].copy_from_slice(&p.x.to_le_bytes());
            out[o + 4..o + 8].copy_from_slice(&p.y.to_le_bytes());
            o += 8;
        });
    }

    pub fn positions(&self, rings_only: bool) -> Vec<Vector2> {
        let mut v = Vec::with_capacity(self.vertex_count(rings_only));
        self.each_position(rings_only, |p| v.push(p));
        v
    }

    /// Writes the attribute buffer (colour as `color_bytes` 4 (RGBA8) or 16 (RGBA f32),
    /// UV, custom0 RGBA f32 per vertex) into `out`.
    pub fn write_attributes(&self, rings_only: bool, color_bytes: usize, out: &mut Vec<u8>) {
        let (colors, uvs, custom, _) = self.mesh_static(rings_only);
        out.clear();
        for i in 0..colors.len() {
            if color_bytes == 4 {
                for ch in colors[i] {
                    out.push((ch.clamp(0.0, 1.0) * 255.0).round() as u8);
                }
            } else {
                for ch in colors[i] {
                    out.extend_from_slice(&ch.to_le_bytes());
                }
            }
            out.extend_from_slice(&uvs[i].x.to_le_bytes());
            out.extend_from_slice(&uvs[i].y.to_le_bytes());
            for ch in custom[i] {
                out.extend_from_slice(&ch.to_le_bytes());
            }
        }
    }

    /// The cores as MultiMesh instances (INSTANCE_FLOATS each): a 2D transform scaling a
    /// unit disc to the core, its colour, custom (radius, 0, cell, 0).
    pub fn write_core_instances(&self, out: &mut [f32]) {
        for k in 0..self.cpos.len() {
            let cell = self.ccell[k] as usize;
            let t = &self.cells[cell].t;
            let (c, r) = (self.cpos[k], self.cr[k]);
            let o = k * INSTANCE_FLOATS;
            out[o..o + INSTANCE_FLOATS].copy_from_slice(&[
                r, 0.0, 0.0, c.x, 0.0, r, 0.0, c.y, t.color[0], t.color[1], t.color[2], 1.0, r, 0.0, cell as f32, 0.0,
            ]);
        }
    }
}

/// The contact candidates between creatures `a` and `b`: their particles inside the
/// overlap of their boxes, b's hashed, a's looked up, by absolute reach.
fn find_cross(creatures: &[Creature], a: usize, b: usize, slop: f32) -> Vec<Cross> {
    let (ca, cb) = (&creatures[a], &creatures[b]);
    let lo = vmax(ca.aabb.pos, cb.aabb.pos);
    let hi = vmin(ca.aabb.pos + ca.aabb.size, cb.aabb.pos + cb.aabb.size);
    let zone = Rect::new(lo, vmax(hi - lo, Vector2::ZERO));
    let gather = |c: &Creature| {
        let mut items: Vec<(Vector2, f32, u32, bool)> = Vec::new();
        for i in 0..c.pos.len() {
            let q = c.abs_reach[i];
            if zone.grow(q).has_point(c.pos[i]) {
                items.push((c.pos[i], q, i as u32, false));
            }
        }
        for k in 0..c.cpos.len() {
            let q = c.cabs_reach[k];
            if zone.grow(q).has_point(c.cpos[k]) {
                items.push((c.cpos[k], q, k as u32, true));
            }
        }
        items
    };
    let (ia, ib) = (gather(ca), gather(cb));
    let mut out = Vec::new();
    if ia.is_empty() || ib.is_empty() {
        return out;
    }
    let qmax = ia.iter().chain(ib.iter()).map(|x| x.1).fold(0.0f32, f32::max);
    let cell = (2.0 * qmax + slop).max(1.0);
    let positions: Vec<Vector2> = ib.iter().map(|x| x.0).collect();
    let mut grid = Grid::default();
    grid.build(&positions, cell);
    for &(p, q, i, core) in &ia {
        let (cx, cy) = grid.cell_of(p);
        for dy in -1..=1 {
            for dx in -1..=1 {
                let (tx, ty) = (cx + dx, cy + dy);
                let bkt = grid.bucket(tx, ty);
                for kk in grid.start[bkt] as usize..grid.start[bkt + 1] as usize {
                    let j = grid.items[kk] as usize;
                    if grid.cells[j] != (tx, ty) {
                        continue;
                    }
                    let within = q + ib[j].1 + slop;
                    if dist_sq(p, ib[j].0) < within * within {
                        out.push(Cross { ca: a as u32, ia: i, a_core: core, cb: b as u32, ib: ib[j].2, b_core: ib[j].3 });
                    }
                }
            }
        }
    }
    out
}

impl Colony {
    pub fn set_threads(&mut self, threads: usize) {
        let threads = threads.max(1);
        self.opt.threads = threads;
        if threads == self.pool_threads && (threads == 1) == self.pool.is_none() {
            return;
        }
        self.pool_threads = threads;
        self.pool = if threads > 1 {
            rayon::ThreadPoolBuilder::new().num_threads(threads).build().ok()
        } else {
            None
        };
    }

    /// Adds a creature of the cells in `cells` (CELL_STRIDE floats each); returns its index.
    pub fn add_creature(&mut self, cells: &[f32]) -> usize {
        let mut c = Creature { every: 1, ..Default::default() };
        let count = cells.len() / CELL_STRIDE;
        for i in 0..count {
            let f = &cells[i * CELL_STRIDE..(i + 1) * CELL_STRIDE];
            c.cells.push(Cell { kind: Kind::Core(0), t: CellTuning::from_floats(f) });
        }
        for i in 0..count {
            let f = &cells[i * CELL_STRIDE..(i + 1) * CELL_STRIDE];
            let at = Vector2::new(f[0], f[1]);
            if f[3] > 0.5 {
                c.push_core(i, at, Vector2::ZERO);
            } else {
                let t = c.cells[i].t;
                let pts = circle(at, t.ring_radius, t.beads);
                c.push_ring(i, &pts, Vector2::ZERO);
            }
        }
        self.creatures.push(c);
        self.creatures.len() - 1
    }

    fn for_each<F: Fn(&mut Creature) + Sync + Send>(&mut self, f: F) {
        let creatures = &mut self.creatures;
        match &self.pool {
            Some(pool) => pool.install(|| creatures.par_iter_mut().for_each(|c| f(c))),
            None => creatures.iter_mut().for_each(|c| f(c)),
        }
    }

    pub fn step(&mut self, delta: f32) {
        let clock = Instant::now();
        self.frame += 1;
        let opt = self.opt;
        let n_sub = opt.substeps.max(1);
        let frame = self.frame;
        for c in self.creatures.iter_mut() {
            let every = c.every.max(1);
            c.active = !c.asleep && (frame + c.phase as u64) % every as u64 == 0;
            c.dt = delta * every as f32;
            c.h = c.dt / n_sub as f32;
            c.ns_rings = 0;
            c.ns_bonds = 0;
            c.ns_intra = 0;
        }
        let mut stats = Stats { draw_build_us: self.stats.draw_build_us, ..Default::default() };
        let t = Instant::now();
        self.for_each(|c| {
            if c.active {
                c.frame_forces(opt.gravity);
            }
        });
        stats.forces_us = t.elapsed().as_micros() as u64;
        let t = Instant::now();
        self.build_pairs();
        stats.pairs_us = t.elapsed().as_micros() as u64;
        let (mut solve, mut cross, mut vel) = (0u64, 0u64, 0u64);
        for _ in 0..n_sub {
            let t = Instant::now();
            self.for_each(|c| c.substep_own());
            solve += ns(t);
            let t = Instant::now();
            stats.cross_hits = self.solve_cross();
            cross += ns(t);
            let t = Instant::now();
            self.for_each(|c| c.velocities(opt.max_speed));
            vel += ns(t);
        }
        for c in self.creatures.iter_mut() {
            c.force.iter_mut().for_each(|f| *f = Vector2::ZERO);
            c.cforce.iter_mut().for_each(|f| *f = Vector2::ZERO);
            stats.rings_cpu_us += c.ns_rings / 1000;
            stats.bonds_cpu_us += c.ns_bonds / 1000;
            stats.intra_cpu_us += c.ns_intra / 1000;
            stats.intra_pairs += c.bb.len() + c.bc.len() + c.cc.len();
        }
        stats.cross_pairs = self.cross.len();
        stats.solve_us = solve / 1000;
        stats.cross_us = cross / 1000;
        stats.vel_us = vel / 1000;
        stats.total_us = clock.elapsed().as_micros() as u64;
        self.stats = stats;
    }

    /// This step's contact candidates. Within each creature (in parallel): its own beads
    /// and cores hashed in grids of its own, each particle's reach its radius grown by how
    /// far it can move in the step against the creature's mean motion (a creature
    /// swimming at 200 px/s needs no 4 px of margin between its own cells). Between
    /// creatures: only pairs of creatures whose boxes (grown by each particle's reach in
    /// absolute terms) overlap, and only their particles inside the overlap.
    fn build_pairs(&mut self) {
        let opt = self.opt;
        self.for_each(|c| c.build_own_pairs(opt));
        let mut overlapping = Vec::new();
        for a in 0..self.creatures.len() {
            for b in a + 1..self.creatures.len() {
                let (ca, cb) = (&self.creatures[a], &self.creatures[b]);
                if (ca.active || cb.active) && ca.aabb.intersects(&cb.aabb) {
                    overlapping.push((a, b));
                }
            }
        }
        let creatures = &self.creatures;
        let find = |&(a, b): &(usize, usize)| find_cross(creatures, a, b, opt.slop);
        let lists: Vec<Vec<Cross>> = match &self.pool {
            Some(pool) => pool.install(|| overlapping.par_iter().map(find).collect()),
            None => overlapping.iter().map(find).collect(),
        };
        self.cross.clear();
        for list in lists {
            self.cross.extend_from_slice(&list);
        }
    }

    /// The contacts between creatures, serially, in the order build_pairs() found them. A
    /// creature not stepped this frame does not move. Returns how many overlapped.
    fn solve_cross(&mut self) -> usize {
        let mut hits = 0;
        for k in 0..self.cross.len() {
            let x = self.cross[k];
            let (a, b) = two_mut(&mut self.creatures, x.ca as usize, x.cb as usize);
            let (ia, ib) = (x.ia as usize, x.ib as usize);
            let (pa, ra, wa) = if x.a_core { (a.cpos[ia], a.cr[ia], a.cw[ia]) } else { (a.pos[ia], a.r[ia], a.w[ia]) };
            let (pb, rb, wb) = if x.b_core { (b.cpos[ib], b.cr[ib], b.cw[ib]) } else { (b.pos[ib], b.r[ib], b.w[ib]) };
            let wa = if a.active { wa } else { 0.0 };
            let wb = if b.active { wb } else { 0.0 };
            let reach = ra + rb;
            let d = pa - pb;
            let dsq = len_sq(d);
            if dsq >= reach * reach || wa + wb <= 0.0 {
                continue;
            }
            hits += 1;
            let dl = dsq.sqrt();
            let n = if dl > 1e-6 { d / dl } else { Vector2::new(0.0, -1.0) };
            let s = (reach - dl) / (wa + wb);
            if x.a_core {
                a.cpos[ia] += n * (s * wa);
            } else {
                a.pos[ia] += n * (s * wa);
            }
            if x.b_core {
                b.cpos[ib] -= n * (s * wb);
            } else {
                b.pos[ib] -= n * (s * wb);
            }
        }
        hits
    }

    /// A few numbers that say whether the colony is sound: [fastest bead px/s, smallest
    /// and largest ring outline area over its target, rings inside out, the bonds'
    /// largest stretch over their rest length, the deepest overlap of a bead or core with
    /// another particle of its creature (beyond 1 px), contacts between creatures].
    pub fn health(&self) -> [f32; 6] {
        let mut fastest = 0.0f32;
        let (mut amin, mut amax) = (f32::INFINITY, 0.0f32);
        let mut inverted = 0.0f32;
        let mut stretch = 0.0f32;
        let mut overlap = 0.0f32;
        for c in &self.creatures {
            for &v in c.vel.iter().chain(c.cvel.iter()) {
                fastest = fastest.max(len(v));
            }
            for ring in &c.rings {
                let t = &c.cells[ring.cell].t;
                let pts = &c.pos[ring.start..ring.start + ring.n];
                if !is_ccw(pts) {
                    inverted += 1.0;
                }
                let ratio = (outline_area(pts, t.bead_radius as f64) / t.target_area.max(1e-3) as f64) as f32;
                amin = amin.min(ratio);
                amax = amax.max(ratio);
            }
            for b in &c.bonds {
                let (pa, _) = c.end_point(b.a);
                let (pb, _) = c.end_point(b.b);
                stretch = stretch.max((dist(pa, pb) - b.rest).abs() / b.rest.max(1e-3));
            }
            for &(i, k) in &c.bc {
                let (i, k) = (i as usize, k as usize);
                overlap = overlap.max(c.r[i] + c.cr[k] - dist(c.pos[i], c.cpos[k]));
            }
            for &(a, b) in &c.cc {
                let (a, b) = (a as usize, b as usize);
                overlap = overlap.max(c.cr[a] + c.cr[b] - dist(c.cpos[a], c.cpos[b]));
            }
        }
        if amin == f32::INFINITY {
            amin = 1.0;
            amax = 1.0;
        }
        [fastest, amin, amax, inverted, stretch, overlap]
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cell(x: f32, y: f32, r: f32, core: bool) -> Vec<f32> {
        // A 14 px cell with GooTuning's numbers at unit 0.5, roughly.
        let beads = 12.0;
        let bead_r = 0.6 * std::f32::consts::TAU * r / beads;
        vec![
            x, y, r, if core { 1.0 } else { 0.0 }, beads, r - bead_r, bead_r, 0.05, 50.0, 200.0, 2000.0, 1.0, 600.0, 0.3, 5.0,
            1.0, std::f32::consts::PI * r * r, 1.0, 0.5, 0.2,
        ]
    }

    fn colony(threads: usize) -> Colony {
        let mut col = Colony::default();
        col.set_threads(threads);
        for c in 0..6 {
            let mut cells = Vec::new();
            for i in 0..5 {
                for j in 0..4 {
                    let core = (1..4).contains(&i) && (1..3).contains(&j);
                    cells.extend(cell(c as f32 * 150.0 + i as f32 * 28.0, j as f32 * 28.0 + (c % 2) as f32 * 7.0, 14.0, core));
                }
            }
            let k = col.add_creature(&cells);
            col.creatures[k].build_bonds(1.5, 1.0);
            col.creatures[k].push = Vector2::new(if c % 2 == 0 { 300.0 } else { -300.0 }, 0.0);
        }
        col
    }

    #[test]
    fn threaded_step_is_bit_identical_to_serial() {
        let mut a = colony(1);
        let mut b = colony(4);
        for _ in 0..90 {
            a.step(1.0 / 60.0);
            b.step(1.0 / 60.0);
        }
        for (ca, cb) in a.creatures.iter().zip(&b.creatures) {
            assert_eq!(ca.pos.len(), cb.pos.len());
            for (p, q) in ca.pos.iter().zip(&cb.pos) {
                assert_eq!(p.x.to_bits(), q.x.to_bits());
                assert_eq!(p.y.to_bits(), q.y.to_bits());
            }
            for (p, q) in ca.cpos.iter().zip(&cb.cpos) {
                assert_eq!(p.x.to_bits(), q.x.to_bits());
                assert_eq!(p.y.to_bits(), q.y.to_bits());
            }
        }
        assert!(!a.cross.is_empty(), "the creatures should have met");
    }

    #[test]
    fn promote_and_demote_round_trip() {
        let mut col = colony(1);
        let c = &mut col.creatures[0];
        let cores = c.core_count();
        let beads = c.bead_count();
        let core_cell = c.cells.iter().position(|x| matches!(x.kind, Kind::Core(_))).unwrap();
        let overlap = c.promote(core_cell, 1.5, 1.0);
        assert!(overlap < 0.5, "a promoted ring clears its neighbours: {}", overlap);
        assert_eq!(c.core_count(), cores - 1);
        assert_eq!(c.bead_count(), beads + 12);
        assert!(c.demote(core_cell, 1.5, 1.0) >= 0.0);
        assert_eq!(c.core_count(), cores);
        assert_eq!(c.bead_count(), beads);
    }
}
