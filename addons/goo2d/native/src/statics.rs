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
    /// A moving obstacle (a Godot body the goo is pushed by: obstacles.rs), its pose
    /// going from `from` toward `to` over a step's substeps, the beads' and cells'
    /// contacts judged on their motion relative to it (`motion`, the pose change of the
    /// current substep) and the impulse they took from it summed for the step. False: a
    /// wall, as before.
    pub dynamic: bool,
    pub from: Transform2D,
    pub to: Transform2D,
    pub motion: Transform2D,
    /// The farthest a point of its outline moves from `from` to `to`, and the box both
    /// poses cover.
    pub sweep: f32,
    pub swept: Rect,
    /// The impulse the goo gave it this step (the reaction of every contact), and that
    /// impulse's moment about the global origin (Σ p × J).
    pub impulse: Vector2,
    pub moment: f32,
    /// A rigid body's (`set_rigid()`): instead of following a set path, the obstacle moves
    /// with `vel` and `ang` (rad/s, clockwise on screen) about its centre of mass `com`,
    /// which every contact changes by its impulse through `inv_mass` and `inv_inertia`
    /// (the goo's units), shared by the shapes of one `body` (0: none). A path's
    /// obstacle (inv_mass and inv_inertia 0) is not moved by the goo.
    pub body: i64,
    pub rigid: bool,
    pub inv_mass: f32,
    pub inv_inertia: f32,
    pub com: Vector2,
    pub vel: Vector2,
    pub ang: f32,
    pose: Transform2D,
    /// Contacts in the last substep, for the cells' mass splitting (each cell judges its
    /// contact alone within a substep), and this substep's count.
    pub split: f32,
    pub split_now: f32,
    /// This substep's contacts with beads (bead, unit normal, the change its velocity
    /// along the normal takes in the kernel's velocity pass).
    pub hits: Vec<(u32, Vector2, f32)>,
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
            body: 0,
            rigid: false,
            inv_mass: 0.0,
            inv_inertia: 0.0,
            com: Vector2::ZERO,
            vel: Vector2::ZERO,
            ang: 0.0,
            pose: xform,
            split: 1.0,
            split_now: 0.0,
            hits: Vec::new(),
        };
        s.set_transform(xform);
        s.swept = s.aabb;
        s
    }

    /// Makes the shape a moving obstacle and gives it the pose `xform` it reaches at the
    /// end of the next step, from the one it reached at the end of the last (its first
    /// target: from where it was registered). Until the step it stays at `from`.
    pub fn set_target(&mut self, xform: Transform2D) {
        let from = self.to;
        self.set_path(from, xform);
        self.rigid = false;
        self.inv_mass = 0.0;
        self.inv_inertia = 0.0;
    }

    /// Makes the shape a moving obstacle of a rigid body (`body`, its other shapes given
    /// the same) at `from` now, its centre of mass at `com`, moving with `vel` and `ang`
    /// (gravity's pull over the step included), of inverse mass and inertia `inv_mass`
    /// and `inv_inertia` in the goo's units; `to` where that motion alone takes it by the
    /// step's end (for the broad phase).
    #[allow(clippy::too_many_arguments)]
    pub fn set_rigid(&mut self, body: i64, from: Transform2D, to: Transform2D, com: Vector2, vel: Vector2, ang: f32, inv_mass: f32, inv_inertia: f32) {
        self.set_path(from, to);
        self.rigid = true;
        self.body = body;
        self.com = com;
        self.vel = vel;
        self.ang = ang;
        self.inv_mass = inv_mass.max(0.0);
        self.inv_inertia = inv_inertia.max(0.0);
        self.split = 1.0;
        self.split_now = 0.0;
    }

    /// Makes the shape a moving obstacle that goes from `from` to `to` over the next step.
    pub fn set_motion(&mut self, from: Transform2D, to: Transform2D) {
        self.set_path(from, to);
        self.rigid = false;
        self.inv_mass = 0.0;
        self.inv_inertia = 0.0;
    }

    fn set_path(&mut self, from: Transform2D, to: Transform2D) {
        self.dynamic = true;
        self.from = from;
        self.to = to;
        self.pose = from;
        self.motion = Transform2D::IDENTITY;
        let mut sweep = 0.0f32;
        let mut ends: Vec<Vector2> = Vec::with_capacity(self.local.len() * 2);
        for &p in &self.local {
            let (a, b) = (from * p, to * p);
            sweep = sweep.max(dist(a, b));
            ends.push(a);
            ends.push(b);
        }
        self.sweep = sweep;
        // A rigid body may end up off its predicted path by what the goo gives it.
        self.swept = Rect::of_points(&ends).grow(0.5 * sweep);
        self.set_transform(from);
    }

    /// Moves the obstacle on to substep `k` of `n` (`h` long), `motion` the change: a path
    /// eased from `from` to `to`, a rigid body by its velocity now.
    pub fn substep(&mut self, k: usize, n: usize, h: f32) {
        let next = if self.rigid {
            let turn = Transform2D::from_angle_origin(self.ang * h, Vector2::ZERO);
            let c = self.com;
            let about = Transform2D::IDENTITY.translated(-c);
            let back = Transform2D::IDENTITY.translated(c + self.vel * h);
            self.com = c + self.vel * h;
            back * turn * about * self.pose
        } else {
            let n = n.max(1) as f32;
            self.from.interpolate_with(&self.to, (k + 1) as f32 / n)
        };
        self.motion = next * self.pose.affine_inverse();
        self.pose = next;
        self.set_transform(next);
        if self.rigid {
            self.split = self.split_now.max(1.0);
            self.split_now = 0.0;
        }
    }

    /// The obstacle's velocity at `p` this substep (`inv_h` one over its length).
    #[inline]
    pub fn velocity_at(&self, p: Vector2, inv_h: f32) -> Vector2 {
        if self.rigid {
            let r = p - self.com;
            self.vel + Vector2::new(-self.ang * r.y, self.ang * r.x)
        } else {
            (p - self.motion.affine_inverse() * p) * inv_h
        }
    }

    /// Its inverse mass seen along `n` at `p` (0: a path's, or an immovable body's).
    #[inline]
    pub fn inv_mass_at(&self, p: Vector2, n: Vector2) -> f32 {
        if !self.rigid {
            return 0.0;
        }
        let c = cross(p - self.com, n);
        self.inv_mass + self.inv_inertia * c * c
    }

    /// The impulse −j at `point` changes a rigid body's motion (any of its shapes).
    #[inline]
    pub fn take(&mut self, point: Vector2, j: Vector2) {
        if self.rigid {
            self.vel -= j * self.inv_mass;
            self.ang -= self.inv_inertia * cross(point - self.com, j);
        }
    }

    /// The step is over: the obstacle where it got to, no motion left to replay.
    pub fn end_step(&mut self) {
        let at = if self.rigid { self.pose } else { self.to };
        self.from = at;
        self.to = at;
        self.pose = at;
        self.motion = Transform2D::IDENTITY;
        self.set_transform(at);
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
