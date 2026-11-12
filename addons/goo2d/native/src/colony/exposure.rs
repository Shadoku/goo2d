//! Exposure, pockets and core cells driven by them (milestone 2 of the colony plan,
//! docs/colony-exposure.md).
//!
//! Each ring bead of a creature is exposed (it faces the water) or enclosed. A bead is
//! enclosed when it is stuck, when it lies within `gap` of another cell's skin of the same
//! creature (walls are held from one side, so the far side's beads are not stuck but are
//! within the gap), or when it faces a closed pocket between cells. Pockets come from the
//! creature's outline as loops: every cell's runs of beads not enclosed by contact are
//! chained, the end of each run joined to the start of the run that continues the outline
//! on the cell it meets there; a loop wound as the rings are (negative signed area, every
//! ring being counter-clockwise on screen) is an outside, one wound the other way a
//! pocket (the largest loop is an outside whatever its winding).
//!
//! A core takes part as the ring it would be: its cell's bead count of virtual beads on its
//! rim, turned with it, tested with a wider gap (`core_gap` × `gap`: the hysteresis that
//! keeps a cell from switching back and forth). A core with a virtual bead on an outside
//! loop is exposed.
//!
//! With `auto_cores` a ring with every bead enclosed for `to_core_time` becomes a core, and
//! an exposed core becomes a ring after `to_ring_time`; a cell that switched does not switch
//! again for `switch_rest`. Each switch sticks the cell straight back to the neighbours it
//! was joined to (restick()), so a switch is not a parting.
//!
//! The pass runs in the per-creature part of the step, on the creature's own data, in a
//! fixed order: the threaded step stays bit-identical to the serial one. It runs when it can
//! have changed: a stick made or broken, an event, a switch, a resize, a join or part by
//! hand, and every `every` frames (staggered by creature) as a safety net.

use super::*;

const NONE: u32 = u32::MAX;
/// Exposure::skip's modes.
pub const SKIP_NONE: u8 = 0;
pub const SKIP_CELLS: u8 = 1;
pub const SKIP_BEADS: u8 = 2;
/// How long (s) two creatures that met faster than Exposure::skip_speed keep colliding
/// whole after they last did.
pub const FAST_REST: f32 = 1.0;

/// The exposure's settings, colony-wide.
#[derive(Clone, Copy, Debug)]
pub struct Exposure {
    pub enabled: bool,
    /// A bead this close (gap between outlines, px) to another cell's skin is enclosed;
    /// below 0: Adhesion::capture.
    pub gap: f32,
    /// A core's virtual beads use `core_gap` × `gap`.
    pub core_gap: f32,
    /// The pass runs at least every this many frames.
    pub every: u32,
    /// And every frame for this many frames after a pair parted (by a break or by hand) or
    /// a cell switched: cells that parted take a few frames to move apart.
    pub hot: u32,
    /// What takes no part in contacts with other creatures: SKIP_NONE (the default),
    /// SKIP_CELLS (the beads of rings with no exposed bead, and cores not on the outside) or
    /// SKIP_BEADS (every enclosed bead). Both skips are unsound (docs/colony-exposure.md):
    /// an outer ring is soft, and the other creature's bead that dents it meets nothing
    /// behind it and passes in.
    pub skip: u8,
    /// ... but only between two creatures whose mean velocities differ by less than this
    /// (px/s): meeting faster, they collide whole, and go on doing so for FAST_REST.
    pub skip_speed: f32,
    pub auto_cores: bool,
    /// How long (s) a ring must stay wholly enclosed before it becomes a core.
    pub to_core_time: f32,
    /// How long (s) a core must stay exposed before it becomes a ring.
    pub to_ring_time: f32,
    /// After a switch a cell does not switch again for this long (s).
    pub switch_rest: f32,
    /// A core made from a ring starts as large as its neighbours leave room for and grows
    /// to its cell's radius over this long (s).
    pub core_ease: f32,
}

impl Default for Exposure {
    fn default() -> Self {
        Exposure {
            enabled: false,
            gap: -1.0,
            core_gap: 2.0,
            every: 30,
            hot: 6,
            skip: SKIP_NONE,
            skip_speed: 1600.0,
            auto_cores: false,
            to_core_time: 0.25,
            to_ring_time: 0.0,
            switch_rest: 1.0,
            core_ease: 0.25,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum LoopKind {
    Outside,
    Pocket,
}

/// A point of an outline loop: a bead (`core` false, `index` the bead) or a core's virtual
/// bead (`index` the core, `local` which of its virtual beads).
#[derive(Clone, Copy, Debug)]
pub struct LoopPt {
    pub core: bool,
    pub index: u32,
    pub local: u32,
}

#[derive(Clone, Debug)]
pub struct OutlineLoop {
    pub kind: LoopKind,
    /// Its signed area when found (px²; negative: wound as the rings).
    pub area: f32,
    pub pts: Vec<LoopPt>,
}

#[derive(Clone, Copy)]
struct Chain {
    start: u32,
    end: u32,
    cell: u32,
    closed: bool,
    succ: u32,
    state: u8,
    /// Its successor was a guess (an open path closed on itself).
    patched: bool,
}

/// The pass's working arrays, kept between passes (no allocation once warm).
#[derive(Default)]
pub(super) struct Scratch {
    pos: Vec<Vector2>,
    r: Vec<f32>,
    cell: Vec<u32>,
    limit: Vec<f32>,
    /// The core a point is a virtual bead of (NONE: a bead).
    core: Vec<u32>,
    /// Per cell: its first point and count.
    range: Vec<(u32, u32)>,
    /// Per point: 1 not enclosed by contact; the cell it is enclosed against; its gap.
    contact: Vec<u8>,
    against: Vec<u32>,
    best: Vec<f32>,
    chain_of: Vec<u32>,
    chains: Vec<Chain>,
    cell_chains: Vec<(u32, u32)>,
    /// Per point: 0 on no loop (or a broken chain), 1 an outside, 2 a pocket.
    mark: Vec<u8>,
    grid: Grid,
    path: Vec<u32>,
    poly: Vec<Vector2>,
    /// The successors' offers: (tier, distance², run, its candidate successor).
    offers: Vec<(u8, f32, u32, u32)>,
    taken: Vec<bool>,
}

#[inline]
fn segment_distance(p: Vector2, a: Vector2, b: Vector2) -> f32 {
    let seg = b - a;
    let l2 = len_sq(seg);
    let t = if l2 > 1e-12 { (dot(p - a, seg) / l2).clamp(0.0, 1.0) } else { 0.0 };
    dist(p, a + seg * t)
}

impl Scratch {
    #[inline]
    fn next(&self, p: u32) -> u32 {
        let (base, n) = self.range[self.cell[p as usize] as usize];
        base + (p - base + 1) % n
    }

    #[inline]
    fn prev(&self, p: u32) -> u32 {
        let (base, n) = self.range[self.cell[p as usize] as usize];
        base + (p - base + n - 1) % n
    }
}

impl Creature {
    /// Core `k`'s virtual bead `j` (of its cell's bead count): where its ring's bead j
    /// would be at rest, turned with it and scaled with its radius now.
    pub fn core_point(&self, k: usize, j: usize) -> Vector2 {
        let t = &self.cells[self.ccell[k] as usize].t;
        let n = t.beads.max(3);
        let a = -std::f32::consts::TAU * j as f32 / n as f32 + self.crot[k];
        let f = self.cr[k] / t.radius.max(1e-6);
        self.cpos[k] + Vector2::new(a.cos(), a.sin()) * (t.ring_radius * f)
    }

    /// The points of loop `l` now.
    pub fn loop_points(&self, l: &OutlineLoop) -> Vec<Vector2> {
        l.pts
            .iter()
            .map(|p| if p.core { self.core_point(p.index as usize, p.local as usize) } else { self.pos[p.index as usize] })
            .collect()
    }

    /// Cell `cell`'s exposed beads (a ring's, one per bead) or [1 exposed / 0] (a core).
    pub fn cell_exposed(&self, cell: usize) -> Vec<u8> {
        match self.cells[cell].kind {
            Kind::Ring(r) => {
                let ring = &self.rings[r];
                self.exposed[ring.start..ring.start + ring.n].to_vec()
            }
            Kind::Core(k) => vec![self.cexposed[k]],
        }
    }

    /// Finds which beads are exposed and the outline's loops (see the module's head).
    pub(super) fn compute_exposure(&mut self, gap: f32, core_gap: f32) {
        let mut s = std::mem::take(&mut self.xs);
        let nb = self.pos.len();
        let ncells = self.cells.len();
        // The points: every bead (same index), then each core's virtual beads.
        s.pos.clear();
        s.r.clear();
        s.cell.clear();
        s.limit.clear();
        s.core.clear();
        s.range.clear();
        s.range.resize(ncells, (0, 0));
        for ring in &self.rings {
            s.range[ring.cell] = (ring.start as u32, ring.n as u32);
        }
        for i in 0..nb {
            s.pos.push(self.pos[i]);
            s.r.push(self.r[i]);
            s.cell.push(self.rings[self.bead_ring[i] as usize].cell as u32);
            s.limit.push(gap);
            s.core.push(NONE);
        }
        for k in 0..self.cpos.len() {
            let cell = self.ccell[k] as usize;
            let t = self.cells[cell].t;
            let n = t.beads.max(3);
            let f = self.cr[k] / t.radius.max(1e-6);
            s.range[cell] = (s.pos.len() as u32, n as u32);
            for j in 0..n {
                s.pos.push(self.core_point(k, j));
                s.r.push(t.bead_radius * f);
                s.cell.push(cell as u32);
                s.limit.push(core_gap);
                s.core.push(k as u32);
            }
        }
        let np = s.pos.len();
        // Enclosed by contact: stuck, or within the gap of another cell's skin.
        s.contact.clear();
        s.contact.resize(np, 1);
        s.against.clear();
        s.against.resize(np, NONE);
        s.best.clear();
        s.best.resize(np, f32::INFINITY);
        // What the sticks already say, without a search: a stuck bead is enclosed against
        // the cell it is stuck to, the beads of the edge it holds onto (within the gap of it)
        // against its own, and a core's virtual beads facing a bead or core stuck to it (tested exactly,
        // the three nearest in angle) against that one's cell.
        let mark = |s: &mut Scratch, p: usize, cell: u32| {
            if s.best[p] != f32::NEG_INFINITY {
                s.contact[p] = 0;
                s.against[p] = cell;
                s.best[p] = f32::NEG_INFINITY;
            }
        };
        for st in &self.sticks {
            if !st.a_core {
                mark(&mut s, st.a as usize, st.cell_b);
            }
        }
        for st in &self.sticks {
            if st.b_core {
                let k = st.b as usize;
                let (from, from_r) = if st.a_core { (self.cpos[st.a as usize], self.cr[st.a as usize]) } else { (self.pos[st.a as usize], self.r[st.a as usize]) };
                self.mark_facing(&mut s, k, from, from_r, st.cell_a);
                if st.a_core {
                    let ka = st.a as usize;
                    self.mark_facing(&mut s, ka, self.cpos[k], self.cr[k], st.cell_b);
                }
            } else if !st.a_core {
                // The edge's beads, where within the gap of the stuck bead.
                let (j, kk, _, _, _, _) = self.edge_at(st.b as usize, st.s);
                let (pa, ra) = (self.pos[st.a as usize], self.r[st.a as usize]);
                for q in [j, kk] {
                    if dist(s.pos[q], pa) - s.r[q] - ra < s.limit[q] {
                        mark(&mut s, q, st.cell_a);
                    }
                }
            }
        }
        let mut rmax = 0.0f32;
        let mut emax = 0.0f32;
        let mut lmax = 0.0f32;
        for p in 0..np {
            rmax = rmax.max(s.r[p]);
            lmax = lmax.max(s.limit[p]);
            emax = emax.max(dist(s.pos[p], s.pos[s.next(p as u32) as usize]));
        }
        let cs = (2.0 * rmax + lmax + emax).max(1.0);
        s.grid.build(&s.pos, cs);
        for p in 0..np {
            if s.best[p] == f32::NEG_INFINITY {
                continue;
            }
            let cp = s.cell[p];
            let (cx, cy) = s.grid.cells[p];
            let pp = s.pos[p];
            for dy in -1..=1 {
                for dx in -1..=1 {
                    let (tx, ty) = (cx + dx, cy + dy);
                    let bkt = s.grid.bucket(tx, ty);
                    for kk in s.grid.start[bkt] as usize..s.grid.start[bkt + 1] as usize {
                        let q = s.grid.items[kk] as usize;
                        if s.grid.cells[q] != (tx, ty) || s.cell[q] == cp {
                            continue;
                        }
                        // Too far for its skin (or its core's rim) to be within the gap.
                        let near = s.r[p] + s.r[q] + s.limit[p] + emax;
                        if dist_sq(pp, s.pos[q]) >= near * near {
                            continue;
                        }
                        let g = if s.core[q] != NONE {
                            let k = s.core[q] as usize;
                            dist(pp, self.cpos[k]) - s.r[p] - self.cr[k]
                        } else {
                            let a = s.pos[s.prev(q as u32) as usize];
                            let b = s.pos[s.next(q as u32) as usize];
                            let d = segment_distance(pp, a, s.pos[q]).min(segment_distance(pp, s.pos[q], b));
                            d - s.r[p] - s.r[q]
                        };
                        if g < s.limit[p] && g < s.best[p] {
                            s.best[p] = g;
                            s.contact[p] = 0;
                            s.against[p] = s.cell[q];
                        }
                    }
                }
            }
        }
        // Each cell's runs of points not enclosed by contact.
        s.chain_of.clear();
        s.chain_of.resize(np, NONE);
        s.chains.clear();
        s.cell_chains.clear();
        s.cell_chains.resize(ncells, (0, 0));
        for cell in 0..ncells {
            let (base, n) = s.range[cell];
            let first = s.chains.len() as u32;
            if n == 0 {
                s.cell_chains[cell] = (first, 0);
                continue;
            }
            let open = (base..base + n).filter(|&p| s.contact[p as usize] == 1).count() as u32;
            if open == n {
                let id = s.chains.len() as u32;
                s.chains.push(Chain { start: base, end: base + n - 1, cell: cell as u32, closed: true, succ: id, state: 0, patched: false });
                for p in base..base + n {
                    s.chain_of[p as usize] = id;
                }
            } else if open > 0 {
                for p in base..base + n {
                    if s.contact[p as usize] == 1 && s.contact[s.prev(p) as usize] == 0 {
                        let id = s.chains.len() as u32;
                        let mut e = p;
                        loop {
                            s.chain_of[e as usize] = id;
                            let nx = s.next(e);
                            if s.contact[nx as usize] == 0 {
                                break;
                            }
                            e = nx;
                        }
                        s.chains.push(Chain { start: p, end: e, cell: cell as u32, closed: false, succ: NONE, state: 0, patched: false });
                    }
                }
            }
            s.cell_chains[cell] = (first, s.chains.len() as u32 - first);
        }
        // Each run's successor along the outline: the run that starts where it ends. Tried
        // in order: (0) a run of the cell it meets there (X) coming out of a contact with
        // this cell (A); (1) a run of any cell nearby coming out of a contact with X (X has
        // no run there: the outline passes along it, wholly enclosed by contact); (2) one
        // coming out of A; (3) any run of X; (4) any run nearby but its own. None: the run
        // is left broken (exposed).
        let rcell = self.cells.iter().map(|c| c.t.radius).fold(0.0f32, f32::max);
        let reach = 3.0 * rcell + cs;
        let span = (reach / cs).ceil() as i32;
        // The successors are given out one to one, best offers (tier, then distance) first:
        // a run another one already continues into is not offered again, so the successors
        // form loops and no run is left on a tail behind two runs that chose the same
        // successor (milestone 3: ragged creatures). Tier 0 offers come first whatever
        // else is offered, so they are given out before the wider search, which is made
        // only for the runs they leave without a successor.
        s.offers.clear();
        s.taken.clear();
        s.taken.resize(s.chains.len(), false);
        for ch in 0..s.chains.len() {
            if s.chains[ch].closed {
                continue;
            }
            let e = s.chains[ch].end;
            let a_cell = s.chains[ch].cell;
            let x_cell = s.against[s.next(e) as usize];
            let pe = s.pos[e as usize];
            if x_cell != NONE {
                let (first, count) = s.cell_chains[x_cell as usize];
                for c2 in first..first + count {
                    let c = s.chains[c2 as usize];
                    if c.closed || c2 as usize == ch {
                        continue;
                    }
                    let d = dist_sq(pe, s.pos[c.start as usize]);
                    if d <= reach * reach {
                        let from_a = s.against[s.prev(c.start) as usize] == a_cell;
                        s.offers.push((if from_a { 0 } else { 3 }, d, ch as u32, c2));
                    }
                }
            }
        }
        let order = |a: &(u8, f32, u32, u32), b: &(u8, f32, u32, u32)| {
            a.0.cmp(&b.0).then(a.1.partial_cmp(&b.1).unwrap_or(std::cmp::Ordering::Equal)).then(a.2.cmp(&b.2)).then(a.3.cmp(&b.3))
        };
        s.offers.sort_by(order);
        for o in 0..s.offers.len() {
            let (tier, _, ch, c2) = s.offers[o];
            if tier != 0 {
                break;
            }
            if s.chains[ch as usize].succ != NONE || s.taken[c2 as usize] {
                continue;
            }
            s.chains[ch as usize].succ = c2;
            s.taken[c2 as usize] = true;
        }
        s.offers.retain(|o| o.0 != 0);
        for ch in 0..s.chains.len() {
            if s.chains[ch].closed || s.chains[ch].succ != NONE {
                continue;
            }
            let e = s.chains[ch].end;
            let a_cell = s.chains[ch].cell;
            let x_cell = s.against[s.next(e) as usize];
            let pe = s.pos[e as usize];
            let (cx, cy) = s.grid.cell_of(pe);
            for dy in -span..=span {
                for dx in -span..=span {
                    let (tx, ty) = (cx + dx, cy + dy);
                    let bkt = s.grid.bucket(tx, ty);
                    for kk in s.grid.start[bkt] as usize..s.grid.start[bkt + 1] as usize {
                        let q = s.grid.items[kk];
                        if s.grid.cells[q as usize] != (tx, ty) {
                            continue;
                        }
                        let c2 = s.chain_of[q as usize];
                        if c2 == NONE || c2 as usize == ch || s.chains[c2 as usize].start != q || s.chains[c2 as usize].closed || s.taken[c2 as usize] {
                            continue;
                        }
                        // X's own runs were offered above.
                        if x_cell != NONE && s.cell[q as usize] == x_cell {
                            continue;
                        }
                        let d = dist_sq(pe, s.pos[q as usize]);
                        if d > reach * reach {
                            continue;
                        }
                        let from = s.against[s.prev(q) as usize];
                        let tier = if x_cell != NONE && from == x_cell {
                            1
                        } else if from == a_cell {
                            2
                        } else {
                            4
                        };
                        s.offers.push((tier, d, ch as u32, c2));
                    }
                }
            }
        }
        s.offers.sort_by(order);
        for o in 0..s.offers.len() {
            let (_, _, ch, c2) = s.offers[o];
            if s.chains[ch as usize].succ != NONE || s.taken[c2 as usize] {
                continue;
            }
            s.chains[ch as usize].succ = c2;
            s.taken[c2 as usize] = true;
        }
        // What is left is open paths, each from a run nothing continues into to a run with
        // no successor within reach (as many of one as of the other). Each path's end is
        // joined to the nearest path start still free (its own included), in path order:
        // the pieces of an outline that one missing link broke join up again, and one
        // missing link does not leave a whole outline without a loop. Their beads are
        // counted (`exp_patched`): the outline at those joins is a guess.
        let mut patched = 0usize;
        let mut paths: Vec<(u32, u32)> = Vec::new();
        for ch in 0..s.chains.len() {
            if s.chains[ch].closed || s.taken[ch] {
                continue;
            }
            let mut cur = ch;
            let mut steps = 0usize;
            while s.chains[cur].succ != NONE && steps <= s.chains.len() {
                cur = s.chains[cur].succ as usize;
                steps += 1;
            }
            if s.chains[cur].succ == NONE {
                paths.push((ch as u32, cur as u32));
                let mut c = ch;
                loop {
                    let chain = s.chains[c];
                    let n = s.range[chain.cell as usize].1.max(1);
                    patched += ((chain.end + n - chain.start) % n) as usize + 1;
                    if c == cur {
                        break;
                    }
                    c = chain.succ as usize;
                }
            }
        }
        for pi in 0..paths.len() {
            let end = paths[pi].1 as usize;
            let pe = s.pos[s.chains[end].end as usize];
            let mut best: (f32, usize) = (f32::INFINITY, usize::MAX);
            for (qi, &(first, _)) in paths.iter().enumerate() {
                if s.taken[first as usize] {
                    continue;
                }
                let d = dist_sq(pe, s.pos[s.chains[first as usize].start as usize]);
                if d < best.0 {
                    best = (d, qi);
                }
            }
            if best.1 != usize::MAX {
                let first = paths[best.1].0 as usize;
                s.chains[end].succ = first as u32;
                s.chains[end].patched = true;
                s.taken[first] = true;
            }
        }
        self.exp_patched = patched;
        // The loops: follow the successors; a walk that closes on itself is a loop, the
        // runs before the closing one (and any walk ending nowhere) stay broken.
        s.mark.clear();
        s.mark.resize(np, 0);
        let mut loops: Vec<(Vec<u32>, f64, bool)> = Vec::new();
        for ch in 0..s.chains.len() {
            if s.chains[ch].state != 0 {
                continue;
            }
            s.path.clear();
            let mut cur = ch as u32;
            loop {
                if cur == NONE {
                    break;
                }
                match s.chains[cur as usize].state {
                    0 => {
                        s.chains[cur as usize].state = 1;
                        s.path.push(cur);
                        cur = s.chains[cur as usize].succ;
                    }
                    1 => {
                        let from = s.path.iter().position(|&c| c == cur).unwrap_or(0);
                        let mut pts: Vec<u32> = Vec::new();
                        let mut guessed = false;
                        for &c in &s.path[from..] {
                            let chain = s.chains[c as usize];
                            guessed |= chain.patched;
                            let mut p = chain.start;
                            loop {
                                pts.push(p);
                                if p == chain.end {
                                    break;
                                }
                                p = s.next(p);
                            }
                        }
                        s.poly.clear();
                        s.poly.extend(pts.iter().map(|&p| s.pos[p as usize]));
                        let area = signed_area(&s.poly);
                        loops.push((pts, area, guessed));
                        break;
                    }
                    _ => break,
                }
            }
            for &c in &s.path {
                s.chains[c as usize].state = 2;
            }
        }
        let largest = (0..loops.len()).max_by(|&a, &b| loops[a].1.abs().partial_cmp(&loops[b].1.abs()).unwrap_or(std::cmp::Ordering::Equal).then(b.cmp(&a)));
        self.loops.clear();
        for (li, (pts, area, guessed)) in loops.iter().enumerate() {
            // A loop of fewer than 3 points or about no area (a run that closed on itself, two
            // runs each other's successor) is no outline: its beads stay exposed, on no loop.
            if pts.len() < 3 || area.abs() < (rmax * rmax) as f64 {
                continue;
            }
            // A loop closed by a guess is never a pocket: its beads stay exposed (the safe
            // side: drag, never a missed contact).
            let kind = if *area < 0.0 || Some(li) == largest || *guessed { LoopKind::Outside } else { LoopKind::Pocket };
            let m = if kind == LoopKind::Outside { 1 } else { 2 };
            for &p in pts {
                s.mark[p as usize] = m;
            }
            let lp = pts
                .iter()
                .map(|&p| {
                    let k = s.core[p as usize];
                    if k == NONE {
                        LoopPt { core: false, index: p, local: 0 }
                    } else {
                        LoopPt { core: true, index: k, local: p - s.range[self.ccell[k as usize] as usize].0 }
                    }
                })
                .collect();
            self.loops.push(OutlineLoop { kind, area: *area as f32, pts: lp });
        }
        // The result: exposed = not enclosed by contact and not on a pocket; the surface
        // the tension acts on (1 facing the outside, 2 facing a pocket, 0 in contact).
        self.exp_broken = 0;
        self.surface.clear();
        self.surface.resize(nb, 0);
        for i in 0..nb {
            if s.contact[i] == 1 {
                self.surface[i] = if s.mark[i] == 2 { 2 } else { 1 };
            }
        }
        self.exp_version += 1;
        for i in 0..nb {
            self.exposed[i] = (s.contact[i] == 1 && s.mark[i] != 2) as u8;
            // Exposed for want of a loop (a broken run): counted, as a health figure.
            if s.contact[i] == 1 && s.mark[i] == 0 {
                self.exp_broken += 1;
            }
        }
        for ring in self.rings.iter_mut() {
            ring.open = self.exposed[ring.start..ring.start + ring.n].iter().map(|&e| e as u32).sum();
        }
        for cell in 0..ncells {
            let (base, n) = s.range[cell];
            let mut open = 0u32;
            let mut out = Vector2::ZERO;
            let mut centre = Vector2::ZERO;
            for p in base..base + n {
                centre += s.pos[p as usize];
            }
            if n > 0 {
                centre = centre / n as f32;
            }
            for p in base..base + n {
                if s.contact[p as usize] == 1 && s.mark[p as usize] != 2 {
                    open += 1;
                    out += s.pos[p as usize] - centre;
                }
            }
            if let Kind::Core(k) = self.cells[cell].kind {
                self.cexposed[k] = (open > 0) as u8;
            }
            let c = &mut self.cells[cell];
            c.exposure = if n > 0 { open as f32 / n as f32 } else { 0.0 };
            c.outward = if open > 0 { norm(out) } else { Vector2::ZERO };
        }
        self.exp_valid = true;
        self.loops_topology = self.topology;
        self.xs = s;
    }

    /// Marks core `k`'s virtual beads facing a bead or core at `from` of radius `from_r`
    /// enclosed against `cell` when within their gap: the three nearest in angle are tested.
    fn mark_facing(&self, s: &mut Scratch, k: usize, from: Vector2, from_r: f32, cell: u32) {
        let (base, n) = s.range[self.ccell[k] as usize];
        if n == 0 {
            return;
        }
        let d = from - self.cpos[k];
        let theta = d.y.atan2(d.x);
        // Virtual bead j sits at the angle −τ j / n + rot.
        let step = std::f32::consts::TAU / n as f32;
        let j0 = ((self.crot[k] - theta) / step).round() as i64;
        for dj in -1..=1i64 {
            let j = (j0 + dj).rem_euclid(n as i64) as u32;
            let p = (base + j) as usize;
            if s.best[p] == f32::NEG_INFINITY {
                continue;
            }
            let g = dist(s.pos[p], from) - s.r[p] - from_r;
            if g < s.limit[p] {
                s.contact[p] = 0;
                s.against[p] = cell;
                s.best[p] = f32::NEG_INFINITY;
            }
        }
    }

    /// After the step (Colony::step(), with exposure on): the pass when it may have
    /// changed, then (auto_cores) the switches it calls for.
    pub(super) fn post_step(&mut self, opt: &Options, frame: u64) {
        if !self.active {
            return;
        }
        let ex = &opt.ex;
        let every = ex.every.max(1) as u64;
        if self.exp_hot {
            self.exp_hot_until = frame + ex.hot as u64;
            self.exp_hot = false;
        }
        if frame >= self.exp_next || frame < self.exp_hot_until || self.loops_topology != self.topology {
            self.exp_dirty = true;
        }
        if !self.exp_dirty {
            return;
        }
        let t = super::CpuClock::now();
        let gap = if ex.gap >= 0.0 { ex.gap } else { opt.ad.capture };
        self.compute_exposure(gap, gap * ex.core_gap);
        self.exp_runs += 1;
        // The next safety-net pass, staggered by creature; sooner when a cell will have been
        // a candidate to switch long enough by then.
        self.exp_next = frame + every - ((frame + self.index as u64) % every);
        if ex.auto_cores {
            self.auto_switch(opt, frame, gap);
        }
        self.exp_dirty = false;
        self.ns_exposure += ns(t);
    }

    /// Rings wholly enclosed for to_core_time become cores; cores exposed for
    /// to_ring_time become rings; each switched cell is stuck straight back to the
    /// neighbours it was joined to, and the pass runs again.
    fn auto_switch(&mut self, opt: &Options, frame: u64, gap: f32) {
        let ex = &opt.ex;
        let dt = self.dt.max(1e-6);
        let mut to_core: Vec<usize> = Vec::new();
        let mut to_ring: Vec<usize> = Vec::new();
        let many = self.cells.len() > 1;
        for cell in 0..self.cells.len() {
            let (candidate, need) = match self.cells[cell].kind {
                Kind::Ring(r) => {
                    let ring = &self.rings[r];
                    (many && self.exposed[ring.start..ring.start + ring.n].iter().all(|&e| e == 0), ex.to_core_time)
                }
                Kind::Core(k) => (self.cexposed[k] == 1, ex.to_ring_time),
            };
            if !candidate || frame < self.switch_until[cell] {
                self.cand_since[cell] = 0;
                continue;
            }
            if self.cand_since[cell] == 0 {
                self.cand_since[cell] = frame;
            }
            // The frames it has been a candidate, this one included.
            let held = (frame - self.cand_since[cell] + 1) as f32 * dt;
            if held + 1e-6 >= need {
                match self.cells[cell].kind {
                    Kind::Ring(_) => to_core.push(cell),
                    Kind::Core(_) => to_ring.push(cell),
                }
            } else {
                // Look again once it will have been a candidate long enough (not every frame).
                let due = self.cand_since[cell] + (need / dt - 1e-3).ceil().max(1.0) as u64;
                self.exp_next = self.exp_next.min(due.max(frame + 1));
            }
        }
        if to_core.is_empty() && to_ring.is_empty() {
            return;
        }
        let rest = (ex.switch_rest / dt).ceil() as u64;
        self.exp_hot_until = frame + ex.hot as u64;
        for &cell in &to_core {
            self.demote(cell, opt.ad.capture, opt.bond_scale);
            self.to_core += 1;
        }
        for &cell in &to_ring {
            self.promote(cell, opt.ad.capture, opt.bond_scale);
            self.to_ring += 1;
        }
        for &cell in to_core.iter().chain(to_ring.iter()) {
            self.cand_since[cell] = 0;
            self.switch_until[cell] = frame + rest;
            if opt.ad.enabled {
                self.restick(cell, &opt.ad);
            }
        }
        if opt.ad.enabled {
            self.recount_bonded();
        }
        // This frame's contact candidates name particles that moved or went: the next
        // frame finds its own; nothing reads them before (health() would).
        for list in [&mut self.bb, &mut self.xbb, &mut self.xbc, &mut self.xcc, &mut self.bc, &mut self.cc] {
            list.clear();
        }
        self.compute_exposure(gap, gap * ex.core_gap);
        self.exp_runs += 1;
    }

    /// Sticks cell `cell` again to every neighbour it was joined to at the last settle
    /// (after it switched between ring and core, which dropped its sticks), within the
    /// join reach, in the mode its pair allows.
    fn restick(&mut self, cell: usize, ad: &Adhesion) {
        let c32 = cell as u32;
        let keys: Vec<((u32, u32), PairState)> = self
            .pairs
            .iter()
            .filter(|(k, p)| (k.0 == c32 || k.1 == c32) && p.joined && matches!(p.state, PairState::Allowed | PairState::Forced))
            .map(|(k, p)| (*k, p.state))
            .collect();
        let reach = ad.capture;
        for (key, state) in keys {
            let other = if key.0 == c32 { key.1 } else { key.0 } as usize;
            let ta = self.cells[cell].ctype as usize;
            let tb = self.cells[other].ctype as usize;
            let mut mode = ad.table[ta.min(MAX_TYPES - 1)][tb.min(MAX_TYPES - 1)];
            if state == PairState::Forced {
                mode = mode.max(JOIN_ANCHORED);
            }
            if mode == JOIN_NONE {
                continue;
            }
            let before = self.sticks.len();
            self.stick_cells(cell, other, mode, reach, ad);
            // Each holds the gap it found, easing to zero: the switch moves nothing at once.
            for k in before..self.sticks.len() {
                self.sticks[k].gap0 = self.raw_gap(k).max(0.0);
            }
        }
    }
}
