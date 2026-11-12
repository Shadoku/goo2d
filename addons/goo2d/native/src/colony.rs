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
//!
//! Milestone 1, adhesion (docs/colony-adhesion.md): with `Adhesion::enabled` a creature's
//! cells hold together by sticking where they touch instead of by spawn-time bonds.
//! Each frame, after the contact candidates are found, every free ring bead that comes
//! within `capture` px of another cell's skin in the same creature sticks to it (a
//! `Stick`: bead to the edge of a ring, at a place `s` along that ring, or bead to a
//! core's rim; touching cores to each other), if the cells' types may join (`table`) and
//! the pair is not refused or waiting for script's answer (`pairs`, `asks`). A stick is
//! an XPBD constraint holding the gap at zero, pulling and pushing; an anchored one also
//! holds the bead at its place along the edge with a softer spring, the place creeping
//! toward where the bead is (`creep`); a sticky one slides freely. A stick whose mean pull
//! over a frame passes `break_force` breaks. Cell pairs going from no stick to some, and
//! back, are reported as events (`events`), per creature in cell-pair order after the
//! step. All of it runs on the creature's own data, so the threaded step stays
//! bit-identical to the serial one.

use crate::consts::{MAX_PRESSURE_RATIO, MAX_STRETCH, MIN_AREA_RATIO};
use crate::geom::*;
use crate::grid::Grid;
use crate::kernel::distances;
use godot::builtin::Vector2;
use rayon::prelude::*;
use std::collections::BTreeMap;
use std::time::Instant;

/// Cell types the join table covers (type ids 0..MAX_TYPES).
pub const MAX_TYPES: usize = 16;
/// Join modes of the type table.
pub const JOIN_NONE: u8 = 0;
pub const JOIN_ANCHORED: u8 = 1;
pub const JOIN_STICKY: u8 = 2;
/// Event kinds.
pub const EVENT_JOINED: u8 = 1;
pub const EVENT_PARTED: u8 = 2;
/// `Creature::stuck` of a bead stuck to a core.
const STUCK_CORE: u32 = u32::MAX;

/// The adhesion's settings, colony-wide. Lengths in px and forces in the cells' mass
/// units × px/s²: the defaults are for GooTuning.unit 1 (callers at another unit scale
/// `capture`, `join_reach` and `break_force` by it).
#[derive(Clone, Copy, Debug)]
pub struct Adhesion {
    /// Capture and the sticks' solve on. Off: the spike's bonds alone (if built).
    pub enabled: bool,
    /// Capture paused for the whole colony (existing sticks hold and may break).
    pub paused: bool,
    /// A cell pair seen for the first time is reported in `asks` and joins only once
    /// answered (`answer()`); off: it joins at once if the type table allows.
    pub ask: bool,
    /// Gap between outlines within which a free bead sticks.
    pub capture: f32,
    /// Capture runs every this many frames (each creature on its own frames: creature i
    /// when (step - 1 + i) is a multiple, so the first step captures for creature 0), and
    /// the wider candidate search only then.
    pub capture_every: u32,
    /// Gap within which join_cells() sticks beads by hand.
    pub join_reach: f32,
    /// Normal stiffness: × the softer cell's skin stiffness (compliance its inverse).
    pub stick_scale: f32,
    /// The anchor's stiffness along the edge over the normal one.
    pub anchor_scale: f32,
    /// How fast an anchor creeps toward where its bead is: the fraction per second.
    pub creep: f32,
    /// A stick whose load (its pull, smoothed over `load_time`) passes this breaks.
    pub break_force: f32,
    /// The time over which a stick's load is smoothed (s): a pull must last to break it.
    pub load_time: f32,
    /// After a stick breaks its pair captures nothing for this long (s): the broken
    /// wall's beads are still within the capture gap.
    pub break_rest: f32,
    /// table[type a][type b]: JOIN_NONE, JOIN_ANCHORED or JOIN_STICKY.
    pub table: [[u8; MAX_TYPES]; MAX_TYPES],
}

impl Default for Adhesion {
    fn default() -> Self {
        Adhesion {
            enabled: false,
            paused: false,
            ask: false,
            capture: 5.0,
            capture_every: 2,
            join_reach: 8.0,
            stick_scale: 1.0,
            anchor_scale: 0.3,
            creep: 1.0,
            break_force: 24000.0,
            load_time: 0.1,
            break_rest: 0.5,
            table: [[JOIN_ANCHORED; MAX_TYPES]; MAX_TYPES],
        }
    }
}

/// One stick (indices local to the creature): end a is a bead (or a core, only for a
/// core-to-core stick), end b the ring `b`'s skin at the place `s` (edge floor(s), the
/// fraction frac(s) of the way along it) or the core `b`.
#[derive(Clone, Copy, Debug)]
pub struct Stick {
    pub a: u32,
    pub b: u32,
    pub a_core: bool,
    pub b_core: bool,
    pub s: f32,
    /// An anchored stick's anchor: a place along ring b, and the bead's offset along
    /// that edge's tangent it is held at (the offset it had when it stuck: zero
    /// tension then, wherever the bead sat). Each frame the anchor moves to `s` keeping
    /// the tension, and the tension creeps toward zero.
    pub anchor: f32,
    pub offset: f32,
    /// A sticky stick's end a slides too: the place along its own ring (bead a's, local)
    /// that faces the contact, `a` kept the bead nearest it. An anchored one's is bead a.
    pub sa: f32,
    pub cell_a: u32,
    pub cell_b: u32,
    pub mode: u8,
    pub alpha_n: f32,
    pub alpha_t: f32,
    /// Its pull (force; negative: pushing), each frame's mean smoothed over load_time.
    pub load: f32,
    pull: f32,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum PairState {
    /// May stick (filters passed, or answered yes).
    Allowed,
    /// Joined by hand: sticks whatever the filters say.
    Forced,
    /// Answered no, or parted by hand: no stick while the cells stay in touch.
    Refused,
    /// Asked, not answered yet.
    Pending,
}

/// What a creature knows about a pair of its cells (key: the smaller cell first).
#[derive(Clone, Copy, Debug)]
pub struct Pair {
    pub sticks: u32,
    /// Reported as joined (sticks > 0 at the last settle).
    pub joined: bool,
    pub state: PairState,
    /// No capture between them before this frame (a stick between them broke).
    pub rest_until: u64,
    /// A core-to-core stick between them exists.
    pub cores: bool,
}

#[inline]
fn pair_key(a: u32, b: u32) -> (u32, u32) {
    if a < b {
        (a, b)
    } else {
        (b, a)
    }
}

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
    /// Its type id (0..MAX_TYPES): what the join table is indexed by.
    pub ctype: u8,
    /// An acceleration on this cell alone (px/s²), on top of the creature's push.
    pub push: Vector2,
    // Room for later milestones (data only: nothing reads or writes them yet).
    #[allow(dead_code)]
    /// 1 exposed to the outside .. 0 enclosed (milestone 2).
    pub exposure: f32,
    #[allow(dead_code)]
    /// Its outward direction (milestone 2: thrusters, spikes).
    pub outward: Vector2,
    #[allow(dead_code)]
    /// Contacts with other creatures or walls in the last step (contact reports).
    pub contacts: u32,
}

impl Cell {
    fn new(t: CellTuning) -> Cell {
        Cell { kind: Kind::Core(0), t, ctype: 0, push: Vector2::ZERO, exposure: 1.0, outward: Vector2::ZERO, contacts: 0 }
    }
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
    // Candidates within the capture gap but beyond contact reach (capture reads them with
    // bb, bc and cc; the contact solve does not iterate them every substep).
    xbb: Vec<(u32, u32)>,
    xbc: Vec<(u32, u32)>,
    xcc: Vec<(u32, u32)>,
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
    // Adhesion.
    pub sticks: Vec<Stick>,
    /// Per bead: 0 while free; the ring it is stuck to + 1, or STUCK_CORE when stuck to
    /// a core (it holds at most one stick, as its end a).
    pub stuck: Vec<u32>,
    pub pairs: BTreeMap<(u32, u32), Pair>,
    /// Joined and parted events not yet taken: (kind, cell a, cell b), a < b.
    pub events: Vec<(u8, u32, u32)>,
    /// Cell pairs seen for the first time, waiting for an answer (a < b).
    pub asks: Vec<(u32, u32)>,
    pub capture_paused: bool,
    /// Whether this frame captures (Adhesion::capture_every, staggered by creature).
    capturing: bool,
    /// Its index in the colony (the stagger).
    index: u32,
    // Capture's best target per bead this frame: (gap, b, s, kind 0 none / 1 edge /
    // 2 core, mode).
    cap: Vec<(f32, u32, f32, u8, u8)>,
    // Whether this frame's own candidates are solved as contacts (else only capture
    // reads them): bead pairs, and anything with a core.
    solve_bb: bool,
    solve_cores: bool,
    active: bool,
    h: f32,
    dt: f32,
    // Nanoseconds spent this step (summed over substeps) in its rings, bonds, own
    // contacts, sticks, and (once a frame) its capture and break/creep pass.
    ns_rings: u64,
    ns_bonds: u64,
    ns_intra: u64,
    ns_sticks: u64,
    ns_capture: u64,
    made: usize,
    broken: usize,
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
    pub ad: Adhesion,
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
            ad: Adhesion::default(),
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
    /// Adhesion: the sticks' solve (CPU, summed), the capture pass and the break/creep
    /// pass (wall), sticks now, made and broken this step.
    pub sticks_cpu_us: u64,
    pub capture_us: u64,
    pub settle_us: u64,
    pub sticks: usize,
    pub made: usize,
    pub broken: usize,
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
        self.stuck.extend(std::iter::repeat(0u32).take(n));
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
            let cell_push = self.cells[ring.cell].push;
            if cell_push != Vector2::ZERO {
                let m = self.cells[ring.cell].t.bead_mass;
                for i in ring.start..ring.start + ring.n {
                    self.force[i] += cell_push * m;
                }
            }
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
            let cell_push = self.cells[self.ccell[k] as usize].push;
            if cell_push != Vector2::ZERO {
                self.cforce[k] += cell_push * m;
            }
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
        let bb = if self.solve_bb { self.bb.len() } else { 0 };
        for k in 0..bb {
            let (i, j) = (self.bb[k].0 as usize, self.bb[k].1 as usize);
            // Joined cells do not collide where they are stuck: a stuck bead's gap to the
            // ring it is stuck to is the stick's to hold.
            if self.stuck[i] == self.bead_ring[j] + 1 || self.stuck[j] == self.bead_ring[i] + 1 {
                continue;
            }
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
        let (bc, cc) = if self.solve_cores { (self.bc.len(), self.cc.len()) } else { (0, 0) };
        for k in 0..bc {
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
        for k in 0..cc {
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
        if !self.sticks.is_empty() {
            let t = Instant::now();
            self.solve_sticks();
            self.ns_sticks += ns(t);
        }
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

    /// After a promotion or demotion: the spike's bonds rebuilt when the creature has
    /// them; with adhesion the next frame's capture sticks the changed cell again.
    fn rebuild_holds(&mut self, capture: f32, bond_scale: f32) {
        if self.bonds.is_empty() && !self.sticks.is_empty() {
            self.recount_bonded();
        } else {
            self.build_bonds(capture, bond_scale);
        }
    }

    // ---- Adhesion ----

    /// The place `s` on ring `rb`'s skin: (bead j, bead k, t, the edge's unit tangent,
    /// its outward normal, its length).
    #[inline]
    fn edge_at(&self, rb: usize, s: f32) -> (usize, usize, f32, Vector2, Vector2, f32) {
        let ring = &self.rings[rb];
        let n = ring.n;
        let e = (s.max(0.0) as usize).min(n - 1);
        let t = (s - e as f32).clamp(0.0, 1.0);
        let j = ring.start + e;
        let k = ring.start + (e + 1) % n;
        let edge = self.pos[k] - self.pos[j];
        let l = len(edge);
        let tan = if l > 1e-6 { edge / l } else { Vector2::new(1.0, 0.0) };
        (j, k, t, tan, Vector2::new(-tan.y, tan.x), l)
    }

    /// `s` wrapped into [0, n) of ring `rb`.
    #[inline]
    fn wrap_s(&self, rb: usize, s: f32) -> f32 {
        let n = self.rings[rb].n as f32;
        let mut s = s % n;
        if s < 0.0 {
            s += n;
        }
        if s >= n {
            s -= n;
        }
        s
    }

    /// The nearest place on ring `rb`'s skin to bead `i` among the two edges at its bead
    /// `j` (or all edges when `j` is None), seen from outside: (gap between outlines, s).
    fn nearest_edge(&self, i: usize, rb: usize, j: Option<usize>, within: f32) -> Option<(f32, f32)> {
        let ring = &self.rings[rb];
        let n = ring.n;
        let p = self.pos[i];
        let mut best: Option<(f32, f32)> = None;
        let mut test = |e: usize| {
            let a = self.pos[ring.start + e];
            let b = self.pos[ring.start + (e + 1) % n];
            let seg = b - a;
            let l2 = len_sq(seg);
            if l2 <= 1e-12 {
                return;
            }
            let t = (dot(p - a, seg) / l2).clamp(0.0, 1.0);
            let q = a + seg * t;
            let nrm = Vector2::new(-seg.y, seg.x);
            if dot(p - q, nrm) <= 0.0 {
                return;
            }
            let gap = dist(p, q) - (self.r[i] + self.r[ring.start + e]);
            if gap < within && best.is_none_or(|bb| gap < bb.0) {
                best = Some((gap, e as f32 + t));
            }
        };
        match j {
            Some(j) => {
                let le = j - ring.start;
                test((le + n - 1) % n);
                test(le);
            }
            None => (0..n).for_each(&mut test),
        }
        best.map(|(g, s)| (g, if s >= n as f32 { s - n as f32 } else { s }))
    }

    /// Whether ring `rx`'s beads stick onto ring `ry`'s skin (else `ry`'s onto `rx`'s):
    /// a wall between two rings is held from one side only, the finer one's (smaller
    /// beads; equal: the lower cell index). Held from both sides it is over-constrained:
    /// each side's beads cannot all sit at zero gap from the other's polyline when the
    /// two are curved, and the two sides fight with a standing load.
    #[inline]
    fn sticks_onto(&self, rx: usize, ry: usize) -> bool {
        let (cx, cy) = (self.rings[rx].cell, self.rings[ry].cell);
        let (bx, by) = (self.cells[cx].t.bead_radius, self.cells[cy].t.bead_radius);
        if bx < by * 0.999 {
            true
        } else if by < bx * 0.999 {
            false
        } else {
            cx < cy
        }
    }

    fn cell_of_bead(&self, i: usize) -> u32 {
        self.rings[self.bead_ring[i] as usize].cell as u32
    }

    /// A stick's compliances for cells `ca`, `cb`.
    fn stick_alphas(&self, ca: usize, cb: usize, ad: &Adhesion) -> (f32, f32) {
        let k = self.cells[ca].t.skin_k.min(self.cells[cb].t.skin_k) * ad.stick_scale;
        let alpha_n = 1.0 / k.max(1e-6);
        (alpha_n, alpha_n / ad.anchor_scale.max(1e-6))
    }

    /// The offset of a point `p` along the tangent of ring `rb`'s edge at `s`, from the
    /// place `s` on it.
    fn tangent_offset(&self, p: Vector2, rb: usize, s: f32) -> f32 {
        let (j, kk, t, tan, _, _) = self.edge_at(rb, s);
        dot(p - (self.pos[j] * (1.0 - t) + self.pos[kk] * t), tan)
    }

    fn add_stick(&mut self, a: u32, a_core: bool, b: u32, b_core: bool, s: f32, cell_a: u32, cell_b: u32, mode: u8, ad: &Adhesion) {
        let (alpha_n, alpha_t) = self.stick_alphas(cell_a as usize, cell_b as usize, ad);
        let offset = if a_core || b_core { 0.0 } else { self.tangent_offset(self.pos[a as usize], b as usize, s) };
        let sa = if a_core { 0.0 } else { (a as usize - self.rings[self.bead_ring[a as usize] as usize].start) as f32 };
        self.sticks.push(Stick { a, b, a_core, b_core, s, anchor: s, offset, sa, cell_a, cell_b, mode, alpha_n, alpha_t, load: 0.0, pull: 0.0 });
        if !a_core {
            self.stuck[a as usize] = if b_core { STUCK_CORE } else { b + 1 };
        }
        if let Some(p) = self.pairs.get_mut(&pair_key(cell_a, cell_b)) {
            p.sticks += 1;
            if a_core && b_core {
                p.cores = true;
            }
        }
    }

    /// Removes every stick `drop` says (in place, keeping the others' order), freeing
    /// their beads and counting them off their pairs. Returns how many.
    fn drop_sticks<F: FnMut(&Stick) -> bool>(&mut self, mut drop: F) -> usize {
        let mut removed = 0;
        let mut k = 0;
        while k < self.sticks.len() {
            let st = self.sticks[k];
            if drop(&st) {
                if !st.a_core {
                    self.stuck[st.a as usize] = 0;
                }
                if let Some(p) = self.pairs.get_mut(&pair_key(st.cell_a, st.cell_b)) {
                    p.sticks = p.sticks.saturating_sub(1);
                    if st.a_core && st.b_core {
                        p.cores = false;
                    }
                }
                removed += 1;
                k += 1;
                continue;
            }
            if removed > 0 {
                self.sticks[k - removed] = st;
            }
            k += 1;
        }
        self.sticks.truncate(self.sticks.len() - removed);
        removed
    }

    /// May cells `ca` and `cb` stick now, and how: the type table, then what is known of
    /// the pair (an unknown pair is allowed at once, or asked about when `ad.ask`).
    fn pair_mode(&mut self, ca: u32, cb: u32, ad: &Adhesion, frame: u64) -> u8 {
        let ta = self.cells[ca as usize].ctype as usize;
        let tb = self.cells[cb as usize].ctype as usize;
        let mode = ad.table[ta.min(MAX_TYPES - 1)][tb.min(MAX_TYPES - 1)];
        let key = pair_key(ca, cb);
        match self.pairs.get_mut(&key) {
            Some(p) => {
                if frame < p.rest_until {
                    return JOIN_NONE;
                }
                match p.state {
                    PairState::Allowed => mode,
                    PairState::Forced => mode.max(JOIN_ANCHORED),
                    PairState::Refused | PairState::Pending => JOIN_NONE,
                }
            }
            None => {
                if mode == JOIN_NONE {
                    return JOIN_NONE;
                }
                let state = if ad.ask { PairState::Pending } else { PairState::Allowed };
                self.pairs.insert(key, Pair { sticks: 0, joined: false, state, rest_until: 0, cores: false });
                if ad.ask {
                    self.asks.push(key);
                    JOIN_NONE
                } else {
                    mode
                }
            }
        }
    }

    /// Capture, once a frame before the substeps, from this frame's own candidates: each
    /// free bead sticks to the nearest skin of another cell within the capture gap that
    /// its pair allows; touching cores stick to each other. Returns the sticks made.
    fn capture(&mut self, ad: &Adhesion, frame: u64) -> usize {
        if !self.active || !self.capturing {
            return 0;
        }
        let n = self.pos.len();
        let mut cap = std::mem::take(&mut self.cap);
        cap.clear();
        cap.resize(n, (f32::INFINITY, 0, 0.0, 0, 0));
        let mut bb = std::mem::take(&mut self.bb);
        let mut bc = std::mem::take(&mut self.bc);
        let mut cc = std::mem::take(&mut self.cc);
        let (nbb, nbc, ncc) = (bb.len(), bc.len(), cc.len());
        bb.extend_from_slice(&self.xbb);
        bc.extend_from_slice(&self.xbc);
        cc.extend_from_slice(&self.xcc);
        // The last pair looked up and its answer (candidates come in runs of one pair).
        let mut memo: ((u32, u32), u8) = ((u32::MAX, u32::MAX), 0);
        let capture = ad.capture;
        for &(i, j) in &bb {
            let (i, j) = (i as usize, j as usize);
            let (ri, rj) = (self.bead_ring[i] as usize, self.bead_ring[j] as usize);
            if ri == rj || (self.stuck[i] != 0 && self.stuck[j] != 0) {
                continue;
            }
            for (x, rx, y, ry) in [(i, ri, j, rj), (j, rj, i, ri)] {
                if self.stuck[x] != 0 || !self.sticks_onto(rx, ry) {
                    continue;
                }
                let Some((gap, s)) = self.nearest_edge(x, ry, Some(y), capture) else { continue };
                if gap >= cap[x].0 {
                    continue;
                }
                let (ca, cb) = (self.rings[rx].cell as u32, self.rings[ry].cell as u32);
                let key = pair_key(ca, cb);
                let mode = if memo.0 == key { memo.1 } else { self.pair_mode(ca, cb, ad, frame) };
                memo = (key, mode);
                if mode != JOIN_NONE {
                    cap[x] = (gap, ry as u32, s, 1, mode);
                }
            }
        }
        for &(i, k) in &bc {
            let (i, k) = (i as usize, k as usize);
            if self.stuck[i] != 0 {
                continue;
            }
            let gap = dist(self.pos[i], self.cpos[k]) - self.r[i] - self.cr[k];
            if gap >= capture || gap >= cap[i].0 {
                continue;
            }
            let (ca, cb) = (self.cell_of_bead(i), self.ccell[k]);
            let key = pair_key(ca, cb);
            let mode = if memo.0 == key { memo.1 } else { self.pair_mode(ca, cb, ad, frame) };
            memo = (key, mode);
            if mode != JOIN_NONE {
                cap[i] = (gap, k as u32, 0.0, 2, mode);
            }
        }
        let before = self.sticks.len();
        for &(a, b) in &cc {
            let gap = dist(self.cpos[a as usize], self.cpos[b as usize]) - self.cr[a as usize] - self.cr[b as usize];
            if gap >= capture {
                continue;
            }
            let (ca, cb) = (self.ccell[a as usize], self.ccell[b as usize]);
            let mode = self.pair_mode(ca, cb, ad, frame);
            if mode != JOIN_NONE && !self.pairs.get(&pair_key(ca, cb)).is_some_and(|p| p.cores) {
                self.add_stick(a, true, b, true, 0.0, ca, cb, JOIN_STICKY, ad);
            }
        }
        for i in 0..n {
            let (_, b, s, kind, mode) = cap[i];
            match kind {
                1 => {
                    let cb = self.rings[b as usize].cell as u32;
                    self.add_stick(i as u32, false, b, false, s, self.cell_of_bead(i), cb, mode, ad);
                }
                // A core has no orientation yet: a bead on its rim holds the gap only.
                2 => self.add_stick(i as u32, false, b, true, 0.0, self.cell_of_bead(i), self.ccell[b as usize], JOIN_STICKY, ad),
                _ => {}
            }
        }
        bb.truncate(nbb);
        bc.truncate(nbc);
        cc.truncate(ncc);
        self.bb = bb;
        self.bc = bc;
        self.cc = cc;
        self.cap = cap;
        self.sticks.len() - before
    }

    /// Every stick, once a substep (after the rings and bonds, before the own contacts):
    /// the gap held at zero along the edge's normal, pulling and pushing; an anchored
    /// stick's bead also held at its place along the edge, more softly; a sticky one's
    /// place follows the bead (hopping to the next edge past an end).
    fn solve_sticks(&mut self) {
        let inv_h2 = 1.0 / (self.h * self.h);
        for k in 0..self.sticks.len() {
            let mut st = self.sticks[k];
            let a = st.a as usize;
            let (pa, wa, ra) = if st.a_core { (self.cpos[a], self.cw[a], self.cr[a]) } else { (self.pos[a], self.w[a], self.r[a]) };
            if st.b_core {
                let b = st.b as usize;
                let (pb, wb) = (self.cpos[b], self.cw[b]);
                let d = pa - pb;
                let l = len(d);
                let denom = wa + wb + st.alpha_n * inv_h2;
                if l < 1e-6 || denom <= 0.0 {
                    continue;
                }
                let n = d / l;
                let dl = -(l - (ra + self.cr[b])) / denom;
                if st.a_core {
                    self.cpos[a] += n * (dl * wa);
                } else {
                    self.pos[a] += n * (dl * wa);
                }
                self.cpos[b] -= n * (dl * wb);
                self.sticks[k].pull += -dl * inv_h2;
                continue;
            }
            let rb = st.b as usize;
            if st.mode == JOIN_STICKY {
                self.solve_sliding(k, inv_h2);
                continue;
            }
            st.s = self.follow(rb, st.s, pa);
            self.sticks[k].s = st.s;
            let (j, kk, _, _, nchord, l) = self.edge_at(rb, st.s);
            if l < 1e-6 {
                continue;
            }
            let (wj, wk) = (self.w[j], self.w[kk]);
            // The gap: the bead's distance to the nearest point of its edge (to the end bead
            // past either end), signed by the side it is on: a conservative distance
            // constraint, pulling and pushing.
            let seg = self.pos[kk] - self.pos[j];
            let tp = (dot(pa - self.pos[j], seg) / (l * l)).clamp(0.0, 1.0);
            let q = self.pos[j] + seg * tp;
            let d = pa - q;
            let dist = len(d);
            let side = dot(d, nchord);
            let (nrm, c) = if side > 0.0 && dist > 1e-6 { (d / dist, dist - (ra + self.r[j])) } else { (nchord, side - (ra + self.r[j])) };
            let wq = wj * (1.0 - tp) * (1.0 - tp) + wk * tp * tp;
            let denom = wa + wq + st.alpha_n * inv_h2;
            if denom <= 0.0 {
                continue;
            }
            let dl = -c / denom;
            self.pos[a] += nrm * (dl * wa);
            self.pos[j] -= nrm * (dl * wj * (1.0 - tp));
            self.pos[kk] -= nrm * (dl * wk * tp);
            self.sticks[k].pull += -dl * inv_h2;
            if st.mode == JOIN_ANCHORED {
                // The anchor: the bead held, more softly, level with its place along the
                // edge: C = (bead - anchor point) · the edge's tangent. Its gradient includes
                // the edge turning (the normal part of bead - anchor over the edge's
                // length): without that term a held shear is a net torque and spins the
                // cells up; with it the constraint is rotation-invariant and conserves
                // angular momentum.
                let (j, kk, ta, _, _, _) = self.edge_at(rb, st.anchor);
                let (wj, wk) = (self.w[j], self.w[kk]);
                let seg = self.pos[kk] - self.pos[j];
                let l = len(seg);
                if l < 1e-6 {
                    continue;
                }
                let tan = seg / l;
                let nrm = Vector2::new(-tan.y, tan.x);
                let u = self.pos[a] - (self.pos[j] * (1.0 - ta) + self.pos[kk] * ta);
                let ct = dot(u, tan) - st.offset;
                let un = nrm * (dot(u, nrm) / l);
                let gj = tan * -(1.0 - ta) - un;
                let gk = tan * -ta + un;
                let denom = wa + wj * len_sq(gj) + wk * len_sq(gk) + st.alpha_t * inv_h2;
                let dt = -ct / denom;
                self.pos[a] += tan * (dt * wa);
                self.pos[j] += gj * (dt * wj);
                self.pos[kk] += gk * (dt * wk);
            }
        }
    }

    /// A sticky stick between two skins (solve_sticks()): both of its ends slide, each to
    /// the place on its own ring facing the other (closest points of the two polylines
    /// near them), and the gap between those is held at zero. Neither cell's material is
    /// held: the wall carries no force along itself.
    fn solve_sliding(&mut self, k: usize, inv_h2: f32) {
        let mut st = self.sticks[k];
        let ra = self.bead_ring[st.a as usize] as usize;
        let rb = st.b as usize;
        let pa0 = self.place_point(ra, st.sa);
        st.s = self.follow(rb, st.s, pa0);
        let q0 = self.closest_on_edge(rb, st.s, pa0);
        st.sa = self.follow(ra, st.sa, q0);
        let (ja, ka, ta, _, _, la) = self.edge_at(ra, st.sa);
        let (jb, kb, _, _, nchord, lb) = self.edge_at(rb, st.s);
        let ring_a = &self.rings[ra];
        st.a = (ring_a.start + (st.sa.round() as usize) % ring_a.n) as u32;
        self.sticks[k].s = st.s;
        self.sticks[k].sa = st.sa;
        self.sticks[k].a = st.a;
        if la < 1e-6 || lb < 1e-6 {
            return;
        }
        let pa = self.pos[ja] * (1.0 - ta) + self.pos[ka] * ta;
        let seg = self.pos[kb] - self.pos[jb];
        let tb = (dot(pa - self.pos[jb], seg) / (lb * lb)).clamp(0.0, 1.0);
        let q = self.pos[jb] + seg * tb;
        let d = pa - q;
        let dist = len(d);
        let side = dot(d, nchord);
        let rest = self.r[ja] + self.r[jb];
        let (nrm, c) = if side > 0.0 && dist > 1e-6 { (d / dist, dist - rest) } else { (nchord, side - rest) };
        let (wja, wka, wjb, wkb) = (self.w[ja], self.w[ka], self.w[jb], self.w[kb]);
        let wa = wja * (1.0 - ta) * (1.0 - ta) + wka * ta * ta;
        let wb = wjb * (1.0 - tb) * (1.0 - tb) + wkb * tb * tb;
        let denom = wa + wb + st.alpha_n * inv_h2;
        if denom <= 0.0 {
            return;
        }
        let dl = -c / denom;
        self.pos[ja] += nrm * (dl * wja * (1.0 - ta));
        self.pos[ka] += nrm * (dl * wka * ta);
        self.pos[jb] -= nrm * (dl * wjb * (1.0 - tb));
        self.pos[kb] -= nrm * (dl * wkb * tb);
        self.sticks[k].pull += -dl * inv_h2;
    }

    /// The point at the place `s` on ring `r`'s polyline.
    #[inline]
    fn place_point(&self, r: usize, s: f32) -> Vector2 {
        let (j, k, t, _, _, _) = self.edge_at(r, s);
        self.pos[j] * (1.0 - t) + self.pos[k] * t
    }

    /// The point of ring `r`'s edge at the place `s` nearest `p`.
    #[inline]
    fn closest_on_edge(&self, r: usize, s: f32, p: Vector2) -> Vector2 {
        let (j, k, _, _, _, _) = self.edge_at(r, s);
        let seg = self.pos[k] - self.pos[j];
        let t = (dot(p - self.pos[j], seg) / len_sq(seg).max(1e-12)).clamp(0.0, 1.0);
        self.pos[j] + seg * t
    }

    /// A sticky stick's place `s` on ring `rb` following the bead at `p`: its projection
    /// on the edge, or on the next edge over past an end.
    fn follow(&self, rb: usize, s: f32, p: Vector2) -> f32 {
        let (j, kk, _, _, _, _) = self.edge_at(rb, s);
        let seg = self.pos[kk] - self.pos[j];
        let l2 = len_sq(seg);
        if l2 <= 1e-12 {
            return s;
        }
        let tp = dot(p - self.pos[j], seg) / l2;
        let e = (s.max(0.0) as usize).min(self.rings[rb].n - 1) as f32;
        if (0.0..=1.0).contains(&tp) {
            return e + tp.min(0.999);
        }
        let s2 = self.wrap_s(rb, if tp < 0.0 { e - 1.0 } else { e + 1.0 });
        let (j2, k2, _, _, _, _) = self.edge_at(rb, s2);
        let seg2 = self.pos[k2] - self.pos[j2];
        let t2 = (dot(p - self.pos[j2], seg2) / len_sq(seg2).max(1e-12)).clamp(0.0, 0.999);
        s2.floor() + t2
    }

    /// Once a frame after the substeps: each stick's mean pull over the frame; those past
    /// the break force break; anchors creep toward their beads; then the pairs are
    /// settled (events) and the ones no longer touching forgotten. Returns how many broke.
    fn after_step(&mut self, ad: &Adhesion, substeps: usize, frame: u64) -> usize {
        if !self.active || (self.sticks.is_empty() && self.pairs.is_empty()) {
            return 0;
        }
        let inv = 1.0 / substeps.max(1) as f32;
        let smooth = if ad.load_time > 0.0 { (self.dt / ad.load_time).min(1.0) } else { 1.0 };
        for st in self.sticks.iter_mut() {
            st.load += (st.pull * inv - st.load) * smooth;
            st.pull = 0.0;
        }
        let limit = ad.break_force;
        let mut resting: Vec<(u32, u32)> = Vec::new();
        let broken = self.drop_sticks(|st| {
            let past = st.load > limit;
            if past {
                resting.push(pair_key(st.cell_a, st.cell_b));
            }
            past
        });
        // A broken wall's beads sit within the capture gap still: the pair rests a while,
        // or it would be captured again in the next frame and never part.
        let until = frame + (ad.break_rest / self.dt.max(1e-6)).ceil() as u64;
        for key in resting {
            if let Some(p) = self.pairs.get_mut(&key) {
                p.rest_until = until;
            }
        }
        // Anchors move to where their beads are, keeping their tension, which creeps
        // toward zero.
        let keep = 1.0 - (ad.creep * self.dt).min(1.0);
        for k in 0..self.sticks.len() {
            let st = self.sticks[k];
            if st.b_core || st.mode != JOIN_ANCHORED {
                continue;
            }
            let rb = st.b as usize;
            let p = self.pos[st.a as usize];
            let tension = self.tangent_offset(p, rb, st.anchor) - st.offset;
            let st = &mut self.sticks[k];
            st.anchor = st.s;
            let here = st.s;
            let off = self.tangent_offset(p, rb, here) - tension * keep;
            self.sticks[k].offset = off;
        }
        self.settle(ad.capture);
        // Sliding sticks may have moved to another bead.
        self.rebuild_stuck();
        self.recount_bonded();
        broken
    }

    /// Reports every pair whose joined state changed (in cell-pair order) and forgets the
    /// ones without sticks whose cells are no longer near each other (what was decided
    /// about a pair, refused, answered, parted by hand, resting, lasts while they touch).
    fn settle(&mut self, capture: f32) {
        let mut far: Vec<(u32, u32)> = Vec::new();
        for (&(a, b), p) in self.pairs.iter_mut() {
            let now = p.sticks > 0;
            if now != p.joined {
                p.joined = now;
                self.events.push((if now { EVENT_JOINED } else { EVENT_PARTED }, a, b));
            }
        }
        for (&(a, b), p) in self.pairs.iter() {
            if p.sticks == 0 && !self.near(a as usize, b as usize, capture) {
                far.push((a, b));
            }
        }
        for key in far {
            self.pairs.remove(&key);
        }
    }

    /// Whether cells `a` and `b` are within reach of touching: centres closer than their
    /// radii (a tenth more, for squashed cells) and twice the capture gap.
    fn near(&self, a: usize, b: usize, capture: f32) -> bool {
        let reach = 1.1 * (self.cells[a].t.radius + self.cells[b].t.radius) + 2.0 * capture;
        dist_sq(self.cell_center(a), self.cell_center(b)) <= reach * reach
    }

    fn settle_pair(&mut self, key: (u32, u32)) {
        if let Some(p) = self.pairs.get_mut(&key) {
            let now = p.sticks > 0;
            if now != p.joined {
                p.joined = now;
                self.events.push((if now { EVENT_JOINED } else { EVENT_PARTED }, key.0, key.1));
            }
        }
    }

    /// `stuck` from the sticks (after their indices changed).
    fn rebuild_stuck(&mut self) {
        self.stuck.iter_mut().for_each(|x| *x = 0);
        for st in &self.sticks {
            if !st.a_core {
                self.stuck[st.a as usize] = if st.b_core { STUCK_CORE } else { st.b + 1 };
            }
        }
    }

    /// `bonded` (the drawing's exposed weight): each bead's bonds and sticks.
    fn recount_bonded(&mut self) {
        self.bonded.iter_mut().for_each(|b| *b = 0);
        let mark = |bonded: &mut Vec<u8>, i: u32| bonded[i as usize] = bonded[i as usize].saturating_add(1);
        for b in &self.bonds {
            for e in [b.a, b.b] {
                match e {
                    End::Bead(i) => mark(&mut self.bonded, i),
                    End::Edge(j, k, _) => {
                        mark(&mut self.bonded, j);
                        mark(&mut self.bonded, k);
                    }
                    End::Core(_) => {}
                }
            }
        }
        for k in 0..self.sticks.len() {
            let st = self.sticks[k];
            if !st.a_core {
                mark(&mut self.bonded, st.a);
            }
            if !st.b_core {
                let (j, kk, _, _, _, _) = self.edge_at(st.b as usize, st.s);
                mark(&mut self.bonded, j as u32);
                mark(&mut self.bonded, kk as u32);
            }
        }
    }

    /// Joins cells `a` and `b` by hand: the pair is forced (it sticks whatever the
    /// filters say, now and whenever they touch again while it is remembered), and every
    /// free bead within `ad.join_reach` of the other's skin sticks now. Returns the sticks
    /// made; the joined event, if any, is queued at once.
    pub fn join_cells(&mut self, a: usize, b: usize, ad: &Adhesion) -> usize {
        if a == b || a >= self.cells.len() || b >= self.cells.len() {
            return 0;
        }
        let key = pair_key(a as u32, b as u32);
        let p = self.pairs.entry(key).or_insert(Pair { sticks: 0, joined: false, state: PairState::Forced, rest_until: 0, cores: false });
        p.state = PairState::Forced;
        p.rest_until = 0;
        let ta = self.cells[a].ctype as usize;
        let tb = self.cells[b].ctype as usize;
        let mode = ad.table[ta.min(MAX_TYPES - 1)][tb.min(MAX_TYPES - 1)].max(JOIN_ANCHORED);
        let before = self.sticks.len();
        let reach = ad.join_reach;
        for (x, y) in [(a, b), (b, a)] {
            match (self.cells[x].kind, self.cells[y].kind) {
                (Kind::Ring(rx), Kind::Ring(ry)) => {
                    if !self.sticks_onto(rx, ry) {
                        continue;
                    }
                    let (start, n) = (self.rings[rx].start, self.rings[rx].n);
                    for i in start..start + n {
                        if self.stuck[i] != 0 {
                            continue;
                        }
                        if let Some((_, s)) = self.nearest_edge(i, ry, None, reach) {
                            self.add_stick(i as u32, false, ry as u32, false, s, x as u32, y as u32, mode, ad);
                        }
                    }
                }
                (Kind::Ring(rx), Kind::Core(ky)) => {
                    let (start, n) = (self.rings[rx].start, self.rings[rx].n);
                    for i in start..start + n {
                        if self.stuck[i] == 0 && dist(self.pos[i], self.cpos[ky]) - self.r[i] - self.cr[ky] < reach {
                            self.add_stick(i as u32, false, ky as u32, true, 0.0, x as u32, y as u32, JOIN_STICKY, ad);
                        }
                    }
                }
                (Kind::Core(kx), Kind::Core(ky)) if x < y => {
                    let cores = self.pairs.get(&key).is_some_and(|p| p.cores);
                    if !cores && dist(self.cpos[kx], self.cpos[ky]) - self.cr[kx] - self.cr[ky] < reach {
                        self.add_stick(kx as u32, true, ky as u32, true, 0.0, x as u32, y as u32, JOIN_STICKY, ad);
                    }
                }
                _ => {}
            }
        }
        self.settle_pair(key);
        self.recount_bonded();
        self.sticks.len() - before
    }

    /// Parts cells `a` and `b` by hand: every stick between them goes and the pair is
    /// refused while they stay within capture of each other. Returns the sticks removed;
    /// the parted event, if they were joined, is queued at once.
    pub fn part_cells(&mut self, a: usize, b: usize) -> usize {
        if a == b || a >= self.cells.len() || b >= self.cells.len() {
            return 0;
        }
        let key = pair_key(a as u32, b as u32);
        let removed = self.drop_sticks(|st| pair_key(st.cell_a, st.cell_b) == key);
        let p = self.pairs.entry(key).or_insert(Pair { sticks: 0, joined: false, state: PairState::Refused, rest_until: 0, cores: false });
        p.state = PairState::Refused;
        self.settle_pair(key);
        self.recount_bonded();
        removed
    }

    /// Script's answer to an ask (or a decision made before one): allowed or refused,
    /// remembered while the cells stay within capture of each other.
    pub fn answer(&mut self, a: usize, b: usize, allow: bool) {
        if a == b || a >= self.cells.len() || b >= self.cells.len() {
            return;
        }
        let state = if allow { PairState::Allowed } else { PairState::Refused };
        let p = self.pairs.entry(pair_key(a as u32, b as u32)).or_insert(Pair { sticks: 0, joined: false, state, rest_until: 0, cores: false });
        p.state = state;
    }

    /// The cells stuck to cell `cell` now, in order.
    pub fn neighbours(&self, cell: u32) -> Vec<u32> {
        let mut out: Vec<u32> = self
            .pairs
            .iter()
            .filter(|(k, p)| p.sticks > 0 && (k.0 == cell || k.1 == cell))
            .map(|(k, _)| if k.0 == cell { k.1 } else { k.0 })
            .collect();
        out.sort_unstable();
        out
    }

    /// Cell `cell` takes radius `radius` at once, in place: its rest outline, bead
    /// radius, target area (a ring) or its disc (a core) scaled; bead count, masses and
    /// springs kept. The ring's pressure and shape matching move its beads there over the
    /// next frames; the sticks' rest gaps follow the bead radius at once.
    pub fn resize_cell(&mut self, cell: usize, radius: f32) -> bool {
        if cell >= self.cells.len() || radius <= 0.0 {
            return false;
        }
        let old = self.cells[cell].t.radius;
        let f = radius / old.max(1e-6);
        let t = &mut self.cells[cell].t;
        t.radius = radius;
        t.ring_radius *= f;
        t.bead_radius *= f;
        t.target_area = std::f32::consts::PI * radius * radius;
        let br = t.bead_radius;
        match self.cells[cell].kind {
            Kind::Ring(r) => {
                let ring = &mut self.rings[r];
                ring.rest.iter_mut().for_each(|p| *p = *p * f);
                ring.rest_edges.iter_mut().for_each(|e| *e *= f);
                ring.rest_bend.iter_mut().for_each(|e| *e *= f);
                for i in ring.start..ring.start + ring.n {
                    self.r[i] = br;
                }
            }
            Kind::Core(k) => self.cr[k] = radius,
        }
        true
    }

    /// Stick `k`'s gap now (px along its normal; 0 is what it holds).
    pub fn stick_gap(&self, k: usize) -> f32 {
        let st = self.sticks[k];
        let a = st.a as usize;
        let (pa, ra) = if st.a_core {
            (self.cpos[a], self.cr[a])
        } else if st.mode == JOIN_STICKY && !st.b_core {
            (self.place_point(self.bead_ring[a] as usize, st.sa), self.r[a])
        } else {
            (self.pos[a], self.r[a])
        };
        if st.b_core {
            dist(pa, self.cpos[st.b as usize]) - ra - self.cr[st.b as usize]
        } else {
            let (j, kk, _, _, nchord, _) = self.edge_at(st.b as usize, st.s);
            let seg = self.pos[kk] - self.pos[j];
            let tp = (dot(pa - self.pos[j], seg) / len_sq(seg).max(1e-12)).clamp(0.0, 1.0);
            let d = pa - (self.pos[j] + seg * tp);
            let side = dot(d, nchord);
            (if side > 0.0 { len(d) } else { side }) - ra - self.r[j]
        }
    }

    /// Anchored stick `k`'s tension now: how far its bead sits from where its anchor holds
    /// it, along the anchor's edge (px; 0 for a sticky or core stick).
    pub fn stick_tension(&self, k: usize) -> f32 {
        let st = self.sticks[k];
        if st.a_core || st.b_core || st.mode != JOIN_ANCHORED {
            return 0.0;
        }
        self.tangent_offset(self.pos[st.a as usize], st.b as usize, st.anchor) - st.offset
    }

    /// The worst stick now: [largest gap beyond zero (px, stretched), deepest below it
    /// (px, squeezed), largest load].
    fn stick_health(&self) -> [f32; 3] {
        let (mut stretch, mut squeeze, mut load) = (0.0f32, 0.0f32, 0.0f32);
        for k in 0..self.sticks.len() {
            let c = self.stick_gap(k);
            stretch = stretch.max(c);
            squeeze = squeeze.max(-c);
            load = load.max(self.sticks[k].load);
        }
        [stretch, squeeze, load]
    }

    /// This step's candidates within the creature (see Colony::build_pairs()).
    fn build_own_pairs(&mut self, opt: Options) {
        self.bb.clear();
        self.xbb.clear();
        self.xbc.clear();
        self.xcc.clear();
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
        // Capture needs every candidate within the capture gap, whatever the contacts.
        let capturing = self.capturing;
        let cores_only = !opt.intra_contacts && opt.core_contacts && nc > 0 && !capturing;
        self.solve_bb = opt.intra_contacts;
        self.solve_cores = opt.intra_contacts || opt.core_contacts;
        if !active || !(opt.intra_contacts || cores_only || capturing) {
            return;
        }
        // How much further than touching a capture candidate may be: the gap, and the
        // way an edge's middle sits closer than its beads (a bead within the gap of an
        // edge is within about 0.15 of the radii more of the edge's nearer bead).
        let rmax = self.r.iter().copied().fold(0.0f32, f32::max);
        let extra = if capturing { opt.ad.capture + 0.3 * rmax } else { 0.0 };
        let slop = opt.slop + extra;
        let contact_slop = opt.slop;
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
                        let dsq = dist_sq(pi, self.pos[lj]);
                        if dsq < within * within {
                            let touch = qi + self.reach[lj] + contact_slop;
                            if dsq < touch * touch {
                                self.bb.push((li as u32, lj as u32));
                            } else {
                                self.xbb.push((li as u32, lj as u32));
                            }
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
                        let dsq = dist_sq(pi, self.cpos[lk]);
                        if dsq < within * within {
                            let touch = qi + self.creach[lk] + contact_slop;
                            if dsq < touch * touch {
                                self.bc.push((li as u32, lk as u32));
                            } else {
                                self.xbc.push((li as u32, lk as u32));
                            }
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
                        let dsq = dist_sq(pk, self.cpos[lj]);
                        if dsq < within * within {
                            let touch = qk + self.creach[lj] + contact_slop;
                            if dsq < touch * touch {
                                self.cc.push((lk as u32, lj as u32));
                            } else {
                                self.xcc.push((lk as u32, lj as u32));
                            }
                        }
                    }
                }
            }
        }
    }

    // ---- Promotion and demotion ----

    /// Removes core `k`, renumbering the later ones.
    fn remove_core(&mut self, k: usize) {
        let k32 = k as u32;
        self.drop_sticks(|st| (st.a_core && st.a == k32) || (st.b_core && st.b == k32));
        for st in self.sticks.iter_mut() {
            if st.a_core && st.a > k32 {
                st.a -= 1;
            }
            if st.b_core && st.b > k32 {
                st.b -= 1;
            }
        }
        self.rebuild_stuck();
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
        // Its sticks, and the ones on its skin, go (their pairs keep `joined`, so a
        // promotion or demotion that sticks again in the next frame reports nothing).
        {
            let (start, end, r32) = (self.rings[r].start as u32, (self.rings[r].start + self.rings[r].n) as u32, r as u32);
            self.drop_sticks(|st| (!st.a_core && st.a >= start && st.a < end) || (!st.b_core && st.b == r32));
            let n = end - start;
            for st in self.sticks.iter_mut() {
                if !st.a_core && st.a >= end {
                    st.a -= n;
                }
                if !st.b_core && st.b > r32 {
                    st.b -= 1;
                }
            }
        }
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
        self.stuck.drain(range.clone());
        self.rebuild_stuck();
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
        self.rebuild_holds(capture, bond_scale);
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
        self.rebuild_holds(capture, bond_scale);
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
        let mut c = Creature { every: 1, index: self.creatures.len() as u32, ..Default::default() };
        let count = cells.len() / CELL_STRIDE;
        for i in 0..count {
            let f = &cells[i * CELL_STRIDE..(i + 1) * CELL_STRIDE];
            c.cells.push(Cell::new(CellTuning::from_floats(f)));
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
            c.ns_sticks = 0;
            c.ns_capture = 0;
            c.made = 0;
            c.broken = 0;
            let ce = opt.ad.capture_every.max(1) as u64;
            c.capturing = opt.ad.enabled && !opt.ad.paused && !c.capture_paused && (frame - 1 + c.index as u64) % ce == 0;
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
        let ad = opt.ad;
        if ad.enabled {
            let t = Instant::now();
            self.for_each(|c| c.made = c.capture(&ad, frame));
            stats.capture_us = t.elapsed().as_micros() as u64;
        }
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
        let t = Instant::now();
        self.for_each(|c| c.broken = c.after_step(&ad, n_sub, frame));
        stats.settle_us = t.elapsed().as_micros() as u64;
        for c in self.creatures.iter_mut() {
            stats.sticks_cpu_us += c.ns_sticks / 1000;
            stats.sticks += c.sticks.len();
            stats.made += c.made;
            stats.broken += c.broken;
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
    /// another particle of its creature (beyond 1 px), the sticks' largest stretch and
    /// squeeze (px beyond and below zero gap) and largest load, how many sticks, how
    /// many particles are not finite].
    pub fn health(&self) -> [f32; 11] {
        let mut sticks = [0.0f32; 3];
        let mut count = 0usize;
        let mut nan = 0usize;
        let mut fastest = 0.0f32;
        let (mut amin, mut amax) = (f32::INFINITY, 0.0f32);
        let mut inverted = 0.0f32;
        let mut stretch = 0.0f32;
        let mut overlap = 0.0f32;
        for c in &self.creatures {
            for &v in c.vel.iter().chain(c.cvel.iter()) {
                fastest = fastest.max(len(v));
            }
            nan += c.pos.iter().chain(c.cpos.iter()).filter(|p| !p.x.is_finite() || !p.y.is_finite()).count();
            let sh = c.stick_health();
            for k in 0..3 {
                sticks[k] = sticks[k].max(sh[k]);
            }
            count += c.sticks.len();
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
        [fastest, amin, amax, inverted, stretch, overlap, sticks[0], sticks[1], sticks[2], count as f32, nan as f32]
    }

    /// Every creature's untaken events, creature after creature, each in the order it
    /// happened: (kind, creature, cell a, cell b).
    pub fn take_events(&mut self) -> Vec<(u8, u32, u32, u32)> {
        let mut out = Vec::new();
        for (ci, c) in self.creatures.iter_mut().enumerate() {
            out.extend(c.events.drain(..).map(|(k, a, b)| (k, ci as u32, a, b)));
        }
        out
    }

    /// Every creature's unanswered first touches: (creature, cell a, cell b).
    pub fn take_asks(&mut self) -> Vec<(u32, u32, u32)> {
        let mut out = Vec::new();
        for (ci, c) in self.creatures.iter_mut().enumerate() {
            out.extend(c.asks.drain(..).map(|(a, b)| (ci as u32, a, b)));
        }
        out
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

    /// GooTuning.tuning(14) at unit 0.5 (tests/unit/test_goo_colony_adhesion.gd builds
    /// cells from GooTuning itself), scaled to radius `r`.
    fn real_cell(x: f32, y: f32, r: f32, damp: f32) -> Vec<f32> {
        let f = r / 14.0;
        vec![
            x, y, r, 0.0, 12.0, 9.78979 * f, 4.39823 * f, 0.21667, 1737.97, 200.0, 8666.67, 4.33333, 2600.0, 1.3, 5.0, damp,
            std::f32::consts::PI * r * r, 1.0, 0.5, 0.2,
        ]
    }

    /// A hexagonal cluster of 19 touching 14 px cells about `at`.
    fn hex(col: &mut Colony, at: Vector2, damp: f32) -> usize {
        let r = 14.0;
        let mut cells = Vec::new();
        for q in -2i32..3 {
            for p in -2i32..3 {
                if (p + q).abs() > 2 {
                    continue;
                }
                cells.extend(real_cell(at.x + p as f32 * 2.0 * r + q as f32 * r, at.y + q as f32 * 3f32.sqrt() * r, r, damp));
            }
        }
        col.add_creature(&cells)
    }

    fn adhesive(threads: usize) -> Colony {
        let mut col = Colony::default();
        col.set_threads(threads);
        col.opt.ad.enabled = true;
        col.opt.ad.capture = 1.5;
        col.opt.ad.break_force = 2500.0;
        col
    }

    fn angular_momentum(c: &Creature) -> f32 {
        let cc = c.center();
        (0..c.pos.len()).map(|i| cross(c.pos[i] - cc, c.vel[i]) / c.w[i]).sum()
    }

    #[test]
    fn a_resting_anchored_cluster_does_not_spin_up() {
        // No damping at all: a stick that is not rotation-invariant (or a standing
        // conflict between sticks) shows as angular momentum growing frame after frame.
        for mode in [JOIN_ANCHORED, JOIN_STICKY] {
            let mut col = adhesive(1);
            col.opt.ad.break_force = 1e9;
            col.opt.ad.table[0][0] = mode;
            hex(&mut col, Vector2::ZERO, 0.0);
            for _ in 0..30 {
                col.step(1.0 / 60.0);
            }
            let l0 = angular_momentum(&col.creatures[0]);
            for _ in 0..300 {
                col.step(1.0 / 60.0);
            }
            let l1 = angular_momentum(&col.creatures[0]);
            let c = &col.creatures[0];
            let fastest = c.vel.iter().map(|v| len(*v)).fold(0.0f32, f32::max);
            println!("mode {}: L {:.3} -> {:.3}, fastest {:.2} px/s, {} sticks", mode, l0, l1, fastest, c.sticks.len());
            // (|L| = 250 is 0.003 rad/s for this cluster, about what capture leaves; 25 more
            // over the 5 s is 0.0003 rad/s, the bonds' own drift. It must not grow beyond.)
            assert!(l1.abs() <= l0.abs() + 25.0 && l1.abs() < 400.0, "angular momentum grows: {} -> {}", l0, l1);
            assert!(fastest < 5.0, "a resting cluster stays at rest: {}", fastest);
            assert!(c.sticks.len() > 30);
        }
    }

    #[test]
    fn threaded_adhesion_is_bit_identical_to_serial() {
        // Clusters thrown at each other: sticks made at spawn, broken by the impacts and
        // the pulls, captured again; anchored and sticky walls; events and all.
        let run = |threads: usize| {
            let mut col = adhesive(threads);
            col.opt.ad.table[0][1] = JOIN_STICKY;
            col.opt.ad.table[1][0] = JOIN_STICKY;
            for c in 0..6 {
                let k = hex(&mut col, Vector2::new(c as f32 * 160.0, (c % 2) as f32 * 30.0), 1.0);
                // Every third cell of type 1: sticky walls with its neighbours.
                for i in (0..col.creatures[k].cells.len()).step_by(3) {
                    col.creatures[k].cells[i].ctype = 1;
                }
                col.creatures[k].push = Vector2::new(if c % 2 == 0 { 900.0 } else { -900.0 }, 0.0);
                col.creatures[k].cells[3].push = Vector2::new(0.0, 6000.0);
            }
            let mut events = Vec::new();
            let (mut made, mut broken) = (0, 0);
            for f in 0..150 {
                col.step(1.0 / 60.0);
                made += col.stats.made;
                broken += col.stats.broken;
                if f == 70 {
                    for c in col.creatures.iter_mut() {
                        c.push = -c.push;
                    }
                }
                events.extend(col.take_events());
            }
            (col, events, made, broken)
        };
        let (a, ea, made, broken) = run(1);
        let (b, eb, _, _) = run(4);
        println!("made {}, broken {}, events {}", made, broken, ea.len());
        assert!(broken > 0 && made > 0, "sticks broke and were made");
        assert_eq!(ea, eb, "the same events in the same order");
        for (ca, cb) in a.creatures.iter().zip(&b.creatures) {
            for (p, q) in ca.pos.iter().zip(&cb.pos) {
                assert_eq!(p.x.to_bits(), q.x.to_bits());
                assert_eq!(p.y.to_bits(), q.y.to_bits());
            }
            assert_eq!(ca.sticks.len(), cb.sticks.len());
            for (s, t) in ca.sticks.iter().zip(&cb.sticks) {
                assert_eq!(s.load.to_bits(), t.load.to_bits());
                assert_eq!(s.anchor.to_bits(), t.anchor.to_bits());
            }
        }
    }

    #[test]
    fn promote_and_demote_keep_the_other_sticks_and_report_nothing() {
        let mut col = adhesive(1);
        col.opt.ad.break_force = 1e9;
        let r = 14.0;
        let mut cells = Vec::new();
        for i in 0..5 {
            for j in 0..5 {
                let mut c = real_cell(i as f32 * 2.0 * r, j as f32 * 2.0 * r, r, 1.0);
                if (1..4).contains(&i) && (1..4).contains(&j) {
                    c[3] = 1.0;
                }
                cells.extend(c);
            }
        }
        col.add_creature(&cells);
        for _ in 0..20 {
            col.step(1.0 / 60.0);
        }
        col.take_events();
        let c = &mut col.creatures[0];
        let before = c.sticks.len();
        let middle = 12;
        assert!(c.promote(middle, 1.5, 1.0) >= 0.0);
        assert!(c.sticks.len() < before, "the core's sticks went with it");
        for _ in 0..3 {
            col.step(1.0 / 60.0);
        }
        let c = &col.creatures[0];
        assert!(c.neighbours(middle as u32).len() >= 4, "the new ring is stuck again: {:?}", c.neighbours(middle as u32));
        let events = col.take_events();
        assert!(events.is_empty(), "a promotion is not a parting: {:?}", events);
        for st in &col.creatures[0].sticks {
            if !st.a_core {
                assert!((st.a as usize) < col.creatures[0].pos.len());
            }
        }
    }
}
