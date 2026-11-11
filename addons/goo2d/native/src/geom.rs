//! Loop geometry: ports of the `GooLoop` statics the per-frame code uses, and of the few
//! Godot built-ins they rely on (`Vector2` lerp/normalize/rotate, `Rect2`, `convex_hull`,
//! the closest point on a segment), written to follow Godot's own float semantics
//! (vectors in `f32`, as Godot's `real_t`; scalar sums in `f64`, as GDScript's `float`), so
//! the kernel agrees with the GDScript reference functions to rounding.
//!
//! Orientation as in `GooLoop`: y points down, so a loop counter-clockwise on screen has a
//! negative shoelace area ("CCW" means `signed_area() < 0`).

use godot::builtin::Vector2;

/// Godot's `Vector2::lerp`: `a + (b - a) * w`, componentwise in `f32`.
#[inline]
pub fn lerp(a: Vector2, b: Vector2, w: f32) -> Vector2 {
    Vector2::new(a.x + w * (b.x - a.x), a.y + w * (b.y - a.y))
}

#[inline]
pub fn dot(a: Vector2, b: Vector2) -> f32 {
    a.x * b.x + a.y * b.y
}

#[inline]
pub fn cross(a: Vector2, b: Vector2) -> f32 {
    a.x * b.y - a.y * b.x
}

#[inline]
pub fn len_sq(a: Vector2) -> f32 {
    a.x * a.x + a.y * a.y
}

#[inline]
pub fn len(a: Vector2) -> f32 {
    len_sq(a).sqrt()
}

#[inline]
pub fn dist(a: Vector2, b: Vector2) -> f32 {
    len(a - b)
}

#[inline]
pub fn dist_sq(a: Vector2, b: Vector2) -> f32 {
    len_sq(a - b)
}

/// Godot's `Vector2::normalized`: the zero vector stays zero.
#[inline]
pub fn norm(a: Vector2) -> Vector2 {
    let l = len_sq(a);
    if l != 0.0 {
        let l = l.sqrt();
        Vector2::new(a.x / l, a.y / l)
    } else {
        a
    }
}

/// Godot's `Vector2::rotated`.
#[inline]
pub fn rotated(a: Vector2, angle: f32) -> Vector2 {
    let (s, c) = angle.sin_cos();
    Vector2::new(a.x * c - a.y * s, a.x * s + a.y * c)
}

#[inline]
pub fn vmin(a: Vector2, b: Vector2) -> Vector2 {
    Vector2::new(a.x.min(b.x), a.y.min(b.y))
}

#[inline]
pub fn vmax(a: Vector2, b: Vector2) -> Vector2 {
    Vector2::new(a.x.max(b.x), a.y.max(b.y))
}

/// Godot's `Rect2` as the goo uses it: position and size in `f32`, `has_point` and
/// `intersects` with Godot's borders (the far edges are outside, touching boxes do not
/// intersect).
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Rect {
    pub pos: Vector2,
    pub size: Vector2,
}

impl Rect {
    pub fn new(pos: Vector2, size: Vector2) -> Self {
        Rect { pos, size }
    }

    /// The bounding box of `points` (`Rect2(low, high - low)`); a zero box for none.
    pub fn of_points(points: &[Vector2]) -> Self {
        if points.is_empty() {
            return Rect::default();
        }
        let mut low = points[0];
        let mut high = points[0];
        for &p in points {
            low = vmin(low, p);
            high = vmax(high, p);
        }
        Rect::new(low, high - low)
    }

    pub fn grow(self, by: f32) -> Self {
        Rect::new(
            Vector2::new(self.pos.x - by, self.pos.y - by),
            Vector2::new(self.size.x + 2.0 * by, self.size.y + 2.0 * by),
        )
    }

    pub fn has_point(&self, p: Vector2) -> bool {
        !(p.x < self.pos.x
            || p.y < self.pos.y
            || p.x >= self.pos.x + self.size.x
            || p.y >= self.pos.y + self.size.y)
    }

    pub fn intersects(&self, b: &Rect) -> bool {
        !(self.pos.x >= b.pos.x + b.size.x
            || self.pos.x + self.size.x <= b.pos.x
            || self.pos.y >= b.pos.y + b.size.y
            || self.pos.y + self.size.y <= b.pos.y)
    }

    /// Godot's `Rect2::expand`: the box grown to hold `p`.
    pub fn expand(self, p: Vector2) -> Self {
        let begin = vmin(self.pos, p);
        let end = vmax(self.pos + self.size, p);
        Rect::new(begin, end - begin)
    }
}

/// `GooLoop.signed_area`: negative for a loop counter-clockwise on screen.
pub fn signed_area(p: &[Vector2]) -> f64 {
    let n = p.len();
    let mut total = 0.0f64;
    for i in 0..n {
        total += cross(p[i], p[(i + 1) % n]) as f64;
    }
    total * 0.5
}

pub fn area(p: &[Vector2]) -> f64 {
    signed_area(p).abs()
}

pub fn is_ccw(p: &[Vector2]) -> bool {
    signed_area(p) < 0.0
}

pub fn perimeter(p: &[Vector2]) -> f64 {
    let n = p.len();
    let mut total = 0.0f64;
    for i in 0..n {
        total += dist(p[i], p[(i + 1) % n]) as f64;
    }
    total
}

/// `GooTuning.outline_area`: the loop's area plus a band `bead` wide around it.
pub fn outline_area(p: &[Vector2], bead: f64) -> f64 {
    area(p) + perimeter(p) * bead + std::f64::consts::PI * bead * bead
}

/// `GooLoop.edge_normals`: one normal per edge i → i+1, as long as the edge, outward for a
/// CCW loop.
pub fn edge_normals(p: &[Vector2], out: &mut Vec<Vector2>) {
    let n = p.len();
    out.clear();
    for i in 0..n {
        let e = p[(i + 1) % n] - p[i];
        out.push(Vector2::new(-e.y, e.x));
    }
}

/// `GooLoop.centroid`: the mean of the points (zero for none).
pub fn centroid(p: &[Vector2]) -> Vector2 {
    if p.is_empty() {
        return Vector2::ZERO;
    }
    let mut total = Vector2::ZERO;
    for &q in p {
        total = total + q;
    }
    total / p.len() as f32
}

/// `GooLoop.best_fit_rotation`.
pub fn best_fit_rotation(rest: &[Vector2], current: &[Vector2]) -> f64 {
    let rc = centroid(rest);
    let cc = centroid(current);
    let mut cross_sum = 0.0f64;
    let mut dot_sum = 0.0f64;
    for i in 0..rest.len().min(current.len()) {
        let q = rest[i] - rc;
        let p = current[i] - cc;
        cross_sum += cross(q, p) as f64;
        dot_sum += dot(q, p) as f64;
    }
    cross_sum.atan2(dot_sum)
}

/// `GooLoop.goal_positions`.
pub fn goal_positions(rest: &[Vector2], current: &[Vector2], out: &mut Vec<Vector2>) {
    let rc = centroid(rest);
    let cc = centroid(current);
    let angle = best_fit_rotation(rest, current) as f32;
    out.clear();
    for &r in rest {
        out.push(cc + rotated(r - rc, angle));
    }
}

/// `GooLoop.chaikin`.
pub fn chaikin(points: &[Vector2], iterations: usize) -> Vec<Vector2> {
    let mut current = points.to_vec();
    for _ in 0..iterations {
        let n = current.len();
        let mut next = Vec::with_capacity(2 * n);
        for i in 0..n {
            let a = current[i];
            let b = current[(i + 1) % n];
            next.push(lerp(a, b, 0.25));
            next.push(lerp(a, b, 0.75));
        }
        current = next;
    }
    current
}

/// `GooLoop.chaikin_keeping`: Chaikin that keeps the points flagged in `keep` sharp.
pub fn chaikin_keeping(points: &[Vector2], iterations: usize, keep: &[u8]) -> Vec<Vector2> {
    let mut current = points.to_vec();
    let mut flags: Vec<u8> = (0..current.len()).map(|i| keep.get(i).copied().unwrap_or(0)).collect();
    for _ in 0..iterations {
        let n = current.len();
        let mut next = Vec::with_capacity(2 * n + 8);
        let mut next_flags = Vec::with_capacity(2 * n + 8);
        for i in 0..n {
            let a = current[i];
            let b = current[(i + 1) % n];
            if flags[i] != 0 {
                next.push(a);
                next_flags.push(1);
            }
            next.push(lerp(a, b, 0.25));
            next.push(lerp(a, b, 0.75));
            next_flags.push(0);
            next_flags.push(0);
        }
        current = next;
        flags = next_flags;
    }
    current
}

/// `GooLoop.resample`: `count` points evenly spaced by arc length, starting at loop[0].
pub fn resample(lp: &[Vector2], count: usize) -> Vec<Vector2> {
    let mut result = Vec::with_capacity(count);
    if count == 0 || lp.is_empty() {
        return result;
    }
    let size = lp.len();
    let mut perim = 0.0f64;
    for i in 0..size {
        perim += dist(lp[i], lp[(i + 1) % size]) as f64;
    }
    result.push(lp[0]);
    if perim <= 0.0 {
        while result.len() < count {
            result.push(lp[0]);
        }
        return result;
    }
    let step = perim / count as f64;
    let mut target = step;
    let mut walked = 0.0f64;
    for i in 0..size {
        let a = lp[i];
        let b = lp[(i + 1) % size];
        let length = dist(a, b) as f64;
        while result.len() < count && target <= walked + length && length > 0.0 {
            result.push(lerp(a, b, ((target - walked) / length) as f32));
            target += step;
        }
        walked += length;
    }
    while result.len() < count {
        result.push(lp[size - 1]);
    }
    result
}

const CMP_EPSILON: f32 = 0.00001;

/// Godot's `Math::is_equal_approx` for `real_t`.
#[inline]
fn equal_approx(a: f32, b: f32) -> bool {
    if a == b {
        return true;
    }
    let tolerance = (CMP_EPSILON * a.abs()).max(CMP_EPSILON);
    (a - b).abs() < tolerance
}

/// Godot's `Geometry2D::segment_intersects_segment`: where segment a crosses segment b.
#[inline]
fn segments_cross(from_a: Vector2, to_a: Vector2, from_b: Vector2, to_b: Vector2) -> Option<Vector2> {
    let b = to_a - from_a;
    let c = from_b - from_a;
    let d = to_b - from_a;
    let ab_len = dot(b, b);
    if ab_len <= 0.0 {
        return None;
    }
    let bn = b / ab_len;
    let c = Vector2::new(c.x * bn.x + c.y * bn.y, c.y * bn.x - c.x * bn.y);
    let d = Vector2::new(d.x * bn.x + d.y * bn.y, d.y * bn.x - d.x * bn.y);
    if (c.y < -CMP_EPSILON && d.y < -CMP_EPSILON) || (c.y > CMP_EPSILON && d.y > CMP_EPSILON) {
        return None;
    }
    if equal_approx(c.y, d.y) {
        return None;
    }
    let ab_pos = d.x + (c.x - d.x) * d.y / (d.y - c.y);
    if !(0.0..=1.0).contains(&ab_pos) {
        return None;
    }
    Some(from_a + b * ab_pos)
}

/// Godot's `Geometry2D.is_point_in_polygon`, ported as Godot computes it (a ray to a
/// point beyond the polygon's box, counting the edges it crosses; a point on an edge is
/// inside), so the kernel and the GDScript reference agree on every bead.
pub fn point_in_polygon(p: Vector2, poly: &[Vector2]) -> bool {
    let n = poly.len();
    if n < 3 {
        return false;
    }
    let mut far = Vector2::new(-1e20, -1e20);
    let mut far_opposite = Vector2::new(1e20, 1e20);
    for &q in poly {
        far = vmax(far, q);
        far_opposite = vmin(far_opposite, q);
    }
    let span = far - far_opposite;
    far = far + Vector2::new(span.x * 1.221313, span.y * 1.512312);
    let mut crossings = 0;
    for i in 0..n {
        if let Some(at) = segments_cross(poly[i], poly[(i + 1) % n], p, far) {
            crossings += 1;
            if equal_approx(at.x, p.x) && equal_approx(at.y, p.y) {
                return true;
            }
        }
    }
    crossings & 1 == 1
}

/// Godot's `Geometry2D.get_closest_point_to_segment`.
#[inline]
pub fn closest_on_segment(p: Vector2, a: Vector2, b: Vector2) -> Vector2 {
    let q = p - a;
    let n = b - a;
    let l2 = len_sq(n);
    if l2 < 1e-20 {
        return a;
    }
    let d = dot(n, q) / l2;
    if d <= 0.0 {
        a
    } else if d >= 1.0 {
        b
    } else {
        a + n * d
    }
}

#[inline]
fn hull_cross(o: Vector2, a: Vector2, b: Vector2) -> f32 {
    (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
}

/// Godot's `Geometry2D.convex_hull` (Andrew's monotone chain; the first point is repeated
/// at the end).
pub fn convex_hull(points: &[Vector2]) -> Vec<Vector2> {
    let n = points.len();
    let mut p = points.to_vec();
    p.sort_by(|a, b| {
        if a.x == b.x {
            a.y.partial_cmp(&b.y).unwrap_or(std::cmp::Ordering::Equal)
        } else {
            a.x.partial_cmp(&b.x).unwrap_or(std::cmp::Ordering::Equal)
        }
    });
    let mut h: Vec<Vector2> = vec![Vector2::ZERO; 2 * n];
    let mut k = 0usize;
    for i in 0..n {
        while k >= 2 && hull_cross(h[k - 2], h[k - 1], p[i]) <= 0.0 {
            k -= 1;
        }
        h[k] = p[i];
        k += 1;
    }
    if n >= 2 {
        let t = k + 1;
        let mut i = n as isize - 2;
        while i >= 0 {
            while k >= t && hull_cross(h[k - 2], h[k - 1], p[i as usize]) <= 0.0 {
                k -= 1;
            }
            h[k] = p[i as usize];
            k += 1;
            i -= 1;
        }
    }
    h.truncate(k);
    h
}

/// `Goo2D._offset_loop`: each point moved `distance` along its vertex normal (the sum of
/// its two edges' length-weighted normals, normalized).
pub fn offset_loop(points: &[Vector2], distance: f32) -> Vec<Vector2> {
    let n = points.len();
    let mut normals = Vec::with_capacity(n);
    edge_normals(points, &mut normals);
    let mut out = Vec::with_capacity(n);
    for i in 0..n {
        let normal = norm(normals[(i + n - 1) % n] + normals[i]);
        out.push(points[i] + normal * distance);
    }
    out
}

/// Index of the point of `points` nearest `target` (0 for none).
pub fn nearest(points: &[Vector2], target: Vector2) -> usize {
    let mut best = 0;
    let mut best_d = f32::INFINITY;
    for (i, &p) in points.iter().enumerate() {
        let d = dist_sq(p, target);
        if d < best_d {
            best_d = d;
            best = i;
        }
    }
    best
}
