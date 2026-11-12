//! Water drag inside the colony's step (milestone 2, docs/colony-exposure.md): the law of
//! the fluid game's FluidDrag.bead_forces() (src/fluid_drag.gd there), applied once a frame
//! to every ring's exposed skin edges only. Per edge, the edge's velocity relative to the
//! water (the mean of its two beads') is split across and along the edge; the force is
//! −(normal · |v_n| + linear_normal) v_n n − (tangent · |v_t| + linear_tangent) v_t t,
//! times the edge's length and the water's density, half to each bead; each bead's force
//! is then clamped so it takes at most `max_step` of the bead's relative speed in the
//! frame. An edge counts by the mean of its beads' exposure (1 both exposed, ½ one, 0
//! none): a fully enclosed cell gets none, and cores get none.

use super::*;

/// The drag's settings, colony-wide. The coefficients are the game's GameSettings ones
/// (DRAG_NORMAL, DRAG_TANGENT, DRAG_LINEAR_NORMAL, DRAG_LINEAR_TANGENT,
/// DRAG_MAX_STEP_FRACTION); `density` is WATER_DENSITY: the water's mass per px² over the
/// cell's own (a cell's mass over π radius²), as the game's FluidWorld sets it per body.
#[derive(Clone, Copy, Debug)]
pub struct Drag {
    pub enabled: bool,
    pub density: f32,
    pub normal: f32,
    pub tangent: f32,
    pub linear_normal: f32,
    pub linear_tangent: f32,
    pub max_step: f32,
}

impl Default for Drag {
    fn default() -> Self {
        Drag { enabled: false, density: 1.0, normal: 0.1, tangent: 0.01, linear_normal: 60.0, linear_tangent: 8.0, max_step: 0.5 }
    }
}

/// The drag force on each bead of one closed loop (FluidDrag.bead_forces()'s law), into
/// `out` (cleared). `water` gives the water's velocity at bead i; `weight` an edge's share
/// from its beads' (i − 1 and i) exposure, or None for every edge whole. `density` is the
/// water's mass per px² (not relative), `bead_mass` and `delta` set the clamp (delta ≤ 0:
/// no clamp).
#[allow(clippy::too_many_arguments)]
pub fn loop_forces<W: Fn(usize) -> Vector2>(
    points: &[Vector2],
    velocities: &[Vector2],
    water: W,
    weight: Option<&[u8]>,
    d: &Drag,
    density: f32,
    bead_mass: f32,
    delta: f32,
    out: &mut Vec<Vector2>,
) {
    let n = points.len();
    out.clear();
    out.resize(n, Vector2::ZERO);
    if n < 3 || velocities.len() != n {
        return;
    }
    let share = 0.5 * density;
    let mut p0 = points[n - 1];
    let mut v0 = velocities[n - 1] - water(n - 1);
    let mut e0 = weight.map(|w| w[n - 1]).unwrap_or(1);
    for j in 0..n {
        let p1 = points[j];
        let v1 = velocities[j] - water(j);
        let e1 = weight.map(|w| w[j]).unwrap_or(1);
        let ew = (e0 as f32 + e1 as f32) * 0.5;
        let (ex, ey) = (p1.x - p0.x, p1.y - p0.y);
        let length = (ex * ex + ey * ey).sqrt();
        if ew > 0.0 && length > 0.000001 {
            let (tx, ty) = (ex / length, ey / length);
            let (vx, vy) = (0.5 * (v0.x + v1.x), 0.5 * (v0.y + v1.y));
            // Across the edge (normal (−ty, tx)) and along it.
            let vn = vy * tx - vx * ty;
            let vt = vx * tx + vy * ty;
            let fnrm = -(d.normal * vn.abs() + d.linear_normal) * vn;
            let ftan = -(d.tangent * vt.abs() + d.linear_tangent) * vt;
            let scale = share * length * ew;
            let f = Vector2::new(-ty * fnrm + tx * ftan, tx * fnrm + ty * ftan) * scale;
            let i = if j > 0 { j - 1 } else { n - 1 };
            out[i] += f;
            out[j] += f;
        }
        p0 = p1;
        v0 = v1;
        e0 = e1;
    }
    if delta > 0.0 && bead_mass > 0.0 {
        // A bead's velocity changes by force × delta / bead_mass over the frame: kept
        // within max_step of its speed relative to the water.
        let limit_per_speed = d.max_step * bead_mass / delta;
        for i in 0..n {
            let f = out[i];
            let limit = limit_per_speed * len(velocities[i] - water(i));
            let size_sq = len_sq(f);
            if size_sq > limit * limit {
                out[i] = if size_sq > 0.0 { f * (limit / size_sq.sqrt()) } else { Vector2::ZERO };
            }
        }
    }
}

impl Creature {
    /// Once a frame, before the substeps: every ring's drag (on its exposed edges when
    /// `exposure` is on, else on all) added to its beads' frame forces and kept in
    /// `drag_f`. The water: `cell_water[cell]` when given, else `water`.
    pub(super) fn apply_drag(&mut self, d: &Drag, exposure: bool) {
        let n = self.pos.len();
        self.drag_f.clear();
        self.drag_f.resize(n, Vector2::ZERO);
        let mut out = Vec::new();
        for r in 0..self.rings.len() {
            let (cell, start, m) = (self.rings[r].cell, self.rings[r].start, self.rings[r].n);
            let t = &self.cells[cell].t;
            let weight = if exposure && self.exp_valid { Some(&self.exposed[start..start + m]) } else { None };
            if weight.is_some_and(|w| w.iter().all(|&e| e == 0)) {
                continue;
            }
            let water = if cell < self.cell_water.len() { self.cell_water[cell] } else { self.water };
            // The water's mass per px², WATER_DENSITY × the cell's own.
            let density = d.density * t.mass() / (std::f32::consts::PI * t.radius * t.radius).max(1e-6);
            loop_forces(
                &self.pos[start..start + m],
                &self.vel[start..start + m],
                |_| water,
                weight,
                d,
                density,
                t.bead_mass,
                self.dt,
                &mut out,
            );
            for i in 0..m {
                self.force[start + i] += out[i];
                self.drag_f[start + i] = out[i];
            }
        }
    }
}
