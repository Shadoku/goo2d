//! Frozen topology's own contacts between retopologies, kept per pair of cells
//! (docs/colony-frozen.md, `FROZEN_SELF_CELLS`).
//!
//! A creature's own contact candidates are kept as one list per pair of neighbouring cells
//! (and one per ring for its own beads), each built with `pair_skin` px of margin and
//! filtered every frame. A list stays valid while the two cells cannot have moved more
//! than that toward each other since it was built, judged from the two cells alone, so a
//! creature that bends or swims rebuilds only the lists of the cells whose neighbourhood
//! changed, never the whole creature's.
//!
//! The judgement. Each cell keeps a snapshot of its beads' places about its centre (q_i)
//! and each frame fits its beads as a similarity of it: p_i = C + z q_i + e_i (C the
//! beads' mean, z a complex number: the cell's turn and scale since the snapshot, e_i the
//! rest, its deformation; a core is its centre with z = 1). A list built at time t keeps
//! C, z and the largest |e| of both cells then. For any of its cells' particles i (cell a)
//! and j (cell b), and any common turn w (|w| = 1), distances being turn-invariant:
//!
//!   |p_i - p_j|(now) >= |p_i - p_j|(t) - B,
//!   B = |w̄ (C_a - C_b)(now) - (C_a - C_b)(t)| + |w̄ z_a(now) - z_a(t)| ρ_a
//!       + |w̄ z_b(now) - z_b(t)| ρ_b + |e|max_a(now) + |e|max_a(t) + |e|max_b(now) + |e|max_b(t)
//!
//! (ρ the largest |q| of the cell), w the mean of the two cells' turns since t: two cells
//! turning together as a bend turns them keep B near zero. A list also loses margin to its
//! cells' bead radii growing (a muscle) and to the motion within the coming frame, M_ab:
//! PAIR_SLACK × ((|V_a - V_b| + the cells' largest bead speeds about their means) dt +
//! |A_a - A_b| dt² / 2) + 2 PAIR_PAD (V, A a cell's mean velocity and acceleration), the
//! per-pair form of what the searches pad each particle with, less the beads' own
//! accelerations about their cell's mean: those are its pressure and damping, held by its
//! skin within the substep (counting them made the margin 15-30 px in a swimming crowd,
//! against the 2-4 px its cells move; measured sound without them: docs/colony-frozen.md).
//! While B + growth + M_ab stays under the margin it
//! was built with, every pair it left out is still farther apart than touching plus this
//! frame's motion: the filter misses nothing the full search would find. Otherwise that
//! one list is built again (all pairs of its two cells, a few dozen distances).
//!
//! A cell whose deformation reaches a quarter of the margin takes a new snapshot (its
//! lists are built again). Which cells neighbour each other comes from a scan of their
//! centres in a small grid, kept with a margin of its own (the margin needed plus the
//! largest cell's reach) while no cell has strayed from a rigid motion of the scan by more
//! than the rest of it allows (a swimming worm scans every 10 frames or so, a creature
//! that keeps its shape almost never); each frame its candidates are tested (a cell pair
//! whose centres are farther apart than both cells' reaches, the slop and the larger of
//! the margin and M_ab cannot touch this frame). Every list is dropped at a
//! change of topology (a ring became a core or back, a cell added or removed) and built
//! afresh as its cells meet. All of it is the creature's own data in a fixed order:
//! threaded stays bit-identical to serial.

use super::*;
use crate::grid::DenseGrid;

/// A cell takes a new snapshot when its deformation reaches this share of the margin.
const SNAP_SHARE: f32 = 0.25;
/// A cell pair's list not near for this many frames is dropped.
const FORGET_FRAMES: u64 = 120;

#[inline]
fn cmul(a: Vector2, b: Vector2) -> Vector2 {
    Vector2::new(a.x * b.x - a.y * b.y, a.x * b.y + a.y * b.x)
}

/// conj(a) × b.
#[inline]
fn cmul_conj(a: Vector2, b: Vector2) -> Vector2 {
    Vector2::new(a.x * b.x + a.y * b.y, a.x * b.y - a.y * b.x)
}

#[inline]
fn unit(v: Vector2) -> Vector2 {
    let l = len(v);
    if l > 1e-12 { v / l } else { Vector2::new(1.0, 0.0) }
}

/// One cell pair's kept list (cell a's entry for cell b >= a).
pub(super) struct CpEntry {
    b: u32,
    epoch_a: u32,
    epoch_b: u32,
    c_a: Vector2,
    c_b: Vector2,
    z_a: Vector2,
    z_b: Vector2,
    /// |e|max of both cells when built.
    dev: f32,
    r_a: f32,
    r_b: f32,
    /// The margin it was built with (px).
    margin: f32,
    seen: u64,
    valid: bool,
    /// Bead-bead (i < j), bead-core (bead, core) or core-core (k < l) by the cells' kinds.
    pairs: Vec<(u32, u32)>,
}

#[derive(Default)]
pub(super) struct CellPairs {
    entries: Vec<Vec<CpEntry>>,
    // Per cell, this frame (and the snapshot's).
    c: Vec<Vector2>,
    z: Vec<Vector2>,
    dev: Vec<f32>,
    rmax: Vec<f32>,
    ext: Vec<f32>,
    v: Vec<Vector2>,
    mv: Vec<f32>,
    a: Vec<Vector2>,
    rho: Vec<f32>,
    epoch: Vec<u32>,
    snapped: Vec<bool>,
    /// Per bead: its place about its cell's centre at the cell's snapshot.
    q: Vec<Vector2>,
    topology: u64,
    beads: usize,
    cores: usize,
    grid: DenseGrid,
    near: Vec<(u32, u32)>,
    /// The candidate cell pairs (a < b) of the last scan, the centres and reaches then, and
    /// the margin it covered.
    scan_pairs: Vec<(u32, u32)>,
    scan_c: Vec<Vector2>,
    scan_ext: Vec<f32>,
    scan_l: f32,
    pub scans: usize,
    /// Lists built and cells snapshot in the last frame; lists in use.
    pub rebuilt: usize,
    pub snaps: usize,
    pub lists: usize,
}

impl Creature {
    /// This frame's own contacts (bb, bc, cc) from the kept cell-pair lists (see the
    /// module's head). `margin` the lists' margin (Options::pair_skin), `contact_slop`
    /// the contacts' slop, `frame` the colony's frame.
    pub(super) fn cell_pair_contacts(&mut self, margin: f32, contact_slop: f32, frame: u64) {
        let mut cp = std::mem::take(&mut self.cp);
        cp.rebuilt = 0;
        cp.snaps = 0;
        cp.lists = 0;
        cp.scans = 0;
        let cells = self.cells.len();
        if cp.topology != self.topology || cp.beads != self.pos.len() || cp.cores != self.cpos.len() || cp.entries.len() != cells {
            cp.entries.clear();
            cp.entries.resize_with(cells, Vec::new);
            cp.snapped.clear();
            cp.snapped.resize(cells, false);
            cp.epoch.resize(cells, 0);
            cp.rho.resize(cells, 0.0);
            cp.q.resize(self.pos.len(), Vector2::ZERO);
            cp.scan_c.clear();
            cp.topology = self.topology;
            cp.beads = self.pos.len();
            cp.cores = self.cpos.len();
        }
        for list in [&mut cp.c, &mut cp.z, &mut cp.v, &mut cp.a] {
            list.resize(cells, Vector2::ZERO);
        }
        for list in [&mut cp.dev, &mut cp.rmax, &mut cp.ext, &mut cp.mv] {
            list.resize(cells, 0.0);
        }
        let snap_at = SNAP_SHARE * margin;
        // Each cell's fit, deformation, reach and motion.
        let (mut vsum, mut asum) = (Vector2::ZERO, Vector2::ZERO);
        let mut ext_max = 0.0f32;
        for cell in 0..cells {
            match self.cells[cell].kind {
                Kind::Ring(r) => {
                    let ring = &self.rings[r];
                    let (s, n) = (ring.start, ring.n);
                    let inv = 1.0 / n.max(1) as f32;
                    let (mut c, mut v, mut a) = (Vector2::ZERO, Vector2::ZERO, Vector2::ZERO);
                    for i in s..s + n {
                        c += self.pos[i];
                        v += self.vel[i];
                        a += self.force[i] * self.w[i];
                    }
                    c = c * inv;
                    v = v * inv;
                    a = a * inv;
                    let mut z = Vector2::new(1.0, 0.0);
                    let mut dev = f32::INFINITY;
                    if cp.snapped[cell] {
                        let (mut num, mut den) = (Vector2::ZERO, 0.0f32);
                        for i in s..s + n {
                            num += cmul_conj(cp.q[i], self.pos[i] - c);
                            den += len_sq(cp.q[i]);
                        }
                        if den > 1e-12 {
                            z = num / den;
                        }
                        let mut dev2 = 0.0f32;
                        for i in s..s + n {
                            dev2 = dev2.max(len_sq(self.pos[i] - c - cmul(z, cp.q[i])));
                        }
                        dev = dev2.sqrt();
                    }
                    if dev > snap_at {
                        let mut rho = 0.0f32;
                        for i in s..s + n {
                            cp.q[i] = self.pos[i] - c;
                            rho = rho.max(len(cp.q[i]));
                        }
                        cp.rho[cell] = rho;
                        cp.epoch[cell] = cp.epoch[cell].wrapping_add(1);
                        cp.snapped[cell] = true;
                        cp.snaps += 1;
                        z = Vector2::new(1.0, 0.0);
                        dev = 0.0;
                    }
                    // The largest distance from the centre plus the largest bead radius (at
                    // least each bead's reach), one square root each.
                    let (mut ext2, mut rmax, mut mv2) = (0.0f32, 0.0f32, 0.0f32);
                    for i in s..s + n {
                        ext2 = ext2.max(len_sq(self.pos[i] - c));
                        rmax = rmax.max(self.r[i]);
                        mv2 = mv2.max(len_sq(self.vel[i] - v));
                    }
                    let (ext, mv) = (ext2.sqrt() + rmax, mv2.sqrt());
                    cp.c[cell] = c;
                    cp.z[cell] = z;
                    cp.dev[cell] = dev;
                    cp.ext[cell] = ext;
                    cp.rmax[cell] = rmax;
                    cp.v[cell] = v;
                    cp.a[cell] = a;
                    cp.mv[cell] = mv;
                }
                Kind::Core(k) => {
                    if !cp.snapped[cell] {
                        cp.snapped[cell] = true;
                        cp.epoch[cell] = cp.epoch[cell].wrapping_add(1);
                        cp.rho[cell] = 0.0;
                    }
                    cp.c[cell] = self.cpos[k];
                    cp.z[cell] = Vector2::new(1.0, 0.0);
                    cp.dev[cell] = 0.0;
                    cp.ext[cell] = self.cr[k];
                    cp.rmax[cell] = self.cr[k];
                    cp.v[cell] = self.cvel[k];
                    cp.a[cell] = self.cforce[k] * self.cw[k];
                    cp.mv[cell] = 0.0;
                }
            }
            vsum += cp.v[cell];
            asum += cp.a[cell];
            ext_max = ext_max.max(cp.ext[cell]);
        }
        let dt = self.dt;
        let inv_cells = 1.0 / cells.max(1) as f32;
        let (vmean, amean) = (vsum * inv_cells, asum * inv_cells);
        let (mut vdev, mut adev, mut mvmax) = (0.0f32, 0.0f32, 0.0f32);
        for cell in 0..cells {
            vdev = vdev.max(len(cp.v[cell] - vmean));
            adev = adev.max(len(cp.a[cell] - amean));
            mvmax = mvmax.max(cp.mv[cell]);
        }
        let motion = |cp: &CellPairs, a: usize, b: usize| {
            PAIR_SLACK * ((len(cp.v[a] - cp.v[b]) + cp.mv[a] + cp.mv[b]) * dt + 0.5 * len(cp.a[a] - cp.a[b]) * dt * dt) + 2.0 * PAIR_PAD
        };
        // Which cells neighbour each other this frame: from the candidate cell pairs of the
        // last scan (centres within both reaches, the slop and `scan_l`), kept while no
        // pair left out can have come within reach: the cells' centres have moved at most
        // r_max each from where a rigid motion of the scan would put them, their reaches
        // grown at most `grow` each.
        let m_max = PAIR_SLACK * (2.0 * (vdev + mvmax) * dt + adev * dt * dt) + 2.0 * PAIR_PAD;
        let need = margin.max(m_max);
        let mut scan = cp.scan_c.len() != cells || cp.scan_ext.len() != cells;
        if !scan {
            let inv = 1.0 / cells.max(1) as f32;
            let (mut m0, mut m1) = (Vector2::ZERO, Vector2::ZERO);
            for cell in 0..cells {
                m0 += cp.scan_c[cell];
                m1 += cp.c[cell];
            }
            m0 = m0 * inv;
            m1 = m1 * inv;
            let (mut cs, mut dt_) = (0.0f32, 0.0f32);
            for cell in 0..cells {
                let (p, q) = (cp.scan_c[cell] - m0, cp.c[cell] - m1);
                cs += cross(p, q);
                dt_ += dot(p, q);
            }
            let rot = unit(Vector2::new(dt_, cs));
            let (mut r_max, mut grow) = (0.0f32, 0.0f32);
            for cell in 0..cells {
                r_max = r_max.max(len(cp.c[cell] - m1 - cmul(rot, cp.scan_c[cell] - m0)));
                grow = grow.max(cp.ext[cell] - cp.scan_ext[cell]);
            }
            scan = 2.0 * r_max + 2.0 * grow.max(0.0) + need > cp.scan_l;
        }
        if scan {
            let l = need + ext_max;
            let cell_size = (2.0 * ext_max + contact_slop + l).max(1.0);
            let mut grid = std::mem::take(&mut cp.grid);
            let mut found = std::mem::take(&mut cp.scan_pairs);
            found.clear();
            let built = grid.build(&cp.c, cell_size, 0.0, 16 * cells + 64);
            for a in 0..cells {
                let mut test = |b: usize| {
                    let th = cp.ext[a] + cp.ext[b] + contact_slop + l;
                    if dist_sq(cp.c[a], cp.c[b]) < th * th {
                        found.push((a as u32, b as u32));
                    }
                };
                if built {
                    let (cx, cy) = grid.cells[a];
                    for dy in -1..=1 {
                        for kk in grid.row(cy + dy, cx - 1, cx + 1) {
                            let b = grid.items[kk] as usize;
                            if b > a {
                                test(b);
                            }
                        }
                    }
                } else {
                    for b in a + 1..cells {
                        test(b);
                    }
                }
            }
            found.sort_unstable();
            cp.grid = grid;
            cp.scan_pairs = found;
            cp.scan_c.clear();
            cp.scan_c.extend_from_slice(&cp.c);
            cp.scan_ext.clear();
            cp.scan_ext.extend_from_slice(&cp.ext);
            cp.scan_l = l;
            cp.scans += 1;
        }
        let mut near = std::mem::take(&mut cp.near);
        near.clear();
        let mut k = 0;
        for a in 0..cells {
            if matches!(self.cells[a].kind, Kind::Ring(_)) {
                near.push((a as u32, a as u32));
            }
            while k < cp.scan_pairs.len() && cp.scan_pairs[k].0 as usize == a {
                let b = cp.scan_pairs[k].1 as usize;
                k += 1;
                let th0 = cp.ext[a] + cp.ext[b] + contact_slop;
                let d2 = dist_sq(cp.c[a], cp.c[b]);
                let th = th0 + need;
                if d2 >= th * th {
                    continue;
                }
                let th = th0 + margin.max(motion(&cp, a, b));
                if d2 < th * th {
                    near.push((a as u32, b as u32));
                }
            }
        }
        for &(a, b) in &near {
            let list = &mut cp.entries[a as usize];
            match list.binary_search_by_key(&b, |e| e.b) {
                Ok(k) => list[k].seen = frame,
                Err(k) => list.insert(
                    k,
                    CpEntry {
                        b,
                        epoch_a: 0,
                        epoch_b: 0,
                        c_a: Vector2::ZERO,
                        c_b: Vector2::ZERO,
                        z_a: Vector2::ZERO,
                        z_b: Vector2::ZERO,
                        dev: 0.0,
                        r_a: 0.0,
                        r_b: 0.0,
                        margin: 0.0,
                        seen: frame,
                        valid: false,
                        pairs: Vec::new(),
                    },
                ),
            }
        }
        cp.near = near;
        // Each near pair's list: judged, built again when it must be, filtered.
        let mut entries = std::mem::take(&mut cp.entries);
        for a in 0..cells {
            let list = &mut entries[a];
            list.retain(|e| frame.saturating_sub(e.seen) <= FORGET_FRAMES);
            for e in list.iter_mut() {
                if e.seen != frame {
                    continue;
                }
                let b = e.b as usize;
                let m = motion(&cp, a, b);
                let mut ok = e.valid && e.epoch_a == cp.epoch[a] && e.epoch_b == cp.epoch[b];
                if ok {
                    // Any common turn w gives a bound; the two cells' turns since t summed (as
                    // complex numbers, both near unit length) is their mean, near enough.
                    let w = unit(cmul_conj(e.z_a, cp.z[a]) + cmul_conj(e.z_b, cp.z[b]));
                    let bound = len(cmul_conj(w, cp.c[a] - cp.c[b]) - (e.c_a - e.c_b))
                        + len(cmul_conj(w, cp.z[a]) - e.z_a) * cp.rho[a]
                        + len(cmul_conj(w, cp.z[b]) - e.z_b) * cp.rho[b]
                        + e.dev
                        + cp.dev[a]
                        + cp.dev[b]
                        + (cp.rmax[a] - e.r_a).max(0.0)
                        + (cp.rmax[b] - e.r_b).max(0.0)
                        + m;
                    ok = bound < e.margin;
                }
                if !ok {
                    let list_margin = margin + m;
                    self.build_cell_pair(e, a, list_margin + contact_slop);
                    e.epoch_a = cp.epoch[a];
                    e.epoch_b = cp.epoch[b];
                    e.c_a = cp.c[a];
                    e.c_b = cp.c[b];
                    e.z_a = cp.z[a];
                    e.z_b = cp.z[b];
                    e.dev = cp.dev[a] + cp.dev[b];
                    e.r_a = cp.rmax[a];
                    e.r_b = cp.rmax[b];
                    e.margin = list_margin;
                    e.valid = true;
                    cp.rebuilt += 1;
                }
                cp.lists += 1;
                self.filter_cell_pair(e, a, m + contact_slop);
            }
        }
        cp.entries = entries;
        self.cp = cp;
    }

    /// Every pair of particles of cells `a` and `e.b` closer than their radii and `extra`.
    fn build_cell_pair(&self, e: &mut CpEntry, a: usize, extra: f32) {
        e.pairs.clear();
        let b = e.b as usize;
        match (self.cells[a].kind, self.cells[b].kind) {
            (Kind::Ring(ra), Kind::Ring(rb)) => {
                let (ring_a, ring_b) = (&self.rings[ra], &self.rings[rb]);
                for i in ring_a.start..ring_a.start + ring_a.n {
                    let lo = if ra == rb { i + 1 } else { ring_b.start };
                    for j in lo..ring_b.start + ring_b.n {
                        if ra == rb {
                            let hop = (i - ring_a.start).abs_diff(j - ring_a.start);
                            if hop.min(ring_a.n - hop) <= 2 {
                                continue;
                            }
                        }
                        let within = self.r[i] + self.r[j] + extra;
                        if dist_sq(self.pos[i], self.pos[j]) < within * within {
                            e.pairs.push(if i < j { (i as u32, j as u32) } else { (j as u32, i as u32) });
                        }
                    }
                }
            }
            (Kind::Ring(r), Kind::Core(k)) | (Kind::Core(k), Kind::Ring(r)) => {
                let ring = &self.rings[r];
                for i in ring.start..ring.start + ring.n {
                    let within = self.r[i] + self.cr[k] + extra;
                    if dist_sq(self.pos[i], self.cpos[k]) < within * within {
                        e.pairs.push((i as u32, k as u32));
                    }
                }
            }
            (Kind::Core(k), Kind::Core(l)) => {
                if k != l {
                    e.pairs.push((k.min(l) as u32, k.max(l) as u32));
                }
            }
        }
    }

    /// This frame's contacts of a kept list: its pairs closer than their radii and `extra`.
    fn filter_cell_pair(&mut self, e: &CpEntry, a: usize, extra: f32) {
        let b = e.b as usize;
        match (self.cells[a].kind, self.cells[b].kind) {
            (Kind::Ring(_), Kind::Ring(_)) => {
                for &(i, j) in &e.pairs {
                    let (iu, ju) = (i as usize, j as usize);
                    let touch = self.r[iu] + self.r[ju] + extra;
                    if dist_sq(self.pos[iu], self.pos[ju]) < touch * touch {
                        self.bb.push((i, j));
                    }
                }
            }
            (Kind::Core(_), Kind::Core(_)) => {
                for &(k, l) in &e.pairs {
                    let (ku, lu) = (k as usize, l as usize);
                    let touch = self.cr[ku] + self.cr[lu] + extra;
                    if dist_sq(self.cpos[ku], self.cpos[lu]) < touch * touch {
                        self.cc.push((k, l));
                    }
                }
            }
            _ => {
                for &(i, k) in &e.pairs {
                    let (iu, ku) = (i as usize, k as usize);
                    let touch = self.r[iu] + self.cr[ku] + extra;
                    if dist_sq(self.pos[iu], self.cpos[ku]) < touch * touch {
                        self.bc.push((i, k));
                    }
                }
            }
        }
    }
}
