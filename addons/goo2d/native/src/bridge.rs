//! The Godot bridge's part of the solvers (docs/bridge.md): moving obstacles. A static
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

use crate::cells::{push_out_of_wall, Body, Cells, Opt};
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

fn substep(statics: &mut [StaticShape], k: usize, n: usize) {
    let n = n.max(1) as f32;
    for s in statics.iter_mut().filter(|s| s.dynamic) {
        s.substep_to(k as f32 / n, (k + 1) as f32 / n);
    }
}

fn end(statics: &mut [StaticShape]) {
    for s in statics.iter_mut().filter(|s| s.dynamic) {
        s.end_step();
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
            if self.statics.iter().any(|s| s.dynamic && s.sweep > 1e-3 && s.swept.grow(reach).intersects(&r.bounds)) {
                wake.push(idx);
            }
        }
        for idx in wake {
            self.wake(idx, true);
        }
    }

    /// Before substep `k` of `n`: every moving obstacle where it is by that substep's end.
    pub(crate) fn move_dynamic(&mut self, k: usize, n: usize) {
        substep(&mut self.statics, k, n);
    }

    /// The step's end: every moving obstacle at its target.
    pub(crate) fn end_dynamic(&mut self) {
        end(&mut self.statics);
    }

    /// One substep `h` of every awake bead against the moving obstacles: swept along its
    /// motion relative to each (from its start carried by the shape's motion to where it
    /// is), stopped at the first overlap and pushed out of it; the push's momentum summed
    /// on the shape as its reaction. No restitution or friction: a bead takes the
    /// obstacle's normal velocity (an inelastic push) and keeps its tangential one.
    pub(crate) fn collide_dynamic(&mut self, h: f32) {
        if h <= 0.0 || !self.statics.iter().any(|s| s.dynamic) {
            return;
        }
        let slop = self.solver.touch_slop;
        let inv_h = 1.0 / h;
        let statics = &mut self.statics;
        let ps = &mut self.ps;
        for s in statics.iter_mut() {
            if !s.dynamic {
                continue;
            }
            for r in &self.rings {
                if r.settled {
                    continue;
                }
                let mass = r.p.bead_mass as f32;
                let rad_max = r.p.bead_radius as f32;
                if !s.swept.grow(rad_max * 4.0 + slop + 64.0).intersects(&r.bounds) {
                    continue;
                }
                for i in r.start..r.start + r.n {
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
                    for m in 1..=samples {
                        let q = if samples == 1 { end } else { start + moved * (m as f32 / samples as f32) };
                        let Some((gap, dir)) = s.gap(q, rad, slop) else {
                            if m == samples {
                                break;
                            }
                            continue;
                        };
                        if gap < 0.0 {
                            let at = q + dir * -gap;
                            let delta = at - ps.pos[i];
                            ps.pos[i] = at;
                            s.add_reaction(at - dir * rad, delta * (mass * inv_h));
                            break;
                        }
                        if m == samples {
                            break;
                        }
                    }
                }
            }
        }
    }
}

impl Body {
    /// The cells near a moving obstacle this step (`dyn_c`: cell, wall index), found over
    /// the box the obstacle sweeps; the step's reactions cleared.
    pub(crate) fn prepare_dynamic(&mut self, opt: &Opt, dt: f32, walls: &[StaticShape]) {
        self.dyn_c.clear();
        self.dyn_j.clear();
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
    /// overlap; each push's momentum summed as the obstacle's reaction.
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
            let delta = p - self.pos[c];
            self.pos[c] = p;
            self.contact = true;
            let j = delta * (self.mass[c] * inv_h);
            let point = p - norm(delta) * self.r[c];
            match self.dyn_j.iter_mut().find(|e| e.0 == wi as u32) {
                Some(e) => {
                    e.1 += j;
                    e.2 += cross(point, j);
                }
                None => self.dyn_j.push((wi as u32, j, cross(point, j))),
            }
        }
    }
}

impl Cells {
    /// The step's start: the moving obstacles' impulses zeroed.
    pub(crate) fn begin_dynamic(&mut self) {
        begin(&mut self.statics);
    }

    /// Before substep `k` of `n`.
    pub(crate) fn move_dynamic(&mut self, k: usize, n: usize) {
        substep(&mut self.statics, k, n);
    }

    /// The step's end: every creature's pushes summed onto the obstacles as reactions,
    /// each obstacle at its target.
    pub(crate) fn end_dynamic(&mut self) {
        if !self.statics.iter().any(|s| s.dynamic) {
            return;
        }
        for b in &self.bodies {
            if !b.alive {
                continue;
            }
            for &(wi, j, moment) in &b.dyn_j {
                if let Some(s) = self.statics.get_mut(wi as usize) {
                    s.impulse -= j;
                    s.moment -= moment;
                }
            }
        }
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
