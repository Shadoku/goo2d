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
//!    weighted by inverse mass (both sides move), the touched rings are pulled toward a
//!    rigid fit of their unperturbed path (`rigidity`: within one frame a ring answers a
//!    push as a whole, not bead by bead), and the ghosts' velocities follow their moves.
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

use crate::cells::{Body, Opt};
use crate::geom::{centroid, cross, dot, len_sq, Rect};
use crate::kernel::Kernel;
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

#[derive(Default)]
pub struct Ghosts {
    /// A kernel's rings are coupled (else none of this runs).
    pub on: bool,
    /// The pull of a touched ring toward a rigid fit of its unperturbed path, per substep
    /// (0..1).
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
    pub cell_pairs: Vec<[u32; 3]>,
    pub bead_pairs: Vec<BeadPair>,
    /// Per creature this frame: the sign of its outline's winding (0: not computed).
    orient: Vec<f32>,
    /// This frame: the deepest overlap a contact found before solving it (px), the
    /// contacts solved (summed over substeps), centres found inside the other's outline.
    pub worst: f32,
    pub contacts: u32,
    pub inside: u32,
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
fn outline_edge(b: &Body, opt: &Opt, e: usize, p: Vector2) -> (usize, usize, f32, Vector2, f32) {
    let m = b.outline.len();
    let (i, j) = (b.outline[e % m] as usize, b.outline[(e + 1) % m] as usize);
    let (a, c) = (b.pos[i], b.pos[j]);
    let ab = c - a;
    let t = (dot(p - a, ab) / len_sq(ab).max(1e-9)).clamp(0.0, 1.0);
    let ri = contact_radius(b, i, opt);
    let rj = contact_radius(b, j, opt);
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
    pub fn broad(&mut self, bodies: &[Body], opt: &Opt, dt: f32) {
        self.cell_pairs.clear();
        self.bead_pairs.clear();
        self.worst = 0.0;
        self.contacts = 0;
        self.inside = 0;
        self.orient.clear();
        self.orient.resize(bodies.len(), 0.0);
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
                // Outline cells near the ring's bead chain (or inside its loop).
                for &c in &b.colliders {
                    let c = c as usize;
                    if !opt.types[b.typ[c] as usize].collide {
                        continue;
                    }
                    let p = b.pos[c];
                    let reach = contact_radius(b, c, opt) + grow;
                    if p.x + reach < ring.lo.x || p.x - reach > ring.hi.x || p.y + reach < ring.lo.y || p.y - reach > ring.hi.y {
                        continue;
                    }
                    let (_, _, _, d2, inside) = loop_nearest(&loop_pts, p);
                    if inside || d2 < reach * reach {
                        self.cell_pairs.push([bi as u32, c as u32, ri as u32]);
                        active = true;
                    }
                }
                // Beads near the creature's outline (or inside it).
                let ml = b.outline.len();
                if ml < 3 {
                    continue;
                }
                if self.orient[bi] == 0.0 {
                    self.orient[bi] = winding_sign(b);
                }
                let rmax = b.r.iter().cloned().fold(0.0f32, f32::max) * (1.0 + opt.contact_pad) + 16.0 * opt.contact_pad;
                let near = ring.br + m + rmax;
                for k in 0..n {
                    let q = self.pos[g0 + k];
                    if q.x + near < b.lo.x || q.x - near > b.hi.x || q.y + near < b.lo.y || q.y - near > b.hi.y {
                        continue;
                    }
                    let mut inside = false;
                    let mut best = (0usize, f32::INFINITY);
                    for e in 0..ml {
                        let (i, j, _, cp, rr) = outline_edge(b, opt, e, q);
                        let (a, c) = (b.pos[i], b.pos[j]);
                        if (a.y > q.y) != (c.y > q.y) && q.x < a.x + (q.y - a.y) * (c.x - a.x) / (c.y - a.y) {
                            inside = !inside;
                        }
                        let gap = len_sq(q - cp).sqrt() - rr;
                        if gap < best.1 {
                            best = (e, gap);
                        }
                    }
                    if inside || best.1 < ring.br + m {
                        self.bead_pairs.push(BeadPair { g: (g0 + k) as u32, body: bi as u32, e0: best.0 as u32, full: inside });
                        active = true;
                    }
                }
            }
            let r = &mut self.rings[ri];
            r.active = active;
            r.touched = false;
            r.wake = false;
        }
    }

    /// One of the cells' substeps (`s` of them so far, each `h` long): the ghosts moved,
    /// the contacts solved both ways, the touched rings held to their shape.
    pub fn substep(&mut self, bodies: &mut [Body], opt: &Opt, h: f32, s: usize) {
        if self.cell_pairs.is_empty() && self.bead_pairs.is_empty() {
            return;
        }
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
            let [bi, c, ri] = self.cell_pairs[x];
            let ring = self.rings[ri as usize];
            let (g0, n) = (ring.g0 as usize, ring.n as usize);
            let loop_pts = &self.pos[g0..g0 + n];
            let b = &mut bodies[bi as usize];
            let c = c as usize;
            let p = b.pos[c];
            let rc = contact_radius(b, c, opt);
            let (k, t, q, d2, inside) = loop_nearest(loop_pts, p);
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
            self.note_touch(ri as usize, pen, dot(b.vel[c] - self.vel[ga], -nrm));
        }
        // Beads against the creatures' outlines.
        for x in 0..self.bead_pairs.len() {
            let bp = self.bead_pairs[x];
            let gi = bp.g as usize;
            let ri = self.ring_of(gi);
            let ring = self.rings[ri];
            let b = &mut bodies[bp.body as usize];
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
                    let (i, j, _, cp, rr) = outline_edge(b, opt, e, q);
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
                    let (_, _, _, cp, rr) = outline_edge(b, opt, e, q);
                    let gap = len_sq(q - cp).sqrt() - rr;
                    if gap < best.1 {
                        best = (e, gap);
                    }
                }
            }
            let e = best.0;
            self.bead_pairs[x].e0 = e as u32;
            let (i, j, t, cp, rr) = outline_edge(b, opt, e, q);
            if !bp.full {
                // Which side of the outline: the edge's normal, or at a corner the two
                // edges' normals together (the pseudo-normal).
                let mut pn = outline_normal(b, e, orient);
                if t <= 0.0 {
                    pn += outline_normal(b, (e + ml - 1) % ml, orient);
                } else if t >= 1.0 {
                    pn += outline_normal(b, (e + 1) % ml, orient);
                }
                inside = dot(q - cp, pn) < 0.0;
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
            let vc = b.vel[i] * (1.0 - t) + b.vel[j] * t;
            let vg = self.vel[gi];
            self.note_touch(ri, pen, dot(vc - vg, nrm));
        }
        // The touched rings held to their own shape: a rigid fit of where their beads
        // would be without the cells.
        let time = (s + 1) as f32 * h - self.dt;
        if self.rigidity > 0.0 {
            for r in &self.rings {
                if !r.active || r.settled {
                    continue;
                }
                let (g0, n) = (r.g0 as usize, r.n as usize);
                let mut xc = Vector2::ZERO;
                let mut uc = Vector2::ZERO;
                for k in g0..g0 + n {
                    xc += self.pos[k];
                    uc += self.p_end[k] + self.v0[k] * time;
                }
                xc /= n as f32;
                uc /= n as f32;
                let (mut sc, mut ss) = (0.0f32, 0.0f32);
                for k in g0..g0 + n {
                    let u = self.p_end[k] + self.v0[k] * time - uc;
                    let x = self.pos[k] - xc;
                    sc += dot(u, x);
                    ss += cross(u, x);
                }
                let l = (sc * sc + ss * ss).sqrt();
                if l < 1e-9 {
                    continue;
                }
                let (co, si) = (sc / l, ss / l);
                for k in g0..g0 + n {
                    let u = self.p_end[k] + self.v0[k] * time - uc;
                    let goal = xc + Vector2::new(u.x * co - u.y * si, u.x * si + u.y * co);
                    let p = self.pos[k];
                    self.pos[k] = p + (goal - p) * self.rigidity;
                }
            }
        }
        let ih = 1.0 / h;
        for r in &self.rings {
            if !r.active || r.settled {
                continue;
            }
            for k in r.g0 as usize..(r.g0 + r.n) as usize {
                self.vel[k] = (self.pos[k] - self.prev[k]) * ih;
            }
        }
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
