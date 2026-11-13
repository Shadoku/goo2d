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
    /// A moving obstacle (a Godot body the goo is pushed by, `set_target()`): its pose
    /// eased from `from` to `to` over a step's substeps, the beads' and cells' contacts
    /// judged on their motion relative to it (`motion`, the pose change of the current
    /// substep), the impulse they took from it summed for the step (bridge.rs). False:
    /// a wall, as before.
    pub dynamic: bool,
    pub from: Transform2D,
    pub to: Transform2D,
    pub motion: Transform2D,
    /// The farthest a point of its outline moves from `from` to `to`, and the box both
    /// poses cover.
    pub sweep: f32,
    pub swept: Rect,
    /// The impulse the goo gave it this step (the reaction of every push it made: −m Δ/h
    /// per push), and that impulse's moment about the global origin (Σ p × J).
    pub impulse: Vector2,
    pub moment: f32,
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
            dynamic: false,
            from: xform,
            to: xform,
            motion: Transform2D::IDENTITY,
            sweep: 0.0,
            swept: Rect::default(),
            impulse: Vector2::ZERO,
            moment: 0.0,
        };
        s.set_transform(xform);
        s.swept = s.aabb;
        s
    }

    /// Makes the shape a moving obstacle and gives it the pose `xform` it reaches at the
    /// end of the next step, from the one it reached at the end of the last (its first
    /// target: from where it was registered). Until the step it stays at `from`.
    pub fn set_target(&mut self, xform: Transform2D) {
        self.dynamic = true;
        self.from = self.to;
        self.to = xform;
        self.motion = Transform2D::IDENTITY;
        let mut sweep = 0.0f32;
        let mut ends: Vec<Vector2> = Vec::with_capacity(self.local.len() * 2);
        for &p in &self.local {
            let (a, b) = (self.from * p, self.to * p);
            sweep = sweep.max(dist(a, b));
            ends.push(a);
            ends.push(b);
        }
        self.sweep = sweep;
        self.swept = Rect::of_points(&ends);
        let from = self.from;
        self.set_transform(from);
    }

    /// Puts a moving obstacle where it is `t1` of the way through the step, `motion` the
    /// change from where it was at `t0`.
    pub fn substep_to(&mut self, t0: f32, t1: f32) {
        let a = self.from.interpolate_with(&self.to, t0);
        let b = self.from.interpolate_with(&self.to, t1);
        self.motion = b * a.affine_inverse();
        self.set_transform(b);
    }

    /// The step is over: the obstacle at its target, no motion left to replay.
    pub fn end_step(&mut self) {
        let to = self.to;
        self.from = to;
        self.motion = Transform2D::IDENTITY;
        self.set_transform(to);
        self.sweep = 0.0;
        self.swept = self.aabb;
    }

    /// The goo took `j` at `point` from this obstacle: its reaction, −j, is summed.
    #[inline]
    pub fn add_reaction(&mut self, point: Vector2, j: Vector2) {
        self.impulse -= j;
        self.moment -= cross(point, j);
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
