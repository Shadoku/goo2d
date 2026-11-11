//! The skin outline: ports of `Goo2D.skin_offset` (the kink-clamped offset) and
//! `Goo2D._drawable_skin` (Chaikin keeping the corners, then the drawability check: an
//! outline that crosses itself is cut at its crossings into loops that do not, one polygon
//! each, and a loop no crossing accounts for is repaired by Clipper). The check and the
//! repair call Godot's own `Geometry2D` (the triangulator `Polygon2D` draws with, and
//! Clipper's offset), so "drawable" means exactly what it means to the renderer.

use crate::consts::*;
use crate::geom::*;
use godot::builtin::{PackedVector2Array, Vector2};
use godot::classes::Geometry2D;

/// `Goo2D.skin_offset`: each bead pushed `distance` along its vertex normal, the offsets
/// around a concave kink shortened so they do not cross.
pub fn skin_offset(points: &[Vector2], distance: f32) -> Vec<Vector2> {
    let count = points.len();
    let mut normals = Vec::with_capacity(count);
    edge_normals(points, &mut normals);
    let mut directions = Vec::with_capacity(count);
    let mut kinks: Vec<i64> = Vec::new();
    let min_turn = SKIN_KINK_TURN.sin();
    for i in 0..count {
        let before = normals[(i + count - 1) % count];
        let after = normals[i];
        directions.push(norm(before + after));
        if (cross(before, after) as f64) > min_turn * len(before) as f64 * len(after) as f64 {
            kinks.push(i as i64);
        }
    }
    let mut offsets = vec![distance; count];
    let n = count as i64;
    for &kink in &kinks {
        for a in (kink - SKIN_KINK_REACH)..(kink + 1) {
            let b_from = (a + 1).max(kink);
            let b_to = (a + SKIN_KINK_REACH).min(a + n - 1);
            for b in b_from..(b_to + 1) {
                let i = a.rem_euclid(n) as usize;
                let j = b.rem_euclid(n) as usize;
                let gap = points[j] - points[i];
                let length = len(gap);
                if length <= 0.0 {
                    continue;
                }
                let along = gap / length;
                let closing = (dot(directions[i], along) as f64).max(0.0)
                    + (-(dot(directions[j], along)) as f64).max(0.0);
                if closing * distance as f64 > SKIN_KINK_CLEARANCE * length as f64 {
                    let limit = (SKIN_KINK_CLEARANCE * length as f64 / closing) as f32;
                    offsets[i] = offsets[i].min(limit);
                    offsets[j] = offsets[j].min(limit);
                }
            }
        }
    }
    (0..count).map(|i| points[i] + directions[i] * offsets[i]).collect()
}

/// The smoothed outline of `raw`, before the drawability check.
pub fn smooth(raw: &[Vector2], corners: &[u8]) -> Vec<Vector2> {
    if corners.iter().any(|&c| c == 1) {
        chaikin_keeping(raw, SKIN_SMOOTHING, corners)
    } else {
        chaikin(raw, SKIN_SMOOTHING)
    }
}

/// `Goo2D._drawable_skin`: the skin of the CCW bead loop `points` (beads of radius
/// `bead_radius`, the corners flagged in `corners`) as polygons Polygon2D can draw, every
/// one CCW. A bead loop that does not cross itself gets one polygon, its smoothed offset
/// (`drawable_outline`). One that does (a ring folded through itself) is first cut at its
/// crossings into loops that do not (`split_at_crossings`), each turned CCW (the lobe of
/// a fold is wound the other way, so its beads' normals point into it: offset as part of
/// the whole loop its skin would shrink, and Clipper's offset dropped it altogether), and
/// each gets the skin of its own, so every part of the body is drawn. A bead loop that is
/// inside out as a whole (CW) is turned CCW first for the same reason. Empty if nothing can
/// be drawn.
pub fn drawable(points: &[Vector2], bead_radius: f32, corners: &[u8], geometry: &mut godot::obj::Gd<Geometry2D>) -> Vec<Vec<Vector2>> {
    drawable_repaired(points, bead_radius, corners, geometry).0
}

/// `drawable()`, and whether Clipper had to repair a loop (the costly case).
pub fn drawable_repaired(points: &[Vector2], bead_radius: f32, corners: &[u8], geometry: &mut godot::obj::Gd<Geometry2D>) -> (Vec<Vec<Vector2>>, bool) {
    let mut out = Vec::new();
    let mut repaired = false;
    if first_crossing(points).is_none() {
        if is_ccw(points) {
            drawable_outline(&skin_offset(points, bead_radius), corners, geometry, &mut out, &mut repaired, false);
        } else {
            let mut reversed = points.to_vec();
            reversed.reverse();
            let mut flags = corners.to_vec();
            flags.reverse();
            drawable_outline(&skin_offset(&reversed, bead_radius), &flags, geometry, &mut out, &mut repaired, true);
        }
        return (out, repaired);
    }
    let mut loops = Vec::new();
    let mut splits = SKIN_MAX_SPLITS;
    split_at_crossings(points.to_vec(), corners.to_vec(), &mut loops, &mut splits);
    for (mut lp, mut flags) in loops {
        if lp.len() < 3 {
            continue;
        }
        if !is_ccw(&lp) {
            lp.reverse();
            flags.reverse();
        }
        drawable_outline(&skin_offset(&lp, bead_radius), &flags, geometry, &mut out, &mut repaired, true);
    }
    (out, repaired)
}

/// The smoothed outline `raw` (`skin_offset` of a loop, with its `corners`) as polygons
/// Polygon2D can draw, appended to `out`: the outline itself when it is a simple polygon
/// (`is_simple`: drawn without asking Godot's triangulator, which never fails on one: ear
/// clipping, with its relaxed last round for aligned points) or the triangulator accepts
/// it, as `Polygon2D` will; else (the offsets crossed at a kink the clamp did not catch)
/// the loops it is cut into at its crossings, each as it is when it triangulates, CCW;
/// a loop that still cannot be drawn (edges touching or overlapping without crossing) is
/// repaired by Clipper into the largest simple boundary of what it covers (`repaired` is
/// then set), or dropped if even that cannot be drawn. With `ask`, the triangulator is
/// asked about the outline whatever `is_simple` says: the lobe of a fold can be a sliver
/// whose offset is simple to the eye of that check but not of the triangulator, and such a
/// piece is not worth a sub-polygon `Polygon2D` would skip.
fn drawable_outline(raw: &[Vector2], corners: &[u8], geometry: &mut godot::obj::Gd<Geometry2D>, out: &mut Vec<Vec<Vector2>>, repaired: &mut bool, ask: bool) {
    let smooth = smooth(raw, corners);
    if (!ask && is_simple(&smooth)) || triangulates(&smooth, geometry) {
        out.push(smooth);
        return;
    }
    let mut loops = Vec::new();
    let mut splits = SKIN_MAX_SPLITS;
    split_at_crossings(smooth, Vec::new(), &mut loops, &mut splits);
    for (mut lp, _) in loops {
        if lp.len() < 3 {
            continue;
        }
        // The triangulator itself, not is_simple(): a sliver loop can be simple to the
        // one and not the other, and Polygon2D would skip it.
        if triangulates(&lp, geometry) {
            if !is_ccw(&lp) {
                lp.reverse();
            }
            out.push(lp);
            continue;
        }
        *repaired = true;
        if let Some(best) = clipper_largest(&lp, geometry) {
            out.push(best);
        }
    }
}

fn triangulates(p: &[Vector2], geometry: &mut godot::obj::Gd<Geometry2D>) -> bool {
    !geometry.triangulate_polygon(&PackedVector2Array::from(p)).is_empty()
}

/// The largest simple boundary (CCW) of what the loop `p` covers, by Clipper's offset of
/// `SKIN_REPAIR_GROW` px, if Polygon2D can draw it.
fn clipper_largest(p: &[Vector2], geometry: &mut godot::obj::Gd<Geometry2D>) -> Option<Vec<Vector2>> {
    let packed = PackedVector2Array::from(p);
    let mut best: Option<PackedVector2Array> = None;
    let mut best_area = 0.0f64;
    for piece in geometry.offset_polygon(&packed, SKIN_REPAIR_GROW).iter_shared() {
        let a = area(piece.as_slice());
        if a > best_area {
            best_area = a;
            best = Some(piece);
        }
    }
    let best = best?;
    if best.len() < 3 || geometry.triangulate_polygon(&best).is_empty() {
        return None;
    }
    let mut out = best.as_slice().to_vec();
    if !is_ccw(&out) {
        out.reverse();
    }
    Some(out)
}

/// `GooLoop.first_crossing`: the first two edges of the closed loop `p` (i < j, in order of
/// i then j) that cross properly, at a point inside both, and that point. Edges that share
/// a vertex, touch or overlap do not count.
pub fn first_crossing(p: &[Vector2]) -> Option<(usize, usize, Vector2)> {
    let n = p.len();
    if n < 4 {
        return None;
    }
    for i in 0..n {
        let a = p[i];
        let b = p[(i + 1) % n];
        for j in (i + 2)..n {
            if i == 0 && j == n - 1 {
                continue;
            }
            if let Some(x) = proper_crossing(a, b, p[j], p[(j + 1) % n]) {
                return Some((i, j, x));
            }
        }
    }
    None
}

/// Where the segments a-b and c-d cross, if they do so properly: at a point strictly inside
/// both. Godot's float semantics: the orientations in f64 from the points' f32 components,
/// the crossing point as `a + (b - a) * t` in f32.
fn proper_crossing(a: Vector2, b: Vector2, c: Vector2, d: Vector2) -> Option<Vector2> {
    let d1 = orient(c, d, a);
    let d2 = orient(c, d, b);
    let d3 = orient(a, b, c);
    let d4 = orient(a, b, d);
    let opposite = |u: f64, v: f64| (u > 0.0 && v < 0.0) || (u < 0.0 && v > 0.0);
    if !(opposite(d1, d2) && opposite(d3, d4)) {
        return None;
    }
    let t = d1 / (d1 - d2);
    Some(a + (b - a) * t as f32)
}

/// `GooLoop.split_at_crossings` (and `split_flags`): the closed loop `p` cut at its
/// crossings into loops that do not cross themselves, appended to `out` with their
/// points' `flags` (one per point, carried along; empty for none; a crossing point gets
/// 0): at the first crossing (`first_crossing`) of edges i and j at X, the loop becomes
/// p[0..=i], X, p[j+1..] and X, p[i+1..=j], each cut again in turn. A loop with no
/// crossing goes to `out` as it is, as does one left when the `splits` budget runs out (a
/// loop tangled past it is not worth more polygons).
pub fn split_at_crossings(p: Vec<Vector2>, flags: Vec<u8>, out: &mut Vec<(Vec<Vector2>, Vec<u8>)>, splits: &mut usize) {
    if p.len() < 3 {
        return;
    }
    let crossing = if *splits > 0 { first_crossing(&p) } else { None };
    let Some((i, j, x)) = crossing else {
        out.push((p, flags));
        return;
    };
    *splits -= 1;
    let tagged = flags.len() == p.len();
    let mut first = Vec::with_capacity(i + 2 + p.len() - j - 1);
    first.extend_from_slice(&p[..=i]);
    first.push(x);
    first.extend_from_slice(&p[j + 1..]);
    let mut second = Vec::with_capacity(j - i + 1);
    second.push(x);
    second.extend_from_slice(&p[i + 1..=j]);
    let (mut first_flags, mut second_flags) = (Vec::new(), Vec::new());
    if tagged {
        first_flags.extend_from_slice(&flags[..=i]);
        first_flags.push(0);
        first_flags.extend_from_slice(&flags[j + 1..]);
        second_flags.push(0);
        second_flags.extend_from_slice(&flags[i + 1..=j]);
    }
    split_at_crossings(first, first_flags, out, splits);
    split_at_crossings(second, second_flags, out, splits);
}

/// The outline the goo shader gets (`GooSkin.update`): `raw` resampled to at most
/// `SHADER_POINTS`, padded with its last point (with `center` if empty) to exactly that many.
pub fn shader_points(raw: &[Vector2], center: Vector2) -> Vec<Vector2> {
    let source = if raw.len() > SHADER_POINTS { resample(raw, SHADER_POINTS) } else { raw.to_vec() };
    let count = source.len();
    (0..SHADER_POINTS)
        .map(|i| if i < count { source[i] } else if count > 0 { source[count - 1] } else { center })
        .collect()
}

#[inline]
fn orient(a: Vector2, b: Vector2, c: Vector2) -> f64 {
    let (ax, ay) = (a.x as f64, a.y as f64);
    (b.x as f64 - ax) * (c.y as f64 - ay) - (b.y as f64 - ay) * (c.x as f64 - ax)
}

/// True if the segments a-b and c-d cross or touch, or come within rounding of it (so a
/// "false" is certain).
fn segments_meet(a: Vector2, b: Vector2, c: Vector2, d: Vector2) -> bool {
    let scale = (len_sq(b - a) as f64).max(len_sq(d - c) as f64).max(1e-12);
    let eps = 1e-9 * scale;
    let d1 = orient(c, d, a);
    let d2 = orient(c, d, b);
    let d3 = orient(a, b, c);
    let d4 = orient(a, b, d);
    let sign = |v: f64| if v > eps { 1 } else if v < -eps { -1 } else { 0 };
    let (s1, s2, s3, s4) = (sign(d1), sign(d2), sign(d3), sign(d4));
    if s1 * s2 < 0 && s3 * s4 < 0 {
        return true;
    }
    // Any (near) collinear case: count it as meeting when the boxes overlap.
    if s1 == 0 || s2 == 0 || s3 == 0 || s4 == 0 {
        return a.x.min(b.x) <= c.x.max(d.x)
            && c.x.min(d.x) <= a.x.max(b.x)
            && a.y.min(b.y) <= c.y.max(d.y)
            && c.y.min(d.y) <= a.y.max(b.y);
    }
    false
}

/// True if the closed loop is certainly a simple polygon: no repeated consecutive points, no
/// edge folding straight back on the one before, no two other edges crossing or touching.
/// A sweep over the edges sorted by their left end, each tested only against the edges
/// whose x range it overlaps.
pub fn is_simple(p: &[Vector2]) -> bool {
    let n = p.len();
    if n < 3 {
        return false;
    }
    let mut a = p[n - 1];
    for i in 0..n {
        let b = p[i];
        let c = p[if i + 1 == n { 0 } else { i + 1 }];
        if b == c {
            return false;
        }
        // Folding back: the two edges at b collinear and opposite.
        let (u, v) = (b - a, c - b);
        if dot(u, v) < 0.0 {
            let cr = cross(u, v) as f64;
            if cr.abs() <= 1e-9 * (len(u) as f64 * len(v) as f64).max(1e-12) {
                return false;
            }
        }
        a = b;
    }
    // Each edge i -> i+1 by its x range, the edges sorted by their left end.
    let mut ends: Vec<(Vector2, Vector2)> = Vec::with_capacity(n);
    let mut order: Vec<(f32, f32, u32)> = Vec::with_capacity(n);
    for i in 0..n {
        let (a, b) = (p[i], p[if i + 1 == n { 0 } else { i + 1 }]);
        ends.push((a, b));
        order.push((a.x.min(b.x), a.x.max(b.x), i as u32));
    }
    order.sort_unstable_by(|a, b| a.0.total_cmp(&b.0));
    // The edges whose x range still reaches the sweep: (right end, index).
    let mut active: Vec<(f32, u32)> = Vec::with_capacity(16);
    for &(x0, x1, i) in &order {
        let i = i as usize;
        let (a, b) = ends[i];
        active.retain(|&(right, _)| right >= x0);
        let (y0, y1) = (a.y.min(b.y), a.y.max(b.y));
        let next = if i + 1 == n { 0 } else { i + 1 };
        for &(_, j) in &active {
            let j = j as usize;
            if j == next || i == (if j + 1 == n { 0 } else { j + 1 }) {
                continue;
            }
            let (c, d) = ends[j];
            if c.y.max(d.y) < y0 || c.y.min(d.y) > y1 {
                continue;
            }
            if segments_meet(a, b, c, d) {
                return false;
            }
        }
        active.push((x1, i as u32));
    }
    true
}
