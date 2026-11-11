//! Static geometry the particles collide with: convex polygons in global space, registered
//! by GDScript (`GooKernel.add_static_shape()`: the arena's floor and walls, the wedge, the
//! blades, any `StaticBody2D` on `GooTuning.LAYER_WALLS`; GooStatics collects them). A
//! rectangle is a polygon of four points, a circle or a capsule an inscribed polygon. Each
//! shape carries its material as the solver combines it with a ring's (friction: the lower
//! of the two; bounce: their sum, clamped to 0..1, the rules the goo's tuning was found
//! with) and whether a bead touching it grips (`GooTuning.WALL_GRIP_DAMP`).

use crate::geom::*;
use godot::builtin::{Transform2D, Vector2};

pub struct StaticShape {
    pub id: i64,
    /// The polygon in the shape's own space, as registered.
    local: Vec<Vector2>,
    /// The polygon in global space, its unit outward edge normals (edge k → k+1) and box.
    pub world: Vec<Vector2>,
    pub normals: Vec<Vector2>,
    pub aabb: Rect,
    pub friction: f32,
    pub bounce: f32,
    pub grip: bool,
}

impl StaticShape {
    pub fn new(id: i64, xform: Transform2D, local: Vec<Vector2>, friction: f32, bounce: f32, grip: bool) -> Self {
        let mut s = StaticShape {
            id,
            local,
            world: Vec::new(),
            normals: Vec::new(),
            aabb: Rect::default(),
            friction,
            bounce,
            grip,
        };
        s.set_transform(xform);
        s
    }

    /// Moves the shape: its polygon is `xform` of the registered one.
    pub fn set_transform(&mut self, xform: Transform2D) {
        self.world = self.local.iter().map(|&p| xform * p).collect();
        let n = self.world.len();
        self.normals.clear();
        self.aabb = Rect::of_points(&self.world);
        if n < 2 {
            return;
        }
        let centre = centroid(&self.world);
        for k in 0..n {
            let a = self.world[k];
            let b = self.world[(k + 1) % n];
            let e = b - a;
            let mut normal = norm(Vector2::new(e.y, -e.x));
            if dot(normal, (a + b) * 0.5 - centre) < 0.0 {
                normal = -normal;
            }
            self.normals.push(normal);
        }
    }

    /// The gap between a circle of radius `r` at `p` and the shape (negative: the circle
    /// overlaps it by that much) and the unit direction pushing the circle out, if the
    /// gap is under `reach` (else None).
    #[inline]
    pub fn gap(&self, p: Vector2, r: f32, reach: f32) -> Option<(f32, Vector2)> {
        let n = self.world.len();
        if n < 3 {
            return None;
        }
        // The edge whose line the centre is furthest outside of (or least inside of).
        let mut best = f32::NEG_INFINITY;
        let mut best_k = 0;
        for k in 0..n {
            let s = dot(self.normals[k], p - self.world[k]);
            if s > best {
                best = s;
                best_k = k;
            }
        }
        if best - r >= reach {
            return None;
        }
        if best <= 0.0 {
            // Inside: out through the nearest face.
            return Some((best - r, self.normals[best_k]));
        }
        // Outside: the closest point of the outline (an edge or a corner).
        let mut nearest = f32::INFINITY;
        let mut closest = p;
        for k in 0..n {
            let q = closest_on_segment(p, self.world[k], self.world[(k + 1) % n]);
            let d = dist_sq(p, q);
            if d < nearest {
                nearest = d;
                closest = q;
            }
        }
        let d = nearest.sqrt();
        if d - r >= reach {
            return None;
        }
        let dir = if d > 1e-6 { (p - closest) / d } else { self.normals[best_k] };
        Some((d - r, dir))
    }
}
