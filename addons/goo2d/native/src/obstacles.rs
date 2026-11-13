//! Godot bodies pushing the goo (docs/godot-physics.md): moving obstacles. A static
//! shape given a target pose every frame (`StaticShape::set_target()`, GooStatics for an
//! AnimatableBody2D, CharacterBody2D or RigidBody2D when a world's `push_bodies` is on)
//! is eased to it over the step's substeps; each substep a bead or cell is judged against
//! it on its motion relative to the shape (its start carried by the shape's own motion),
//! so a body sweeping into the goo pushes it out ahead of itself instead of jumping over
//! it or pushing it out of the far side. Every push Δ of a particle of mass m within a
//! substep h gives that particle the momentum m Δ / h (its velocity is taken from its
//! positions); the shape sums the reaction (`impulse`, `moment`) for the step, which
//! GDScript applies to a RigidBody2D after it. Walls (shapes never given a target) are
//! untouched by any of this.

use crate::cells::{push_out_of_wall, Body, Cells, Hit, Opt};
use crate::geom::*;
use crate::kernel::Kernel;
use crate::statics::StaticShape;
use godot::builtin::Vector2;

/// The impulses of the last step on every moving obstacle: [id, jx, jy, moment] each.
pub fn impulses(statics: &[StaticShape]) -> Vec<f32> {
    let mut out = Vec::new();
    for s in statics.iter().filter(|s| s.dynamic) {
        out.extend_from_slice(&[s.id as f32, s.impulse.x, s.impulse.y, s.moment]);
    }
    out
}

fn begin(statics: &mut [StaticShape]) {
    for s in statics.iter_mut().filter(|s| s.dynamic) {
        s.impulse = Vector2::ZERO;
        s.moment = 0.0;
    }
}

fn substep(statics: &mut [StaticShape], k: usize, n: usize, h: f32) {
    for s in statics.iter_mut().filter(|s| s.dynamic) {
        s.substep(k, n, h);
    }
}

fn end(statics: &mut [StaticShape]) {
    for s in statics.iter_mut().filter(|s| s.dynamic) {
        s.end_step();
    }
}

/// The impulse `j` the goo took at `point` from obstacle `si`: summed as its reaction, and
/// a rigid body's motion changed by it (every shape of that body alike).
fn give(statics: &mut [StaticShape], si: usize, point: Vector2, j: Vector2) {
    statics[si].add_reaction(point, j);
    if !statics[si].rigid {
        return;
    }
    let body = statics[si].body;
    if body == 0 {
        statics[si].take(point, j);
        return;
    }
    for s in statics.iter_mut().filter(|s| s.dynamic && s.rigid && s.body == body) {
        s.take(point, j);
    }
}

/// Coulomb friction of a push, position based: `at` (where the push put a particle that
/// was at `pos`, along the unit normal `n`) moved against its slip along the surface this
/// substep (its motion from `prev` less the surface's, which carried `prev` to
/// `carried`), by at most `mu` times the push's depth.
#[inline]
fn friction(at: Vector2, pos: Vector2, prev: Vector2, carried: Vector2, n: Vector2, mu: f32) -> Vector2 {
    if mu <= 0.0 {
        return at;
    }
    let rel = (at - prev) - (carried - prev);
    let slip = rel - n * dot(rel, n);
    let slip_len = len(slip);
    if slip_len < 1e-7 {
        return at;
    }
    let depth = dot(at - pos, n).abs();
    at - slip * ((mu * depth) / slip_len).min(1.0)
}

/// A contact's normal impulse on a particle of inverse mass `w` approaching an obstacle
/// at `rel` (its normal velocity relative to it; negative: closing) whose inverse mass
/// there is `ws`: an inelastic contact between the two (all of it from a path's obstacle).
#[inline]
fn normal_impulse(rel: f32, w: f32, ws: f32) -> f32 {
    if rel >= 0.0 || w + ws <= 0.0 {
        0.0
    } else {
        -rel / (w + ws)
    }
}

impl Kernel {
    /// The step's start: impulses zeroed, and a settled ring near a moving obstacle woken
    /// (a settled ring's beads are not moved, so it could not be pushed).
    pub(crate) fn begin_dynamic(&mut self) {
        if !self.statics.iter().any(|s| s.dynamic) {
            return;
        }
        begin(&mut self.statics);
        let mut wake = Vec::new();
        for (idx, r) in self.rings.iter().enumerate() {
            if !r.settled {
                continue;
            }
            let reach = 2.0 * r.p.bead_radius as f32 + self.solver.touch_slop;
            if self.statics.iter().any(|s| s.dynamic && (s.sweep > 1e-3 || s.rigid) && s.swept.grow(reach).intersects(&r.bounds)) {
                wake.push(idx);
            }
        }
        for idx in wake {
            self.wake(idx, true);
        }
    }

    /// Before substep `k` of `n`, `h` long: every moving obstacle where it is by that
    /// substep's end.
    pub(crate) fn move_dynamic(&mut self, k: usize, n: usize, h: f32) {
        substep(&mut self.statics, k, n, h);
    }

    /// The step's end: every moving obstacle where it got to.
    pub(crate) fn end_dynamic(&mut self) {
        end(&mut self.statics);
    }

    /// One substep `h` of every awake bead against the moving obstacles: swept along its
    /// motion relative to each (from its start carried by the shape's motion to where it
    /// is), stopped at the first overlap and pushed out of it (with Coulomb friction);
    /// the contact's inelastic impulse between the bead and the obstacle (a rigid body
    /// takes its share at once) summed as the obstacle's reaction, and the bead's normal
    /// velocity set to match in dynamic_velocities().
    pub(crate) fn collide_dynamic(&mut self, h: f32) {
        if h <= 0.0 || !self.statics.iter().any(|s| s.dynamic) {
            return;
        }
        let slop = self.solver.touch_slop;
        let density = self.solver.body_mass_density;
        let inv_h = 1.0 / h;
        for si in 0..self.statics.len() {
            if !self.statics[si].dynamic {
                continue;
            }
            self.statics[si].hits.clear();
            for ri in 0..self.rings.len() {
                let r = &self.rings[ri];
                if r.settled {
                    continue;
                }
                let (start_i, n_i) = (r.start, r.n);
                // Its beads' masses, or its share of its area's mass (body_mass_density).
                let mass = if density > 0.0 && r.n > 0 { (r.target_area.max(0.0) as f32) * density / r.n as f32 } else { r.p.bead_mass as f32 };
                let w = if mass > 0.0 { 1.0 / mass } else { 0.0 };
                let mu = r.p.friction as f32;
                let rad_max = r.p.bead_radius as f32;
                if !self.statics[si].swept.grow(rad_max * 4.0 + slop + 64.0).intersects(&r.bounds) {
                    continue;
                }
                for i in start_i..start_i + n_i {
                    let s = &self.statics[si];
                    let ps = &mut self.ps;
                    let rad = ps.r[i];
                    let start = s.motion * ps.prev[i];
                    let end = ps.pos[i];
                    let reach = Rect::of_points(&[start, end]).grow(rad + slop);
                    if !reach.intersects(&s.aabb) {
                        continue;
                    }
                    let moved = end - start;
                    let travel = len(moved);
                    let samples = if travel > rad { (travel / (0.5 * rad.max(0.1))).ceil().min(64.0) as usize } else { 1 };
                    let mut contact = None;
                    for m in 1..=samples {
                        let q = if samples == 1 { end } else { start + moved * (m as f32 / samples as f32) };
                        if let Some((gap, dir)) = s.gap(q, rad, slop) {
                            if gap < 0.0 {
                                contact = Some((q + dir * -gap, dir));
                                break;
                            }
                        }
                    }
                    let Some((pushed, dir)) = contact else { continue };
                    let pos = ps.pos[i];
                    let at = friction(pushed, pos, ps.prev[i], start, dir, mu.min(s.friction));
                    let point = at - dir * rad;
                    let rel = dot(ps.vel[i] - s.velocity_at(point, inv_h), dir);
                    let jn = normal_impulse(rel, w, s.inv_mass_at(point, dir));
                    let slide = (at - pos) - dir * dot(at - pos, dir);
                    let j = dir * jn + slide * (mass * inv_h);
                    ps.pos[i] = at;
                    // The push adds its depth over h to the velocity taken from the
                    // positions; along n the bead's velocity change is the impulse's.
                    let correction = jn * w - dot(at - pos, dir) * inv_h;
                    self.statics[si].hits.push((i as u32, dir, correction));
                    give(&mut self.statics, si, point, j);
                }
            }
        }
    }

    /// After the substep's velocities came from its positions: along its normal, a bead
    /// a moving obstacle pushed changes velocity by the contact's impulse, not by the
    /// push out of the overlap (which the positions would make a fling of), so its
    /// momentum changes by the impulse counted.
    pub(crate) fn dynamic_velocities(&mut self, _h: f32) {
        let ps = &mut self.ps;
        for s in self.statics.iter().filter(|s| s.dynamic) {
            for &(i, n, correction) in &s.hits {
                ps.vel[i as usize] += n * correction;
            }
        }
    }
}

impl Body {
    /// The cells near a moving obstacle this step (`dyn_c`: cell, wall index), found over
    /// the box the obstacle sweeps; the step's reactions cleared.
    pub(crate) fn prepare_dynamic(&mut self, opt: &Opt, dt: f32, walls: &[StaticShape]) {
        self.dyn_c.clear();
        self.dyn_sub.clear();
        let margin = opt.margin + self.vmax * dt;
        for (wi, w) in walls.iter().enumerate() {
            if !w.dynamic {
                continue;
            }
            let (wlo, whi) = (w.swept.pos, w.swept.pos + w.swept.size);
            if whi.x < self.lo.x - margin || wlo.x > self.hi.x + margin || whi.y < self.lo.y - margin || wlo.y > self.hi.y + margin {
                continue;
            }
            for c in 0..self.n {
                if !opt.types[self.typ[c] as usize].walls {
                    continue;
                }
                let p = self.pos[c];
                let r = self.r[c] + margin;
                if p.x + r < wlo.x || p.x - r > whi.x || p.y + r < wlo.y || p.y - r > whi.y {
                    continue;
                }
                self.dyn_c.push((c as u32, wi as u32));
            }
        }
    }

    /// One substep `h` of its cells against the moving obstacles: out through the face a
    /// cell's centre entered by on its motion relative to the obstacle, or out of any
    /// overlap (with Coulomb friction); the contact's inelastic impulse between the cell
    /// and the obstacle (whose inverse mass is shared among last substep's contacts:
    /// each cell judges its own alone within a substep) set as the cell's velocity change
    /// and kept for the obstacle (`dyn_sub`, given to it after the substep).
    pub(crate) fn solve_dynamic(&mut self, walls: &[StaticShape], h: f32) {
        if self.dyn_c.is_empty() || h <= 0.0 {
            return;
        }
        let inv_h = 1.0 / h;
        for k in 0..self.dyn_c.len() {
            let (c, wi) = self.dyn_c[k];
            let (c, wi) = (c as usize, wi as usize);
            let w = &walls[wi];
            let start = w.motion * self.prev[c];
            let p = push_out_of_wall(w, start, self.pos[c], self.r[c]);
            if p == self.pos[c] {
                continue;
            }
            let n = norm(p - self.pos[c]);
            let p = friction(p, self.pos[c], self.prev[c], start, n, w.friction);
            let point = p - n * self.r[c];
            let rel = dot(self.vel[c] - w.velocity_at(point, inv_h), n);
            let jn = normal_impulse(rel, self.w[c], w.inv_mass_at(point, n) * w.split);
            let delta = p - self.pos[c];
            let slide = delta - n * dot(delta, n);
            let j = n * jn + slide * (self.mass[c] * inv_h);
            // The cell's velocity takes the correction over the substep (finish_substep():
            // (pos − pred) / h): along n it is set to the contact's impulse through pred.
            let excess = dot(delta, n) * inv_h - jn * self.w[c];
            self.pred[c] += n * (excess * h);
            if self.records() {
                let speed = -dot((self.pos[c] - self.prev[c]) * inv_h - w.velocity_at(point, inv_h), n);
                self.touch(c, Hit::thing(crate::cells::TOUCH_OBSTACLE, w.id, n, speed, jn, point));
            }
            self.pos[c] = p;
            self.contact = true;
            self.dyn_sub.push((wi as u32, point, j));
        }
    }

    /// The tips near a moving obstacle this step (`tip_dyn_c`: cell, wall index).
    pub(crate) fn prepare_tips_dynamic(&mut self, opt: &Opt, dt: f32, walls: &[StaticShape]) {
        self.tip_dyn_c.clear();
        if self.tips.is_empty() {
            return;
        }
        let margin = opt.margin + self.tip_vmax * dt;
        for (wi, w) in walls.iter().enumerate() {
            if !w.dynamic {
                continue;
            }
            let (wlo, whi) = (w.swept.pos, w.swept.pos + w.swept.size);
            if whi.x < self.lo.x - margin || wlo.x > self.hi.x + margin || whi.y < self.lo.y - margin || wlo.y > self.hi.y + margin {
                continue;
            }
            for k in 0..self.tips.len() {
                let c = self.tips[k] as usize;
                let tp = &opt.types[self.typ[c] as usize];
                if !tp.walls {
                    continue;
                }
                let (q, rt) = self.tip(tp, c, false);
                let r = rt + margin;
                if q.x + r < wlo.x || q.x - r > whi.x || q.y + r < wlo.y || q.y - r > whi.y {
                    continue;
                }
                self.tip_dyn_c.push((c as u32, wi as u32));
            }
        }
    }

    /// One substep of its tips against the moving obstacles: out through the face the tip
    /// entered by on its motion relative to the obstacle; the push moves the cell and its
    /// neighbours rigidly (it turns them), and the obstacle takes the momentum the push
    /// gives them (the push over h).
    pub(crate) fn solve_tips_dynamic(&mut self, opt: &Opt, walls: &[StaticShape], h: f32) {
        if self.tip_dyn_c.is_empty() || h <= 0.0 {
            return;
        }
        let inv_h = 1.0 / h;
        for k in 0..self.tip_dyn_c.len() {
            let (c, wi) = self.tip_dyn_c[k];
            let (c, wi) = (c as usize, wi as usize);
            let w = &walls[wi];
            let tp = &opt.types[self.typ[c] as usize];
            let (at, rt) = self.tip(tp, c, false);
            let (from, _) = self.tip(tp, c, true);
            let start = w.motion * from;
            let p = push_out_of_wall(w, start, at, rt);
            if p == at {
                continue;
            }
            let d = p - at;
            let dl = len(d);
            if dl < 1e-9 {
                continue;
            }
            let n = d / dl;
            let lam = dl / self.tip_w(c, at, n);
            let point = p - n * rt;
            let speed = -dot((at - from) * inv_h - w.velocity_at(point, inv_h), n);
            self.push_at(c, at, n, lam);
            self.contact = true;
            if self.records() {
                self.touch(c, Hit { tip: crate::cells::TIP_SELF, ..Hit::thing(crate::cells::TOUCH_OBSTACLE, w.id, n, speed, lam * inv_h, point) });
            }
            self.dyn_sub.push((wi as u32, point, n * (lam * inv_h)));
        }
    }
}

impl Cells {
    /// The step's start: the moving obstacles' impulses zeroed.
    pub(crate) fn begin_dynamic(&mut self) {
        begin(&mut self.statics);
    }

    /// Before substep `k` of `n`, `h` long; the last substep's contacts given to their
    /// obstacles first (a rigid body's motion changed by them).
    pub(crate) fn move_dynamic(&mut self, k: usize, n: usize, h: f32) {
        if k > 0 {
            self.give_dynamic();
        }
        substep(&mut self.statics, k, n, h);
    }

    fn give_dynamic(&mut self) {
        for b in self.bodies.iter_mut() {
            if !b.alive || b.dyn_sub.is_empty() {
                continue;
            }
            for &(wi, point, j) in &b.dyn_sub {
                let wi = wi as usize;
                if wi < self.statics.len() {
                    self.statics[wi].split_now += 1.0;
                    give(&mut self.statics, wi, point, j);
                }
            }
            b.dyn_sub.clear();
        }
    }

    /// The step's end: the last contacts given, each obstacle where it got to.
    pub(crate) fn end_dynamic(&mut self) {
        if !self.statics.iter().any(|s| s.dynamic) {
            return;
        }
        self.give_dynamic();
        end(&mut self.statics);
    }
}

// ---- GDScript ----

use crate::{GooCells, GooKernel};
use godot::prelude::*;

#[godot_api(secondary)]
impl GooKernel {
    /// Makes static shape `id` a moving obstacle and gives it the pose it reaches by the
    /// end of the next step (call every frame it may move, before step()). Nothing for an
    /// unknown id.
    #[func]
    fn set_static_target(&mut self, id: i64, transform: Transform2D) {
        if let Some(s) = self.k.statics.iter_mut().find(|s| s.id == id) {
            s.set_target(transform);
        }
    }

    /// Makes static shape `id` a moving obstacle going from `from` to `to` over the next
    /// step (a rigid body: where it is and where its velocity takes it in Godot's step).
    #[func]
    fn set_static_motion(&mut self, id: i64, from: Transform2D, to: Transform2D) {
        if let Some(s) = self.k.statics.iter_mut().find(|s| s.id == id) {
            s.set_motion(from, to);
        }
    }

    /// Makes static shape `id` a moving obstacle of rigid body `body` (the key its other
    /// shapes share): at `from` now, its centre of mass at `com`, moving with `velocity`
    /// and `angular_velocity` (gravity's pull over the step included), of inverse mass and
    /// inertia `inv_mass` and `inv_inertia` in the goo's units; `to` where that motion
    /// alone takes it by the step's end. The goo's contacts change its motion within the
    /// step; static_impulses() sums them.
    #[func]
    #[allow(clippy::too_many_arguments)]
    fn set_static_rigid(&mut self, id: i64, body: i64, from: Transform2D, to: Transform2D, com: Vector2, velocity: Vector2, angular_velocity: f64, inv_mass: f64, inv_inertia: f64) {
        if let Some(s) = self.k.statics.iter_mut().find(|s| s.id == id) {
            s.set_rigid(body, from, to, com, velocity, angular_velocity as f32, inv_mass as f32, inv_inertia as f32);
        }
    }

    /// The last step's impulse on every moving obstacle, four floats each: id, the
    /// impulse's x and y (the goo's reaction on it), and its moment about the global origin.
    #[func]
    fn static_impulses(&self) -> PackedFloat32Array {
        PackedFloat32Array::from(impulses(&self.k.statics).as_slice())
    }
}

#[godot_api(secondary)]
impl GooCells {
    /// GooKernel.set_static_target()'s.
    #[func]
    fn set_static_target(&mut self, id: i64, transform: Transform2D) {
        for s in self.c.statics.iter_mut().filter(|s| s.id == id) {
            s.set_target(transform);
        }
    }

    /// GooKernel.set_static_motion()'s.
    #[func]
    fn set_static_motion(&mut self, id: i64, from: Transform2D, to: Transform2D) {
        for s in self.c.statics.iter_mut().filter(|s| s.id == id) {
            s.set_motion(from, to);
        }
    }

    /// GooKernel.set_static_rigid()'s.
    #[func]
    #[allow(clippy::too_many_arguments)]
    fn set_static_rigid(&mut self, id: i64, body: i64, from: Transform2D, to: Transform2D, com: Vector2, velocity: Vector2, angular_velocity: f64, inv_mass: f64, inv_inertia: f64) {
        for s in self.c.statics.iter_mut().filter(|s| s.id == id) {
            s.set_rigid(body, from, to, com, velocity, angular_velocity as f32, inv_mass as f32, inv_inertia as f32);
        }
    }

    /// GooKernel.static_impulses()'s.
    #[func]
    fn static_impulses(&self) -> PackedFloat32Array {
        PackedFloat32Array::from(impulses(&self.c.statics).as_slice())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cells::hex_design;
    use godot::builtin::Transform2D;

    fn bar(w: f32, h: f32) -> Vec<Vector2> {
        vec![Vector2::new(-w / 2.0, -h / 2.0), Vector2::new(w / 2.0, -h / 2.0), Vector2::new(w / 2.0, h / 2.0), Vector2::new(-w / 2.0, h / 2.0)]
    }

    fn creature(cl: &mut Cells, rings: i32, r: f32) -> usize {
        let c = hex_design(rings, r, Vector2::ZERO);
        let n = c.len();
        cl.add_creature(&c, &vec![r; n], &vec![0; n])
    }

    /// A thin bar sweeping through a creature at 300 px/s pushes every cell ahead of it,
    /// as a moving obstacle; teleported as a wall (set_static_transform) it leaves cells
    /// behind it.
    #[test]
    fn a_sweeping_obstacle_leaves_no_cell_behind() {
        let mut behind = [0usize; 2];
        for (k, dynamic) in [true, false].into_iter().enumerate() {
            let mut cl = Cells::default();
            cl.opt.drag.enabled = false;
            let c = creature(&mut cl, 3, 7.0);
            let start = Transform2D::IDENTITY.translated(Vector2::new(-120.0, 0.0));
            cl.add_static_shape(1, start, bar(6.0, 400.0), 0.0, 0.0, false);
            let mut x = -120.0;
            for _ in 0..50 {
                x += 5.0;
                let t = Transform2D::IDENTITY.translated(Vector2::new(x, 0.0));
                if dynamic {
                    cl.statics[0].set_target(t);
                } else {
                    cl.set_static_transform(1, t);
                }
                cl.step(1.0 / 60.0);
            }
            behind[k] = cl.bodies[c].pos.iter().filter(|p| p.x < x).count();
            println!("dynamic {}: wall at {}, cells behind it {}, centre {:?}", dynamic, x, behind[k], cl.bodies[c].center());
        }
        assert_eq!(behind[0], 0);
    }

    /// The impulse the obstacle reports is the momentum the creature gained.
    #[test]
    fn the_reaction_balances_the_momentum_given() {
        let mut cl = Cells::default();
        cl.opt.drag.enabled = false;
        let c = creature(&mut cl, 2, 7.0);
        cl.add_static_shape(7, Transform2D::IDENTITY.translated(Vector2::new(-60.0, 0.0)), bar(20.0, 100.0), 0.0, 0.0, false);
        let mut total = Vector2::ZERO;
        let mut x = -60.0;
        for _ in 0..20 {
            x += 4.0;
            cl.statics[0].set_target(Transform2D::IDENTITY.translated(Vector2::new(x, 0.0)));
            cl.step(1.0 / 60.0);
            let j = impulses(&cl.statics);
            assert_eq!(j[0], 7.0);
            total += Vector2::new(j[1], j[2]);
        }
        let b = &cl.bodies[c];
        let p: Vector2 = (0..b.n).fold(Vector2::ZERO, |s, i| s + b.vel[i] * b.mass[i]);
        println!("creature momentum {:?}, reaction {:?}", p, total);
        assert!(p.x > 0.0);
        assert!(len(p + total) < 0.05 * len(p), "{:?} vs {:?}", p, total);
    }
}

#[cfg(test)]
mod rigid_tests {
    use super::*;
    use crate::cells::hex_design;
    use godot::builtin::Transform2D;

    /// A rigid body as Godot steps it: gravity, the goo's impulse, semi-implicit Euler.
    struct Box2 {
        pos: Vector2,
        rot: f32,
        vel: Vector2,
        ang: f32,
        inv_m: f32,
        inv_i: f32,
    }

    fn square(h: f32) -> Vec<Vector2> {
        vec![Vector2::new(-h, -h), Vector2::new(h, -h), Vector2::new(h, h), Vector2::new(-h, h)]
    }

    fn run(cl: &mut Cells, b: &mut Box2, g: Vector2, frames: usize, log: bool) -> (f32, f32) {
        let dt = 1.0 / 60.0;
        let (mut lo, mut hi) = (f32::INFINITY, f32::NEG_INFINITY);
        for f in 0..frames {
            let v = b.vel + g * dt;
            let from = Transform2D::from_angle_origin(b.rot, b.pos);
            let to = Transform2D::from_angle_origin(b.rot + b.ang * dt, b.pos + v * dt);
            let idx = cl.statics.iter().position(|s| s.id == 9).unwrap();
            cl.statics[idx].set_rigid(9, from, to, b.pos, v, b.ang, b.inv_m, b.inv_i);
            cl.step(dt);
            let j = impulses(&cl.statics);
            let ji = Vector2::new(j[1], j[2]);
            b.vel = v + ji * b.inv_m;
            b.ang += b.inv_i * (j[3] - cross(b.pos, ji));
            b.pos += b.vel * dt;
            b.rot += b.ang * dt;
            if f >= frames / 2 {
                lo = lo.min(b.pos.y);
                hi = hi.max(b.pos.y);
            }
            if log && f % 30 == 0 {
                println!("{} box {:?} rot {:.3} vel {:?} ang {:.3}", f, b.pos, b.rot, b.vel, b.ang);
            }
        }
        (lo, hi)
    }

    /// A rigid square resting on a blob of cells on a floor under gravity stays on it.
    #[test]
    fn a_rigid_box_rests_on_a_creature() {
        let mut cl = Cells::default();
        cl.opt.drag.enabled = false;
        let g = Vector2::new(0.0, 490.0);
        cl.opt.gravity = g;
        let r = 7.0;
        let c = hex_design(3, r, Vector2::new(0.0, -6.0 * r * 0.866 - r));
        let n = c.len();
        let k = cl.add_creature(&c, &vec![r; n], &vec![0; n]);
        cl.add_static_shape(1, Transform2D::IDENTITY, vec![Vector2::new(-500.0, 0.0), Vector2::new(500.0, 0.0), Vector2::new(500.0, 100.0), Vector2::new(-500.0, 100.0)], 1.0, 0.0, true);
        for _ in 0..60 {
            cl.step(1.0 / 60.0);
        }
        let top = cl.bodies[k].pos.iter().fold(f32::INFINITY, |m, p| m.min(p.y - r));
        let h = 15.0;
        let mass = 0.5 * cl.bodies[k].total_mass();
        let mut b = Box2 { pos: Vector2::new(0.0, top - h - 1.0), rot: 0.0, vel: Vector2::ZERO, ang: 0.0, inv_m: 1.0 / mass, inv_i: 12.0 / (mass * 8.0 * h * h) };
        cl.add_static_shape(9, Transform2D::from_angle_origin(0.0, b.pos), square(h), 1.0, 0.0, true);
        let (lo, hi) = run(&mut cl, &mut b, g, 300, true);
        println!("top {} box y {}..{} rot {}", top, lo, hi, b.rot);
        assert!(b.rot.abs() < 0.2 && b.pos.x.abs() < 10.0 && hi < 0.0 - h - 2.0 * r);
    }
}
