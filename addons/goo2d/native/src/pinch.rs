//! Split detection: ports of `Goo2D.hull_depths`, `Goo2D.find_pinch` (with its candidate
//! sweep) and `Goo2D._short_axis_beads`. `test_goo_kernel.gd` checks them against the
//! GDScript functions on random loops.

use crate::geom::*;
use godot::builtin::Vector2;

/// What `find_pinch` found: the narrowest neck, or `a == b == -1` and an infinite gap.
#[derive(Clone, Copy, Debug)]
pub struct Neck {
    pub a: i64,
    pub b: i64,
    pub gap: f64,
    pub constriction: f64,
}

impl Neck {
    pub const NONE: Neck = Neck { a: -1, b: -1, gap: f64::INFINITY, constriction: 0.0 };
}

/// How far each point of the loop lies inside the loop's convex hull (0 on it).
pub fn hull_depths(points: &[Vector2]) -> Vec<f32> {
    let mut depths = vec![0.0f32; points.len()];
    let hull = convex_hull(points);
    let corners = hull.len();
    if corners < 3 {
        return depths;
    }
    for (i, &p) in points.iter().enumerate() {
        // A hull corner is at depth 0 without measuring (most beads of a ring).
        if hull.iter().any(|&c| c == p) {
            continue;
        }
        let mut nearest = f64::INFINITY;
        for k in 0..corners {
            let on_edge = closest_on_segment(p, hull[k], hull[(k + 1) % corners]);
            nearest = nearest.min(dist_sq(p, on_edge) as f64);
        }
        depths[i] = nearest.sqrt() as f32;
    }
    depths
}

/// `Goo2D._pinch_candidates`: the pairs `i * count + j` find_pinch must look at, ascending.
fn candidates(points: &[Vector2], depths: &[f32], apart: usize, min_c: f64) -> Vec<usize> {
    let count = points.len();
    let mut pairs = Vec::new();
    if min_c <= 0.0 {
        for i in 0..count {
            for j in (i + apart)..count {
                if count - (j - i) < apart {
                    break;
                }
                pairs.push(i * count + j);
            }
        }
        return pairs;
    }
    let mut deepest = 0.0f64;
    for &d in depths {
        deepest = (d as f64).max(deepest);
    }
    if deepest <= 0.0 {
        return pairs;
    }
    let mut reach = 2.0 * deepest * (1.0 - min_c).max(0.0) / min_c;
    reach = reach * 1.001 + 0.001;
    let mut order: Vec<(f32, f32, f32)> = points.iter().enumerate().map(|(i, p)| (p.x, p.y, i as f32)).collect();
    order.sort_by(|a, b| {
        a.0.partial_cmp(&b.0)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then(a.1.partial_cmp(&b.1).unwrap_or(std::cmp::Ordering::Equal))
            .then(a.2.partial_cmp(&b.2).unwrap_or(std::cmp::Ordering::Equal))
    });
    for a in 0..count {
        let from = order[a];
        for b in (a + 1)..count {
            let to = order[b];
            if (to.0 - from.0) as f64 > reach {
                break;
            }
            if ((to.1 - from.1).abs() as f64) > reach {
                continue;
            }
            let i = (from.2 as usize).min(to.2 as usize);
            let j = (from.2 as usize).max(to.2 as usize);
            if j - i < apart || count - (j - i) < apart {
                continue;
            }
            pairs.push(i * count + j);
        }
    }
    pairs.sort_unstable();
    pairs
}

/// `Goo2D.find_pinch`.
pub fn find_pinch(
    points: &[Vector2],
    bead_size: f64,
    min_c: f64,
    rest: &[Vector2],
    min_rest_distance: f64,
    rest_depths: &[f32],
) -> Neck {
    let count = points.len();
    if count == 0 {
        return Neck::NONE;
    }
    let apart = (count / 4).max(2);
    let mut depths = hull_depths(points);
    if rest_depths.len() == count {
        for i in 0..count {
            depths[i] = (depths[i] - rest_depths[i]).max(0.0);
        }
    }
    let mut best = Neck::NONE;
    let mut best_distance = f64::INFINITY;
    let check_rest = rest.len() == count;
    for pair in candidates(points, &depths, apart, min_c) {
        let i = pair / count;
        let j = pair % count;
        if check_rest && (dist(rest[i], rest[j]) as f64) < min_rest_distance {
            continue;
        }
        let distance = dist(points[i], points[j]) as f64;
        if distance >= best_distance {
            continue;
        }
        let pressed = depths[i] as f64 + depths[j] as f64;
        let constriction = pressed / (distance + pressed).max(0.001);
        if constriction < min_c {
            continue;
        }
        if !point_in_polygon((points[i] + points[j]) * 0.5, points) {
            continue;
        }
        best_distance = distance;
        best = Neck { a: i as i64, b: j as i64, gap: distance - 2.0 * bead_size, constriction };
    }
    best
}

/// `Goo2D._short_axis_beads`: the beads nearest the ends of the loop's short principal axis.
pub fn short_axis_beads(points: &[Vector2]) -> (usize, usize) {
    let centre = centroid(points);
    let (mut sxx, mut sxy, mut syy) = (0.0f64, 0.0f64, 0.0f64);
    for &p in points {
        let d = p - centre;
        sxx += (d.x * d.x) as f64;
        sxy += (d.x * d.y) as f64;
        syy += (d.y * d.y) as f64;
    }
    let angle = 0.5 * (2.0 * sxy).atan2(sxx - syy) + std::f64::consts::FRAC_PI_2;
    let minor = Vector2::new(angle.cos() as f32, angle.sin() as f32);
    let mut low = f64::INFINITY;
    let mut high = f64::NEG_INFINITY;
    for &p in points {
        let along = dot(p - centre, minor) as f64;
        low = low.min(along);
        high = high.max(along);
    }
    (
        nearest(points, centre + minor * high as f32),
        nearest(points, centre + minor * low as f32),
    )
}
