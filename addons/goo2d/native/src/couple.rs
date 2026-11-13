//! Rings (a GooKernel's Goo2D bodies) and cell creatures (a GooCells') colliding, coupled
//! directly between the two solvers (docs/cells.md, "Rings and cells").
//!
//! The cell solver steps after the ring kernel each frame and resolves every ring-cell
//! contact itself, so no contact is counted twice:
//!
//! 1. `gather()` / `gather_kernel()`: before the cells' step, every ring's beads as the
//!    kernel's step left them (position p_end, velocity v), its bead radius, its mass (its
//!    area × the cells' density × a scale: the two solvers' masses are in different units)
//!    and whether it is settled.
//! 2. `broad()`, after the cells' own broad phase: the rings near a creature, and the
//!    candidate pairs: outline cells near a ring's bead chain, beads near (or inside) a
//!    creature's outline. Rings near no creature take no further part.
//! 3. `substep()`, in each of the cells' substeps after their own contacts: the touched
//!    rings' beads move as ghost particles along the path the kernel gave them (from
//!    p_end − v·dt to p_end), then the contacts are solved as position corrections
//!    weighted by inverse mass (both sides move), the ghosts' velocities follow their moves,
//!    and a touched ring's change of velocity is drawn toward its rigid part (`rigidity`:
//!    within one frame a ring answers a push as a whole, not bead by bead).
//!    Cells against a ring: the ring's bead chain as capsules (bead radius), and a cell
//!    whose centre is inside the bead loop pushed out across the nearest edge. Beads
//!    against a creature: its outline (the outline cells' centres) as capsules of the cells'
//!    radii, signed the same way.
//! 4. `apply()`: after the cells' step, each ghost's change (position and velocity against
//!    its unperturbed end) is added to its bead in the kernel; a settled ring touched past
//!    the kernel's wake depth or speed is woken (it was immovable this frame), a ring touched
//!    at all is kept from settling (its calm time restarts: it rests on something the
//!    kernel cannot see).
//!
//! Everything here is serial and in a fixed order: a replay is identical and the cells'
//! threaded step stays equal to their serial one.

use crate::cells::{grid_query, key, Body, Opt};
use crate::geom::{centroid, cross, dot, len_sq, Rect};
use crate::kernel::Kernel;
use crate::statics::StaticShape;
use godot::builtin::Vector2;

/// Edges either side of a bead's nearest outline edge tested in a substep (the bead was
/// outside the creature at the frame's start).
const WINDOW: i32 = 3;

/// One ring of the kernel as the cells see it this frame.
#[derive(Clone, Copy, Debug, Default)]
pub struct GhostRing {
    pub key: i64,
    /// The kernel particle of its bead 0, and the ghost of its bead 0.
    pub start: u32,
    pub g0: u32,
    pub n: u32,
    /// Each bead's inverse mass (0: settled, immovable unless woken).
    pub w: f32,
    pub br: f32,
    pub settled: bool,
    /// The box of its bead centres at the frame's start and end, and its fastest bead.
    pub lo: Vector2,
    pub hi: Vector2,
    pub vmax: f32,
    /// Near a creature this frame (its ghosts are moved and solved).
    pub active: bool,
    /// A contact pushed it this frame.
    pub touched: bool,
    /// Settled and touched past the wake depth or speed.
    pub wake: bool,
}

/// A bead near a creature's outline: its ghost, the creature, the outline edge nearest it
/// and whether it started the frame inside (then every edge is searched each substep).
#[derive(Clone, Copy, Debug)]
pub struct BeadPair {
    pub g: u32,
    pub body: u32,
    pub e0: u32,
    pub full: bool,
}

/// An outline cell near a ring's bead chain: the creature, the cell, the ring, the ring's
/// edge nearest it (last found) and whether it started the frame inside the ring.
#[derive(Clone, Copy, Debug)]
pub struct CellPair {
    pub body: u32,
    pub cell: u32,
    pub ring: u32,
    pub e0: u32,
    pub full: bool,
}

#[derive(Default)]
pub struct Ghosts {
    /// A kernel's rings are coupled (else none of this runs).
    pub on: bool,
    /// How far a touched ring's change of velocity is drawn toward its rigid part (its mean
    /// and turn) per substep (0..1).
    pub rigidity: f32,
    /// The kernel's wake thresholds (px, px/s).
    pub wake_depth: f32,
    pub wake_speed: f32,
    pub dt: f32,
    pub rings: Vec<GhostRing>,
    /// Per ghost: the bead's end of the kernel's step and its velocity there.
    pub p_end: Vec<Vector2>,
    pub v0: Vec<Vector2>,
    pub pos: Vec<Vector2>,
    pub prev: Vec<Vector2>,
    pub vel: Vec<Vector2>,
    /// Outline cells near a ring: (creature, cell, ring).
    pub cell_pairs: Vec<CellPair>,
    pub bead_pairs: Vec<BeadPair>,
    /// Per creature this frame: the sign of its outline's winding (0: not computed).
    orient: Vec<f32>,
    /// Per creature this frame: each cell's place on its outline (u32::MAX: inside).
    opos: Vec<Vec<u32>>,
    rmax: Vec<f32>,
    /// Per creature this frame: each cell's contact radius against a ring.
    crad: Vec<Vec<f32>>,
    /// This frame: the deepest overlap a contact found before solving it (px), the
    /// contacts solved (summed over substeps), centres found inside the other's outline.
    pub worst: f32,
    pub contacts: u32,
    pub inside: u32,
    /// Wall-clock µs of this frame's broad phase and substeps (nothing reads it back).
    pub us: u64,
    pub broad_us: u64,
}

/// The nearest point of a closed loop of points to `p`: (edge, t along it, the point, its
/// distance², inside the loop).
fn loop_nearest(pts: &[Vector2], p: Vector2) -> (usize, f32, Vector2, f32, bool) {
    let n = pts.len();
    let mut best = (0usize, 0.0f32, pts[0], f32::INFINITY);
    let mut inside = false;
    for k in 0..n {
        let a = pts[k];
        let b = pts[(k + 1) % n];
        if (a.y > p.y) != (b.y > p.y) && p.x < a.x + (p.y - a.y) * (b.x - a.x) / (b.y - a.y) {
            inside = !inside;
        }
        let ab = b - a;
        let t = (dot(p - a, ab) / len_sq(ab).max(1e-9)).clamp(0.0, 1.0);
        let q = a + ab * t;
        let d2 = len_sq(p - q);
        if d2 < best.3 {
            best = (k, t, q, d2);
        }
    }
    (best.0, best.1, best.2, best.3, inside)
}

#[inline]
fn contact_radius(b: &Body, i: usize, opt: &Opt) -> f32 {
    let r = b.r[i];
    let pad = if b.boundary[i] { opt.contact_pad * r } else { 0.0 };
    r + pad + opt.types[b.typ[i] as usize].pad
}

/// Creature b's outline edge e: its two cells, the closest point to p, t, the radius there.
#[inline]
fn outline_edge(b: &Body, crad: &[f32], e: usize, p: Vector2) -> (usize, usize, f32, Vector2, f32) {
    let m = b.outline.len();
    let (i, j) = (b.outline[e % m] as usize, b.outline[(e + 1) % m] as usize);
    let (a, c) = (b.pos[i], b.pos[j]);
    let ab = c - a;
    let t = (dot(p - a, ab) / len_sq(ab).max(1e-9)).clamp(0.0, 1.0);
    let (ri, rj) = (crad[i], crad[j]);
    (i, j, t, a + ab * t, ri + (rj - ri) * t)
}

/// The outward normal of creature b's outline edge e (unit; `orient` the winding's sign).
#[inline]
fn outline_normal(b: &Body, e: usize, orient: f32) -> Vector2 {
    let m = b.outline.len();
    let d = b.pos[b.outline[(e + 1) % m] as usize] - b.pos[b.outline[e % m] as usize];
    let n = Vector2::new(d.y, -d.x) * orient;
    let l = len_sq(n).sqrt();
    if l > 1e-9 { n / l } else { Vector2::ZERO }
}

/// Whether `q` is inside creature b's outline, judged at its edge e (the nearest): the
/// edge's outward normal, or at a corner the two edges' normals together (the pseudo-normal).
fn outline_inside(b: &Body, crad: &[f32], e: usize, q: Vector2, orient: f32) -> bool {
    let ml = b.outline.len();
    let (_, _, t, cp, _) = outline_edge(b, crad, e, q);
    let mut pn = outline_normal(b, e, orient);
    if t <= 0.0 {
        pn += outline_normal(b, (e + ml - 1) % ml, orient);
    } else if t >= 1.0 {
        pn += outline_normal(b, (e + 1) % ml, orient);
    }
    dot(q - cp, pn) < 0.0
}

fn winding_sign(b: &Body) -> f32 {
    let m = b.outline.len();
    let mut s = 0.0f64;
    for k in 0..m {
        let p = b.pos[b.outline[k] as usize];
        let q = b.pos[b.outline[(k + 1) % m] as usize];
        s += cross(p, q) as f64;
    }
    if s >= 0.0 { 1.0 } else { -1.0 }
}

impl Ghosts {
    /// Starts a frame's gather: no rings.
    pub fn begin(&mut self, dt: f32) {
        self.dt = dt;
        self.rings.clear();
        self.p_end.clear();
        self.v0.clear();
    }

    /// Adds a ring: its key, its first particle in the kernel, its beads' positions and
    /// velocities at the end of the kernel's step, its mass (in the cells' units), its
    /// bead radius, settled or not.
    pub fn add_ring(&mut self, key: i64, start: usize, points: &[Vector2], velocities: &[Vector2], mass: f32, br: f32, settled: bool) {
        let n = points.len();
        if n < 3 || velocities.len() != n {
            return;
        }
        let g0 = self.p_end.len();
        let mut lo = Vector2::new(f32::INFINITY, f32::INFINITY);
        let mut hi = -lo;
        let mut vmax = 0.0f32;
        for k in 0..n {
            let v = if settled { Vector2::ZERO } else { velocities[k] };
            let p = points[k];
            let q = p - v * self.dt;
            lo = Vector2::new(lo.x.min(p.x).min(q.x), lo.y.min(p.y).min(q.y));
            hi = Vector2::new(hi.x.max(p.x).max(q.x), hi.y.max(p.y).max(q.y));
            vmax = vmax.max(len_sq(v));
            self.p_end.push(p);
            self.v0.push(v);
        }
        let w = if settled || mass <= 0.0 { 0.0 } else { n as f32 / mass };
        self.rings.push(GhostRing { key, start: start as u32, g0: g0 as u32, n: n as u32, w, br, settled, lo, hi, vmax: vmax.sqrt(), ..Default::default() });
    }

    /// The candidate pairs for this frame (after the cells' prepare: their boxes and speeds
    /// are this frame's), and every ghost at its path's start.
    pub fn broad(&mut self, bodies: &[Body], opt: &Opt, dt: f32, cell: f32) {
        let clock = std::time::Instant::now();
        let mut near: Vec<u32> = Vec::new();
        if self.opos.len() < bodies.len() {
            self.opos.resize(bodies.len(), Vec::new());
            self.crad.resize(bodies.len(), Vec::new());
        }
        self.cell_pairs.clear();
        self.bead_pairs.clear();
        self.worst = 0.0;
        self.contacts = 0;
        self.inside = 0;
        self.orient.clear();
        self.orient.resize(bodies.len(), 0.0);
        self.rmax.clear();
        self.rmax.resize(bodies.len(), 0.0);
        let total = self.p_end.len();
        self.pos.clear();
        self.vel.clear();
        for k in 0..total {
            self.pos.push(self.p_end[k] - self.v0[k] * dt);
            self.vel.push(self.v0[k]);
        }
        self.prev.clear();
        self.prev.extend_from_slice(&self.pos);
        let mut loop_pts: Vec<Vector2> = Vec::new();
        for ri in 0..self.rings.len() {
            let ring = self.rings[ri];
            let (g0, n) = (ring.g0 as usize, ring.n as usize);
            loop_pts.clear();
            loop_pts.extend_from_slice(&self.pos[g0..g0 + n]);
            let mut active = false;
            for (bi, b) in bodies.iter().enumerate() {
                if !b.alive || b.n == 0 {
                    continue;
                }
                let m = opt.margin + (b.vmax + ring.vmax) * dt;
                let grow = ring.br + m;
                if ring.hi.x + grow < b.lo.x || b.hi.x + grow < ring.lo.x || ring.hi.y + grow < b.lo.y || b.hi.y + grow < ring.lo.y {
                    continue;
                }
                if self.orient[bi] == 0.0 {
                    self.orient[bi] = winding_sign(b);
                    self.rmax[bi] = b.r.iter().cloned().fold(0.0f32, f32::max) * (1.0 + opt.contact_pad) + 16.0 * opt.contact_pad;
                    // Each cell's place on the outline (u32::MAX: not on it) and its contact
                    // radius this frame.
                    let opos = &mut self.opos[bi];
                    opos.clear();
                    opos.resize(b.n, u32::MAX);
                    for (e, &c) in b.outline.iter().enumerate() {
                        if opos[c as usize] == u32::MAX {
                            opos[c as usize] = e as u32;
                        }
                    }
                    let crad = &mut self.crad[bi];
                    crad.clear();
                    crad.extend((0..b.n).map(|c| contact_radius(b, c, opt)));
                }
                let crad = &self.crad[bi][..];
                let orient = self.orient[bi];
                let rmax = self.rmax[bi];
                // The creature's colliders near the ring (its colliders' grid, over the
                // ring's box grown by a contact's reach and an outline edge).
                let pad = grow + 3.0 * rmax;
                let (qlo, qhi) = (
                    Vector2::new((ring.lo.x - pad).max(b.lo.x), (ring.lo.y - pad).max(b.lo.y)),
                    Vector2::new((ring.hi.x + pad).min(b.hi.x), (ring.hi.y + pad).min(b.hi.y)),
                );
                near.clear();
                let (k0, k1) = (key(qlo.x, qlo.y, cell), key(qhi.x, qhi.y, cell));
                let mut cx = k0.0 + 1;
                while cx - 1 <= k1.0 {
                    let mut cy = k0.1 + 1;
                    while cy - 1 <= k1.1 {
                        grid_query(&b.grid, (cx, cy), &mut near);
                        cy += 3;
                    }
                    cx += 3;
                }
                // Outline cells near the ring's bead chain (or inside its loop).
                for &o in near.iter() {
                    let c = b.colliders[o as usize] as usize;
                    if !opt.types[b.typ[c] as usize].collide {
                        continue;
                    }
                    let p = b.pos[c];
                    let reach = contact_radius(b, c, opt) + grow;
                    if p.x + reach < ring.lo.x || p.x - reach > ring.hi.x || p.y + reach < ring.lo.y || p.y - reach > ring.hi.y {
                        continue;
                    }
                    let (k, _, _, d2, inside) = loop_nearest(&loop_pts, p);
                    if inside || d2 < reach * reach {
                        self.cell_pairs.push(CellPair { body: bi as u32, cell: c as u32, ring: ri as u32, e0: k as u32, full: inside });
                        active = true;
                    }
                }
                // Beads near the creature's outline (or inside it).
                let ml = b.outline.len();
                if ml < 3 {
                    continue;
                }
                let near_box = ring.br + m + rmax;
                let near_cell = near_box + 2.0 * rmax;
                for k in 0..n {
                    let q = self.pos[g0 + k];
                    if q.x + near_box < b.lo.x || q.x - near_box > b.hi.x || q.y + near_box < b.lo.y || q.y - near_box > b.hi.y {
                        continue;
                    }
                    // The outline edges at the outline cells near the bead: the one whose
                    // capsule it is deepest in.
                    let mut best = (usize::MAX, f32::INFINITY);
                    for &o in near.iter() {
                        let c = b.colliders[o as usize] as usize;
                        let e = self.opos[bi][c];
                        if e == u32::MAX || len_sq(b.pos[c] - q) > near_cell * near_cell {
                            continue;
                        }
                        for ee in [e as usize, (e as usize + ml - 1) % ml] {
                            let (_, _, _, cp, rr) = outline_edge(b, crad, ee, q);
                            let gap = len_sq(q - cp).sqrt() - rr;
                            if gap < best.1 || (gap == best.1 && ee < best.0) {
                                best = (ee, gap);
                            }
                        }
                    }
                    let (inside, e0) = if best.0 != usize::MAX {
                        (outline_inside(b, crad, best.0, q, orient), best.0)
                    } else {
                        // No outline cell near: far outside, or deep inside.
                        let mut inside = false;
                        for e in 0..ml {
                            let (a, c) = (b.pos[b.outline[e] as usize], b.pos[b.outline[(e + 1) % ml] as usize]);
                            if (a.y > q.y) != (c.y > q.y) && q.x < a.x + (q.y - a.y) * (c.x - a.x) / (c.y - a.y) {
                                inside = !inside;
                            }
                        }
                        (inside, 0)
                    };
                    if inside || best.1 < ring.br + m {
                        self.bead_pairs.push(BeadPair { g: (g0 + k) as u32, body: bi as u32, e0: e0 as u32, full: inside });
                        active = true;
                    }
                }
            }
            let r = &mut self.rings[ri];
            r.active = active;
            r.touched = false;
            r.wake = false;
        }
        self.us = clock.elapsed().as_micros() as u64;
        self.broad_us = self.us;
    }

    /// One of the cells' substeps (`h` long): the ghosts moved, the contacts solved both
    /// ways, the ghosts kept out of the walls, a touched ring's push spread over it.
    pub fn substep(&mut self, bodies: &mut [Body], opt: &Opt, walls: &[StaticShape], h: f32) {
        if self.cell_pairs.is_empty() && self.bead_pairs.is_empty() {
            return;
        }
        let clock = std::time::Instant::now();
        for r in &self.rings {
            if !r.active {
                continue;
            }
            for k in r.g0 as usize..(r.g0 + r.n) as usize {
                self.prev[k] = self.pos[k];
                self.pos[k] += self.vel[k] * h;
            }
        }
        // Cells against the rings' bead chains.
        for x in 0..self.cell_pairs.len() {
            let cp = self.cell_pairs[x];
            let (bi, c, ri) = (cp.body, cp.cell, cp.ring);
            let ring = self.rings[ri as usize];
            let (g0, n) = (ring.g0 as usize, ring.n as usize);
            let loop_pts = &self.pos[g0..g0 + n];
            let b = &mut bodies[bi as usize];
            let c = c as usize;
            let p = b.pos[c];
            let rc = contact_radius(b, c, opt);
            // Every edge of the loop, and the side by its winding: a dented or folded loop
            // misleads a local test (measured: a ring of free beads let a blob in).
            let (k, t, q, d2, inside) = loop_nearest(loop_pts, p);
            self.cell_pairs[x].e0 = k as u32;
            let (ea, eb) = (loop_pts[k], loop_pts[(k + 1) % n]);
            let reach = rc + ring.br;
            if !inside && d2 >= reach * reach {
                continue;
            }
            let d = d2.sqrt();
            let (nrm, pen) = if inside {
                // Out across the nearest edge: toward q, then a contact's reach beyond it.
                let nrm = if d > 1e-6 { (q - p) / d } else { -edge_left(ea, eb) };
                self.inside += 1;
                (nrm, d + reach)
            } else {
                let nrm = if d > 1e-6 { (p - q) / d } else { edge_left(ea, eb) };
                (nrm, reach - d)
            };
            let (ga, gb) = (g0 + k, g0 + (k + 1) % n);
            let wc = b.w[c];
            let we = (1.0 - t) * (1.0 - t) * ring.w + t * t * ring.w;
            if wc + we <= 0.0 {
                continue;
            }
            self.worst = self.worst.max(pen);
            self.contacts += 1;
            let dl = pen / (wc + we);
            b.pos[c] = p + nrm * (dl * wc);
            self.pos[ga] -= nrm * (dl * (1.0 - t) * ring.w);
            self.pos[gb] -= nrm * (dl * t * ring.w);
            b.contact = true;
            if b.records() {
                b.touch(c, crate::cells::TOUCH_RING, ring.key, nrm);
            }
            self.note_touch(ri as usize, pen, dot(b.vel[c] - self.vel[ga], -nrm));
        }
        // Beads against the creatures' outlines.
        let crads = std::mem::take(&mut self.crad);
        for x in 0..self.bead_pairs.len() {
            let bp = self.bead_pairs[x];
            let gi = bp.g as usize;
            let ri = self.ring_of(gi);
            let ring = self.rings[ri];
            let b = &mut bodies[bp.body as usize];
            let crad = &crads[bp.body as usize][..];
            let ml = b.outline.len();
            if ml < 3 {
                continue;
            }
            let orient = self.orient[bp.body as usize];
            let q = self.pos[gi];
            // The edge whose capsule the bead is deepest in (or nearest).
            let mut best = (0usize, f32::INFINITY);
            let mut inside = false;
            if bp.full {
                for e in 0..ml {
                    let (i, j, _, cp, rr) = outline_edge(b, crad, e, q);
                    let (a, c) = (b.pos[i], b.pos[j]);
                    if (a.y > q.y) != (c.y > q.y) && q.x < a.x + (q.y - a.y) * (c.x - a.x) / (c.y - a.y) {
                        inside = !inside;
                    }
                    let gap = len_sq(q - cp).sqrt() - rr;
                    if gap < best.1 {
                        best = (e, gap);
                    }
                }
            } else {
                for o in -WINDOW..=WINDOW {
                    let e = (bp.e0 as i32 + o).rem_euclid(ml as i32) as usize;
                    let (_, _, _, cp, rr) = outline_edge(b, crad, e, q);
                    let gap = len_sq(q - cp).sqrt() - rr;
                    if gap < best.1 {
                        best = (e, gap);
                    }
                }
            }
            let e = best.0;
            self.bead_pairs[x].e0 = e as u32;
            let (i, j, t, cp, rr) = outline_edge(b, crad, e, q);
            if !bp.full {
                inside = outline_inside(b, crad, e, q, orient);
            }
            let reach = rr + ring.br;
            let d = len_sq(q - cp).sqrt();
            if !inside && d >= reach {
                continue;
            }
            let (nrm, pen) = if inside {
                let nrm = if d > 1e-6 { (cp - q) / d } else { outline_normal(b, e, orient) };
                self.inside += 1;
                (nrm, d + reach)
            } else {
                let nrm = if d > 1e-6 { (q - cp) / d } else { outline_normal(b, e, orient) };
                (nrm, reach - d)
            };
            let (wi, wj) = (b.w[i], b.w[j]);
            let we = (1.0 - t) * (1.0 - t) * wi + t * t * wj;
            if ring.w + we <= 0.0 {
                continue;
            }
            self.worst = self.worst.max(pen);
            self.contacts += 1;
            let dl = pen / (ring.w + we);
            self.pos[gi] = q + nrm * (dl * ring.w);
            b.pos[i] -= nrm * (dl * (1.0 - t) * wi);
            b.pos[j] -= nrm * (dl * t * wj);
            b.contact = true;
            if b.records() {
                b.touch(if t < 0.5 { i } else { j }, crate::cells::TOUCH_RING, ring.key, -nrm);
            }
            let vc = b.vel[i] * (1.0 - t) + b.vel[j] * t;
            let vg = self.vel[gi];
            self.note_touch(ri, pen, dot(vc - vg, nrm));
        }
        self.crad = crads;
        // The ghosts kept out of the walls (as the kernel keeps their beads): a bead pressed
        // between a cell and a wall stays out of the wall here, not just next frame. Moving
        // obstacles (obstacles.rs) are left out: the ring's own kernel resolves its beads
        // against them with their reaction, and a push here would give a ghost momentum no
        // obstacle answers (4 % of a ring, a creature and a crate's momentum, measured).
        if !walls.is_empty() {
            for r in &self.rings {
                if !r.active || r.settled {
                    continue;
                }
                for k in r.g0 as usize..(r.g0 + r.n) as usize {
                    let mut at = self.pos[k];
                    for w in walls {
                        if w.dynamic || !w.aabb.grow(r.br).has_point(at) {
                            continue;
                        }
                        if let Some((gap, dir)) = w.gap(at, r.br, 0.0) {
                            if gap < 0.0 {
                                at += dir * -gap;
                            }
                        }
                    }
                    self.pos[k] = at;
                }
            }
        }
        let ih = 1.0 / h;
        let kr = self.rigidity;
        for r in &self.rings {
            if !r.active || r.settled {
                continue;
            }
            let (g0, n) = (r.g0 as usize, r.n as usize);
            for k in g0..g0 + n {
                self.vel[k] = (self.pos[k] - self.prev[k]) * ih;
            }
            if kr <= 0.0 || !r.touched {
                continue;
            }
            // The ring answers a push as a whole: the change of its beads' velocities
            // against their unperturbed ones is drawn toward its rigid part (the mean
            // and the turn about the centre), keeping its momentum and angular momentum
            // and leaving the dent where it is (the ring's own elasticity, in the kernel,
            // undoes it).
            let mut c = Vector2::ZERO;
            let mut dv = Vector2::ZERO;
            for k in g0..g0 + n {
                c += self.pos[k];
                dv += self.vel[k] - self.v0[k];
            }
            c /= n as f32;
            dv /= n as f32;
            let (mut l, mut i) = (0.0f32, 0.0f32);
            for k in g0..g0 + n {
                let rr = self.pos[k] - c;
                l += cross(rr, self.vel[k] - self.v0[k] - dv);
                i += len_sq(rr);
            }
            let om = if i > 1e-9 { l / i } else { 0.0 };
            for k in g0..g0 + n {
                let rr = self.pos[k] - c;
                let rigid = dv + Vector2::new(-rr.y, rr.x) * om;
                let d = self.vel[k] - self.v0[k];
                let v = self.v0[k] + d + (rigid - d) * kr;
                self.vel[k] = v;
                self.pos[k] = self.prev[k] + v * h;
            }
        }
        self.us += clock.elapsed().as_micros() as u64;
    }

    fn ring_of(&self, g: usize) -> usize {
        // Rings are in ghost order: a binary search by first ghost.
        match self.rings.binary_search_by(|r| (r.g0 as usize).cmp(&g)) {
            Ok(i) => i,
            Err(i) => i - 1,
        }
    }

    fn note_touch(&mut self, ri: usize, pen: f32, closing: f32) {
        let wd = self.wake_depth;
        let ws = self.wake_speed;
        let r = &mut self.rings[ri];
        r.touched = true;
        if r.settled && (pen > wd || closing > ws) {
            r.wake = true;
        }
    }

    /// Each touched ring's change, added to its beads in `k` (see the module docs).
    pub fn apply(&self, k: &mut Kernel) {
        for r in &self.rings {
            if !r.touched {
                continue;
            }
            let Some(idx) = k.find(r.key) else { continue };
            if k.rings[idx].start != r.start as usize || k.rings[idx].n != r.n as usize {
                continue;
            }
            if r.settled {
                if r.wake {
                    k.wake(idx, true);
                }
                continue;
            }
            let start = r.start as usize;
            for j in 0..r.n as usize {
                let g = r.g0 as usize + j;
                let dp = self.pos[g] - self.p_end[g];
                let dv = self.vel[g] - self.v0[g];
                let pi = start + j;
                k.ps.pos[pi] += dp;
                k.ps.prev[pi] += dp;
                k.ps.vel[pi] = k.solver.capped(k.ps.vel[pi] + dv);
            }
            let ring = &mut k.rings[idx];
            ring.points.copy_from_slice(&k.ps.pos[start..start + ring.n]);
            ring.velocities.copy_from_slice(&k.ps.vel[start..start + ring.n]);
            ring.center = centroid(&ring.points);
            ring.bounds = Rect::of_points(&ring.points);
            ring.calm_time = 0.0;
        }
    }

    /// Every ring of `k`, as gather() takes them: its mass its target area × `density`.
    pub fn gather_kernel(&mut self, k: &Kernel, density: f32, dt: f32) {
        self.begin(dt);
        self.wake_depth = k.solver.wake_depth;
        self.wake_speed = k.solver.wake_speed;
        for r in &k.rings {
            let range = r.start..r.start + r.n;
            let mass = (r.target_area.max(0.0) as f32) * density;
            self.add_ring(r.key, r.start, &k.ps.pos[range.clone()], &k.ps.vel[range], mass, r.p.bead_radius as f32, r.settled);
        }
    }

    /// The touched rings' count this frame.
    pub fn touched_rings(&self) -> usize {
        self.rings.iter().filter(|r| r.touched).count()
    }

    /// Sum of mass × velocity of the ghosts of touched, awake rings (their masses from
    /// w), against their unperturbed sum: the momentum the cells handed the rings.
    pub fn momentum_given(&self) -> Vector2 {
        let mut p = Vector2::ZERO;
        for r in &self.rings {
            if !r.touched || r.settled || r.w <= 0.0 {
                continue;
            }
            for g in r.g0 as usize..(r.g0 + r.n) as usize {
                p += (self.vel[g] - self.v0[g]) / r.w;
            }
        }
        p
    }
}

/// The unit normal to the left of a → b.
#[inline]
fn edge_left(a: Vector2, b: Vector2) -> Vector2 {
    let d = b - a;
    let n = Vector2::new(-d.y, d.x);
    let l = len_sq(n).sqrt();
    if l > 1e-9 { n / l } else { Vector2::new(0.0, -1.0) }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cells::{hex_design, Cells};

    fn circle(c: Vector2, r: f32, n: usize) -> Vec<Vector2> {
        (0..n).map(|k| c + Vector2::from_angle(std::f32::consts::TAU * k as f32 / n as f32) * r).collect()
    }

    /// A ring of free beads (no ring constraints between frames: what the cells see of a
    /// ring within one frame, its changes applied by hand) and a blob, thrown together.
    struct Scene {
        cl: Cells,
        pts: Vec<Vector2>,
        vel: Vec<Vector2>,
        mass: f32,
    }

    impl Scene {
        fn new(threads: usize, speed: f32) -> Scene {
            let mut cl = Cells::default();
            cl.set_threads(threads);
            cl.opt.drag.enabled = false;
            let r = 7.0;
            let cells = hex_design(2, r, Vector2::new(90.0, 3.0));
            let n = cells.len();
            cl.add_creature(&cells, &vec![r; n], &vec![0u8; n]);
            for v in cl.bodies[0].vel.iter_mut() {
                *v = Vector2::new(-speed, 0.0);
            }
            cl.ghosts.on = true;
            cl.ghosts.rigidity = 0.15;
            cl.ghosts.wake_depth = 0.5;
            cl.ghosts.wake_speed = 30.0;
            let pts = circle(Vector2::ZERO, 20.0, 16);
            let vel = vec![Vector2::new(speed, 0.0); 16];
            Scene { cl, pts, vel, mass: std::f32::consts::PI * 400.0 }
        }

        fn frame(&mut self) {
            let dt = 1.0 / 60.0;
            for (p, v) in self.pts.iter_mut().zip(&self.vel) {
                *p += *v * dt;
            }
            self.cl.ghosts.begin(dt);
            self.cl.ghosts.add_ring(1, 0, &self.pts, &self.vel, self.mass, 2.4, false);
            self.cl.step(dt);
            let g = &self.cl.ghosts;
            if g.rings[0].touched {
                for k in 0..16 {
                    self.pts[k] += g.pos[k] - g.p_end[k];
                    self.vel[k] += g.vel[k] - g.v0[k];
                }
            }
        }

        fn momentum(&self) -> Vector2 {
            let b = &self.cl.bodies[0];
            let mut p = Vector2::ZERO;
            for i in 0..b.n {
                p += b.vel[i] * b.mass[i];
            }
            for v in &self.vel {
                p += *v * (self.mass / 16.0);
            }
            p
        }

        fn cells_inside(&self) -> usize {
            self.cl.bodies[0].pos.iter().filter(|&&p| crate::geom::point_in_polygon(p, &self.pts)).count()
        }
    }

    #[test]
    fn a_blob_and_a_ring_of_beads_collide_keeping_momentum() {
        for speed in [300.0f32, 600.0] {
            let mut s = Scene::new(1, speed);
            let p0 = s.momentum();
            let mut inside = 0;
            let mut touched = 0;
            for _ in 0..40 {
                s.frame();
                inside = inside.max(s.cells_inside());
                touched += s.cl.ghosts.rings[0].touched as usize;
            }
            let p1 = s.momentum();
            let scale = speed * (s.mass + s.cl.bodies[0].total_mass());
            println!("{} px/s: momentum {:?} -> {:?}, inside {}, frames touching {}", speed, p0, p1, inside, touched);
            assert!(touched > 0);
            assert_eq!(inside, 0);
            assert!((p1 - p0).length() < 1e-3 * scale, "momentum {:?} -> {:?}", p0, p1);
            // They no longer close on each other.
            let vb = s.cl.bodies[0].velocity();
            let vr = s.vel.iter().fold(Vector2::ZERO, |a, &v| a + v) / 16.0;
            assert!(vb.x >= vr.x - 1.0, "blob {:?}, ring {:?}", vb, vr);
        }
    }

    #[test]
    fn threaded_equals_serial_with_rings() {
        let mut a = Scene::new(1, 500.0);
        let mut b = Scene::new(4, 500.0);
        for _ in 0..40 {
            a.frame();
            b.frame();
        }
        assert_eq!(a.cl.state_hash(), b.cl.state_hash());
        assert_eq!(a.pts, b.pts);
    }

    #[test]
    fn a_bead_inside_a_creature_is_pushed_out() {
        let mut cl = Cells::default();
        cl.opt.drag.enabled = false;
        let r = 7.0;
        let cells = hex_design(3, r, Vector2::ZERO);
        let n = cells.len();
        cl.add_creature(&cells, &vec![r; n], &vec![0u8; n]);
        cl.ghosts.on = true;
        // A ring whose beads all sit inside the blob, between its cells.
        let pts = circle(Vector2::new(3.0, 2.0), 12.0, 12);
        let vel = vec![Vector2::ZERO; 12];
        let mut pts_now = pts.clone();
        let mut vel_now = vel.clone();
        for _ in 0..60 {
            cl.ghosts.begin(1.0 / 60.0);
            cl.ghosts.add_ring(1, 0, &pts_now, &vel_now, 400.0, 2.0, false);
            cl.step(1.0 / 60.0);
            let g = &cl.ghosts;
            for k in 0..12 {
                pts_now[k] += g.pos[k] - g.p_end[k];
                vel_now[k] += g.vel[k] - g.v0[k];
                vel_now[k] *= 0.9;
            }
        }
        let b = &cl.bodies[0];
        let outline: Vec<Vector2> = b.outline.iter().map(|&c| b.pos[c as usize]).collect();
        let inside = pts_now.iter().filter(|&&p| crate::geom::point_in_polygon(p, &outline)).count();
        println!("beads inside after 1 s: {}", inside);
        assert_eq!(inside, 0);
    }

    #[test]
    fn an_awake_ring_is_pushed_and_a_settled_one_woken() {
        // (Kernel::add_ring() needs Godot, so the kernel side, apply(), is tested from
        // GDScript: tests/integration/test_goo_ring_cells.gd.)
        let pts = circle(Vector2::ZERO, 20.0, 12);
        let mut cl = Cells::default();
        cl.opt.drag.enabled = false;
        let cells = hex_design(1, 7.0, Vector2::new(42.0, 0.0));
        cl.add_creature(&cells, &vec![7.0; 7], &vec![0u8; 7]);
        cl.ghosts.on = true;
        cl.ghosts.rigidity = 0.15;
        cl.ghosts.wake_depth = 0.5;
        cl.ghosts.wake_speed = 30.0;
        let still = vec![Vector2::ZERO; 12];
        cl.ghosts.begin(1.0 / 60.0);
        cl.ghosts.add_ring(7, 0, &pts, &still, 1200.0, 2.4, false);
        cl.step(1.0 / 60.0);
        let g = &cl.ghosts;
        assert!(g.rings[0].touched && !g.rings[0].wake);
        assert!(g.vel[0].x < 0.0, "the facing bead pushed away: {:?}", g.vel[0]);
        assert!(g.momentum_given().x < 0.0);
        // Settled: immovable (the blob takes the whole push), woken by a fast blob.
        for v in cl.bodies[0].vel.iter_mut() {
            *v = Vector2::new(-200.0, 0.0);
        }
        cl.ghosts.begin(1.0 / 60.0);
        cl.ghosts.add_ring(7, 0, &pts, &still, 1200.0, 2.4, true);
        cl.step(1.0 / 60.0);
        let g = &cl.ghosts;
        assert_eq!(g.pos[..12].to_vec(), pts, "a settled ring does not move");
        assert!(g.rings[0].touched && g.rings[0].wake, "woken");
        assert!(cl.bodies[0].velocity().x > -200.0, "the blob was stopped");
    }
}
