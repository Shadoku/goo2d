//! PoseSolver: an as-rigid-as-possible (ARAP) pose of a link graph driven by handle cells,
//! in 2D (the fluid game's docs/pose-solve-plan.md, milestone 1). A plain module: no
//! creature, no Godot object; cells_pose.rs wires it into cells.rs's pose wave behind
//! Opt::pose_solve (milestones 2 and 3).
//!
//! The problem. `n` cells with design positions d_i, links (i, j) with weights w_ij, and a
//! set of handle cells whose posed positions are given (fixed handles: each sits exactly on
//! its target). Find the free cells' posed positions p and one rotation R_i per cell that
//! minimise
//!
//!     E = Σ_cells i Σ_links ij w_ij |(p_i − p_j) − R_i (d_i − d_j)|²
//!
//! so every cell's neighbourhood is as close to a turned copy of its design as it can be.
//!
//! The method (Sorkine and Alexa's local/global alternation). Each iteration:
//! 1. Local: for every cell (handles included) the best-fit rotation taking its design
//!    edges d_j − d_i to its posed edges p_j − p_i over all its linked neighbours, in closed
//!    form: the angle atan2(Σ w cross(e₀, e), Σ w dot(e₀, e)), the pattern of cells.rs's
//!    shape matching (BEND_SHAPE) against the design rather than live positions.
//! 2. Global: with the rotations fixed E is quadratic in the free cells; its minimum is the
//!    linear system L_ff p_f = b, where L_ff is the graph Laplacian restricted to the free
//!    cells (the handles eliminated: their terms moved to the right-hand side) and
//!    b_i = Σ_j w_ij / 2 (R_i + R_j)(d_i − d_j) + Σ_{j handle} w_ij target_j. One matrix for x
//!    and y.
//!
//! L_ff depends only on the topology and the handle set, so `build()` assembles and factors
//! it once: the free cells ordered to keep the band small (the better of a sort along the
//! caller's axis and reverse Cuthill-McKee, which also keeps components cut apart by handles
//! in separate blocks: the 24 × 5 worm with its middle row as handles has a half bandwidth
//! of 2), then a banded Cholesky factorisation LLᵀ in f64. Each iteration costs two passes
//! over the links (each link visited once, its sums added to both ends) and one forward and
//! one back substitution for x and y together. L_ff is positive definite exactly when every
//! free cell is joined to a handle through the graph: build() checks that first and names an
//! unanchored cell instead of failing.
//!
//! The rotation seed. Plain local/global iterations pass a turn on from cell to cell by
//! diffusion: a dead-end branch 17 cells long took about 5000 iterations to follow a 0.3 rad
//! turn of its body to 0.001 px, and a 3-iteration frame left a swimming fin 90 px off.
//! So solve() first spreads the handles' turns over the free cells as a harmonic function
//! (the same factor: L_ff θ_f = Σ_{j handle} w_ij θ_j, one more substitution), takes the
//! seeded rotations through one global step, then iterates (`PoseSeed`; seed_rotations()).
//! A dead-end branch takes its root's turn whole and stays rigid; a rigid motion of the
//! handles is exact at once, whatever the angle. What the iterations still converge slowly
//! is a branch's own small turn against its root (the converged pose turns a swimming fin a
//! degree or so past the seed's, about one e-fold per several hundred iterations): with 3
//! iterations a frame the fin's links keep their lengths as well as the converged pose's,
//! and its tip is a few px from where the converged pose would put it.
//!
//! Conventions. Positions in px, in whatever frame the caller uses (the kernel's design
//! space, `rest_local`); angles in radians, positive from +x toward +y (the kernel's
//! `rot()`; clockwise on a y-down screen). A cell's turn is its local rotation relative to
//! its design (as `bent_turn`); `turns` are kept continuous (no jumps of a whole turn).
//! Arithmetic is f64 inside, f32 (Vector2) at the interface.
//!
//! What the caller owes it:
//! - The handles' targets in the order the handles were given to build().
//! - A warm start in `pose` and the `turns` that go with it: last frame's pose and turns, or
//!   the design and zeros, or `reset_to_rigid_fit()`'s. The default seed (Increment) adds
//!   the handles' turn since the warm start to `turns`, so the two must belong together;
//!   PoseSeed::Absolute needs `turns` only to unwrap against. The handles' warm-start
//!   positions are their last targets (the seed measures their turn from there). A frame's
//!   change of the handles under half a turn.
//! - A rebuild when the topology or the handle set changes: `is_built_from()` compares what
//!   it was built from (cell, link and handle counts and a version number the caller moves).
//!   A new solver keeps nothing from the old; the caller's pose and turns are the state.
//!
//! Determinism: one thread, a fixed order and a fixed iteration count, no allocation in
//! solve(): the same inputs give the same bits.

// Some of its API (reset_to_rigid_fit(), the seed modes, the queries) is used only by its
// tests so far.
#![allow(dead_code)]

use godot::builtin::Vector2;

/// Why build() or solve() refused.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PoseError {
    /// No cells.
    Empty,
    /// No handle cells.
    NoHandles,
    /// The handles' design positions are all the same point: the rotation is not fixed.
    TooFewHandles,
    /// A link names a cell out of range or the same cell twice.
    BadLink { link: u32 },
    /// A link's weight is not finite and positive.
    BadWeight { link: u32 },
    /// A handle index out of range, or given twice.
    BadHandle { handle: u32 },
    /// `weights` and `links` differ in length, or solve()'s slices do not fit the solver.
    SizeMismatch,
    /// A free cell with no path through the links to any handle (the first one found).
    Unanchored { cell: u32 },
    /// The factorisation met a pivot that was not positive (should not happen once every
    /// free cell is anchored; kept as a guard against degenerate weights).
    NotPositiveDefinite,
}

/// What a solver was built from, for the caller to know when to rebuild.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub struct PoseKey {
    pub cells: usize,
    pub links: usize,
    pub handles: usize,
    pub version: u64,
}

/// How solve() seeds the rotations before its iterations (seed_rotations()).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PoseSeed {
    /// No seed: the iterations start from the warm start alone.
    Off,
    /// Each handle's turn since the warm start, spread harmonically and added to `turns`
    /// (the default: the closest to the converged pose frame after frame, it keeps the
    /// iterations' progress; it needs `turns` to go with the warm start).
    Increment,
    /// Each handle's turn from the design, spread harmonically: the seed forgets the warm
    /// start's turns, so it is right whatever they hold, but the iterations start afresh
    /// every frame.
    Absolute,
}

/// Which ordering of the free cells build() kept.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PoseOrdering {
    /// By the coordinate along the caller's axis, ties by the one across it.
    Axis,
    /// Reverse Cuthill-McKee over the free cells' graph.
    Rcm,
}

#[inline]
fn wrap(a: f64) -> f64 {
    let mut a = a;
    while a > std::f64::consts::PI {
        a -= std::f64::consts::TAU;
    }
    while a < -std::f64::consts::PI {
        a += std::f64::consts::TAU;
    }
    a
}

/// Solves L Lᵀ x = b in place for two right-hand sides at once (the banded factor's layout
/// as in PoseSolver::l).
fn substitute(l: &[f64], inv_diag: &[f64], band: usize, bx: &mut [f64], by: &mut [f64]) {
    let m = inv_diag.len();
    if m == 0 {
        return;
    }
    let w1 = band + 1;
    for i in 0..m {
        let (mut sx, mut sy) = (bx[i], by[i]);
        let row = i * w1 + band - i;
        for k in i.saturating_sub(band)..i {
            let lik = l[row + k];
            sx -= lik * bx[k];
            sy -= lik * by[k];
        }
        bx[i] = sx * inv_diag[i];
        by[i] = sy * inv_diag[i];
    }
    for i in (0..m).rev() {
        let (mut sx, mut sy) = (bx[i], by[i]);
        let hi = (i + band).min(m - 1);
        for k in (i + 1)..=hi {
            let lki = l[k * w1 + (i + band - k)];
            sx -= lki * bx[k];
            sy -= lki * by[k];
        }
        bx[i] = sx * inv_diag[i];
        by[i] = sy * inv_diag[i];
    }
}

/// One direction of a link, as the per-frame loops read it: the neighbour, whether it is a
/// handle, the weight, and the design edge d_j − d_i.
#[derive(Clone, Copy, Debug, Default)]
struct Edge {
    j: u32,
    handle: bool,
    w: f64,
    hw: f64,
    ex: f64,
    ey: f64,
}

/// A link as the per-frame loops read it (each visited once, its sums added to both ends):
/// its cells, the weight, half the weight, and the design edge d_j − d_i.
#[derive(Clone, Copy, Debug, Default)]
struct Link {
    i: u32,
    j: u32,
    w: f64,
    hw: f64,
    ex: f64,
    ey: f64,
}

#[derive(Clone, Debug)]
pub struct PoseSolver {
    key: PoseKey,
    n: usize,
    /// Design positions (f64).
    dx: Vec<f64>,
    dy: Vec<f64>,
    /// Adjacency (CSR, both directions of every link, in link order): the neighbour, the
    /// weight, the design edge d_j − d_i, and the design length.
    adj_start: Vec<u32>,
    adj_j: Vec<u32>,
    adj_w: Vec<f64>,
    adj_ex: Vec<f64>,
    adj_ey: Vec<f64>,
    adj_len: Vec<f64>,
    /// The same adjacency packed for the per-frame loops (adj_start indexes it too).
    edges: Vec<Edge>,
    links: Vec<Link>,
    /// Per cell, Σ_j w_ij / 2 (d_j − d_i): the cell's own rotation's share of its
    /// right-hand side, R_i times this.
    half_x: Vec<f64>,
    half_y: Vec<f64>,
    /// The handles in the caller's order, a mask by cell, and each cell's index among the
    /// handles (u32::MAX for a free cell).
    handles: Vec<u32>,
    is_handle: Vec<bool>,
    hidx: Vec<u32>,
    /// How solve() seeds the rotations first (seed_rotations()).
    seed: PoseSeed,
    /// Free cells in factor order, and each cell's slot in it (u32::MAX for a handle).
    free: Vec<u32>,
    slot: Vec<u32>,
    ordering: PoseOrdering,
    /// The factor L (lower, banded): row i holds columns i − band ..= i at
    /// l[i * (band + 1) + (j + band − i)]; inv_diag[i] = 1 / L_ii.
    band: usize,
    l: Vec<f64>,
    inv_diag: Vec<f64>,
    // Scratch, sized at build (solve() allocates nothing).
    px: Vec<f64>,
    py: Vec<f64>,
    rc: Vec<f64>,
    rs: Vec<f64>,
    dt: Vec<f64>,
    hbx: Vec<f64>,
    hby: Vec<f64>,
    sc: Vec<f64>,
    ss: Vec<f64>,
    cx: Vec<f64>,
    cy: Vec<f64>,
    bx: Vec<f64>,
    by: Vec<f64>,
}

impl PoseSolver {
    /// Builds and factors the solver. `design`: each cell's design position; `links`: index
    /// pairs (a pair given twice counts twice); `weights`: one per link, finite and > 0 (all
    /// ones for uniform); `handles`: the handle cells, in the order solve() will take their
    /// targets; `axis`: the body's forward in design space (orders the cells; any non-zero
    /// vector works, only the band's width depends on it); `version`: the caller's own
    /// number, stored in the key.
    pub fn build(
        design: &[Vector2],
        links: &[(u32, u32)],
        weights: &[f32],
        handles: &[u32],
        axis: Vector2,
        version: u64,
    ) -> Result<PoseSolver, PoseError> {
        let n = design.len();
        if n == 0 {
            return Err(PoseError::Empty);
        }
        if weights.len() != links.len() {
            return Err(PoseError::SizeMismatch);
        }
        if handles.is_empty() {
            return Err(PoseError::NoHandles);
        }
        for (k, &(a, b)) in links.iter().enumerate() {
            if a as usize >= n || b as usize >= n || a == b {
                return Err(PoseError::BadLink { link: k as u32 });
            }
            let w = weights[k];
            if !(w.is_finite() && w > 0.0) {
                return Err(PoseError::BadWeight { link: k as u32 });
            }
        }
        let mut is_handle = vec![false; n];
        for &h in handles {
            if h as usize >= n || is_handle[h as usize] {
                return Err(PoseError::BadHandle { handle: h });
            }
            is_handle[h as usize] = true;
        }
        let h0 = design[handles[0] as usize];
        if !handles.iter().any(|&h| (design[h as usize] - h0).length() > 1e-4) {
            return Err(PoseError::TooFewHandles);
        }
        let dx: Vec<f64> = design.iter().map(|p| p.x as f64).collect();
        let dy: Vec<f64> = design.iter().map(|p| p.y as f64).collect();

        // Adjacency, both directions, in link order.
        let mut deg = vec![0u32; n];
        for &(a, b) in links {
            deg[a as usize] += 1;
            deg[b as usize] += 1;
        }
        let mut adj_start = vec![0u32; n + 1];
        for i in 0..n {
            adj_start[i + 1] = adj_start[i] + deg[i];
        }
        let m2 = adj_start[n] as usize;
        let mut fill: Vec<u32> = adj_start[..n].to_vec();
        let mut adj_j = vec![0u32; m2];
        let mut adj_w = vec![0f64; m2];
        for (k, &(a, b)) in links.iter().enumerate() {
            let w = weights[k] as f64;
            for (i, j) in [(a, b), (b, a)] {
                let p = fill[i as usize] as usize;
                adj_j[p] = j;
                adj_w[p] = w;
                fill[i as usize] += 1;
            }
        }
        let mut adj_ex = vec![0f64; m2];
        let mut adj_ey = vec![0f64; m2];
        let mut adj_len = vec![0f64; m2];
        for i in 0..n {
            for p in adj_start[i] as usize..adj_start[i + 1] as usize {
                let j = adj_j[p] as usize;
                adj_ex[p] = dx[j] - dx[i];
                adj_ey[p] = dy[j] - dy[i];
                adj_len[p] = (adj_ex[p] * adj_ex[p] + adj_ey[p] * adj_ey[p]).sqrt();
            }
        }

        // Every free cell must reach a handle (else L_ff is singular).
        {
            let mut seen = is_handle.clone();
            let mut queue: Vec<u32> = handles.to_vec();
            let mut head = 0;
            while head < queue.len() {
                let i = queue[head] as usize;
                head += 1;
                for p in adj_start[i] as usize..adj_start[i + 1] as usize {
                    let j = adj_j[p] as usize;
                    if !seen[j] {
                        seen[j] = true;
                        queue.push(j as u32);
                    }
                }
            }
            if let Some(c) = (0..n).find(|&i| !seen[i]) {
                return Err(PoseError::Unanchored { cell: c as u32 });
            }
        }

        // Orderings of the free cells: along the axis, and reverse Cuthill-McKee.
        let ax = Vector2::new(axis.x, axis.y);
        let (ux, uy) = if ax.length() > 1e-9 {
            let a = ax.normalized();
            (a.x as f64, a.y as f64)
        } else {
            (1.0, 0.0)
        };
        let mut by_axis: Vec<u32> = (0..n as u32).filter(|&i| !is_handle[i as usize]).collect();
        let along = |i: u32| dx[i as usize] * ux + dy[i as usize] * uy;
        let across = |i: u32| -dx[i as usize] * uy + dy[i as usize] * ux;
        by_axis.sort_by(|&a, &b| along(a).total_cmp(&along(b)).then(across(a).total_cmp(&across(b))).then(a.cmp(&b)));
        let mut rank = vec![0u32; n];
        for (r, &i) in by_axis.iter().enumerate() {
            rank[i as usize] = r as u32;
        }
        let free_deg = |i: usize| -> u32 {
            (adj_start[i] as usize..adj_start[i + 1] as usize).filter(|&p| !is_handle[adj_j[p] as usize]).count() as u32
        };
        let rcm = {
            let mut order: Vec<u32> = Vec::with_capacity(by_axis.len());
            let mut seen = is_handle.clone();
            let mut comp: Vec<u32> = Vec::new();
            let mut nbrs: Vec<u32> = Vec::new();
            for &s in &by_axis {
                if seen[s as usize] {
                    continue;
                }
                // The component, to pick its start: the least free degree, then the
                // earliest along the axis.
                comp.clear();
                comp.push(s);
                let mut cs = vec![false; n];
                cs[s as usize] = true;
                let mut head = 0;
                while head < comp.len() {
                    let i = comp[head] as usize;
                    head += 1;
                    for p in adj_start[i] as usize..adj_start[i + 1] as usize {
                        let j = adj_j[p] as usize;
                        if !is_handle[j] && !cs[j] {
                            cs[j] = true;
                            comp.push(j as u32);
                        }
                    }
                }
                let start = *comp.iter().min_by_key(|&&i| (free_deg(i as usize), rank[i as usize])).unwrap();
                seen[start as usize] = true;
                let first = order.len();
                order.push(start);
                let mut head = first;
                while head < order.len() {
                    let i = order[head] as usize;
                    head += 1;
                    nbrs.clear();
                    for p in adj_start[i] as usize..adj_start[i + 1] as usize {
                        let j = adj_j[p];
                        if !seen[j as usize] {
                            seen[j as usize] = true;
                            nbrs.push(j);
                        }
                    }
                    nbrs.sort_by_key(|&j| (free_deg(j as usize), rank[j as usize]));
                    order.extend_from_slice(&nbrs);
                }
            }
            order.reverse();
            order
        };
        let bandwidth_of = |order: &[u32]| -> usize {
            let mut slot = vec![u32::MAX; n];
            for (s, &i) in order.iter().enumerate() {
                slot[i as usize] = s as u32;
            }
            let mut b = 0usize;
            for &(a, c) in links {
                let (sa, sc) = (slot[a as usize], slot[c as usize]);
                if sa != u32::MAX && sc != u32::MAX {
                    b = b.max((sa as i64 - sc as i64).unsigned_abs() as usize);
                }
            }
            b
        };
        let (b_axis, b_rcm) = (bandwidth_of(&by_axis), bandwidth_of(&rcm));
        let (free, ordering, band) = if b_rcm < b_axis { (rcm, PoseOrdering::Rcm, b_rcm) } else { (by_axis, PoseOrdering::Axis, b_axis) };
        let mut slot = vec![u32::MAX; n];
        for (s, &i) in free.iter().enumerate() {
            slot[i as usize] = s as u32;
        }

        // Assemble L_ff in the band and factor it in place.
        let m = free.len();
        let w1 = band + 1;
        let mut l = vec![0f64; m * w1];
        for s in 0..m {
            let i = free[s] as usize;
            for p in adj_start[i] as usize..adj_start[i + 1] as usize {
                let j = adj_j[p] as usize;
                l[s * w1 + band] += adj_w[p];
                let t = slot[j];
                if t != u32::MAX && (t as usize) < s {
                    l[s * w1 + (t as usize + band - s)] -= adj_w[p];
                }
            }
        }
        let mut inv_diag = vec![0f64; m];
        for i in 0..m {
            let lo = i.saturating_sub(band);
            for j in lo..=i {
                let mut sum = l[i * w1 + (j + band - i)];
                let klo = lo.max(j.saturating_sub(band));
                for k in klo..j {
                    sum -= l[i * w1 + (k + band - i)] * l[j * w1 + (k + band - j)];
                }
                if j == i {
                    if !(sum > 1e-12) {
                        return Err(PoseError::NotPositiveDefinite);
                    }
                    let d = sum.sqrt();
                    l[i * w1 + band] = d;
                    inv_diag[i] = 1.0 / d;
                } else {
                    l[i * w1 + (j + band - i)] = sum * inv_diag[j];
                }
            }
        }

        let edges: Vec<Edge> = (0..m2)
            .map(|p| Edge { j: adj_j[p], handle: is_handle[adj_j[p] as usize], w: adj_w[p], hw: 0.5 * adj_w[p], ex: adj_ex[p], ey: adj_ey[p] })
            .collect();
        let packed: Vec<Link> = links
            .iter()
            .enumerate()
            .map(|(k, &(a, b))| {
                let w = weights[k] as f64;
                Link { i: a, j: b, w, hw: 0.5 * w, ex: dx[b as usize] - dx[a as usize], ey: dy[b as usize] - dy[a as usize] }
            })
            .collect();
        let mut half_x = vec![0f64; n];
        let mut half_y = vec![0f64; n];
        for i in 0..n {
            for e in &edges[adj_start[i] as usize..adj_start[i + 1] as usize] {
                half_x[i] += e.hw * e.ex;
                half_y[i] += e.hw * e.ey;
            }
        }

        Ok(PoseSolver {
            key: PoseKey { cells: n, links: links.len(), handles: handles.len(), version },
            n,
            dx,
            dy,
            adj_start,
            adj_j,
            adj_w,
            adj_ex,
            adj_ey,
            adj_len,
            edges,
            links: packed,
            half_x,
            half_y,
            handles: handles.to_vec(),
            is_handle,
            hidx: {
                let mut v = vec![u32::MAX; n];
                for (k, &h) in handles.iter().enumerate() {
                    v[h as usize] = k as u32;
                }
                v
            },
            seed: PoseSeed::Increment,
            free,
            slot,
            ordering,
            band,
            l,
            inv_diag,
            px: vec![0.0; n],
            py: vec![0.0; n],
            rc: vec![1.0; n],
            rs: vec![0.0; n],
            dt: vec![0.0; n],
            hbx: vec![0.0; m],
            hby: vec![0.0; m],
            sc: vec![0.0; n],
            ss: vec![0.0; n],
            cx: vec![0.0; n],
            cy: vec![0.0; n],
            bx: vec![0.0; m],
            by: vec![0.0; m],
        })
    }

    /// What it was built from.
    pub fn key(&self) -> PoseKey {
        self.key
    }

    /// Whether a solver built from these would be this one (the caller rebuilds otherwise).
    pub fn is_built_from(&self, cells: usize, links: usize, handles: usize, version: u64) -> bool {
        self.key == PoseKey { cells, links, handles, version }
    }

    pub fn cell_count(&self) -> usize {
        self.n
    }

    pub fn free_count(&self) -> usize {
        self.free.len()
    }

    pub fn handles(&self) -> &[u32] {
        &self.handles
    }

    pub fn is_handle(&self, cell: usize) -> bool {
        self.is_handle[cell]
    }

    /// The factor's half bandwidth: the largest slot distance between two linked free cells.
    pub fn bandwidth(&self) -> usize {
        self.band
    }

    pub fn ordering(&self) -> PoseOrdering {
        self.ordering
    }

    /// How solve() seeds the rotations before its iterations (PoseSeed::Increment by default).
    pub fn set_seed(&mut self, mode: PoseSeed) {
        self.seed = mode;
    }

    pub fn seed(&self) -> PoseSeed {
        self.seed
    }

    /// One frame: the rotation seed (when on), then `iterations` local/global iterations.
    /// `handle_targets`: one per handle, in build()'s order; `pose`: the warm start on entry
    /// (last frame's pose, the design, or `reset_to_rigid_fit()`), the result on exit
    /// (handles exactly on their targets); `turns`: the turns that go with the warm start on
    /// entry (last frame's; zeros with the design), each cell's rotation on exit (from the
    /// last local step, or the seed's with 0 iterations), kept continuous. With the seed off
    /// and 0 iterations only the handles are placed.
    pub fn solve(&mut self, handle_targets: &[Vector2], pose: &mut [Vector2], turns: &mut [f32], iterations: usize) -> Result<(), PoseError> {
        let n = self.n;
        if handle_targets.len() != self.handles.len() || pose.len() != n || turns.len() != n {
            return Err(PoseError::SizeMismatch);
        }
        for i in 0..n {
            self.px[i] = pose[i].x as f64;
            self.py[i] = pose[i].y as f64;
        }
        if self.seed != PoseSeed::Off {
            self.seed_rotations(handle_targets, turns);
        }
        for (k, &h) in self.handles.iter().enumerate() {
            self.px[h as usize] = handle_targets[k].x as f64;
            self.py[h as usize] = handle_targets[k].y as f64;
        }
        // The handles' share of every free cell's right-hand side, fixed for the frame.
        for s in 0..self.free.len() {
            let i = self.free[s] as usize;
            let (mut bx, mut by) = (0.0f64, 0.0f64);
            for e in &self.edges[self.adj_start[i] as usize..self.adj_start[i + 1] as usize] {
                if e.handle {
                    bx += e.w * self.px[e.j as usize];
                    by += e.w * self.py[e.j as usize];
                }
            }
            self.hbx[s] = bx;
            self.hby[s] = by;
        }
        if self.seed != PoseSeed::Off {
            self.global_step();
        }
        for it in 0..iterations {
            let last = it + 1 == iterations;
            self.local_step(turns, last);
            self.global_step();
        }
        for i in 0..n {
            pose[i] = Vector2::new(self.px[i] as f32, self.py[i] as f32);
        }
        Ok(())
    }

    /// The rotation seed (the module comment says why): each handle's turn, θ_h, is the
    /// best-fit rotation of its edges to other handles from where they were (Increment: the
    /// warm start; Absolute: the design, unwrapped against the handle's turn on entry) to the
    /// targets; a handle with no handle neighbour takes the whole handle set's. The free cells
    /// get the harmonic θ_f (L_ff θ_f = Σ_{j handle} w_ij θ_j). Every cell's rotation becomes
    /// its turn on entry plus its θ (Increment) or its θ (Absolute), `turns` is set to it, and
    /// solve()'s global step places the cells. Increments add only while under half a turn.
    fn seed_rotations(&mut self, targets: &[Vector2], turns: &mut [f32]) {
        let n = self.n;
        let absolute = self.seed == PoseSeed::Absolute;
        // Where the handles' turns are measured from: the design, or the warm start.
        let (fx, fy) = if absolute { (&self.dx, &self.dy) } else { (&self.px, &self.py) };
        // The whole handle set's turn, for handles with no handle neighbour.
        let mut all: Option<f64> = None;
        for i in 0..n {
            self.dt[i] = 0.0;
        }
        for (k, &h) in self.handles.iter().enumerate() {
            let h = h as usize;
            let (mut sc, mut ss) = (0.0f64, 0.0f64);
            let (tix, tiy) = (targets[k].x as f64, targets[k].y as f64);
            for p in self.adj_start[h] as usize..self.adj_start[h + 1] as usize {
                let j = self.adj_j[p] as usize;
                let kj = self.hidx[j];
                if kj == u32::MAX {
                    continue;
                }
                let w = self.adj_w[p];
                let (ax, ay) = (fx[j] - fx[h], fy[j] - fy[h]);
                let (bx, by) = (targets[kj as usize].x as f64 - tix, targets[kj as usize].y as f64 - tiy);
                sc += w * (ax * bx + ay * by);
                ss += w * (ax * by - ay * bx);
            }
            let fit = if sc * sc + ss * ss > 1e-24 {
                ss.atan2(sc)
            } else {
                *all.get_or_insert_with(|| {
                    let (mut ax, mut ay, mut bx, mut by) = (0.0f64, 0.0f64, 0.0f64, 0.0f64);
                    for (q, &c) in self.handles.iter().enumerate() {
                        ax += fx[c as usize];
                        ay += fy[c as usize];
                        bx += targets[q].x as f64;
                        by += targets[q].y as f64;
                    }
                    let inv = 1.0 / self.handles.len() as f64;
                    let (ax, ay, bx, by) = (ax * inv, ay * inv, bx * inv, by * inv);
                    let (mut sc, mut ss) = (0.0f64, 0.0f64);
                    for (q, &c) in self.handles.iter().enumerate() {
                        let (ux, uy) = (fx[c as usize] - ax, fy[c as usize] - ay);
                        let (vx, vy) = (targets[q].x as f64 - bx, targets[q].y as f64 - by);
                        sc += ux * vx + uy * vy;
                        ss += ux * vy - uy * vx;
                    }
                    if sc * sc + ss * ss > 1e-24 {
                        ss.atan2(sc)
                    } else {
                        0.0
                    }
                })
            };
            // An absolute turn unwrapped against the handle's turn on entry.
            self.dt[h] = if absolute { turns[h] as f64 + wrap(fit - turns[h] as f64) } else { fit };
        }
        let m = self.free.len();
        for s in 0..m {
            let i = self.free[s] as usize;
            let mut b = 0.0f64;
            for p in self.adj_start[i] as usize..self.adj_start[i + 1] as usize {
                let j = self.adj_j[p] as usize;
                if self.is_handle[j] {
                    b += self.adj_w[p] * self.dt[j];
                }
            }
            self.bx[s] = b;
            self.by[s] = 0.0;
        }
        substitute(&self.l, &self.inv_diag, self.band, &mut self.bx, &mut self.by);
        for s in 0..m {
            self.dt[self.free[s] as usize] = self.bx[s];
        }
        for i in 0..n {
            let prev = turns[i] as f64;
            let t = if absolute { prev + wrap(self.dt[i] - prev) } else { prev + self.dt[i] };
            turns[i] = t as f32;
            let (sn, cs) = t.sin_cos();
            self.rc[i] = cs;
            self.rs[i] = sn;
        }
    }

    /// Local step: each cell's best-fit rotation into rc, rs; the turns written when `last`.
    /// Σ w dot(e₀, e) and Σ w cross(e₀, e) are the same seen from either end of a link (both
    /// edges flip), so each link is visited once and added to both cells.
    fn local_step(&mut self, turns: &mut [f32], last: bool) {
        let n = self.n;
        let (sc, ss) = (&mut self.sc[..n], &mut self.ss[..n]);
        sc.fill(0.0);
        ss.fill(0.0);
        let (px, py) = (&self.px[..n], &self.py[..n]);
        for l in &self.links {
            let (i, j) = (l.i as usize, l.j as usize);
            let (ex, ey) = (px[j] - px[i], py[j] - py[i]);
            let d = l.w * (l.ex * ex + l.ey * ey);
            let c = l.w * (l.ex * ey - l.ey * ex);
            sc[i] += d;
            ss[i] += c;
            sc[j] += d;
            ss[j] += c;
        }
        for i in 0..n {
            let (sci, ssi) = (sc[i], ss[i]);
            let ll = (sci * sci + ssi * ssi).sqrt();
            if ll > 1e-18 {
                self.rc[i] = sci / ll;
                self.rs[i] = ssi / ll;
                if last {
                    let prev = turns[i] as f64;
                    turns[i] = (prev + wrap(ssi.atan2(sci) - prev)) as f32;
                }
            } else {
                // No neighbourhood to fit (a lone handle, or all neighbours on top of it):
                // keep the turn it has.
                let (sn, cs) = (turns[i] as f64).sin_cos();
                self.rc[i] = cs;
                self.rs[i] = sn;
            }
        }
    }

    /// Global step: the right-hand side for the free cells, then the banded solve.
    /// b_i = Σ_j w_ij / 2 (R_i + R_j)(d_i − d_j) + Σ_{j handle} w_ij p_j
    ///     = −R_i half_i − Σ_j w_ij / 2 R_j (d_j − d_i) + (the handles' share, hbx / hby);
    /// the middle sum gathered link by link (each link gives −hw R_j e to i and +hw R_i e to
    /// j), handles' sums computed and dropped.
    fn global_step(&mut self) {
        let m = self.free.len();
        if m == 0 {
            return;
        }
        let n = self.n;
        let (rc, rs) = (&self.rc[..n], &self.rs[..n]);
        let (cx, cy) = (&mut self.cx[..n], &mut self.cy[..n]);
        for i in 0..n {
            let (hx, hy) = (self.half_x[i], self.half_y[i]);
            cx[i] = -(rc[i] * hx - rs[i] * hy);
            cy[i] = -(rs[i] * hx + rc[i] * hy);
        }
        for l in &self.links {
            let (i, j) = (l.i as usize, l.j as usize);
            let (ax, ay) = (l.hw * l.ex, l.hw * l.ey);
            cx[i] -= rc[j] * ax - rs[j] * ay;
            cy[i] -= rs[j] * ax + rc[j] * ay;
            cx[j] += rc[i] * ax - rs[i] * ay;
            cy[j] += rs[i] * ax + rc[i] * ay;
        }
        for s in 0..m {
            let i = self.free[s] as usize;
            self.bx[s] = cx[i] + self.hbx[s];
            self.by[s] = cy[i] + self.hby[s];
        }
        substitute(&self.l, &self.inv_diag, self.band, &mut self.bx, &mut self.by);
        for s in 0..m {
            let i = self.free[s] as usize;
            self.px[i] = self.bx[s];
            self.py[i] = self.by[s];
        }
    }

    /// A cold start for large turns: the rotation and translation that best fit the handles'
    /// design positions to their targets (least squares about their centroids), applied to
    /// every cell; the handles then put exactly on their targets, and every turn set to the
    /// fit's angle (continuous against what `turns` held). Returns the angle.
    pub fn reset_to_rigid_fit(&self, handle_targets: &[Vector2], pose: &mut [Vector2], turns: &mut [f32]) -> Result<f32, PoseError> {
        let n = self.n;
        let h = self.handles.len();
        if handle_targets.len() != h || pose.len() != n || turns.len() != n {
            return Err(PoseError::SizeMismatch);
        }
        let (mut dcx, mut dcy, mut tcx, mut tcy) = (0.0f64, 0.0f64, 0.0f64, 0.0f64);
        for (k, &c) in self.handles.iter().enumerate() {
            dcx += self.dx[c as usize];
            dcy += self.dy[c as usize];
            tcx += handle_targets[k].x as f64;
            tcy += handle_targets[k].y as f64;
        }
        let inv = 1.0 / h as f64;
        let (dcx, dcy, tcx, tcy) = (dcx * inv, dcy * inv, tcx * inv, tcy * inv);
        let (mut sc, mut ss) = (0.0f64, 0.0f64);
        for (k, &c) in self.handles.iter().enumerate() {
            let (ax, ay) = (self.dx[c as usize] - dcx, self.dy[c as usize] - dcy);
            let (bx, by) = (handle_targets[k].x as f64 - tcx, handle_targets[k].y as f64 - tcy);
            sc += ax * bx + ay * by;
            ss += ax * by - ay * bx;
        }
        let ll = (sc * sc + ss * ss).sqrt();
        let (c, s, ang) = if ll > 1e-18 { (sc / ll, ss / ll, ss.atan2(sc)) } else { (1.0, 0.0, 0.0) };
        for i in 0..n {
            let (ax, ay) = (self.dx[i] - dcx, self.dy[i] - dcy);
            pose[i] = Vector2::new((tcx + c * ax - s * ay) as f32, (tcy + s * ax + c * ay) as f32);
            let prev = turns[i] as f64;
            turns[i] = (prev + wrap(ang - prev)) as f32;
        }
        for (k, &c) in self.handles.iter().enumerate() {
            pose[c as usize] = handle_targets[k];
        }
        Ok(ang as f32)
    }

    /// Per cell, the mean of its links' posed length over their design length (1 for a cell
    /// with no links, or none of non-zero design length): a radius scale for the caller to
    /// clamp.
    pub fn strain_scales(&self, pose: &[Vector2], out: &mut [f32]) {
        let n = self.n.min(pose.len()).min(out.len());
        for i in 0..n {
            let (mut sum, mut k) = (0.0f64, 0u32);
            for p in self.adj_start[i] as usize..self.adj_start[i + 1] as usize {
                let d0 = self.adj_len[p];
                if d0 <= 1e-9 {
                    continue;
                }
                let j = self.adj_j[p] as usize;
                let (ex, ey) = ((pose[j].x - pose[i].x) as f64, (pose[j].y - pose[i].y) as f64);
                sum += (ex * ex + ey * ey).sqrt() / d0;
                k += 1;
            }
            out[i] = if k > 0 { (sum / k as f64) as f32 } else { 1.0 };
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cells::{hex_design, worm_design};

    const R: f32 = 7.0;

    /// Links at touch distance (the kernel's link tolerance, 1.08).
    fn touch_links(d: &[Vector2], r: f32) -> Vec<(u32, u32)> {
        let mut out = Vec::new();
        for i in 0..d.len() {
            for j in (i + 1)..d.len() {
                if (d[j] - d[i]).length() < 2.0 * r * 1.08 {
                    out.push((i as u32, j as u32));
                }
            }
        }
        out
    }

    /// A hex strip `long` × `wide` (odd) along +x; its middle row the handles.
    fn strip(long: i32, wide: i32) -> (Vec<Vector2>, Vec<u32>) {
        let d = worm_design(long, wide, R, Vector2::ZERO);
        let mid = wide / 2;
        let h = (0..long).map(|k| (mid * long + k) as u32).collect();
        (d, h)
    }

    /// A dead-end branch of `width` (1 or 2) lines of `len` cells, leaving the cell at
    /// `root` along the hex direction `dir`; the second line beside the first by `shift`.
    /// Returns each line's cell indices, root first.
    fn branch(d: &mut Vec<Vector2>, root: Vector2, dir: Vector2, shift: Vector2, len: usize, width: usize) -> Vec<Vec<usize>> {
        let mut lines = Vec::new();
        for w in 0..width {
            let mut line = Vec::new();
            for k in 1..=len {
                line.push(d.len());
                d.push(root + dir * (2.0 * R * k as f32) + shift * w as f32);
            }
            lines.push(line);
        }
        lines
    }

    struct Shape {
        design: Vec<Vector2>,
        links: Vec<(u32, u32)>,
        handles: Vec<u32>,
        branch: Vec<Vec<usize>>,
    }

    fn ones(k: usize) -> Vec<f32> {
        vec![1.0; k]
    }

    /// The 3-row strip (20 long, middle row handles) with one branch of `width` 17 cells
    /// long: forward-outward at 60° from the top row's 8th cell, or swept back (120°) from
    /// its 3rd, past the strip's tail.
    fn strip_with_branch(width: usize, swept: bool) -> Shape {
        let (mut d, handles) = strip(20, 3);
        let (k, dir, shift) = if swept {
            (2, Vector2::new(-0.5, -0.866_025_4), Vector2::new(-2.0 * R, 0.0))
        } else {
            (7, Vector2::new(0.5, -0.866_025_4), Vector2::new(2.0 * R, 0.0))
        };
        let root = d[k];
        let br = branch(&mut d, root, dir, shift, 17, width);
        let links = touch_links(&d, R);
        Shape { design: d, links, handles, branch: br }
    }

    fn solver(s: &Shape) -> PoseSolver {
        PoseSolver::build(&s.design, &s.links, &ones(s.links.len()), &s.handles, Vector2::new(1.0, 0.0), 1).unwrap()
    }

    fn max_gap(a: &[Vector2], b: &[Vector2]) -> f32 {
        a.iter().zip(b).map(|(p, q)| (*p - *q).length()).fold(0.0, f32::max)
    }

    /// A tiny deterministic generator for perturbations.
    fn noise(seed: &mut u64) -> f32 {
        *seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        ((*seed >> 33) as f32 / (1u64 << 31) as f32) * 2.0 - 1.0
    }

    #[test]
    fn unmoved_handles_give_the_design() {
        for s in [strip_with_branch(1, false), strip_with_branch(2, true)] {
            let mut sv = solver(&s);
            let targets: Vec<Vector2> = s.handles.iter().map(|&h| s.design[h as usize]).collect();
            let mut pose = s.design.clone();
            let mut turns = vec![0.0; pose.len()];
            sv.solve(&targets, &mut pose, &mut turns, 3).unwrap();
            let g = max_gap(&pose, &s.design);
            assert!(g < 1e-4, "design start: {}", g);
            assert!(turns.iter().all(|t| t.abs() < 1e-6));
            // From a warm start whose free cells are off by up to 5 px per axis (its handles
            // where last frame's targets put them), with the design's turns: the seed puts
            // every cell back at once; plain iterations (seed off) take long.
            for seeded in [PoseSeed::Absolute, PoseSeed::Increment, PoseSeed::Off] {
                sv.set_seed(seeded);
                let mut seed = 7u64;
                let mut pose: Vec<Vector2> = s.design.clone();
                for (i, p) in pose.iter_mut().enumerate() {
                    if !sv.is_handle(i) {
                        *p += Vector2::new(5.0 * noise(&mut seed), 5.0 * noise(&mut seed));
                    }
                }
                let mut turns = vec![0.0; pose.len()];
                let its = iterations_to(&mut sv, &targets, &mut pose, &mut turns, &s.design, 1e-4, 20000);
                println!(
                    "unmoved handles: {} cells, free cells off by 5 px, back to the design (1e-4 px) in {} iterations, seed {:?}",
                    s.design.len(),
                    its,
                    seeded
                );
                assert!(its <= if seeded != PoseSeed::Off { 1 } else { 20000 - 1 }, "{} iterations, seed {:?}", its, seeded);
            }
        }
    }

    /// Iterations (from the pose given) until every cell is within `tol` of `want`, at most
    /// `cap`: one at a time up to 50, then 50 at a time (solve()'s pose goes through f32
    /// between calls, and that rounding, taken every iteration, holds a slow mode up).
    fn iterations_to(sv: &mut PoseSolver, targets: &[Vector2], pose: &mut [Vector2], turns: &mut [f32], want: &[Vector2], tol: f32, cap: usize) -> usize {
        let mut its = 0;
        while max_gap(pose, want) >= tol && its < cap {
            let k = if its < 50 { 1 } else { 50 };
            sv.solve(targets, pose, turns, k).unwrap();
            its += k;
        }
        its
    }

    fn rigid(p: Vector2, a: f32, t: Vector2) -> Vector2 {
        let (c, s) = (a.cos(), a.sin());
        Vector2::new(c * p.x - s * p.y, s * p.x + c * p.y) + t
    }

    #[test]
    fn rigidly_moved_handles_move_everything_rigidly() {
        let shapes = [("strip + swept 2-wide branch", strip_with_branch(2, true)), ("strip + 1-wide branch", strip_with_branch(1, false)), ("blob 37", {
            let d = hex_design(3, R, Vector2::ZERO);
            let links = touch_links(&d, R);
            // The row through the middle as handles.
            let handles: Vec<u32> = (0..d.len() as u32).filter(|&i| d[i as usize].y.abs() < 1e-3).collect();
            Shape { design: d, links, handles, branch: vec![] }
        })];
        let t = Vector2::new(40.0, -25.0);
        for (name, s) in shapes.iter() {
            let mut sv = solver(s);
            for &a in &[0.3f32, 1.5, 3.0] {
                let want: Vec<Vector2> = s.design.iter().map(|&p| rigid(p, a, t)).collect();
                let targets: Vec<Vector2> = s.handles.iter().map(|&h| want[h as usize]).collect();
                for seeded in [PoseSeed::Absolute, PoseSeed::Increment, PoseSeed::Off] {
                    sv.set_seed(seeded);
                    let mut pose = s.design.clone();
                    let mut turns = vec![0.0; pose.len()];
                    let its = iterations_to(&mut sv, &targets, &mut pose, &mut turns, &want, 1e-3, 20000);
                    let worst_turn = turns.iter().map(|&x| (x - a).abs()).fold(0.0, f32::max);
                    println!(
                        "rigid {}: {:.1} rad from the design, seed {:?}: {} iterations to 1e-3 px (turns off by {:.2e})",
                        name,
                        a,
                        seeded,
                        its,
                        worst_turn
                    );
                    if seeded != PoseSeed::Off {
                        assert!(its <= 1, "{} {}: {}", name, a, its);
                        assert!(worst_turn < 1e-4, "{} {}: turns", name, a);
                    } else if a < 2.0 {
                        assert!(its < 20000, "{} {}: {}", name, a, its);
                    }
                }
                // From the rigid fit with the seed off: exact at once.
                sv.set_seed(PoseSeed::Off);
                let mut pose = s.design.clone();
                let mut turns = vec![0.0; pose.len()];
                let fit = sv.reset_to_rigid_fit(&targets, &mut pose, &mut turns).unwrap();
                assert!((fit - a).abs() < 1e-5);
                sv.solve(&targets, &mut pose, &mut turns, 1).unwrap();
                let g = max_gap(&pose, &want);
                assert!(g < 1e-3, "{} {}: from the rigid fit {}", name, a, g);
                assert!(turns.iter().all(|&x| (x - a).abs() < 1e-4), "{} {}: turns", name, a);
            }
        }
    }

    /// The spine's centreline bent to a circle of curvature `kappa` (sign: toward +y) from
    /// x = x0: (position, tangent angle) at design x.
    fn arc(x: f32, x0: f32, kappa: f32) -> (Vector2, f32) {
        let s = x - x0;
        if kappa.abs() < 1e-9 {
            return (Vector2::new(x, 0.0), 0.0);
        }
        let th = s * kappa;
        (Vector2::new(x0 + th.sin() / kappa, (1.0 - th.cos()) / kappa), th)
    }

    fn link_strain(pose: &[Vector2], d: &[Vector2], i: usize, j: usize) -> f32 {
        (pose[j] - pose[i]).length() / (d[j] - d[i]).length() - 1.0
    }

    /// The best-fit line through points: (direction from the first to the last, worst
    /// perpendicular distance).
    fn line_fit(p: &[Vector2]) -> (Vector2, f32) {
        let c = p.iter().fold(Vector2::ZERO, |a, &b| a + b) / p.len() as f32;
        let (mut sxx, mut sxy, mut syy) = (0.0f32, 0.0f32, 0.0f32);
        for q in p {
            let e = *q - c;
            sxx += e.x * e.x;
            sxy += e.x * e.y;
            syy += e.y * e.y;
        }
        let ang = 0.5 * (2.0 * sxy).atan2(sxx - syy);
        let mut u = Vector2::new(ang.cos(), ang.sin());
        if (p[p.len() - 1] - p[0]).dot(u) < 0.0 {
            u = -u;
        }
        let worst = p.iter().map(|q| (*q - c).cross(u).abs()).fold(0.0, f32::max);
        (u, worst)
    }

    #[test]
    fn dead_end_branch_keeps_its_shape_under_a_90_degree_bend() {
        for (name, width, swept) in [("1-wide", 1, false), ("2-wide", 2, false), ("2-wide swept back", 2, true)] {
            let s = strip_with_branch(width, swept);
            let mut sv = solver(&s);
            let hx: Vec<f32> = s.handles.iter().map(|&h| s.design[h as usize].x).collect();
            let x0 = hx[0];
            let span = hx[hx.len() - 1] - x0;
            for sign in [1.0f32, -1.0] {
                let kappa = sign * std::f32::consts::FRAC_PI_2 / span;
                let targets: Vec<Vector2> = hx.iter().map(|&x| arc(x, x0, kappa).0).collect();
                let mut pose = s.design.clone();
                let mut turns = vec![0.0; pose.len()];
                // From the design, 3 iterations (one frame's worth) and converged.
                sv.solve(&targets, &mut pose, &mut turns, 3).unwrap();
                let three = pose.clone();
                sv.solve(&targets, &mut pose, &mut turns, 2997).unwrap();
                let mut more = pose.clone();
                let mut more_turns = turns.clone();
                sv.solve(&targets, &mut more, &mut more_turns, 3000).unwrap();
                let converged_gap = max_gap(&pose, &more);
                let first_frame_gap = max_gap(&three, &pose);
                let in_branch: Vec<bool> = (0..pose.len()).map(|i| s.branch.iter().any(|l| l.contains(&i))).collect();
                let at_base: Vec<bool> = (0..pose.len()).map(|i| s.branch.iter().any(|l| l[0] == i)).collect();
                let (mut worst_branch, mut worst_beyond, mut worst_root, mut worst_body) = (0.0f32, 0.0f32, 0.0f32, 0.0f32);
                for &(a, b) in &s.links {
                    let (a, b) = (a as usize, b as usize);
                    let e = link_strain(&pose, &s.design, a, b).abs();
                    match (in_branch[a], in_branch[b]) {
                        (true, true) => {
                            worst_branch = worst_branch.max(e);
                            if !at_base[a] && !at_base[b] {
                                worst_beyond = worst_beyond.max(e);
                            }
                        }
                        (false, false) => worst_body = worst_body.max(e),
                        _ => worst_root = worst_root.max(e),
                    }
                }
                // Straightness, and the angle at which it leaves against the spine's tangent
                // at the middle of its base (its first cells' mean along the axis).
                let base_x = s.branch.iter().map(|l| s.design[l[0]].x).sum::<f32>() / s.branch.len() as f32;
                let (_, tangent) = arc(base_x, x0, kappa);
                let design_dir = s.design[s.branch[0][16]] - s.design[s.branch[0][0]];
                let design_ang = design_dir.y.atan2(design_dir.x);
                let mut worst_line = 0.0f32;
                let mut worst_ang = 0.0f32;
                for line in &s.branch {
                    let pts: Vec<Vector2> = line.iter().map(|&i| pose[i]).collect();
                    let (u, dev) = line_fit(&pts);
                    worst_line = worst_line.max(dev);
                    let ang = (u.y.atan2(u.x) - tangent - design_ang + 3.0 * std::f32::consts::PI).rem_euclid(std::f32::consts::TAU) - std::f32::consts::PI;
                    worst_ang = worst_ang.max(ang.abs());
                }
                println!(
                    "90° bend ({}, bend {}): branch links {:.2} % worst ({:.2} % past its first cells), root links {:.2} %, body links {:.2} %, branch off its line {:.3} px, its angle off the design against the tangent {:.2}°; one frame (3 iterations from the design) within {:.3} px of converged (3000; 6000 within {:.1e})",
                    name,
                    if sign > 0.0 { "+" } else { "-" },
                    100.0 * worst_branch,
                    100.0 * worst_beyond,
                    100.0 * worst_root,
                    100.0 * worst_body,
                    worst_line,
                    worst_ang.to_degrees(),
                    first_frame_gap,
                    converged_gap
                );
                assert!(converged_gap < 1e-2, "{}: not converged {}", name, converged_gap);
                assert!(worst_beyond < 0.02, "{}: branch strain past its base {}", name, worst_beyond);
                assert!(worst_branch < 0.035, "{}: branch strain {}", name, worst_branch);
                assert!(worst_line < 1.0, "{}: off its line {}", name, worst_line);
                assert!(worst_ang.to_degrees() < 5.0, "{}: angle {}", name, worst_ang.to_degrees());
            }
        }
    }

    #[test]
    fn a_thick_strip_bends_with_the_geometrys_strain() {
        let (d, handles) = strip(30, 5);
        let links = touch_links(&d, R);
        let mut sv = PoseSolver::build(&d, &links, &ones(links.len()), &handles, Vector2::new(1.0, 0.0), 0).unwrap();
        let kappa = 0.01f32;
        let hx: Vec<f32> = handles.iter().map(|&h| d[h as usize].x).collect();
        let targets: Vec<Vector2> = hx.iter().map(|&x| arc(x, hx[0], kappa).0).collect();
        let mut pose = d.clone();
        let mut turns = vec![0.0; d.len()];
        sv.solve(&targets, &mut pose, &mut turns, 300).unwrap();
        let mut scales = vec![0.0; d.len()];
        sv.strain_scales(&pose, &mut scales);
        // Links along each row in the middle third: strain against offset × curvature (the
        // ribbon's 1 − v κ, with v the row's offset; +y toward the centre of curvature).
        let (lo, hi) = (hx[0] + 0.33 * (hx[29] - hx[0]), hx[0] + 0.67 * (hx[29] - hx[0]));
        for row in 0..5 {
            let v = d[row * 30].y;
            let (mut sum, mut k) = (0.0f32, 0);
            let mut scale_sum = 0.0f32;
            for c in 0..29 {
                let (a, b) = (row * 30 + c, row * 30 + c + 1);
                if d[a].x < lo || d[b].x > hi {
                    continue;
                }
                sum += link_strain(&pose, &d, a, b);
                scale_sum += scales[a];
                k += 1;
            }
            let mean = sum / k as f32;
            let geometric = -v * kappa;
            println!(
                "thick strip, curvature 0.01: row offset {:+.1} px: along-row strain {:+.2} % (the geometry's {:+.2} %, ratio {:.2}), strain_scales {:.3}",
                v,
                100.0 * mean,
                100.0 * geometric,
                if geometric != 0.0 { mean / geometric } else { 0.0 },
                scale_sum / k as f32
            );
            if v.abs() > 20.0 {
                // The outer rows carry most of the geometry's strain.
                assert!(mean / geometric > 0.7 && mean / geometric < 1.1, "row {}: {} against {}", row, mean, geometric);
                assert!((scale_sum / k as f32 - 1.0) * geometric > 0.0, "strain_scales' sign, row {}", row);
            }
            if v.abs() < 1.0 {
                assert!(mean.abs() < 0.002, "the handle row {}", mean);
            }
        }
    }

    /// Handle targets for a wave of curvature along the spine (handles at design x, the
    /// centreline integrated from x = 0 with the heading there 0).
    fn wave_targets(hx: &[f32], amp: f32, wavelength: f32, phase: f32, out: &mut Vec<Vector2>) {
        out.clear();
        let k = std::f32::consts::TAU / wavelength;
        for &x in hx {
            let steps = ((x.abs() / 0.25).ceil() as usize).max(1);
            let h = x / steps as f32;
            let (mut psi, mut px, mut py) = (0.0f32, 0.0f32, 0.0f32);
            for st in 0..steps {
                let s0 = st as f32 * h;
                let s1 = s0 + h;
                let k0 = amp * (k * s0 - phase).sin();
                let k1 = amp * (k * s1 - phase).sin();
                let psi1 = psi + 0.5 * (k0 + k1) * h;
                let a = 0.5 * (psi + psi1);
                px += a.cos() * h;
                py += a.sin() * h;
                psi = psi1;
            }
            out.push(Vector2::new(px, py));
        }
    }

    /// Iterations a frame of the wave's converged reference (warm-started from its last frame).
    const REF_ITERS: usize = 2000;

    /// The wave's handle targets frame by frame for two cycles: curvature amplitude 0.015 /px
    /// (eased in over 0.5 s, as the kernel's wave starts), 1.4 body lengths, 1.4 Hz, 60 frames
    /// a second.
    fn wave_frames(s: &Shape) -> Vec<Vec<Vector2>> {
        let hx: Vec<f32> = s.handles.iter().map(|&h| s.design[h as usize].x).collect();
        let length = hx[hx.len() - 1] - hx[0] + 2.0 * R;
        let dt = 1.0f32 / 60.0;
        let freq = 1.4f32;
        let frames = (2.0 / freq / dt).ceil() as usize;
        (0..frames)
            .map(|f| {
                let t = (f + 1) as f32 * dt;
                let ramp = (t / 0.5).min(1.0);
                let mut targets = Vec::new();
                wave_targets(&hx, 0.015 * ramp, 1.4 * length, std::f32::consts::TAU * freq * t, &mut targets);
                targets
            })
            .collect()
    }

    /// Plays the frames at `iters` a frame, warm-started from the last frame; the poses.
    fn play(s: &Shape, frames: &[Vec<Vector2>], iters: usize, seeded: PoseSeed) -> Vec<Vec<Vector2>> {
        let mut sv = solver(s);
        sv.set_seed(seeded);
        let (mut p, mut t) = (s.design.clone(), vec![0.0f32; s.design.len()]);
        frames
            .iter()
            .map(|tg| {
                sv.solve(tg, &mut p, &mut t, iters).unwrap();
                p.clone()
            })
            .collect()
    }

    /// The worst strain of the links inside the branch, over every pose.
    fn branch_strain(s: &Shape, poses: &[Vec<Vector2>]) -> f32 {
        let in_branch = |i: u32| s.branch.iter().any(|l| l.contains(&(i as usize)));
        let mut worst = 0.0f32;
        for &(a, b) in s.links.iter().filter(|&&(a, b)| in_branch(a) && in_branch(b)) {
            for p in poses {
                worst = worst.max(link_strain(p, &s.design, a as usize, b as usize).abs());
            }
        }
        worst
    }

    #[test]
    fn warm_started_wave_stays_near_the_converged_pose() {
        let worm = {
            let (d, handles) = strip(24, 5);
            let links = touch_links(&d, R);
            Shape { design: d, links, handles, branch: vec![] }
        };
        let finned = strip_with_branch(2, true);
        let finned1 = strip_with_branch(1, false);
        for (name, s, bound) in [("worm 24 × 5", &worm, 0.3f32), ("strip + 1-wide fin", &finned1, 7.0), ("strip + swept 2-wide fin", &finned, 3.0)] {
            let frames = wave_frames(s);
            let reference = play(s, &frames, REF_ITERS, PoseSeed::Increment);
            // How converged is the reference: its last frame against 4000 more.
            let mut sv = solver(s);
            let (mut p, mut t) = (reference[reference.len() - 1].clone(), vec![0.0f32; s.design.len()]);
            sv.solve(&frames[frames.len() - 1], &mut p, &mut t, 4000).unwrap();
            let reference_strain = branch_strain(s, &reference);
            println!(
                "wave on the {} ({} frames): the reference ({} a frame) within {:.1e} px of 4000 more; its fin's worst link strain {:.2} %",
                name,
                frames.len(),
                REF_ITERS,
                max_gap(&p, &reference[reference.len() - 1]),
                100.0 * branch_strain(s, &reference)
            );
            let mut gaps = Vec::new();
            let mut strains = Vec::new();
            for (iters, seeded) in [(1, PoseSeed::Increment), (2, PoseSeed::Increment), (3, PoseSeed::Increment), (3, PoseSeed::Absolute), (3, PoseSeed::Off)] {
                let poses = play(s, &frames, iters, seeded);
                let gap = poses.iter().zip(&reference).map(|(a, b)| max_gap(a, b)).fold(0.0, f32::max);
                println!(
                    "wave on the {}: {} iterations a frame, seed {:?}, warm-started: worst gap to the converged pose {:.3} px; fin's worst link strain {:.2} %",
                    name,
                    iters,
                    seeded,
                    gap,
                    100.0 * branch_strain(s, &poses)
                );
                gaps.push(gap);
                strains.push(branch_strain(s, &poses));
            }
            // The gap is the dead-end fin's orientation (the seed turns it with its root, the
            // converged pose a degree or so further; the iterations barely move that mode);
            // its links keep their lengths as well as the converged pose's.
            assert!(gaps[2] < bound, "{}: 3 iterations {} px", name, gaps[2]);
            assert!(gaps[2] <= gaps[0], "{}: more iterations, no closer", name);
            assert!(strains[2] < reference_strain + 0.005, "{}: fin strain {} against {}", name, strains[2], reference_strain);
        }
    }

    #[test]
    fn same_input_same_bits() {
        let s = strip_with_branch(2, true);
        let mut a = solver(&s);
        let mut b = solver(&s);
        let hx: Vec<f32> = s.handles.iter().map(|&h| s.design[h as usize].x).collect();
        let (mut pa, mut ta) = (s.design.clone(), vec![0.0f32; s.design.len()]);
        let (mut pb, mut tb) = (s.design.clone(), vec![0.0f32; s.design.len()]);
        let mut targets = Vec::new();
        for f in 0..120 {
            wave_targets(&hx, 0.015, 400.0, 0.15 * f as f32, &mut targets);
            a.solve(&targets, &mut pa, &mut ta, 3).unwrap();
            b.solve(&targets, &mut pb, &mut tb, 3).unwrap();
            assert!(pa.iter().zip(&pb).all(|(p, q)| p.x.to_bits() == q.x.to_bits() && p.y.to_bits() == q.y.to_bits()), "frame {}", f);
            assert!(ta.iter().zip(&tb).all(|(p, q)| p.to_bits() == q.to_bits()), "frame {}", f);
        }
        let mut sa = vec![0.0; pa.len()];
        let mut sb = vec![0.0; pb.len()];
        a.strain_scales(&pa, &mut sa);
        b.strain_scales(&pb, &mut sb);
        assert!(sa.iter().zip(&sb).all(|(p, q)| p.to_bits() == q.to_bits()));
    }

    #[test]
    fn errors() {
        let x = Vector2::new(1.0, 0.0);
        assert_eq!(PoseSolver::build(&[], &[], &[], &[0], x, 0).unwrap_err(), PoseError::Empty);
        let d = vec![Vector2::new(0.0, 0.0), Vector2::new(14.0, 0.0), Vector2::new(28.0, 0.0), Vector2::new(100.0, 0.0), Vector2::new(114.0, 0.0)];
        // Cells 3 and 4 linked to each other only.
        let links = vec![(0, 1), (1, 2), (3, 4)];
        let w = ones(3);
        assert_eq!(PoseSolver::build(&d, &links, &w, &[], x, 0).unwrap_err(), PoseError::NoHandles);
        assert_eq!(PoseSolver::build(&d, &links, &w, &[0, 2], x, 0).unwrap_err(), PoseError::Unanchored { cell: 3 });
        // Lone handles are allowed (cells 3 and 4 unlinked).
        assert!(PoseSolver::build(&d, &links[..2], &w[..2], &[0, 2, 3, 4], x, 0).is_ok());
        // One handle, or two on the same point.
        let chain = &d[..3];
        assert_eq!(PoseSolver::build(chain, &links[..2], &w[..2], &[1], x, 0).unwrap_err(), PoseError::TooFewHandles);
        let same = vec![Vector2::new(0.0, 0.0), Vector2::new(14.0, 0.0), Vector2::new(0.0, 0.0)];
        assert_eq!(PoseSolver::build(&same, &links[..2], &w[..2], &[0, 2], x, 0).unwrap_err(), PoseError::TooFewHandles);
        // Bad input.
        assert_eq!(PoseSolver::build(chain, &[(0, 3)], &[1.0], &[0, 2], x, 0).unwrap_err(), PoseError::BadLink { link: 0 });
        assert_eq!(PoseSolver::build(chain, &[(1, 1)], &[1.0], &[0, 2], x, 0).unwrap_err(), PoseError::BadLink { link: 0 });
        assert_eq!(PoseSolver::build(chain, &links[..2], &[1.0, 0.0], &[0, 2], x, 0).unwrap_err(), PoseError::BadWeight { link: 1 });
        assert_eq!(PoseSolver::build(chain, &links[..2], &[1.0], &[0, 2], x, 0).unwrap_err(), PoseError::SizeMismatch);
        assert_eq!(PoseSolver::build(chain, &links[..2], &w[..2], &[0, 0], x, 0).unwrap_err(), PoseError::BadHandle { handle: 0 });
        assert_eq!(PoseSolver::build(chain, &links[..2], &w[..2], &[0, 5], x, 0).unwrap_err(), PoseError::BadHandle { handle: 5 });
        // Every cell a handle: no free cells, nothing to solve but the turns.
        let mut sv = PoseSolver::build(chain, &links[..2], &w[..2], &[0, 1, 2], x, 9).unwrap();
        assert_eq!(sv.free_count(), 0);
        assert!(sv.is_built_from(3, 2, 3, 9));
        assert!(!sv.is_built_from(3, 2, 3, 10));
        let targets = vec![Vector2::new(0.0, 0.0), Vector2::new(0.0, 14.0), Vector2::new(0.0, 28.0)];
        let mut pose = chain.to_vec();
        let mut turns = vec![0.0; 3];
        sv.solve(&targets, &mut pose, &mut turns, 2).unwrap();
        assert_eq!(pose, targets);
        assert!(turns.iter().all(|t| (t - std::f32::consts::FRAC_PI_2).abs() < 1e-6));
        assert_eq!(sv.solve(&targets[..2], &mut pose, &mut turns, 2).unwrap_err(), PoseError::SizeMismatch);
    }

    #[test]
    fn turns_stay_continuous_past_a_half_turn() {
        // The whole body turned a little at a time through two full turns: every turn
        // follows without a jump of a whole turn.
        let s = strip_with_branch(1, false);
        let mut sv = solver(&s);
        let (mut pose, mut turns) = (s.design.clone(), vec![0.0f32; s.design.len()]);
        let steps = 200;
        for f in 1..=steps {
            let a = 2.0 * std::f32::consts::TAU * f as f32 / steps as f32;
            let targets: Vec<Vector2> = s.handles.iter().map(|&h| rigid(s.design[h as usize], a, Vector2::ZERO)).collect();
            sv.solve(&targets, &mut pose, &mut turns, 3).unwrap();
            assert!(turns.iter().all(|&t| (t - a).abs() < 0.05), "frame {}: {:?}", f, turns.iter().map(|t| t - a).fold(0.0f32, |m, x| m.max(x.abs())));
        }
    }

    #[test]
    fn cost_printed() {
        use std::time::Instant;
        let mut shapes: Vec<(String, Shape)> = Vec::new();
        for (long, wide) in [(10, 3), (24, 5), (30, 5), (40, 5)] {
            let (d, handles) = strip(long, wide);
            let links = touch_links(&d, R);
            shapes.push((format!("worm {} × {}", long, wide), Shape { design: d, links, handles, branch: vec![] }));
        }
        {
            // Like the user's creature: 85 cells, 20 handles: a 20 × 3 strip and two fins one
            // cell wide (12 and 13 long), one swept back.
            let (mut d, handles) = strip(20, 3);
            let r1 = d[6];
            branch(&mut d, r1, Vector2::new(0.5, -0.866_025_4), Vector2::ZERO, 12, 1);
            let r2 = d[2 * 20 + 3];
            branch(&mut d, r2, Vector2::new(-0.5, 0.866_025_4), Vector2::ZERO, 13, 1);
            let links = touch_links(&d, R);
            shapes.push(("strip 20 × 3 + two fins (85)".to_string(), Shape { design: d, links, handles, branch: vec![] }));
        }
        {
            // 150 cells with swept fins: a 30 × 3 strip and two 2-wide fins of 15.
            let (mut d, handles) = strip(30, 3);
            let r1 = d[3];
            branch(&mut d, r1, Vector2::new(-0.5, -0.866_025_4), Vector2::new(-2.0 * R, 0.0), 15, 2);
            let r2 = d[2 * 30 + 3];
            branch(&mut d, r2, Vector2::new(-0.5, 0.866_025_4), Vector2::new(-2.0 * R, 0.0), 15, 2);
            let links = touch_links(&d, R);
            shapes.push(("strip 30 × 3 + two swept 2-wide fins (150)".to_string(), Shape { design: d, links, handles, branch: vec![] }));
        }
        for (name, s) in &shapes {
            let w = ones(s.links.len());
            let builds = 200;
            let t0 = Instant::now();
            let mut sv = None;
            for _ in 0..builds {
                sv = Some(PoseSolver::build(&s.design, &s.links, &w, &s.handles, Vector2::new(1.0, 0.0), 0).unwrap());
            }
            let build_us = t0.elapsed().as_secs_f64() * 1e6 / builds as f64;
            let mut sv = sv.unwrap();
            let hx: Vec<f32> = s.handles.iter().map(|&h| s.design[h as usize].x).collect();
            let frames = 2000;
            let mut all_targets = Vec::with_capacity(frames);
            let mut targets = Vec::new();
            for f in 0..frames {
                wave_targets(&hx, 0.015, 400.0, 0.15 * f as f32, &mut targets);
                all_targets.push(targets.clone());
            }
            let (mut pose, mut turns) = (s.design.clone(), vec![0.0f32; s.design.len()]);
            let mut scales = vec![0.0f32; s.design.len()];
            let t0 = Instant::now();
            for t in &all_targets {
                sv.solve(t, &mut pose, &mut turns, 3).unwrap();
            }
            let solve_us = t0.elapsed().as_secs_f64() * 1e6 / frames as f64;
            let t0 = Instant::now();
            for _ in 0..frames {
                sv.strain_scales(&pose, &mut scales);
            }
            let scales_us = t0.elapsed().as_secs_f64() * 1e6 / frames as f64;
            println!(
                "cost {}: {} cells, {} links, {} handles, {} free, bandwidth {} ({:?}): build {:.1} µs, a frame's solve (3 iterations) {:.2} µs, strain_scales {:.2} µs",
                name,
                s.design.len(),
                s.links.len(),
                s.handles.len(),
                sv.free_count(),
                sv.bandwidth(),
                sv.ordering(),
                build_us,
                solve_us,
                scales_us
            );
        }
    }
}
