//! The pair passes' forces as pure functions over plain data: the overlap push between
//! two rings (`GooWorld2D.intrusion`) and the Untangler's impulse
//! (`GooWorld2D.Untangler.push`). The kernel's step and the `GooKernel` statics the tests
//! call both use these. (The ring's own forces are the solver's constraints, kernel.rs.)

use crate::consts::*;
use crate::geom::*;
use godot::builtin::Vector2;

/// A ring as the overlap push sees it (`GooWorld2D.OverlapRing`).
pub struct OverlapView<'a> {
    pub points: &'a [Vector2],
    /// One velocity per bead; empty for beads at rest.
    pub velocities: &'a [Vector2],
    pub bead_mass: f64,
    pub margin: f64,
    /// The box of the points grown by `margin`.
    pub bounds: Rect,
    /// Unit outward edge normals (flipped for a loop inside out).
    pub normals: Vec<Vector2>,
    /// The loop grown by `margin` along its vertex normals.
    pub grown: Vec<Vector2>,
}

impl<'a> OverlapView<'a> {
    pub fn new(points: &'a [Vector2], velocities: &'a [Vector2], bead_radius: f64, bead_mass: f64, bounds: Rect) -> Self {
        let margin = INTRUSION_MARGIN_BEADS * bead_radius;
        let bounds = if points.is_empty() { bounds } else { bounds.grow(margin as f32) };
        OverlapView { points, velocities, bead_mass, margin, bounds, normals: Vec::new(), grown: Vec::new() }
    }

    /// Computes `normals` and `grown` (once).
    pub fn prepare(&mut self) {
        let n = self.points.len();
        if !self.normals.is_empty() || n < 3 {
            return;
        }
        edge_normals(self.points, &mut self.normals);
        let outward = if is_ccw(self.points) { 1.0f32 } else { -1.0f32 };
        for v in self.normals.iter_mut() {
            *v = norm(*v) * outward;
        }
        self.grown = (0..n)
            .map(|i| self.points[i] + norm(self.normals[(i + n - 1) % n] + self.normals[i]) * self.margin as f32)
            .collect();
    }

    #[inline]
    fn velocity(&self, i: usize) -> Vector2 {
        self.velocities.get(i).copied().unwrap_or(Vector2::ZERO)
    }
}

/// What `intrusion` found (`GooWorld2D.Intrusion`).
#[derive(Default, Debug)]
pub struct Intrusion {
    pub forces_a: Vec<Vector2>,
    pub forces_b: Vec<Vector2>,
    pub inside_a: usize,
    pub inside_b: usize,
    pub count_a: usize,
    pub count_b: usize,
    pub pressed: bool,
    pub beads_in_a: Vec<usize>,
    pub beads_in_b: Vec<usize>,
    pub reach_a: Vec<usize>,
    pub reach_b: Vec<usize>,
    pub centre_in_a: bool,
    pub centre_in_b: bool,
}

impl Intrusion {
    pub fn deep(&self) -> bool {
        self.centre_in_a
            || self.centre_in_b
            || (self.count_a > 0 && self.inside_a == self.count_a)
            || (self.count_b > 0 && self.inside_b == self.count_b)
    }
}

#[inline]
fn reduced(a: f64, b: f64) -> f64 {
    let total = a + b;
    if total <= 0.0 {
        0.0
    } else {
        a * b / total
    }
}

/// `GooWorld2D.intrusion`. Both views must be `prepare()`d.
pub fn intrusion(a: &OverlapView, b: &OverlapView) -> Intrusion {
    let mut result = Intrusion { count_a: a.points.len(), count_b: b.points.len(), ..Default::default() };
    if result.count_a < 3 || result.count_b < 3 || !a.bounds.intersects(&b.bounds) {
        return result;
    }
    let mut forces_a = Vec::new();
    let mut forces_b = Vec::new();
    let (inside_a, beads_in_a, reach_a) = intrude(a, b, &mut forces_a, &mut forces_b);
    let (inside_b, beads_in_b, reach_b) = intrude(b, a, &mut forces_b, &mut forces_a);
    result.pressed = !reach_a.is_empty() || !reach_b.is_empty();
    result.inside_a = inside_a;
    result.inside_b = inside_b;
    result.beads_in_a = beads_in_a;
    result.beads_in_b = beads_in_b;
    result.reach_a = reach_a;
    result.reach_b = reach_b;
    result.forces_a = forces_a;
    result.forces_b = forces_b;
    if result.inside_a > 0 {
        result.centre_in_a = point_in_polygon(centroid(a.points), b.points);
    }
    if result.inside_b > 0 {
        result.centre_in_b = point_in_polygon(centroid(b.points), a.points);
    }
    result
}

/// `GooWorld2D._intrude`: pushes the beads of `ring` that got into `other` out of it.
/// Returns (beads inside the loop, their indices, indices within the margin or inside).
fn intrude(
    ring: &OverlapView,
    other: &OverlapView,
    forces_ring: &mut Vec<Vector2>,
    forces_other: &mut Vec<Vector2>,
) -> (usize, Vec<usize>, Vec<usize>) {
    let red = reduced(ring.bead_mass, other.bead_mass);
    let stiffness = INTRUSION_FREQUENCY * INTRUSION_FREQUENCY * red;
    let damping = 2.0 * INTRUSION_FREQUENCY * red;
    let lp = other.points;
    let count = lp.len();
    let mut beads_in = Vec::new();
    let mut reach = Vec::new();
    for (i, &point) in ring.points.iter().enumerate() {
        if !other.bounds.has_point(point) || !point_in_polygon(point, &other.grown) {
            continue;
        }
        let in_loop = point_in_polygon(point, lp);
        let mut nearest = 0usize;
        let mut best = f64::INFINITY;
        let mut closest = Vector2::ZERO;
        for j in 0..count {
            let on_edge = closest_on_segment(point, lp[j], lp[(j + 1) % count]);
            let d = dist_sq(point, on_edge) as f64;
            if d < best {
                best = d;
                nearest = j;
                closest = on_edge;
            }
        }
        let depth = other.margin + if in_loop { best.sqrt() } else { -best.sqrt() };
        if depth <= 0.0 && !in_loop {
            continue;
        }
        if forces_ring.is_empty() {
            forces_ring.resize(ring.points.len(), Vector2::ZERO);
        }
        if forces_other.is_empty() {
            forces_other.resize(count, Vector2::ZERO);
        }
        if in_loop {
            beads_in.push(i);
        }
        reach.push(i);
        let next = (nearest + 1) % count;
        let length = dist(lp[nearest], lp[next]);
        let along = if length > 0.0 { (dist(lp[nearest], closest) / length).clamp(0.0, 1.0) } else { 0.5 };
        let normal = other.normals[nearest];
        let edge_velocity = lerp(other.velocity(nearest), other.velocity(next), along);
        let sinking = dot(edge_velocity - ring.velocity(i), normal) as f64;
        let push = stiffness * depth.max(0.0) + damping * sinking.max(0.0);
        if push <= 0.0 {
            continue;
        }
        let force = normal * push as f32;
        forces_ring[i] = forces_ring[i] + force;
        forces_other[nearest] = forces_other[nearest] - force * (1.0 - along);
        forces_other[next] = forces_other[next] - force * along;
    }
    (beads_in.len(), beads_in, reach)
}

/// `GooWorld2D.Untangler.push`: equal and opposite impulses along the centre line, at
/// `strength` (px/s² per px of overlap, `Untangler.STRENGTH`) up to a parting speed of
/// `separation_speed` (px/s, `Untangler.SEPARATION_SPEED`).
#[allow(clippy::too_many_arguments)]
pub fn untangle_push(
    center_a: Vector2,
    radius_a: f64,
    mass_a: f64,
    center_b: Vector2,
    radius_b: f64,
    mass_b: f64,
    delta: f64,
    velocity_a: Vector2,
    velocity_b: Vector2,
    strength: f64,
    separation_speed: f64,
) -> (Vector2, Vector2) {
    let reach = radius_a + radius_b;
    let distance = dist(center_a, center_b) as f64;
    let overlap = (reach - distance).max(UNTANGLE_MIN_OVERLAP_RATIO * reach);
    let mut direction = Vector2::new(1.0, 0.0);
    if distance > 0.0001 {
        direction = (center_a - center_b) / distance as f32;
    }
    let red = reduced(mass_a, mass_b);
    let parting = dot(velocity_a - velocity_b, direction) as f64;
    let change = (strength * overlap * delta).min((separation_speed - parting).max(0.0));
    let impulse = direction * (change * red) as f32;
    (impulse, -impulse)
}

/// `Goo2D.beads_inside` on plain data: how many of `points` lie inside `other` grown by
/// `margin` (boxes `bounds`/`other_bounds` of the bead centres, not grown).
pub fn beads_inside(points: &[Vector2], bounds: Rect, other: &[Vector2], other_bounds: Rect, margin: f64) -> usize {
    if points.is_empty() || other.is_empty() {
        return 0;
    }
    if !bounds.intersects(&other_bounds.grow((margin.max(0.0) * 1.001 + 0.01) as f32)) {
        return 0;
    }
    let grown;
    let lp: &[Vector2] = if margin > 0.0 {
        grown = offset_loop(other, margin as f32);
        &grown
    } else {
        other
    };
    let mut box_ = Rect::new(lp[0], Vector2::ZERO);
    for &p in lp {
        box_ = box_.expand(p);
    }
    points.iter().filter(|&&p| box_.has_point(p) && point_in_polygon(p, lp)).count()
}
