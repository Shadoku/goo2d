//! Goo2D's native kernel, loaded by Godot through `addons/goo2d/goo2d.gdextension`.
//!
//! Stage 2 of `docs/native-kernel-plan.md`: the kernel owns the goo's beads and moves them
//! with its own position-based (XPBD) solver; no physics server is involved. A `GooKernel`
//! holds rings (one per `Goo2D`: its particles, rest shape, tuning and per-frame state;
//! never a Godot object) and the static shapes they collide with, and steps them all once
//! per physics frame (`step()`; see kernel.rs for what a step does). A `GooWorld2D` owns
//! one kernel and runs its pair passes in it; `Goo2D`s outside any world share one of
//! their own. GDScript reads the step's events (`take_events()`) and each ring's results
//! (points, velocities, centre, box, skin...), and keeps everything event-driven.
//!
//! The static functions (`find_pinch`, `hull_depths`, `skin_outline`, `intrusion`,
//! `untangle_push`, the loop helpers...) are the kernel's math on plain arrays, for
//! `tests/unit/test_goo_kernel.gd` to check against the GDScript reference
//! implementations on random loops.

mod cells;
mod cells_draw;
mod colony;
mod consts;
mod forces;
mod geom;
mod grid;
mod kernel;
mod links;
mod pinch;
mod skin;
mod statics;

use crate::geom::Rect;
use godot::classes::Geometry2D;
use godot::prelude::*;

struct Goo2dKernel;

/// The extension's entry point. godot-rust exports it as `gdext_rust_init`, the
/// `entry_symbol` in `goo2d.gdextension`.
#[gdextension]
unsafe impl ExtensionLibrary for Goo2dKernel {}

/// The goo's native kernel: the per-frame math of a set of Goo2D rings (see the crate
/// docs). Rings are named by a key, the Goo2D's instance id.
#[derive(GodotClass)]
#[class(base = RefCounted, init)]
pub struct GooKernel {
    k: kernel::Kernel,
    base: Base<RefCounted>,
}

fn v2(p: &PackedVector2Array) -> Vec<Vector2> {
    p.as_slice().to_vec()
}

fn pv2(v: &[Vector2]) -> PackedVector2Array {
    PackedVector2Array::from(v)
}

fn num(d: &VarDictionary, key: &str) -> f64 {
    match d.get(&key.to_variant()) {
        Some(v) => v.try_to::<f64>().or_else(|_| v.try_to::<i64>().map(|i| i as f64)).unwrap_or(0.0),
        None => 0.0,
    }
}

fn put<T: ToGodot>(d: &mut VarDictionary, key: &str, value: T) {
    d.set(&key.to_variant(), &value.to_variant());
}

fn indices(v: &[usize]) -> PackedInt32Array {
    PackedInt32Array::from(v.iter().map(|&i| i as i32).collect::<Vec<_>>().as_slice())
}

fn rect2(r: Rect) -> Rect2 {
    Rect2::new(r.pos, r.size)
}

#[godot_api]
impl GooKernel {
    /// The kernel's version (the crate's), e.g. "0.2.0".
    #[func]
    fn version(&self) -> GString {
        GString::from(env!("CARGO_PKG_VERSION"))
    }

    /// The sum of `values`: proves a packed array reaches Rust and a float comes back.
    #[func]
    fn sum(&self, values: PackedFloat32Array) -> f32 {
        values.as_slice().iter().sum()
    }

    // ---- Rings ----

    /// Adds (or replaces) the ring `key`: its beads at `points` (global, ring order, at
    /// rest), its rest shape about its centroid, rest edge lengths, rest hull depths
    /// (empty for a round ring), corner flags, and `params` (radius, bead_mass,
    /// bead_radius, pressure_k, shape_match_k, internal_damp, settle_speed, settle_time,
    /// split_neck, splat_area_ratio, min_neck_rest, target_area, split_lock,
    /// skin_stiffness, skin_damping, bending_stiffness, bending_damping, linear_damp,
    /// bounce, friction). Builds the skin right away.
    #[func]
    #[allow(clippy::too_many_arguments)]
    fn add_ring(
        &mut self,
        key: i64,
        points: PackedVector2Array,
        rest: PackedVector2Array,
        rest_edges: PackedFloat32Array,
        rest_depths: PackedFloat32Array,
        corners: PackedByteArray,
        params: VarDictionary,
    ) {
        let p = kernel::Params {
            radius: num(&params, "radius"),
            bead_mass: num(&params, "bead_mass"),
            bead_radius: num(&params, "bead_radius"),
            pressure_k: num(&params, "pressure_k"),
            shape_k: num(&params, "shape_match_k"),
            internal_damp: num(&params, "internal_damp"),
            settle_speed: num(&params, "settle_speed"),
            settle_time: num(&params, "settle_time"),
            split_neck: num(&params, "split_neck"),
            splat_area_ratio: num(&params, "splat_area_ratio"),
            min_neck_rest: num(&params, "min_neck_rest"),
            target_area: num(&params, "target_area"),
            split_lock: num(&params, "split_lock"),
            skin_stiffness: num(&params, "skin_stiffness"),
            skin_damping: num(&params, "skin_damping"),
            bending_stiffness: num(&params, "bending_stiffness"),
            bending_damping: num(&params, "bending_damping"),
            linear_damp: num(&params, "linear_damp"),
            bounce: num(&params, "bounce"),
            friction: num(&params, "friction"),
        };
        self.k.add_ring(
            key,
            v2(&points),
            v2(&rest),
            rest_edges.as_slice().to_vec(),
            rest_depths.as_slice().to_vec(),
            corners.as_slice().to_vec(),
            p,
        );
    }

    /// Forgets the ring `key` and its particles.
    #[func]
    fn remove_ring(&mut self, key: i64) {
        self.k.remove_ring(key);
    }

    #[func]
    fn has_ring(&self, key: i64) -> bool {
        self.k.find(key).is_some()
    }

    #[func]
    fn ring_count(&self) -> i64 {
        self.k.rings.len() as i64
    }

    /// Particles of every ring.
    #[func]
    fn particle_count(&self) -> i64 {
        self.k.ps.pos.len() as i64
    }

    /// Sets one of the values GDScript changes after building: "target_area" (the inflate
    /// tween), "split_lock" (seconds) or "rest_blend" (0..1: the skin and bending rest
    /// lengths go from those of the loop the ring was placed on at add_ring(), 0, to
    /// those of its rest shape, 1, the default; a merged ring's tween, Goo2D.rest_blend).
    #[func]
    fn set_ring_param(&mut self, key: i64, name: StringName, value: f64) {
        let name = name.to_string();
        if name == "rest_blend" {
            self.k.set_rest_blend(key, value);
            return;
        }
        let Some(r) = self.k.ring_mut(key) else { return };
        match name.as_str() {
            "target_area" => r.target_area = value,
            "split_lock" => r.split_lock = value,
            other => godot_error!("GooKernel.set_ring_param(): unknown parameter '{}'", other),
        }
    }

    /// Sets several of ring `key`'s tuning values at once (Goo2D's resize ease sends them
    /// every frame of it), by the names add_ring()'s params use: "radius", "bead_mass",
    /// "pressure_k", "shape_match_k", "internal_damp", "settle_speed", "settle_time",
    /// "split_neck", "splat_area_ratio", "min_neck_rest", "skin_stiffness", "skin_damping",
    /// "bending_stiffness", "bending_damping", "linear_damp", "bounce", "friction";
    /// "target_area", "split_lock" and "rest_blend" as set_ring_param() takes them. Other
    /// keys (a whole GooTuning dictionary's "bead_count", "spacing"...) are skipped
    /// quietly: the geometry changes through set_rest().
    #[func]
    fn set_ring_params(&mut self, key: i64, params: VarDictionary) {
        if self.k.find(key).is_none() {
            return;
        }
        for (name, value) in params.iter_shared() {
            let name = name.to_string();
            let number = value.try_to::<f64>().or_else(|_| value.try_to::<i64>().map(|i| i as f64)).unwrap_or(0.0);
            match name.as_str() {
                "rest_blend" => self.k.set_rest_blend(key, number),
                "target_area" | "split_lock" => {
                    if let Some(r) = self.k.ring_mut(key) {
                        if name == "target_area" {
                            r.target_area = number;
                        } else {
                            r.split_lock = number;
                        }
                    }
                }
                _ => {
                    self.k.set_ring_value(key, &name, number);
                }
            }
        }
    }

    /// Gives ring `key` a new rest shape in place, without rebuilding it (Goo2D.resize(),
    /// Goo2D.set_rest_deform(): cheap enough for every frame): `rest`, one point per bead
    /// about its centroid, is what shape matching pulls toward and what the skin and
    /// bending rest lengths are measured on (still blended with the placed loop's by
    /// "rest_blend"), and the pinch scan's rest depths of a ring built with some; with a
    /// `bead_radius` above 0, every bead's collision radius (and "min_neck_rest" in
    /// proportion). The beads stay where they are and the constraints pull them into the
    /// new shape. The target area is set_ring_param()'s. Returns false, with an error, for a
    /// rest of another length than the ring.
    #[func]
    fn set_rest(&mut self, key: i64, rest: PackedVector2Array, bead_radius: f64) -> bool {
        self.k.set_rest(key, v2(&rest), bead_radius)
    }

    /// One of ring `key`'s values by add_ring()'s param names (and "target_area",
    /// "split_lock", "rest_blend"); NaN for another name or no such ring. For the tests.
    #[func]
    fn ring_param(&self, key: i64, name: StringName) -> f64 {
        self.k.ring_value(key, &name.to_string())
    }

    /// The skin rest lengths ring `key`'s solver holds now (edge i → i+1: the rest shape's
    /// blended with the placed loop's by its rest blend). For the tests.
    #[func]
    fn rest_edges(&self, key: i64) -> PackedFloat32Array {
        PackedFloat32Array::from(self.k.rest_edges(key).as_slice())
    }

    /// Ring `key`'s rest shape as shape matching holds it (about its centroid).
    #[func]
    fn rest_points(&self, key: i64) -> PackedVector2Array {
        self.k.ring(key).map(|r| pv2(&r.rest)).unwrap_or_default()
    }

    /// Whether step() runs the pair passes (the overlap push and the Untangler): on for a
    /// GooWorld2D's kernel, off (the default) for lone rings.
    #[func]
    fn set_pair_passes(&mut self, on: bool) {
        self.k.pair_passes = on;
    }

    /// The solver's knobs, any of: "substeps" (per step), "max_substeps" (while something
    /// moves fast), "gravity" (Vector2, px/s²), "base_damp" (linear damping on top of every
    /// ring's), "grip_damp" (extra linear damping touching a gripping shape), "touch_slop"
    /// (px), "wake_depth" (px), "wake_speed" (px/s), "max_bead_speed" (px/s, 0 for no cap),
    /// "untangle_strength" (the Untangler's push, px/s² per px of overlap) and
    /// "untangle_separation_speed" (px/s; both default to the Untangler's constants).
    #[func]
    fn set_solver(&mut self, settings: VarDictionary) {
        let s = &mut self.k.solver;
        for (key, value) in settings.iter_shared() {
            let name = key.to_string();
            let number = value.try_to::<f64>().or_else(|_| value.try_to::<i64>().map(|i| i as f64)).unwrap_or(0.0);
            match name.as_str() {
                "substeps" => s.substeps = (number as usize).max(1),
                "max_substeps" => s.max_substeps = (number as usize).max(1),
                "gravity" => s.gravity = value.try_to::<Vector2>().unwrap_or(s.gravity),
                "base_damp" => s.base_damp = number as f32,
                "grip_damp" => s.grip_damp = number as f32,
                "touch_slop" => s.touch_slop = number as f32,
                "wake_depth" => s.wake_depth = number as f32,
                "wake_speed" => s.wake_speed = number as f32,
                "max_bead_speed" => s.max_bead_speed = number as f32,
                "untangle_strength" => s.untangle_strength = number,
                "untangle_separation_speed" => s.untangle_separation_speed = number,
                other => godot_error!("GooKernel.set_solver(): unknown setting '{}'", other),
            }
        }
    }

    /// The solver's knobs as set_solver() takes them, "last_substeps" (the last step's) and
    /// "last_capped" (particle velocities the last step clamped to "max_bead_speed", summed
    /// over its substeps).
    #[func]
    fn solver(&self) -> VarDictionary {
        let s = &self.k.solver;
        let mut d = VarDictionary::new();
        put(&mut d, "substeps", s.substeps as i64);
        put(&mut d, "max_substeps", s.max_substeps as i64);
        put(&mut d, "gravity", s.gravity);
        put(&mut d, "base_damp", s.base_damp as f64);
        put(&mut d, "grip_damp", s.grip_damp as f64);
        put(&mut d, "touch_slop", s.touch_slop as f64);
        put(&mut d, "wake_depth", s.wake_depth as f64);
        put(&mut d, "wake_speed", s.wake_speed as f64);
        put(&mut d, "max_bead_speed", s.max_bead_speed as f64);
        put(&mut d, "untangle_strength", s.untangle_strength);
        put(&mut d, "untangle_separation_speed", s.untangle_separation_speed);
        put(&mut d, "last_substeps", self.k.last_substeps as i64);
        put(&mut d, "last_capped", self.k.last_capped as i64);
        put(&mut d, "last_step_usec", self.k.last_step_usec as i64);
        let phases: Vec<i64> = self.k.last_phase_usec.iter().map(|&u| u as i64).collect();
        put(&mut d, "last_phase_usec", PackedInt64Array::from(phases.as_slice()));
        d
    }

    /// The pairs of rings being pulled into a merge, as [a, b, a, b, ...] keys: the overlap
    /// push leaves each pair alone (not third rings).
    #[func]
    fn set_merge_partners(&mut self, pairs: PackedInt64Array) {
        self.k.set_merge_partners(pairs.as_slice());
    }

    /// One physics frame for every ring (see kernel.rs).
    #[func]
    fn step(&mut self, delta: f64) {
        self.k.step(delta);
    }

    /// The events recorded since the last call, four integers each: [kind, ring, x, y] with
    /// kind 0 touched (x: the other ring), 1 pinched (x, y: the chord's beads), 2 settled,
    /// 3 woke.
    #[func]
    fn take_events(&mut self) -> PackedInt64Array {
        let events = PackedInt64Array::from(self.k.events.as_slice());
        self.k.events.clear();
        events
    }

    // ---- Static shapes ----

    /// Adds (or replaces) the static shape `id`: the convex polygon `points` (its own
    /// space, at least 3 points, either winding) placed by `transform`, with the material
    /// `friction` and `bounce` and whether a bead touching it grips.
    #[func]
    fn add_static_shape(&mut self, id: i64, transform: Transform2D, points: PackedVector2Array, friction: f64, bounce: f64, grip: bool) {
        if points.len() < 3 {
            godot_error!("GooKernel.add_static_shape(): a shape needs 3 points or more, got {}", points.len());
            return;
        }
        self.k.add_static_shape(statics::StaticShape::new(id, transform, v2(&points), friction as f32, bounce as f32, grip));
    }

    /// Moves the static shape `id`.
    #[func]
    fn set_static_transform(&mut self, id: i64, transform: Transform2D) {
        self.k.set_static_transform(id, transform);
    }

    #[func]
    fn remove_static_shape(&mut self, id: i64) {
        self.k.remove_static_shape(id);
    }

    #[func]
    fn clear_static_shapes(&mut self) {
        self.k.statics.clear();
    }

    /// The ids of the static shapes, in the order they were added.
    #[func]
    fn static_shape_ids(&self) -> PackedInt64Array {
        PackedInt64Array::from(self.k.statics.iter().map(|s| s.id).collect::<Vec<_>>().as_slice())
    }

    /// The static shape `id`'s polygon in global space (empty if there is none).
    #[func]
    fn static_shape_points(&self, id: i64) -> PackedVector2Array {
        self.k.statics.iter().find(|s| s.id == id).map(|s| pv2(&s.world)).unwrap_or_default()
    }

    /// The static shape `id` as { "points" (global), "friction", "bounce", "grip" }, or
    /// an empty dictionary if there is none.
    #[func]
    fn static_shape_info(&self, id: i64) -> VarDictionary {
        let mut d = VarDictionary::new();
        if let Some(s) = self.k.statics.iter().find(|s| s.id == id) {
            put(&mut d, "points", pv2(&s.world));
            put(&mut d, "friction", s.friction as f64);
            put(&mut d, "bounce", s.bounce as f64);
            put(&mut d, "grip", s.grip);
        }
        d
    }

    // ---- Per ring: queries ----

    /// The bead centres at the end of the last step, in ring order (global).
    #[func]
    fn points(&self, key: i64) -> PackedVector2Array {
        self.k.ring(key).map(|r| pv2(&r.points)).unwrap_or_default()
    }

    /// The beads' velocities (zero while settled).
    #[func]
    fn velocities(&self, key: i64) -> PackedVector2Array {
        self.k.ring(key).map(|r| pv2(&self.k.ps.vel[r.start..r.start + r.n])).unwrap_or_default()
    }

    #[func]
    fn bead_position(&self, key: i64, bead: i64) -> Vector2 {
        self.k.ring(key).and_then(|r| r.points.get(bead as usize).copied()).unwrap_or(Vector2::ZERO)
    }

    #[func]
    fn bead_velocity(&self, key: i64, bead: i64) -> Vector2 {
        match self.k.ring(key) {
            Some(r) if (bead as usize) < r.n => self.k.ps.vel[r.start + bead as usize],
            _ => Vector2::ZERO,
        }
    }

    /// True while bead `bead` touched a gripping static shape during the last step.
    #[func]
    fn bead_gripping(&self, key: i64, bead: i64) -> bool {
        self.k.find(key).map(|i| self.k.bead_gripping(i, bead.max(0) as usize)).unwrap_or(false)
    }

    /// The centroid of the bead centres.
    #[func]
    fn center(&self, key: i64) -> Vector2 {
        self.k.ring(key).map(|r| r.center).unwrap_or(Vector2::ZERO)
    }

    /// The bounding box of the bead centres.
    #[func]
    fn bounds(&self, key: i64) -> Rect2 {
        self.k.ring(key).map(|r| rect2(r.bounds)).unwrap_or_default()
    }

    /// The area inside the collision outline (GooTuning.outline_area()).
    #[func]
    fn area(&self, key: i64) -> f64 {
        self.k.ring(key).map(|r| geom::outline_area(&r.points, r.p.bead_radius)).unwrap_or(0.0)
    }

    #[func]
    fn average_velocity(&self, key: i64) -> Vector2 {
        self.k.find(key).map(|i| self.k.average_velocity(i)).unwrap_or(Vector2::ZERO)
    }

    #[func]
    fn is_settled(&self, key: i64) -> bool {
        self.k.ring(key).map(|r| r.settled).unwrap_or(false)
    }

    #[func]
    fn split_lock(&self, key: i64) -> f64 {
        self.k.ring(key).map(|r| r.split_lock).unwrap_or(0.0)
    }

    /// The rings this ring's beads touched in its last step (kept while it is settled).
    #[func]
    fn touching(&self, key: i64) -> PackedInt64Array {
        self.k.ring(key).map(|r| PackedInt64Array::from(r.touching.as_slice())).unwrap_or_default()
    }

    /// The skin polygon (global): the last drawable one. One polygon, or several one after
    /// the other (skin_piece_sizes() says how many points each has) when the outline
    /// crossed itself and was cut into loops that do not.
    #[func]
    fn skin(&self, key: i64) -> PackedVector2Array {
        self.k.ring(key).map(|r| pv2(&r.skin)).unwrap_or_default()
    }

    /// How many points each polygon of skin() has: one entry for a skin that is one
    /// polygon, several (adding up to skin()'s length) for one cut into loops.
    #[func]
    fn skin_piece_sizes(&self, key: i64) -> PackedInt32Array {
        self.k.ring(key).map(|r| PackedInt32Array::from(r.skin_sizes.as_slice())).unwrap_or_default()
    }

    /// The unsmoothed outline (skin_offset() of the beads), global.
    #[func]
    fn raw_outline(&self, key: i64) -> PackedVector2Array {
        self.k.ring(key).map(|r| pv2(&r.raw)).unwrap_or_default()
    }

    /// raw_outline() as the goo shader takes it: GooSkin.MAX_POINTS points exactly.
    #[func]
    fn shader_points(&self, key: i64) -> PackedVector2Array {
        self.k.ring(key).map(|r| pv2(&r.shader)).unwrap_or_default()
    }

    /// Goes up by one every time the skin is rebuilt.
    #[func]
    fn skin_version(&self, key: i64) -> i64 {
        self.k.ring(key).map(|r| r.skin_version).unwrap_or(-1)
    }

    /// Ring `key`'s bead centres inside ring `other`'s bead loop grown by `margin` px.
    #[func]
    fn beads_inside(&self, key: i64, other: i64, margin: f64) -> i64 {
        match (self.k.find(key), self.k.find(other)) {
            (Some(a), Some(b)) => self.k.beads_inside(a, b, margin) as i64,
            _ => 0,
        }
    }

    #[func]
    fn is_frictionless(&self, key: i64) -> bool {
        self.k.find(key).map(|i| self.k.is_frictionless(i)).unwrap_or(false)
    }

    /// True while every bead of `key` and of `other` pass through each other
    /// (set_pass_through(), or the Untangler).
    #[func]
    fn passes_through(&self, key: i64, other: i64) -> bool {
        self.k.passes_through(key, other)
    }

    /// True while bead `bead` of `key` passes through the beads of `other`.
    #[func]
    fn bead_passes_through(&self, key: i64, bead: i64, other: i64) -> bool {
        self.k.bead_passes_through(key, bead.max(0) as usize, other)
    }

    // ---- Per ring: actions ----

    /// Puts the ring's beads at `points` (one per bead, global) and rebuilds its skin.
    #[func]
    fn set_points(&mut self, key: i64, points: PackedVector2Array) {
        if let Some(i) = self.k.find(key) {
            self.k.set_points(i, points.as_slice());
        }
    }

    /// Moves one bead (and rebuilds the skin).
    #[func]
    fn set_bead_position(&mut self, key: i64, bead: i64, point: Vector2) {
        if let Some(i) = self.k.find(key) {
            self.k.set_bead_position(i, bead.max(0) as usize, point);
        }
    }

    /// Clears `settled` and the calm timer (no event).
    #[func]
    fn wake(&mut self, key: i64) {
        if let Some(i) = self.k.find(key) {
            self.k.wake(i, false);
        }
    }

    /// Puts the ring to sleep now (records a settled event).
    #[func]
    fn settle(&mut self, key: i64) {
        if let Some(i) = self.k.find(key) {
            self.k.settle(i);
        }
    }

    /// Wakes the ring and applies `impulse` to every bead (no event), each bead's velocity
    /// capped at the solver's "max_bead_speed".
    #[func]
    fn apply_impulse(&mut self, key: i64, impulse: Vector2) {
        if let Some(i) = self.k.find(key) {
            self.k.apply_impulse(i, impulse, false);
        }
    }

    /// Applies forces[i] to bead i over the next step, waking a settled ring.
    #[func]
    fn apply_bead_forces(&mut self, key: i64, forces: PackedVector2Array) {
        if let Some(i) = self.k.find(key) {
            self.k.add_bead_forces(i, forces.as_slice(), true);
        }
    }

    /// Sets the beads' velocities (one per bead, or one for all), capped at the solver's
    /// "max_bead_speed".
    #[func]
    fn set_velocities(&mut self, key: i64, velocities: PackedVector2Array) {
        if let Some(i) = self.k.find(key) {
            self.k.set_velocities(i, velocities.as_slice());
        }
    }

    /// Sets one bead's velocity, capped at the solver's "max_bead_speed".
    #[func]
    fn set_bead_velocity(&mut self, key: i64, bead: i64, velocity: Vector2) {
        if let Some(i) = self.k.find(key) {
            self.k.set_bead_velocity(i, bead.max(0) as usize, velocity);
        }
    }

    /// With `on`, the ring's beads have no friction and no bounce of their own (a merge's
    /// transition); without, the ring's tuning again.
    #[func]
    fn set_frictionless(&mut self, key: i64, on: bool) {
        if let Some(i) = self.k.find(key) {
            self.k.set_frictionless(i, on);
        }
    }

    /// With `on`, no bead of `key` collides with a bead of `other`; without, they do again.
    #[func]
    fn set_pass_through(&mut self, key: i64, other: i64, on: bool) {
        self.k.set_pass_through(key, other, on);
    }

    /// With `on`, bead `bead` of `key` does not collide with the beads of `other`.
    #[func]
    fn set_bead_pass_through(&mut self, key: i64, bead: i64, other: i64, on: bool) {
        self.k.set_bead_pass_through(key, bead.max(0) as usize, other, on);
    }

    // ---- Links (links.rs) ----

    /// Adds (or replaces) the link `id` tying ring `key_a` to ring `key_b`: `pairs` holds
    /// bead index pairs [bead of a, bead of b, ...]; `through_a` and `through_b` the beads
    /// of each that do not collide with each other (the tied ones and their close
    /// neighbours); `params` any of "gap" (px between the patches' bead centres at rest),
    /// "stiffness", "damping" (the pairs', per reduced bead mass: 1/s², 1/s),
    /// "bend_stiffness", "bend_damping" (the angular term's, per reduced moment of
    /// inertia), "rest_angle" (radians), "ease_time" (s) and "min_rest" (px). The link
    /// eases from where the rings are into its ideal pose. Removed with either ring.
    /// False (nothing added) for a missing ring, one ring twice, no pairs or a bead out
    /// of range.
    #[func]
    fn add_link(
        &mut self,
        id: i64,
        key_a: i64,
        key_b: i64,
        pairs: PackedInt32Array,
        through_a: PackedInt32Array,
        through_b: PackedInt32Array,
        params: VarDictionary,
    ) -> bool {
        let flat = pairs.as_slice();
        if flat.len() < 2 || flat.len() % 2 != 0 || flat.iter().any(|&i| i < 0) {
            godot_error!("GooKernel.add_link(): pairs must be [bead of a, bead of b, ...], got {} values", flat.len());
            return false;
        }
        let p = links::LinkParams {
            gap: num(&params, "gap") as f32,
            stiffness: num(&params, "stiffness") as f32,
            damping: num(&params, "damping") as f32,
            bend_stiffness: num(&params, "bend_stiffness") as f32,
            bend_damping: num(&params, "bend_damping") as f32,
            rest_angle: num(&params, "rest_angle") as f32,
            ease_time: num(&params, "ease_time") as f32,
            min_rest: num(&params, "min_rest") as f32,
        };
        let beads = |a: &PackedInt32Array| a.as_slice().iter().filter(|&&i| i >= 0).map(|&i| i as usize).collect::<Vec<_>>();
        self.k.add_link(
            id,
            key_a,
            key_b,
            flat.chunks_exact(2).map(|c| (c[0] as usize, c[1] as usize)).collect(),
            beads(&through_a),
            beads(&through_b),
            p,
        )
    }

    /// Sets one of link `id`'s knobs, by add_link()'s names (not "gap" or "ease_time":
    /// fixed at add_link()). "rest_angle" moves its pose's targets at once; a link still
    /// easing in eases toward the new ones.
    #[func]
    fn set_link_param(&mut self, id: i64, name: StringName, value: f64) {
        let name = name.to_string();
        let Some(l) = self.k.link_mut(id) else { return };
        let v = value as f32;
        match name.as_str() {
            "stiffness" => l.p.stiffness = v,
            "damping" => l.p.damping = v,
            "bend_stiffness" => l.p.bend_stiffness = v,
            "bend_damping" => l.p.bend_damping = v,
            "rest_angle" | "min_rest" => {
                if name == "rest_angle" {
                    l.p.rest_angle = v;
                } else {
                    l.p.min_rest = v;
                }
                l.set_goal();
                l.refresh();
            }
            other => godot_error!("GooKernel.set_link_param(): unknown parameter '{}'", other),
        }
    }

    #[func]
    fn remove_link(&mut self, id: i64) {
        self.k.remove_link(id);
    }

    #[func]
    fn has_link(&self, id: i64) -> bool {
        self.k.link(id).is_some()
    }

    /// The links' ids, in the order they were added.
    #[func]
    fn link_ids(&self) -> PackedInt64Array {
        PackedInt64Array::from(self.k.links.iter().map(|l| l.id).collect::<Vec<_>>().as_slice())
    }

    /// Link `id` as { "key_a", "key_b", "pairs" (flat, as add_link() takes them),
    /// "through_a", "through_b", "rest_lengths" (what the solver holds now),
    /// "goal_lengths" (at its rest angle, eased in), "rest_angle", "ease" (0..1),
    /// "target_angle" (θ_b − θ_a the solver pulls toward), "angle" (θ_b − θ_a now),
    /// "bend" (angle less the pose's: what rest_angle names, now) }; empty if none.
    #[func]
    fn link_info(&self, id: i64) -> VarDictionary {
        let mut d = VarDictionary::new();
        let Some(l) = self.k.link(id) else { return d };
        put(&mut d, "key_a", l.ka);
        put(&mut d, "key_b", l.kb);
        let flat: Vec<i32> = l.pairs.iter().flat_map(|&(i, j)| [i as i32, j as i32]).collect();
        put(&mut d, "pairs", PackedInt32Array::from(flat.as_slice()));
        put(&mut d, "through_a", indices(&l.through_a));
        put(&mut d, "through_b", indices(&l.through_b));
        put(&mut d, "rest_lengths", PackedFloat32Array::from(l.rest.as_slice()));
        put(&mut d, "goal_lengths", PackedFloat32Array::from(l.goal.as_slice()));
        put(&mut d, "rest_angle", l.p.rest_angle as f64);
        put(&mut d, "ease", l.ease as f64);
        put(&mut d, "target_angle", l.target_angle as f64);
        if let (Some(a), Some(b)) = (self.k.find(l.ka), self.k.find(l.kb)) {
            let angle = self.k.relative_angle(a, b);
            put(&mut d, "angle", angle as f64);
            put(&mut d, "bend", links::wrap(angle - l.pose.psi) as f64);
        }
        d
    }

    // ---- Statics: the kernel's math on plain arrays, for the tests ----

    /// The constants the kernel was built with, by their GDScript names.
    #[func]
    fn constants() -> VarDictionary {
        use consts::*;
        let mut d = VarDictionary::new();
        put(&mut d, "MAX_PRESSURE_RATIO", MAX_PRESSURE_RATIO);
        put(&mut d, "MIN_AREA_RATIO", MIN_AREA_RATIO);
        put(&mut d, "SKIN_SMOOTHING", SKIN_SMOOTHING as i64);
        put(&mut d, "SKIN_KINK_TURN", SKIN_KINK_TURN);
        put(&mut d, "SKIN_KINK_REACH", SKIN_KINK_REACH);
        put(&mut d, "SKIN_KINK_CLEARANCE", SKIN_KINK_CLEARANCE);
        put(&mut d, "SKIN_REPAIR_GROW", SKIN_REPAIR_GROW as f64);
        put(&mut d, "SKIN_MAX_SPLITS", SKIN_MAX_SPLITS as f64);
        put(&mut d, "GROUP_CHECK_INTERVAL", GROUP_CHECK_INTERVAL);
        put(&mut d, "MAX_STRETCH", MAX_STRETCH);
        put(&mut d, "PINCH_SCAN_FRAMES", PINCH_SCAN_FRAMES);
        put(&mut d, "PINCH_CONSTRICTION", PINCH_CONSTRICTION);
        put(&mut d, "SPLIT_HOLD", SPLIT_HOLD);
        put(&mut d, "SPLAT_HOLD_FRAMES", SPLAT_HOLD_FRAMES);
        put(&mut d, "SPLIT_LOCK", SPLIT_LOCK);
        put(&mut d, "INTRUSION_MARGIN_BEADS", INTRUSION_MARGIN_BEADS);
        put(&mut d, "INTRUSION_FREQUENCY", INTRUSION_FREQUENCY);
        put(&mut d, "STRENGTH", UNTANGLE_STRENGTH);
        put(&mut d, "SEPARATION_SPEED", UNTANGLE_SEPARATION_SPEED);
        put(&mut d, "RELEASE_MARGIN", UNTANGLE_RELEASE_MARGIN);
        put(&mut d, "MIN_OVERLAP_RATIO", UNTANGLE_MIN_OVERLAP_RATIO);
        put(&mut d, "MAX_POINTS", SHADER_POINTS as i64);
        d
    }

    /// Goo2D.find_pinch(): { "a", "b", "gap", "constriction" }.
    #[func]
    fn find_pinch(
        points: PackedVector2Array,
        bead_size: f64,
        min_constriction: f64,
        rest: PackedVector2Array,
        min_rest_distance: f64,
        rest_depths: PackedFloat32Array,
    ) -> VarDictionary {
        let neck = pinch::find_pinch(
            points.as_slice(),
            bead_size,
            min_constriction,
            rest.as_slice(),
            min_rest_distance,
            rest_depths.as_slice(),
        );
        let mut d = VarDictionary::new();
        put(&mut d, "a", neck.a);
        put(&mut d, "b", neck.b);
        put(&mut d, "gap", neck.gap);
        put(&mut d, "constriction", neck.constriction);
        d
    }

    /// Goo2D.hull_depths().
    #[func]
    fn hull_depths(points: PackedVector2Array) -> PackedFloat32Array {
        PackedFloat32Array::from(pinch::hull_depths(points.as_slice()).as_slice())
    }

    /// Goo2D._short_axis_beads() as Vector2i(a, b).
    #[func]
    fn short_axis_beads(points: PackedVector2Array) -> Vector2i {
        let (a, b) = pinch::short_axis_beads(points.as_slice());
        Vector2i::new(a as i32, b as i32)
    }

    /// Goo2D.skin_offset().
    #[func]
    fn skin_offset(points: PackedVector2Array, distance: f64) -> PackedVector2Array {
        pv2(&skin::skin_offset(points.as_slice(), distance as f32))
    }

    /// Goo2D.skin_pieces().
    #[func]
    fn skin_pieces(points: PackedVector2Array, bead_radius: f64, corner_flags: PackedByteArray) -> Array<PackedVector2Array> {
        let mut geometry = Geometry2D::singleton();
        skin::drawable(points.as_slice(), bead_radius as f32, corner_flags.as_slice(), &mut geometry)
            .iter()
            .map(|piece| pv2(piece))
            .collect()
    }

    /// GooLoop.split_at_crossings().
    #[func]
    fn split_at_crossings(points: PackedVector2Array, max_splits: i64) -> Array<PackedVector2Array> {
        let mut out = Vec::new();
        let mut splits = max_splits.max(0) as usize;
        skin::split_at_crossings(points.as_slice().to_vec(), Vec::new(), &mut out, &mut splits);
        out.iter().map(|(piece, _)| pv2(piece)).collect()
    }

    /// True if the closed loop is certainly a simple polygon (the skin's fast path: such an
    /// outline is drawn without asking Godot's triangulator).
    #[func]
    fn is_simple(points: PackedVector2Array) -> bool {
        skin::is_simple(points.as_slice())
    }

    /// GooSkin's padded shader outline of `raw` (MAX_POINTS points).
    #[func]
    fn shader_outline(raw: PackedVector2Array, center: Vector2) -> PackedVector2Array {
        pv2(&skin::shader_points(raw.as_slice(), center))
    }

    /// GooWorld2D.intrusion() of two rings given as bead centres, velocities, bead radius
    /// and bead mass: { forces_a, forces_b, inside_a, inside_b, pressed, beads_in_a,
    /// beads_in_b, reach_a, reach_b, centre_in_a, centre_in_b, deep }.
    #[func]
    #[allow(clippy::too_many_arguments)]
    fn intrusion(
        points_a: PackedVector2Array,
        velocities_a: PackedVector2Array,
        radius_a: f64,
        mass_a: f64,
        points_b: PackedVector2Array,
        velocities_b: PackedVector2Array,
        radius_b: f64,
        mass_b: f64,
    ) -> VarDictionary {
        let (pa, pb) = (points_a.as_slice(), points_b.as_slice());
        let mut a = forces::OverlapView::new(pa, velocities_a.as_slice(), radius_a, mass_a, Rect::of_points(pa));
        let mut b = forces::OverlapView::new(pb, velocities_b.as_slice(), radius_b, mass_b, Rect::of_points(pb));
        a.prepare();
        b.prepare();
        let hit = forces::intrusion(&a, &b);
        let mut d = VarDictionary::new();
        put(&mut d, "forces_a", pv2(&hit.forces_a));
        put(&mut d, "forces_b", pv2(&hit.forces_b));
        put(&mut d, "inside_a", hit.inside_a as i64);
        put(&mut d, "inside_b", hit.inside_b as i64);
        put(&mut d, "pressed", hit.pressed);
        put(&mut d, "beads_in_a", indices(&hit.beads_in_a));
        put(&mut d, "beads_in_b", indices(&hit.beads_in_b));
        put(&mut d, "reach_a", indices(&hit.reach_a));
        put(&mut d, "reach_b", indices(&hit.reach_b));
        put(&mut d, "centre_in_a", hit.centre_in_a);
        put(&mut d, "centre_in_b", hit.centre_in_b);
        put(&mut d, "deep", hit.deep());
        d
    }

    /// GooWorld2D.Untangler.push() as [impulse_a, impulse_b], with its constants
    /// (a kernel's own pushes use its solver's "untangle_*" settings).
    #[func]
    #[allow(clippy::too_many_arguments)]
    fn untangle_push(
        center_a: Vector2,
        radius_a: f64,
        mass_a: f64,
        center_b: Vector2,
        radius_b: f64,
        mass_b: f64,
        delta: f64,
        velocity_a: Vector2,
        velocity_b: Vector2,
    ) -> PackedVector2Array {
        let (a, b) = forces::untangle_push(
            center_a,
            radius_a,
            mass_a,
            center_b,
            radius_b,
            mass_b,
            delta,
            velocity_a,
            velocity_b,
            consts::UNTANGLE_STRENGTH,
            consts::UNTANGLE_SEPARATION_SPEED,
        );
        pv2(&[a, b])
    }

    /// Goo2D.beads_inside() on plain loops: how many of `points` lie inside `other` grown
    /// by `margin` px.
    #[func]
    fn count_inside(points: PackedVector2Array, other: PackedVector2Array, margin: f64) -> i64 {
        let (p, o) = (points.as_slice(), other.as_slice());
        forces::beads_inside(p, Rect::of_points(p), o, Rect::of_points(o), margin) as i64
    }

    /// GooLoop.edge_normals().
    #[func]
    fn edge_normals(points: PackedVector2Array) -> PackedVector2Array {
        let mut out = Vec::new();
        geom::edge_normals(points.as_slice(), &mut out);
        pv2(&out)
    }

    /// GooLoop.goal_positions().
    #[func]
    fn goal_positions(rest: PackedVector2Array, current: PackedVector2Array) -> PackedVector2Array {
        let mut out = Vec::new();
        geom::goal_positions(rest.as_slice(), current.as_slice(), &mut out);
        pv2(&out)
    }

    /// GooLoop.best_fit_rotation().
    #[func]
    fn best_fit_rotation(rest: PackedVector2Array, current: PackedVector2Array) -> f64 {
        geom::best_fit_rotation(rest.as_slice(), current.as_slice())
    }

    /// GooLoop.chaikin().
    #[func]
    fn chaikin(points: PackedVector2Array, iterations: i64) -> PackedVector2Array {
        pv2(&geom::chaikin(points.as_slice(), iterations.max(0) as usize))
    }

    /// GooLoop.chaikin_keeping().
    #[func]
    fn chaikin_keeping(points: PackedVector2Array, iterations: i64, keep: PackedByteArray) -> PackedVector2Array {
        pv2(&geom::chaikin_keeping(points.as_slice(), iterations.max(0) as usize, keep.as_slice()))
    }

    /// GooLoop.resample().
    #[func]
    fn resample(points: PackedVector2Array, count: i64) -> PackedVector2Array {
        pv2(&geom::resample(points.as_slice(), count.max(0) as usize))
    }

    /// GooLoop.centroid().
    #[func]
    fn centroid(points: PackedVector2Array) -> Vector2 {
        geom::centroid(points.as_slice())
    }

    /// GooLoop.signed_area().
    #[func]
    fn signed_area(points: PackedVector2Array) -> f64 {
        geom::signed_area(points.as_slice())
    }

    /// GooTuning.outline_area().
    #[func]
    fn outline_area(points: PackedVector2Array, bead_size: f64) -> f64 {
        geom::outline_area(points.as_slice(), bead_size)
    }

    /// Geometry2D.is_point_in_polygon() as the kernel computes it.
    #[func]
    fn point_in_polygon(point: Vector2, polygon: PackedVector2Array) -> bool {
        geom::point_in_polygon(point, polygon.as_slice())
    }

    /// Geometry2D.convex_hull() as the kernel computes it.
    #[func]
    fn convex_hull(points: PackedVector2Array) -> PackedVector2Array {
        pv2(&geom::convex_hull(points.as_slice()))
    }
}


/// The colony spike (docs/colony-spike.md, src/colony.rs): creatures of many goo cells
/// that are not nodes, with core cells, bonds holding them together, threaded stepping
/// and batch drawing. Used by tools/colony_bench.gd and its tests only.
#[derive(GodotClass)]
#[class(base = RefCounted, init)]
pub struct GooColony {
    c: colony::Colony,
    attr: Vec<u8>,
    base: Base<RefCounted>,
}

#[godot_api]
impl GooColony {
    /// Floats per cell add_creature() takes.
    #[constant]
    const CELL_STRIDE: i64 = colony::CELL_STRIDE as i64;
    /// Floats per core in core_instances().
    #[constant]
    const INSTANCE_FLOATS: i64 = colony::INSTANCE_FLOATS as i64;
    /// Rim vertices of a core's disc in the mesh.
    #[constant]
    const CORE_SIDES: i64 = colony::CORE_SIDES as i64;
    /// Cell types the join table covers (ids 0..MAX_TYPES).
    #[constant]
    const MAX_TYPES: i64 = colony::MAX_TYPES as i64;
    /// Join modes (set_join_mode()).
    #[constant]
    const JOIN_NONE: i64 = colony::JOIN_NONE as i64;
    #[constant]
    const JOIN_ANCHORED: i64 = colony::JOIN_ANCHORED as i64;
    #[constant]
    const JOIN_STICKY: i64 = colony::JOIN_STICKY as i64;
    /// Event kinds (take_events()).
    #[constant]
    const EVENT_JOINED: i64 = colony::EVENT_JOINED as i64;
    #[constant]
    const EVENT_PARTED: i64 = colony::EVENT_PARTED as i64;
    /// Floats per stick in creature_sticks().
    #[constant]
    const STICK_FLOATS: i64 = 12;

    /// Any of: "threads", "substeps", "gravity" (Vector2), "max_speed", "cell_scale"
    /// (the bead grid's cell over the one its reach needs), "intra_contacts" (bool:
    /// contacts between different cells of one creature), "core_contacts" (bool: with
    /// intra_contacts off, a creature's cores still collide with its beads and cores),
    /// "slop", "bond_scale", "reuse_pairs" (bool: a creature's own candidates kept across
    /// frames), "pair_skin" (px); adhesion's (docs/colony-adhesion.md): "adhesion" (bool),
    /// "capture" (px), "capture_every" (frames), "join_reach" (px), "stick_scale", "anchor_scale", "creep" (/s),
    /// "break_force", "load_time" (s), "break_rest" (s), "ask" (bool: first touches wait for answer()), "capture_paused"
    /// (bool, the whole colony), "core_anchors" (bool: a bead on a core's rim anchored
    /// when the table says so); milestone 2's (docs/colony-exposure.md): "exposure"
    /// (bool), "exposure_gap" (px; below 0: the capture gap), "core_gap" (× the gap for a
    /// core's virtual beads), "exposure_every", "exposure_hot" (frames), "skip_enclosed" (SKIP_NONE, SKIP_CELLS
    /// (or true: the default), SKIP_BEADS),
    /// "auto_cores" (bool), "to_core_time", "to_ring_time", "switch_rest", "core_ease"
    /// (s), "soft_cores" (bool), "core_stiffness", "core_damping", "core_min_radius",
    /// "core_max_radius", "core_contact" (× the core cell's skin stiffness; 0 rigid), "skip_speed" (px/s), "drag" (bool), "drag_density", "drag_normal", "drag_tangent",
    /// "drag_linear_normal", "drag_linear_tangent", "drag_max_step"; milestone 3's
    /// (docs/colony-tension.md): "tension" (the force each outline edge pulls with; 0
    /// off), "tension_pockets" (× it on skin facing a pocket), "tension_min_edge" (px),
    /// "tension_hop", "tension_hop_max" (× a hop's two bead radii: full, none); the frozen
    /// topology's (docs/colony-frozen.md): "frozen" (bool), "retopo_every" (frames; 0: only
    /// on request), "frozen_self" (0 none, 1 kept, 2 searched every frame, 3 Verlet, 4 cell
    /// pairs), "pair_skin" (px), "frozen_breaks" (bool: a stick past the break force breaks
    /// between retopologies), "frozen_creep" (bool), "urgent_retopo" (bool), "retopo_switches"
    /// (the most switches per retopology; 0 no limit), "fast_search", "spin", "fast_rings"
    /// (bools: the step's), "cpu_timers" (bool, process-wide: the per-part CPU timers in
    /// stats()).
    #[func]
    fn set_options(&mut self, options: VarDictionary) {
        for (key, value) in options.iter_shared() {
            let name = key.to_string();
            let number = value.try_to::<f64>().or_else(|_| value.try_to::<i64>().map(|i| i as f64)).unwrap_or(0.0);
            let o = &mut self.c.opt;
            match name.as_str() {
                "threads" => self.c.set_threads(number as usize),
                "substeps" => o.substeps = (number as usize).max(1),
                "gravity" => o.gravity = value.try_to::<Vector2>().unwrap_or(o.gravity),
                "max_speed" => o.max_speed = number as f32,
                "cell_scale" => o.cell_scale = (number as f32).max(0.1),
                "intra_contacts" => o.intra_contacts = value.try_to::<bool>().unwrap_or(number != 0.0),
                "core_contacts" => o.core_contacts = value.try_to::<bool>().unwrap_or(number != 0.0),
                "slop" => o.slop = number as f32,
                "bond_scale" => o.bond_scale = number as f32,
                "reuse_pairs" => o.reuse_pairs = value.try_to::<bool>().unwrap_or(number != 0.0),
                "frozen" => o.frozen = value.try_to::<bool>().unwrap_or(number != 0.0),
                "retopo_every" => o.retopo_every = number.max(0.0) as u32,
                "frozen_self" => o.frozen_self = number as u8,
                "frozen_breaks" => o.frozen_breaks = value.try_to::<bool>().unwrap_or(number != 0.0),
                "frozen_creep" => o.frozen_creep = value.try_to::<bool>().unwrap_or(number != 0.0),
                "urgent_retopo" => o.urgent_retopo = value.try_to::<bool>().unwrap_or(number != 0.0),
                "retopo_switches" => o.retopo_switches = number.max(0.0) as u32,
                "cpu_timers" => colony::CPU_TIMERS.store(value.try_to::<bool>().unwrap_or(number != 0.0), std::sync::atomic::Ordering::Relaxed),
                "fast_search" => o.fast_search = value.try_to::<bool>().unwrap_or(number != 0.0),
                "spin" => o.spin = value.try_to::<bool>().unwrap_or(number != 0.0),
                "fast_rings" => o.fast_rings = value.try_to::<bool>().unwrap_or(number != 0.0),
                "pair_skin" => o.pair_skin = (number as f32).max(0.0),
                "adhesion" => o.ad.enabled = value.try_to::<bool>().unwrap_or(number != 0.0),
                "capture" => o.ad.capture = (number as f32).max(0.0),
                "capture_every" => o.ad.capture_every = (number as u32).max(1),
                "join_reach" => o.ad.join_reach = (number as f32).max(0.0),
                "stick_scale" => o.ad.stick_scale = (number as f32).max(1e-6),
                "anchor_scale" => o.ad.anchor_scale = (number as f32).max(1e-6),
                "creep" => o.ad.creep = (number as f32).max(0.0),
                "break_force" => o.ad.break_force = number as f32,
                "load_time" => o.ad.load_time = (number as f32).max(0.0),
                "break_rest" => o.ad.break_rest = (number as f32).max(0.0),
                "ask" => o.ad.ask = value.try_to::<bool>().unwrap_or(number != 0.0),
                "capture_paused" => o.ad.paused = value.try_to::<bool>().unwrap_or(number != 0.0),
                "core_anchors" => o.ad.core_anchors = value.try_to::<bool>().unwrap_or(number != 0.0),
                "exposure" => o.ex.enabled = value.try_to::<bool>().unwrap_or(number != 0.0),
                "exposure_gap" => o.ex.gap = number as f32,
                "core_gap" => o.ex.core_gap = (number as f32).max(0.0),
                "exposure_every" => o.ex.every = (number as u32).max(1),
                "exposure_hot" => o.ex.hot = number.max(0.0) as u32,
                "skip_enclosed" => {
                    o.ex.skip = match value.try_to::<bool>() {
                        Ok(b) => b as u8,
                        Err(_) => (number as u8).min(2),
                    }
                }
                "auto_cores" => o.ex.auto_cores = value.try_to::<bool>().unwrap_or(number != 0.0),
                "to_core_time" => o.ex.to_core_time = (number as f32).max(0.0),
                "to_ring_time" => o.ex.to_ring_time = (number as f32).max(0.0),
                "switch_rest" => o.ex.switch_rest = (number as f32).max(0.0),
                "core_ease" => o.ex.core_ease = (number as f32).max(0.0),
                "soft_cores" => o.cores.soft = value.try_to::<bool>().unwrap_or(number != 0.0),
                "core_stiffness" => o.cores.stiffness = (number as f32).max(1e-4),
                "core_damping" => o.cores.damping = (number as f32).max(0.0),
                "core_min_radius" => o.cores.min_radius = (number as f32).clamp(0.1, 1.0),
                "core_max_radius" => o.cores.max_radius = (number as f32).max(1.0),
                "core_contact" => o.cores.contact = (number as f32).max(0.0),
                "skip_speed" => o.ex.skip_speed = (number as f32).max(0.0),
                "drag" => o.drag.enabled = value.try_to::<bool>().unwrap_or(number != 0.0),
                "drag_density" => o.drag.density = (number as f32).max(0.0),
                "drag_normal" => o.drag.normal = (number as f32).max(0.0),
                "drag_tangent" => o.drag.tangent = (number as f32).max(0.0),
                "drag_linear_normal" => o.drag.linear_normal = (number as f32).max(0.0),
                "drag_linear_tangent" => o.drag.linear_tangent = (number as f32).max(0.0),
                "drag_max_step" => o.drag.max_step = (number as f32).max(0.0),
                "tension" => o.tension.strength = (number as f32).max(0.0),
                "tension_pockets" => o.tension.pockets = (number as f32).max(0.0),
                "tension_min_edge" => o.tension.min_edge = (number as f32).max(1e-3),
                "tension_hop" => o.tension.hop = (number as f32).max(0.0),
                "tension_hop_max" => o.tension.hop_max = (number as f32).max(0.0),
                other => godot_error!("GooColony.set_options(): unknown option '{}'", other),
            }
        }
    }

    /// Adds a creature of `cells` (CELL_STRIDE floats each, see colony.rs); its index.
    #[func]
    fn add_creature(&mut self, cells: PackedFloat32Array) -> i64 {
        self.c.add_creature(cells.as_slice()) as i64
    }

    /// Bonds creature `c`'s touching cells (within `capture` px); how many bonds.
    #[func]
    fn build_bonds(&mut self, c: i64, capture: f64) -> i64 {
        let scale = self.c.opt.bond_scale;
        match self.c.creatures.get_mut(c as usize) {
            Some(cr) => cr.build_bonds(capture as f32, scale) as i64,
            None => -1,
        }
    }

    #[func]
    fn creature_count(&self) -> i64 {
        self.c.creatures.len() as i64
    }

    /// Sets creature `c`'s push (an acceleration, px/s², for every step until changed).
    #[func]
    fn push_creature(&mut self, c: i64, acceleration: Vector2) {
        if let Some(cr) = self.c.creatures.get_mut(c as usize) {
            cr.push = acceleration;
        }
    }

    /// A sleeping creature is not stepped and does not move when touched.
    #[func]
    fn set_asleep(&mut self, c: i64, asleep: bool) {
        if let Some(cr) = self.c.creatures.get_mut(c as usize) {
            cr.asleep = asleep;
        }
    }

    /// Creature `c` is stepped every `every` frames (on frames where frame + phase is a
    /// multiple of it), each time over `every` frames' time.
    #[func]
    fn set_every(&mut self, c: i64, every: i64, phase: i64) {
        if let Some(cr) = self.c.creatures.get_mut(c as usize) {
            cr.every = every.max(1) as u32;
            cr.phase = phase.max(0) as u32;
        }
    }

    #[func]
    fn step(&mut self, delta: f64) {
        self.c.step(delta as f32);
    }

    /// The last step's timing (microseconds) and counts.
    #[func]
    fn stats(&self) -> VarDictionary {
        let s = &self.c.stats;
        let mut d = VarDictionary::new();
        put(&mut d, "total_us", s.total_us as i64);
        put(&mut d, "forces_us", s.forces_us as i64);
        put(&mut d, "pairs_us", s.pairs_us as i64);
        put(&mut d, "own_pairs_us", s.own_pairs_us as i64);
        put(&mut d, "solve_us", s.solve_us as i64);
        put(&mut d, "cross_us", s.cross_us as i64);
        put(&mut d, "vel_us", s.vel_us as i64);
        put(&mut d, "rings_cpu_us", s.rings_cpu_us as i64);
        put(&mut d, "bonds_cpu_us", s.bonds_cpu_us as i64);
        put(&mut d, "intra_cpu_us", s.intra_cpu_us as i64);
        put(&mut d, "intra_pairs", s.intra_pairs as i64);
        put(&mut d, "cross_pairs", s.cross_pairs as i64);
        put(&mut d, "cross_hits", s.cross_hits as i64);
        put(&mut d, "draw_build_us", s.draw_build_us as i64);
        put(&mut d, "sticks_cpu_us", s.sticks_cpu_us as i64);
        put(&mut d, "capture_us", s.capture_us as i64);
        put(&mut d, "settle_us", s.settle_us as i64);
        put(&mut d, "sticks", s.sticks as i64);
        put(&mut d, "made", s.made as i64);
        put(&mut d, "broken", s.broken as i64);
        put(&mut d, "drag_cpu_us", s.drag_cpu_us as i64);
        put(&mut d, "exposure_us", s.exposure_us as i64);
        put(&mut d, "exposure_runs", s.exposure_runs as i64);
        put(&mut d, "exposed", s.exposed as i64);
        put(&mut d, "enclosed", s.enclosed as i64);
        put(&mut d, "pockets", s.pockets as i64);
        put(&mut d, "broken_runs", s.broken_runs as i64);
        put(&mut d, "patched_runs", s.patched_runs as i64);
        put(&mut d, "pair_builds", s.pair_builds as i64);
        put(&mut d, "to_core", s.to_core as i64);
        put(&mut d, "to_ring", s.to_ring as i64);
        put(&mut d, "cross_skipped", s.cross_skipped as i64);
        put(&mut d, "tension_cpu_us", s.tension_cpu_us as i64);
        put(&mut d, "after_cpu_us", s.after_cpu_us as i64);
        put(&mut d, "retopos", s.retopos as i64);
        put(&mut d, "own_cpu_us", s.own_cpu_us as i64);
        put(&mut d, "retopo_cpu_us", s.retopo_cpu_us as i64);
        put(&mut d, "cp_rebuilt", s.cp_rebuilt as i64);
        put(&mut d, "cp_snaps", s.cp_snaps as i64);
        put(&mut d, "cp_lists", s.cp_lists as i64);
        put(&mut d, "cp_cpu_us", s.cp_cpu_us as i64);
        put(&mut d, "urgent", s.urgent as i64);
        let (mut beads, mut cores, mut rings, mut bonds) = (0usize, 0usize, 0usize, 0usize);
        for c in &self.c.creatures {
            beads += c.bead_count();
            cores += c.core_count();
            rings += c.rings.len();
            bonds += c.bonds.len();
        }
        put(&mut d, "beads", beads as i64);
        put(&mut d, "cores", cores as i64);
        put(&mut d, "rings", rings as i64);
        put(&mut d, "bonds", bonds as i64);
        d
    }

    /// colony.rs's health(): fastest, area_min, area_max, inverted, stretch, overlap.
    #[func]
    fn health(&self) -> VarDictionary {
        let h = self.c.health();
        let mut d = VarDictionary::new();
        let names = [
            "fastest", "area_min", "area_max", "inverted", "stretch", "overlap", "stick_stretch", "stick_squeeze", "stick_load", "sticks",
            "not_finite", "core_min", "core_max",
        ];
        for (k, name) in names.iter().enumerate() {
            put(&mut d, name, h[k] as f64);
        }
        d
    }

    /// colony.rs's soundness() (explore-frozen): own_inside, cross_inside, inverted,
    /// area_min, own_core_overlap, cross_core_overlap.
    #[func]
    fn soundness(&self) -> VarDictionary {
        let h = self.c.soundness();
        let mut d = VarDictionary::new();
        for (k, name) in ["own_inside", "cross_inside", "inverted", "area_min", "own_core_overlap", "cross_core_overlap"].iter().enumerate() {
            put(&mut d, name, h[k] as f64);
        }
        d
    }

    /// Frozen topology: creature `c` retopologises in its next step (capture, breaks
    /// settled, exposure and switches, its own candidates searched again).
    #[func]
    fn request_retopology(&mut self, c: i64) {
        if let Some(cr) = self.c.creatures.get_mut(c as usize) {
            cr.retopo_req = true;
        }
    }

    /// Adds a cell (CELL_STRIDE floats, as add_creature() takes them) to creature `c`;
    /// its index (the creature's last), or -1. Frozen topology: it asks for a retopology,
    /// where it sticks to its neighbours.
    #[func]
    fn add_cell(&mut self, c: i64, cell: PackedFloat32Array) -> i64 {
        let f = cell.as_slice();
        if f.len() < colony::CELL_STRIDE {
            godot_error!("GooColony.add_cell(): {} floats, a cell takes {}", f.len(), colony::CELL_STRIDE);
            return -1;
        }
        self.c.creatures.get_mut(c as usize).map(|cr| cr.add_cell(&f[..colony::CELL_STRIDE]) as i64).unwrap_or(-1)
    }

    /// Removes cell `cell` of creature `c` (the later cells renumbered down by one; each
    /// pair it was joined in reported parted, in the old numbering). Asks for a
    /// retopology. False for a cell that is not there or a creature's last.
    #[func]
    fn remove_cell(&mut self, c: i64, cell: i64) -> bool {
        if cell < 0 {
            return false;
        }
        self.c.creatures.get_mut(c as usize).map(|cr| cr.remove_cell(cell as usize)).unwrap_or(false)
    }

    #[func]
    fn creature_center(&self, c: i64) -> Vector2 {
        self.c.creatures.get(c as usize).map(|cr| cr.center()).unwrap_or(Vector2::ZERO)
    }

    #[func]
    fn creature_velocity(&self, c: i64) -> Vector2 {
        self.c.creatures.get(c as usize).map(|cr| cr.velocity()).unwrap_or(Vector2::ZERO)
    }

    /// Creature `c`'s particles: every bead (ring after ring), then every core.
    #[func]
    fn creature_points(&self, c: i64) -> PackedVector2Array {
        match self.c.creatures.get(c as usize) {
            Some(cr) => {
                let mut v = cr.pos.clone();
                v.extend_from_slice(&cr.cpos);
                PackedVector2Array::from(v)
            }
            None => PackedVector2Array::new(),
        }
    }

    /// [beads, cores, rings, bonds, topology version] of creature `c`.
    #[func]
    fn creature_info(&self, c: i64) -> PackedInt64Array {
        match self.c.creatures.get(c as usize) {
            Some(cr) => PackedInt64Array::from(
                [cr.bead_count() as i64, cr.core_count() as i64, cr.rings.len() as i64, cr.bonds.len() as i64, cr.topology as i64]
                    .as_slice(),
            ),
            None => PackedInt64Array::new(),
        }
    }

    /// 0 ring, 1 core, -1 none.
    #[func]
    fn cell_kind(&self, c: i64, cell: i64) -> i64 {
        match self.c.creatures.get(c as usize).and_then(|cr| cr.cells.get(cell as usize)) {
            Some(x) => match x.kind {
                colony::Kind::Ring(_) => 0,
                colony::Kind::Core(_) => 1,
            },
            None => -1,
        }
    }

    #[func]
    fn cell_center(&self, c: i64, cell: i64) -> Vector2 {
        match self.c.creatures.get(c as usize) {
            Some(cr) if (cell as usize) < cr.cells.len() => cr.cell_center(cell as usize),
            _ => Vector2::ZERO,
        }
    }

    /// Core cell `cell` becomes a ring (see colony.rs); the deepest overlap left, or -1.
    #[func]
    fn promote(&mut self, c: i64, cell: i64, capture: f64) -> f64 {
        let scale = self.c.opt.bond_scale;
        match self.c.creatures.get_mut(c as usize) {
            Some(cr) if (cell as usize) < cr.cells.len() => cr.promote(cell as usize, capture as f32, scale) as f64,
            _ => -1.0,
        }
    }

    /// Ring cell `cell` becomes a core; the deepest overlap it makes, or -1.
    #[func]
    fn demote(&mut self, c: i64, cell: i64, capture: f64) -> f64 {
        let scale = self.c.opt.bond_scale;
        match self.c.creatures.get_mut(c as usize) {
            Some(cr) if (cell as usize) < cr.cells.len() => cr.demote(cell as usize, capture as f32, scale) as f64,
            _ => -1.0,
        }
    }

    /// Creature `c`'s mesh for RenderingServer.mesh_add_surface_from_arrays(): [vertices
    /// (PackedVector2Array), colours, UVs, custom0 (PackedFloat32Array, 4 per vertex),
    /// indices]. With `rings_only` the cores are left out (drawn as instances).
    #[func]
    fn mesh_arrays(&self, c: i64, rings_only: bool) -> VarArray {
        let mut out = VarArray::new();
        let Some(cr) = self.c.creatures.get(c as usize) else { return out };
        let (colors, uvs, custom, indices) = cr.mesh_static(rings_only);
        let verts = cr.positions(rings_only);
        let cols: Vec<Color> = colors.iter().map(|c| Color::from_rgba(c[0], c[1], c[2], c[3])).collect();
        let flat: Vec<f32> = custom.iter().flat_map(|x| x.iter().copied()).collect();
        out.push(&PackedVector2Array::from(verts).to_variant());
        out.push(&PackedColorArray::from(cols).to_variant());
        out.push(&PackedVector2Array::from(uvs).to_variant());
        out.push(&PackedFloat32Array::from(flat).to_variant());
        out.push(&PackedInt32Array::from(indices).to_variant());
        out
    }

    #[func]
    fn vertex_count(&self, c: i64, rings_only: bool) -> i64 {
        self.c.creatures.get(c as usize).map(|cr| cr.vertex_count(rings_only) as i64).unwrap_or(0)
    }

    /// Creature `c`'s vertex positions now, as the bytes of Godot's 2D vertex buffer
    /// (for RenderingServer.mesh_surface_update_vertex_region()). Adds its build time
    /// to stats()'s draw_build_us.
    #[func]
    fn mesh_positions(&mut self, c: i64, rings_only: bool) -> PackedByteArray {
        let t = std::time::Instant::now();
        let mut bytes = PackedByteArray::new();
        if let Some(cr) = self.c.creatures.get(c as usize) {
            bytes.resize(cr.vertex_count(rings_only) * 8);
            cr.write_positions(rings_only, bytes.as_mut_slice());
        }
        self.c.stats.draw_build_us += t.elapsed().as_micros() as u64;
        bytes
    }

    /// Every creature's positions in one buffer, creature after creature.
    #[func]
    fn all_mesh_positions(&mut self, rings_only: bool) -> PackedByteArray {
        let t = std::time::Instant::now();
        let total: usize = self.c.creatures.iter().map(|cr| cr.vertex_count(rings_only)).sum();
        let mut bytes = PackedByteArray::new();
        bytes.resize(total * 8);
        let slice = bytes.as_mut_slice();
        let mut o = 0;
        for cr in &self.c.creatures {
            let n = cr.vertex_count(rings_only) * 8;
            cr.write_positions(rings_only, &mut slice[o..o + n]);
            o += n;
        }
        self.c.stats.draw_build_us += t.elapsed().as_micros() as u64;
        bytes
    }

    /// Creature `c`'s attribute buffer (colour of `color_bytes` 4 or 16, UV, custom0),
    /// for RenderingServer.mesh_surface_update_attribute_region().
    #[func]
    fn mesh_attributes(&mut self, c: i64, rings_only: bool, color_bytes: i64) -> PackedByteArray {
        let t = std::time::Instant::now();
        let mut attr = std::mem::take(&mut self.attr);
        if let Some(cr) = self.c.creatures.get(c as usize) {
            cr.write_attributes(rings_only, color_bytes as usize, &mut attr);
        }
        let bytes = PackedByteArray::from(attr.as_slice());
        self.attr = attr;
        self.c.stats.draw_build_us += t.elapsed().as_micros() as u64;
        bytes
    }

    /// Creature `c`'s cores as MultiMesh instance data (INSTANCE_FLOATS each: a 2D
    /// transform, colour, custom data).
    #[func]
    fn core_instances(&mut self, c: i64) -> PackedFloat32Array {
        let t = std::time::Instant::now();
        let mut out = PackedFloat32Array::new();
        if let Some(cr) = self.c.creatures.get(c as usize) {
            out.resize(cr.core_count() * colony::INSTANCE_FLOATS);
            cr.write_core_instances(out.as_mut_slice());
        }
        self.c.stats.draw_build_us += t.elapsed().as_micros() as u64;
        out
    }

    /// Zeroes stats()'s draw_build_us (the bench calls it at each frame's start).
    #[func]
    fn reset_draw_clock(&mut self) {
        self.c.stats.draw_build_us = 0;
    }

    // ---- Adhesion (docs/colony-adhesion.md) ----

    /// May cells of types `a` and `b` join, and how: JOIN_NONE, JOIN_ANCHORED (the
    /// default for every pair) or JOIN_STICKY. Symmetric.
    #[func]
    fn set_join_mode(&mut self, type_a: i64, type_b: i64, mode: i64) {
        let n = colony::MAX_TYPES as i64;
        if !(0..n).contains(&type_a) || !(0..n).contains(&type_b) || !(0..=2).contains(&mode) {
            godot_error!("GooColony.set_join_mode(): types 0..{} and modes 0..2", n - 1);
            return;
        }
        self.c.opt.ad.table[type_a as usize][type_b as usize] = mode as u8;
        self.c.opt.ad.table[type_b as usize][type_a as usize] = mode as u8;
    }

    #[func]
    fn join_mode(&self, type_a: i64, type_b: i64) -> i64 {
        let n = colony::MAX_TYPES as i64;
        if !(0..n).contains(&type_a) || !(0..n).contains(&type_b) {
            return -1;
        }
        self.c.opt.ad.table[type_a as usize][type_b as usize] as i64
    }

    #[func]
    fn cell_count(&self, c: i64) -> i64 {
        self.c.creatures.get(c as usize).map(|cr| cr.cells.len() as i64).unwrap_or(0)
    }

    /// Cell `cell` of creature `c` is of type `type_id` (0..MAX_TYPES; 0 by default).
    #[func]
    fn set_cell_type(&mut self, c: i64, cell: i64, type_id: i64) {
        if !(0..colony::MAX_TYPES as i64).contains(&type_id) {
            godot_error!("GooColony.set_cell_type(): a type is 0..{}", colony::MAX_TYPES - 1);
            return;
        }
        match self.c.creatures.get_mut(c as usize).and_then(|cr| cr.cells.get_mut(cell as usize)) {
            Some(x) => x.ctype = type_id as u8,
            None => godot_error!("GooColony.set_cell_type(): no cell {} in creature {}", cell, c),
        }
    }

    #[func]
    fn cell_type(&self, c: i64, cell: i64) -> i64 {
        self.c.creatures.get(c as usize).and_then(|cr| cr.cells.get(cell as usize)).map(|x| x.ctype as i64).unwrap_or(-1)
    }

    /// An acceleration (px/s²) on cell `cell` alone, every step until changed.
    #[func]
    fn push_cell(&mut self, c: i64, cell: i64, acceleration: Vector2) {
        if let Some(x) = self.c.creatures.get_mut(c as usize).and_then(|cr| cr.cells.get_mut(cell as usize)) {
            x.push = acceleration;
        }
    }

    /// Cell `cell` takes radius `radius` in place (colony.rs's resize_cell()).
    #[func]
    fn resize_cell(&mut self, c: i64, cell: i64, radius: f64) -> bool {
        self.c.creatures.get_mut(c as usize).map(|cr| cr.resize_cell(cell as usize, radius as f32)).unwrap_or(false)
    }

    /// A muscle: cell `cell` at `scale` × its size (colony.rs's set_cell_muscle()): no
    /// exposure pass, no retopology. False for a cell that is not there or a scale not
    /// above 0.
    #[func]
    fn set_cell_muscle(&mut self, c: i64, cell: i64, scale: f64) -> bool {
        self.c.creatures.get_mut(c as usize).map(|cr| cr.set_cell_muscle(cell as usize, scale as f32)).unwrap_or(false)
    }

    /// Every muscle of creature `c` at once, one scale per cell in cell order (fewer: the
    /// rest left as they are); the cheap path for a gait driven every frame.
    #[func]
    fn set_cell_muscles(&mut self, c: i64, scales: PackedFloat32Array) {
        if let Some(cr) = self.c.creatures.get_mut(c as usize) {
            for (i, &s) in scales.as_slice().iter().enumerate().take(cr.cells.len()) {
                cr.set_cell_muscle(i, s);
            }
        }
    }

    #[func]
    fn cell_muscle(&self, c: i64, cell: i64) -> f64 {
        self.c.creatures.get(c as usize).and_then(|cr| cr.cells.get(cell as usize)).map(|x| x.muscle as f64).unwrap_or(0.0)
    }

    /// A ring cell's bead radius (px; a core's: 0).
    #[func]
    fn cell_bead_radius(&self, c: i64, cell: i64) -> f64 {
        let Some(cr) = self.c.creatures.get(c as usize) else { return 0.0 };
        match cr.cells.get(cell as usize).map(|x| x.kind) {
            Some(colony::Kind::Ring(r)) => cr.r[cr.rings[r].start] as f64,
            _ => 0.0,
        }
    }

    #[func]
    fn cell_radius(&self, c: i64, cell: i64) -> f64 {
        self.c.creatures.get(c as usize).and_then(|cr| cr.cells.get(cell as usize)).map(|x| x.t.radius as f64).unwrap_or(0.0)
    }

    /// A ring cell's beads now, or a core's centre.
    #[func]
    fn cell_points(&self, c: i64, cell: i64) -> PackedVector2Array {
        let Some(cr) = self.c.creatures.get(c as usize) else { return PackedVector2Array::new() };
        match cr.cells.get(cell as usize).map(|x| x.kind) {
            Some(colony::Kind::Ring(r)) => {
                let ring = &cr.rings[r];
                PackedVector2Array::from(&cr.pos[ring.start..ring.start + ring.n])
            }
            Some(colony::Kind::Core(k)) => PackedVector2Array::from(&[cr.cpos[k]][..]),
            None => PackedVector2Array::new(),
        }
    }

    /// Pauses or resumes capture for creature `c`, or for the whole colony when `c` is
    /// -1 (existing sticks hold and may still break).
    #[func]
    fn set_capture_paused(&mut self, c: i64, paused: bool) {
        if c < 0 {
            self.c.opt.ad.paused = paused;
        } else if let Some(cr) = self.c.creatures.get_mut(c as usize) {
            cr.capture_paused = paused;
        }
    }

    #[func]
    fn is_capture_paused(&self, c: i64) -> bool {
        if c < 0 {
            return self.c.opt.ad.paused;
        }
        self.c.creatures.get(c as usize).map(|cr| cr.capture_paused || self.c.opt.ad.paused).unwrap_or(false)
    }

    /// Joins cells `a` and `b` of creature `c` by hand (whatever the filters say): every
    /// free bead within "join_reach" of the other's skin sticks now, and they stick again
    /// whenever they touch while remembered. The sticks made; a joined event is queued.
    #[func]
    fn join_cells(&mut self, c: i64, a: i64, b: i64) -> i64 {
        let ad = self.c.opt.ad;
        match self.c.creatures.get_mut(c as usize) {
            Some(cr) if a >= 0 && b >= 0 => cr.join_cells(a as usize, b as usize, &ad) as i64,
            _ => 0,
        }
    }

    /// Parts cells `a` and `b` by hand: their sticks go, and they stay apart while they
    /// touch. The sticks removed; a parted event is queued if they were joined.
    #[func]
    fn part_cells(&mut self, c: i64, a: i64, b: i64) -> i64 {
        match self.c.creatures.get_mut(c as usize) {
            Some(cr) if a >= 0 && b >= 0 => cr.part_cells(a as usize, b as usize) as i64,
            _ => 0,
        }
    }

    /// Answers an ask (take_asks()): may cells `a` and `b` of creature `c` join. Read by
    /// the next step's capture; remembered while they stay in touch.
    #[func]
    fn answer(&mut self, c: i64, a: i64, b: i64, allow: bool) {
        if let Some(cr) = self.c.creatures.get_mut(c as usize) {
            if a >= 0 && b >= 0 {
                cr.answer(a as usize, b as usize, allow);
            }
        }
    }

    /// The cells stuck to cell `cell` of creature `c` now, in order.
    #[func]
    fn cell_neighbours(&self, c: i64, cell: i64) -> PackedInt32Array {
        match self.c.creatures.get(c as usize) {
            Some(cr) => PackedInt32Array::from(cr.neighbours(cell as u32).iter().map(|&x| x as i32).collect::<Vec<i32>>()),
            None => PackedInt32Array::new(),
        }
    }

    /// The events since the last call, four ints each: kind (EVENT_JOINED or
    /// EVENT_PARTED), creature, cell a, cell b (a < b); creature after creature, each in
    /// the order they happened (a step's in cell-pair order).
    #[func]
    fn take_events(&mut self) -> PackedInt64Array {
        let v: Vec<i64> = self.c.take_events().iter().flat_map(|&(k, c, a, b)| [k as i64, c as i64, a as i64, b as i64]).collect();
        PackedInt64Array::from(v)
    }

    /// The cell pairs touching for the first time since the last call, while "ask" is on,
    /// three ints each: creature, cell a, cell b. They join only once answer()ed yes.
    #[func]
    fn take_asks(&mut self) -> PackedInt64Array {
        let v: Vec<i64> = self.c.take_asks().iter().flat_map(|&(c, a, b)| [c as i64, a as i64, b as i64]).collect();
        PackedInt64Array::from(v)
    }

    /// Creature `c`'s sticks, STICK_FLOATS each: end a (bead or core index), a is a core
    /// (0/1), end b (ring or core index), b is a core, s (the place along ring b), cell a,
    /// cell b, mode, its load (smoothed), the gap now (px; 0 is held), the anchor (a place
    /// along ring b), the anchor's tension now (px along the edge; 0 at rest).
    #[func]
    fn creature_sticks(&self, c: i64) -> PackedFloat32Array {
        let Some(cr) = self.c.creatures.get(c as usize) else { return PackedFloat32Array::new() };
        let mut v = Vec::with_capacity(cr.sticks.len() * 12);
        for (k, st) in cr.sticks.iter().enumerate() {
            v.extend_from_slice(&[
                st.a as f32,
                st.a_core as u8 as f32,
                st.b as f32,
                st.b_core as u8 as f32,
                st.s,
                st.cell_a as f32,
                st.cell_b as f32,
                st.mode as f32,
                st.load,
                cr.stick_gap(k),
                st.anchor,
                cr.stick_tension(k),
            ]);
        }
        PackedFloat32Array::from(v)
    }

    // ---- Exposure, cores, drag (docs/colony-exposure.md) ----

    /// The "skip_enclosed" modes: none; the particles of cells with no exposed bead
    /// (the default); every enclosed bead.
    #[constant]
    const SKIP_NONE: i64 = 0;
    #[constant]
    const SKIP_CELLS: i64 = 1;
    #[constant]
    const SKIP_BEADS: i64 = 2;
    /// Loop kinds in creature_loop_kinds().
    #[constant]
    const LOOP_OUTSIDE: i64 = 1;
    #[constant]
    const LOOP_POCKET: i64 = 2;

    /// Every particle of creature `c` moves at `velocity` (beads and cores; cores stop
    /// turning, soft radii stop changing).
    #[func]
    fn set_creature_velocity(&mut self, c: i64, velocity: Vector2) {
        if let Some(cr) = self.c.creatures.get_mut(c as usize) {
            cr.set_velocity(velocity);
        }
    }

    /// Creature `c`'s velocities: every bead's (ring after ring), then every core's.
    #[func]
    fn creature_velocities(&self, c: i64) -> PackedVector2Array {
        match self.c.creatures.get(c as usize) {
            Some(cr) => {
                let mut v = cr.vel.clone();
                v.extend_from_slice(&cr.cvel);
                PackedVector2Array::from(v)
            }
            None => PackedVector2Array::new(),
        }
    }

    /// The water's velocity at creature `c` (px/s), used by the drag until changed.
    #[func]
    fn set_water(&mut self, c: i64, velocity: Vector2) {
        if let Some(cr) = self.c.creatures.get_mut(c as usize) {
            cr.water = velocity;
        }
    }

    /// The water's velocity at each cell of creature `c` (one per cell, in cell order),
    /// in place of set_water()'s; an empty array goes back to it.
    #[func]
    fn set_cell_water(&mut self, c: i64, velocities: PackedVector2Array) {
        if let Some(cr) = self.c.creatures.get_mut(c as usize) {
            let v = velocities.as_slice();
            if !v.is_empty() && v.len() != cr.cells.len() {
                godot_error!("GooColony.set_cell_water(): {} velocities for {} cells", v.len(), cr.cells.len());
                return;
            }
            cr.cell_water.clear();
            cr.cell_water.extend_from_slice(v);
        }
    }

    /// Every cell's centre of creature `c`, in cell order (where to sample the water).
    #[func]
    fn creature_cell_centers(&self, c: i64) -> PackedVector2Array {
        match self.c.creatures.get(c as usize) {
            Some(cr) => PackedVector2Array::from((0..cr.cells.len()).map(|i| cr.cell_center(i)).collect::<Vec<_>>()),
            None => PackedVector2Array::new(),
        }
    }

    /// The last frame's drag force on each bead of creature `c` (zero where none).
    #[func]
    fn creature_drag_forces(&self, c: i64) -> PackedVector2Array {
        match self.c.creatures.get(c as usize) {
            Some(cr) => {
                let mut v = cr.drag_f.clone();
                v.resize(cr.pos.len(), Vector2::ZERO);
                PackedVector2Array::from(v)
            }
            None => PackedVector2Array::new(),
        }
    }

    /// Runs creature `c`'s exposure pass now (it otherwise runs in step() when needed).
    #[func]
    fn update_exposure(&mut self, c: i64) {
        let opt = self.c.opt;
        if let Some(cr) = self.c.creatures.get_mut(c as usize) {
            let gap = if opt.ex.gap >= 0.0 { opt.ex.gap } else { opt.ad.capture };
            cr.update_exposure_now(gap, gap * opt.ex.core_gap);
        }
    }

    /// Creature `c`'s exposure per bead (ring after ring): 1 exposed, 0 enclosed.
    #[func]
    fn creature_exposure(&self, c: i64) -> PackedByteArray {
        match self.c.creatures.get(c as usize) {
            Some(cr) => PackedByteArray::from(cr.exposed.as_slice()),
            None => PackedByteArray::new(),
        }
    }

    /// Cell `cell`'s exposure: a ring's per bead (1 exposed), or [1] / [0] for a core
    /// on the outside or not.
    #[func]
    fn cell_exposed(&self, c: i64, cell: i64) -> PackedByteArray {
        match self.c.creatures.get(c as usize) {
            Some(cr) if (cell as usize) < cr.cells.len() => PackedByteArray::from(cr.cell_exposed(cell as usize).as_slice()),
            _ => PackedByteArray::new(),
        }
    }

    /// How many of cell `cell`'s beads are exposed (a core: 1 if on the outside, else 0).
    #[func]
    fn cell_exposed_count(&self, c: i64, cell: i64) -> i64 {
        self.cell_exposed(c, cell).as_slice().iter().map(|&e| e as i64).sum()
    }

    /// Cell `cell`'s outward direction: the mean direction of its exposed beads from its
    /// centre (zero when none).
    #[func]
    fn cell_outward(&self, c: i64, cell: i64) -> Vector2 {
        self.c.creatures.get(c as usize).and_then(|cr| cr.cells.get(cell as usize)).map(|x| x.outward).unwrap_or(Vector2::ZERO)
    }

    /// A core's turn (rad), or 0 for a ring.
    #[func]
    fn cell_rotation(&self, c: i64, cell: i64) -> f64 {
        match self.c.creatures.get(c as usize).and_then(|cr| cr.cells.get(cell as usize).map(|x| (cr, x.kind))) {
            Some((cr, colony::Kind::Core(k))) => cr.crot[k] as f64,
            _ => 0.0,
        }
    }

    /// Creature `c`'s outline loops from the last exposure pass, one kind each:
    /// LOOP_OUTSIDE or LOOP_POCKET.
    #[func]
    fn creature_loop_kinds(&self, c: i64) -> PackedInt32Array {
        match self.c.creatures.get(c as usize) {
            Some(cr) => PackedInt32Array::from(
                cr.loops.iter().map(|l| if l.kind == colony::LoopKind::Outside { 1 } else { 2 }).collect::<Vec<i32>>(),
            ),
            None => PackedInt32Array::new(),
        }
    }

    /// Loop `k`'s points now (beads, and a core's virtual beads where the loop runs along
    /// a core), in the rings' winding for an outside.
    #[func]
    fn creature_loop(&self, c: i64, k: i64) -> PackedVector2Array {
        match self.c.creatures.get(c as usize).and_then(|cr| cr.loops.get(k as usize).map(|l| cr.loop_points(l))) {
            Some(v) => PackedVector2Array::from(v),
            None => PackedVector2Array::new(),
        }
    }

    /// Creature `c`'s outline: its largest outside loop's points now (empty before the
    /// first exposure pass).
    #[func]
    fn creature_outline(&self, c: i64) -> PackedVector2Array {
        let Some(cr) = self.c.creatures.get(c as usize) else { return PackedVector2Array::new() };
        let best = cr
            .loops
            .iter()
            .filter(|l| l.kind == colony::LoopKind::Outside)
            .max_by(|a, b| a.area.abs().partial_cmp(&b.area.abs()).unwrap_or(std::cmp::Ordering::Equal));
        match best {
            Some(l) => PackedVector2Array::from(cr.loop_points(l)),
            None => PackedVector2Array::new(),
        }
    }
    /// A cell type's factor on the surface tension (an edge takes the mean of its two
    /// ends' cells'): 0 slack, 1 the default, above 1 taut.
    #[func]
    fn set_type_tension(&mut self, type_id: i64, factor: f64) {
        if (0..colony::MAX_TYPES as i64).contains(&type_id) {
            self.c.opt.tension.types[type_id as usize] = (factor as f32).max(0.0);
        } else {
            godot_error!("GooColony.set_type_tension(): type {} out of 0..{}", type_id, colony::MAX_TYPES);
        }
    }

    #[func]
    fn type_tension(&self, type_id: i64) -> f64 {
        self.c.opt.tension.types.get(type_id.max(0) as usize).copied().unwrap_or(0.0) as f64
    }

    /// Creature `c`'s factor on the colony's surface tension (1 when added; 0 none).
    #[func]
    fn set_creature_tension(&mut self, c: i64, factor: f64) {
        if let Some(cr) = self.c.creatures.get_mut(c as usize) {
            cr.tension_scale = (factor as f32).max(0.0);
        }
    }

    #[func]
    fn creature_tension(&self, c: i64) -> f64 {
        self.c.creatures.get(c as usize).map(|cr| cr.tension_scale as f64).unwrap_or(0.0)
    }

    /// The last substep's surface tension forces of creature `c`: two per edge it pulls
    /// along (its first end's, then its second's: equal and opposite), at the points
    /// creature_tension_points() gives (a core's virtual bead's force went to the core and
    /// its moment to the core's turn).
    #[func]
    fn creature_tension_forces(&self, c: i64) -> PackedVector2Array {
        self.c.creatures.get(c as usize).map(|cr| pv2(&cr.tension_f)).unwrap_or_default()
    }

    /// Where those points were when the forces were found.
    #[func]
    fn creature_tension_points(&self, c: i64) -> PackedVector2Array {
        self.c.creatures.get(c as usize).map(|cr| pv2(&cr.tension_x)).unwrap_or_default()
    }
}

/// Exploration prototype (src/cells.rs, docs/explore-cells.md): creatures whose every cell
/// is one oriented disc particle held by links. Used by tools/cells_*.gd,
/// addons/goo2d/goo_cells_sim.gd and tests/unit/test_goo_cells.gd only.
#[derive(GodotClass)]
#[class(base = RefCounted, init)]
pub struct GooCells {
    c: cells::Cells,
    base: Base<RefCounted>,
}

fn cells_num(value: &Variant) -> f64 {
    value.try_to::<f64>().or_else(|_| value.try_to::<i64>().map(|i| i as f64)).or_else(|_| value.try_to::<bool>().map(|b| if b { 1.0 } else { 0.0 })).unwrap_or(0.0)
}

#[godot_api]
impl GooCells {
    #[constant]
    const BEND_NONE: i64 = cells::BEND_NONE as i64;
    #[constant]
    const BEND_LINK: i64 = cells::BEND_LINK as i64;
    #[constant]
    const BEND_SHAPE: i64 = cells::BEND_SHAPE as i64;
    #[constant]
    const SELF_NONE: i64 = cells::SELF_NONE as i64;
    #[constant]
    const SELF_UNLINKED: i64 = cells::SELF_UNLINKED as i64;
    #[constant]
    const SELF_TYPES: i64 = cells::SELF_TYPES as i64;
    #[constant]
    const SELF_FAR: i64 = cells::SELF_FAR as i64;
    #[constant]
    const WAVE_OFF: i64 = cells::WAVE_OFF as i64;
    #[constant]
    const WAVE_RADIUS: i64 = cells::WAVE_RADIUS as i64;
    #[constant]
    const WAVE_POSE: i64 = cells::WAVE_POSE as i64;
    #[constant]
    const WAVE_SQUEEZE: i64 = cells::WAVE_SQUEEZE as i64;
    #[constant]
    const EVENT_PARTED: i64 = cells::EVENT_PARTED as i64;
    #[constant]
    const EVENT_JOINED: i64 = cells::EVENT_JOINED as i64;
    #[constant]
    const EVENT_SPLIT: i64 = cells::EVENT_SPLIT as i64;
    #[constant]
    const BODY_DEFAULT: i64 = cells::BODY_DEFAULT as i64;

    /// threads, substeps, stretch_hz, bend_hz, bend_mode, shape_k, link_damp, bend_damp,
    /// collide_all, capsules, contact_hz, contact_pad, self_mode, margin, drag (bool),
    /// drag_normal, drag_tangent, drag_linear_normal, drag_linear_tangent, drag_density,
    /// drag_facing, drag_substep, current (Vector2), tension, gravity (Vector2),
    /// plastic_yield, plastic_rate, plastic_recover, break_force, break_torque, break_smooth,
    /// link_tol, max_speed, density, ease_time, ease_from.
    #[func]
    fn set_options(&mut self, options: VarDictionary) {
        let mut colliders = false;
        let mut ratio: Option<f32> = None;
        let mut linear_tangent: Option<f32> = None;
        for (key, value) in options.iter_shared() {
            let name = key.to_string();
            let x = cells_num(&value);
            let o = &mut self.c.opt;
            match name.as_str() {
                "threads" => self.c.set_threads(x as usize),
                "substeps" => o.substeps = (x as usize).max(1),
                "stretch_hz" => o.stretch_hz = x as f32,
                "bend_hz" => o.bend_hz = x as f32,
                "bend_mode" => o.bend_mode = x as u8,
                "shape_k" => o.shape_k = x as f32,
                "link_damp" => o.link_damp = x as f32,
                "bend_damp" => o.bend_damp = x as f32,
                "collide_all" => {
                    o.collide_all = x != 0.0;
                    colliders = true;
                }
                "capsules" => o.capsules = x != 0.0,
                "contact_hz" => o.contact_hz = x as f32,
                "contact_pad" => {
                    o.contact_pad = x as f32;
                    colliders = true;
                }
                "self_mode" => o.self_mode = x as u8,
                "contact_iters" => o.contact_iters = (x as u32).max(1),
                "self_every" => o.self_every = (x as u32).max(1),
                "margin" => o.margin = x as f32,
                "drag" => o.drag.enabled = x != 0.0,
                "drag_normal" => o.drag.normal = x as f32,
                "drag_tangent" => o.drag.tangent = x as f32,
                "drag_linear_normal" => o.drag.linear_normal = x as f32,
                "drag_linear_tangent" => linear_tangent = Some(x as f32),
                "drag_density" => o.drag.density = x as f32,
                "drag_facing" => o.drag.facing_only = x != 0.0,
                "drag_substep" => o.drag_substep = x != 0.0,
                "drag_max_step" => o.drag.max_step = x as f32,
                "current" => o.current = value.try_to::<Vector2>().unwrap_or(Vector2::ZERO),
                "tension" => o.tension = x as f32,
                "gravity" => o.gravity = value.try_to::<Vector2>().unwrap_or(Vector2::ZERO),
                "plastic_yield" => o.plastic_yield = x as f32,
                "plastic_rate" => o.plastic_rate = x as f32,
                "plastic_recover" => o.plastic_recover = x as f32,
                "break_force" => o.break_force = x as f32,
                "break_torque" => o.break_torque = x as f32,
                "break_smooth" => o.break_smooth = x as f32,
                "link_tol" => o.link_tol = x as f32,
                "max_speed" => o.max_speed = x as f32,
                "density" => o.density = x as f32,
                "ease_time" => o.ease_time = x as f32,
                "ease_from" => o.ease_from = x as f32,
                "break_excess" => o.break_excess = x != 0.0,
                "break_envelope_time" => o.break_envelope_time = x as f32,
                "break_envelope_scale" => o.break_envelope_scale = x as f32,
                "drag_ratio" => ratio = Some(x as f32),
                _ => godot_error!("GooCells: unknown option {}", name),
            }
        }
        if let Some(r) = ratio {
            // The tangential terms (quadratic and linear) a ratio-th of the normal ones.
            let o = &mut self.c.opt;
            let r = r.max(1e-3);
            o.drag.tangent = o.drag.normal / r;
            o.drag.linear_tangent = o.drag.linear_normal / r;
        }
        if let Some(t) = linear_tangent {
            // Given with drag_ratio, it wins: the along-edge linear term set on its own.
            self.c.opt.drag.linear_tangent = t;
        }
        if colliders {
            self.c.refresh_colliders();
        }
    }

    /// A type's factors: stretch, bend, break (× the options), self_collide (bool),
    /// join_mask (bits of the types it may join), pad (px added to its contact radius),
    /// body (BEND_NONE / BEND_LINK / BEND_SHAPE / BODY_DEFAULT), collide (with other
    /// creatures), walls (with walls), color (the skin's), swim (its share of the swim drive).
    #[func]
    fn set_type(&mut self, t: i64, params: VarDictionary) {
        let tp = &mut self.c.opt.types[(t as usize).min(cells::TYPES - 1)];
        let mut version = false;
        for (key, value) in params.iter_shared() {
            let x = cells_num(&value);
            match key.to_string().as_str() {
                "body" => {
                    tp.body = x as u8;
                    version = true;
                }
                "collide" => tp.collide = x != 0.0,
                "walls" => tp.walls = x != 0.0,
                "color" => {
                    let c = value.try_to::<Color>().unwrap_or(Color::WHITE);
                    tp.color = [c.r, c.g, c.b, c.a];
                }
                "stretch" => tp.stretch = x as f32,
                "bend" => tp.bend = x as f32,
                "break" => tp.brk = x as f32,
                "self_collide" => tp.self_collide = x != 0.0,
                "join_mask" => tp.join_mask = x as u16,
                "pad" => tp.pad = x as f32,
                "swim" => tp.swim = x as f32,
                other => godot_error!("GooCells: unknown type parameter {}", other),
            }
        }
        if version {
            self.c.opt.types_version = self.c.opt.types_version.wrapping_add(1) % (u32::MAX - 1);
        }
    }

    /// add_creature() with each cell's group (cells of one type and group linked together
    /// form a region) and mass factor (× the density; empty: 1).
    #[func]
    fn add_creature_ex(&mut self, centers: PackedVector2Array, radii: PackedFloat32Array, types: PackedInt32Array, groups: PackedInt32Array, masses: PackedFloat32Array) -> i64 {
        let t: Vec<u8> = types.as_slice().iter().map(|&x| x as u8).collect();
        let g: Vec<u16> = groups.as_slice().iter().map(|&x| x as u16).collect();
        self.c.add_creature_ex(centers.as_slice(), radii.as_slice(), &t, &g, masses.as_slice()) as i64
    }

    /// The links a design gets (pairs of cell indices, flat): cells closer than
    /// (r_a + r_b) × tol, crossing links dropped longest first (GooCellDesign.links()).
    #[func]
    fn design_links(centers: PackedVector2Array, radii: PackedFloat32Array, tol: f64) -> PackedInt32Array {
        let v = cells::design_links(centers.as_slice(), radii.as_slice(), tol as f32);
        PackedInt32Array::from_iter(v.iter().flat_map(|p| [p.0 as i32, p.1 as i32]))
    }

    /// GooStatics' interface, as GooKernel's: a convex polygon in `transform`'s space.
    #[func]
    fn add_static_shape(&mut self, id: i64, transform: Transform2D, points: PackedVector2Array, friction: f64, bounce: f64, grip: bool) {
        self.c.add_static_shape(id, transform, points.as_slice().to_vec(), friction as f32, bounce as f32, grip);
    }

    #[func]
    fn set_static_transform(&mut self, id: i64, transform: Transform2D) {
        self.c.set_static_transform(id, transform);
    }

    #[func]
    fn remove_static_shape(&mut self, id: i64) {
        self.c.remove_static_shape(id);
    }

    #[func]
    fn clear_static_shapes(&mut self) {
        self.c.clear_static_shapes();
    }

    #[func]
    fn static_shape_count(&self) -> i64 {
        self.c.statics.len() as i64
    }

    /// The walls' polygons in global space, in order.
    #[func]
    fn static_shape_points(&self, index: i64) -> PackedVector2Array {
        self.c.statics.get(index as usize).map(|s| PackedVector2Array::from(s.world.as_slice())).unwrap_or_default()
    }

    /// The water's velocity at creature c's cells: empty (its current, else the options'),
    /// one value for all, or one per cell.
    #[func]
    fn set_water(&mut self, c: i64, water: PackedVector2Array) {
        let b = &mut self.c.bodies[c as usize];
        b.water.clear();
        let w = water.as_slice();
        if w.len() == 1 {
            b.water.resize(b.n, w[0]);
        } else if w.len() == b.n {
            b.water.extend_from_slice(w);
        }
    }

    /// set_water() for every live creature in one call, in centers_all()'s order.
    #[func]
    fn set_water_all(&mut self, water: PackedVector2Array) {
        self.c.set_water_all(water.as_slice());
    }

    /// A uniform current for creature c (on: false falls back to the options' current).
    #[func]
    fn set_creature_current(&mut self, c: i64, current: Vector2, on: bool) {
        let b = &mut self.c.bodies[c as usize];
        b.current = current;
        b.has_current = on;
    }

    /// [every live creature's cell centres in slot order, cells per slot]
    #[func]
    fn centers_all(&self) -> VarArray {
        let (p, counts) = self.c.centers_all();
        let mut a = VarArray::new();
        a.push(&PackedVector2Array::from(p.as_slice()).to_variant());
        a.push(&PackedInt32Array::from(counts.as_slice()).to_variant());
        a
    }

    /// The creature whose outline holds `point` (-1: none).
    #[func]
    fn creature_at(&self, point: Vector2) -> i64 {
        self.c.creature_at(point)
    }

    /// Creature c's cell nearest `point` within `reach` px of its disc (-1: none).
    #[func]
    fn cell_at(&self, c: i64, point: Vector2, reach: f64) -> i64 {
        self.c.cell_at(c as usize, point, reach as f32)
    }

    /// A force on one cell, kept until set again.
    #[func]
    fn set_cell_force(&mut self, c: i64, i: i64, force: Vector2) {
        let b = &mut self.c.bodies[c as usize];
        if let Some(f) = b.user_force.get_mut(i as usize) {
            *f = force;
        }
    }

    #[func]
    fn creature_mass(&self, c: i64) -> f64 {
        self.c.bodies[c as usize].total_mass() as f64
    }

    /// Each cell's group.
    #[func]
    fn groups(&self, c: i64) -> PackedInt32Array {
        PackedInt32Array::from_iter(self.c.bodies[c as usize].group.iter().map(|&g| g as i32))
    }

    /// Each cell's region (built at the frame's start: call after a step).
    #[func]
    fn regions(&self, c: i64) -> PackedInt32Array {
        PackedInt32Array::from_iter(self.c.bodies[c as usize].region.iter().map(|&g| g as i32))
    }

    /// Each cell: shape matched (1) or not.
    #[func]
    fn shape_matched(&self, c: i64) -> PackedInt32Array {
        PackedInt32Array::from_iter(self.c.bodies[c as usize].cell_shape.iter().map(|&g| g as i32))
    }

    /// Each link: its angle constraints solved (1) or not.
    #[func]
    fn link_bends(&self, c: i64) -> PackedInt32Array {
        PackedInt32Array::from_iter(self.c.bodies[c as usize].links.iter().map(|l| l.bend as i32))
    }

    /// The joints between creature c's regions: [region a, region b, key a, key b, links] each.
    #[func]
    fn joints(&self, c: i64) -> PackedInt32Array {
        let b = &self.c.bodies[c as usize];
        PackedInt32Array::from_iter(b.joints.iter().flat_map(|j| [j.ra as i32, j.rb as i32, j.ka as i32, j.kb as i32, j.links as i32]))
    }

    /// The joint between regions of keys (type << 16 | group) key_a and key_b bent by
    /// `angle` (rad: the second region turned against the first about the joint).
    #[func]
    fn set_joint_angle(&mut self, c: i64, key_a: i64, key_b: i64, angle: f64) {
        let b = &mut self.c.bodies[c as usize];
        let (ka, kb, a) = if key_a <= key_b { (key_a as u32, key_b as u32, angle as f32) } else { (key_b as u32, key_a as u32, -angle as f32) };
        match b.joint_angles.iter_mut().find(|x| x.0 == ka && x.1 == kb) {
            Some(x) => x.2 = a,
            None => b.joint_angles.push((ka, kb, a)),
        }
    }

    /// Each link's envelope (the creature's own share the break test leaves out).
    #[func]
    fn link_envelopes(&self, c: i64) -> PackedFloat32Array {
        PackedFloat32Array::from_iter(self.c.bodies[c as usize].links.iter().map(|l| l.env))
    }

    /// One cell's thrust (force along its heading turned by its thrust angle).
    #[func]
    fn set_thrust_one(&mut self, c: i64, i: i64, thrust: f64) {
        let b = &mut self.c.bodies[c as usize];
        if let Some(t) = b.thrust.get_mut(i as usize) {
            *t = thrust as f32;
        }
    }

    /// Each cell's thrust angle (rad, in its own frame).
    #[func]
    fn thrust_angles(&self, c: i64) -> PackedFloat32Array {
        PackedFloat32Array::from(self.c.bodies[c as usize].thrust_angle.as_slice())
    }

    /// Each cell's thrust.
    #[func]
    fn thrusts(&self, c: i64) -> PackedFloat32Array {
        PackedFloat32Array::from(self.c.bodies[c as usize].thrust.as_slice())
    }

    /// Removes creature c: its slot stays, dead (alive() false); no events.
    #[func]
    fn remove_creature(&mut self, c: i64) {
        self.c.remove_creature(c as usize);
    }

    /// add_cell() with its group and mass factor.
    #[func]
    fn add_cell_ex(&mut self, c: i64, at: Vector2, radius: f64, typ: i64, group: i64, mass: f64) -> i64 {
        self.c.add_cell_ex(c as usize, at, radius as f32, typ as u8, group as u16, mass as f32) as i64
    }

    /// Every live creature's skin mesh (cells_draw.rs): [points, colors, uvs (vertices),
    /// border lines (pairs), build µs, indices (triangles, three vertex indices each)].
    #[func]
    fn meshes_all(&self, borders: bool) -> VarArray {
        let t = std::time::Instant::now();
        let m = self.c.meshes_all(borders);
        let us = t.elapsed().as_micros() as i64;
        let mut a = VarArray::new();
        a.push(&PackedVector2Array::from(m.points.as_slice()).to_variant());
        a.push(&PackedColorArray::from(m.colors.as_slice()).to_variant());
        a.push(&PackedVector2Array::from(m.uvs.as_slice()).to_variant());
        a.push(&PackedVector2Array::from(m.lines.as_slice()).to_variant());
        a.push(&us.to_variant());
        a.push(&PackedInt32Array::from(m.indices.as_slice()).to_variant());
        a
    }

    #[func]
    fn add_creature(&mut self, centers: PackedVector2Array, radii: PackedFloat32Array, types: PackedInt32Array) -> i64 {
        let t: Vec<u8> = types.as_slice().iter().map(|&x| x as u8).collect();
        self.c.add_creature(centers.as_slice(), radii.as_slice(), &t) as i64
    }

    #[func]
    fn add_wall(&mut self, points: PackedVector2Array) {
        self.c.add_wall(points.as_slice());
    }

    #[func]
    fn step(&mut self, delta: f64) {
        self.c.step(delta as f32);
    }

    /// Creature slots (a merged creature's slot stays, dead).
    #[func]
    fn creature_count(&self) -> i64 {
        self.c.bodies.len() as i64
    }

    #[func]
    fn alive(&self, c: i64) -> bool {
        self.c.bodies.get(c as usize).map(|b| b.alive).unwrap_or(false)
    }

    #[func]
    fn cell_count(&self, c: i64) -> i64 {
        self.c.bodies[c as usize].n as i64
    }

    #[func]
    fn push_creature(&mut self, c: i64, acceleration: Vector2) {
        self.c.bodies[c as usize].push = acceleration;
    }

    /// An angular acceleration (rad/s², clockwise on screen positive) about its centre of
    /// mass: forces of a rigid turn, no net force.
    #[func]
    fn twist(&mut self, c: i64, alpha: f64) {
        self.c.bodies[c as usize].twist = alpha as f32;
    }

    /// push_creature() for the next step only (added to the kept push; calls add up).
    #[func]
    fn push_once(&mut self, c: i64, acceleration: Vector2) {
        self.c.bodies[c as usize].push_once += acceleration;
    }

    /// twist() for the next step only (added to the kept twist; calls add up).
    #[func]
    fn twist_once(&mut self, c: i64, alpha: f64) {
        self.c.bodies[c as usize].twist_once += alpha as f32;
    }

    /// Forces per cell (by index) for the next step only, added to the kept ones (calls add
    /// up; fewer than the cells: the rest none). They count as outside the creature for the
    /// break test, as set_cell_force()'s do.
    #[func]
    fn add_cell_forces_once(&mut self, c: i64, forces: PackedVector2Array) {
        let b = &mut self.c.bodies[c as usize];
        if b.force_once.len() != b.n {
            b.force_once.clear();
            b.force_once.resize(b.n, Vector2::ZERO);
        }
        for (f, add) in b.force_once.iter_mut().zip(forces.as_slice()) {
            *f += *add;
        }
    }

    /// The swim drive, kept until set again: every cell pushed along `axis` (its forward in
    /// the creature's design frame) turned by its angle, the forces' magnitudes summing to
    /// `acceleration` (px/s², negative backward) × its mass, shared by mass × its type's
    /// swim weight, rippling by ± `pulse` (0..1) with the pose wave's phase. 0 stops it.
    #[func]
    fn set_swim(&mut self, c: i64, acceleration: f64, pulse: f64, axis: Vector2) {
        let b = &mut self.c.bodies[c as usize];
        b.swim = cells::Swim { acc: acceleration as f32, pulse: pulse as f32, axis: if axis.length_squared() > 0.0 { axis.normalized() } else { Vector2::new(1.0, 0.0) } };
    }

    /// Damping (1/s) of creature c's mean velocity and of its rigid spin about its centre,
    /// both relative to the water at its cells: each decays by exp(−rate × time), exactly;
    /// the motion of its cells relative to that (the stroke) is left alone. 0: none.
    #[func]
    fn set_damping(&mut self, c: i64, linear: f64, angular: f64) {
        let b = &mut self.c.bodies[c as usize];
        b.damp_lin = (linear as f32).max(0.0);
        b.damp_ang = (angular as f32).max(0.0);
    }

    /// The threads the last step ran on (threads 0 chooses them by size each step).
    #[func]
    fn threads_in_use(&self) -> i64 {
        self.c.threads_in_use() as i64
    }

    /// threads 0's choice for `cells` live cells in `creatures` live creatures on `cores`.
    #[func]
    fn auto_threads(cells: i64, creatures: i64, cores: i64) -> i64 {
        cells::Cells::auto_threads(cells.max(0) as usize, creatures.max(0) as usize, cores.max(1) as usize) as i64
    }

    /// Forces per cell, kept until set again (empty: none).
    #[func]
    fn set_cell_forces(&mut self, c: i64, forces: PackedVector2Array) {
        let b = &mut self.c.bodies[c as usize];
        for i in 0..b.n {
            b.user_force[i] = forces.as_slice().get(i).copied().unwrap_or(Vector2::ZERO);
        }
    }

    /// Thrust per cell (force) along its heading turned by `angles` (rad, in its frame).
    #[func]
    fn set_cell_thrust(&mut self, c: i64, thrust: PackedFloat32Array, angles: PackedFloat32Array) {
        let b = &mut self.c.bodies[c as usize];
        for i in 0..b.n {
            b.thrust[i] = thrust.as_slice().get(i).copied().unwrap_or(0.0);
            b.thrust_angle[i] = angles.as_slice().get(i).copied().unwrap_or(0.0);
        }
    }

    #[func]
    fn set_velocity(&mut self, c: i64, v: Vector2) {
        let b = &mut self.c.bodies[c as usize];
        for i in 0..b.n {
            b.vel[i] = v;
            b.om[i] = 0.0;
        }
    }

    #[func]
    fn translate(&mut self, c: i64, by: Vector2) {
        let b = &mut self.c.bodies[c as usize];
        for i in 0..b.n {
            b.pos[i] += by;
            b.prev[i] += by;
            b.pred[i] += by;
        }
    }

    #[func]
    fn creature_center(&self, c: i64) -> Vector2 {
        self.c.bodies[c as usize].center()
    }

    #[func]
    fn creature_velocity(&self, c: i64) -> Vector2 {
        self.c.bodies[c as usize].velocity()
    }

    /// The best-fit turn against its design (rad).
    #[func]
    fn creature_turn(&self, c: i64) -> f64 {
        self.c.bodies[c as usize].turn_against_rest() as f64
    }

    #[func]
    fn creature_spin(&self, c: i64) -> f64 {
        self.c.bodies[c as usize].spin() as f64
    }

    #[func]
    fn shape_error(&self, c: i64) -> f64 {
        self.c.bodies[c as usize].shape_error() as f64
    }

    /// mode (WAVE_*), amplitude (WAVE_RADIUS/SQUEEZE: of the radius; WAVE_POSE: the slope
    /// k·A), wavelength (px), frequency (Hz), axis (design frame; WAVE_POSE swims toward
    /// +axis), half_width (px, WAVE_RADIUS), bias (1/px, WAVE_POSE), envelope (0..1).
    #[func]
    fn set_wave(&mut self, c: i64, mode: i64, amplitude: f64, wavelength: f64, frequency: f64, axis: Vector2, half_width: f64, bias: f64, envelope: f64) {
        let b = &mut self.c.bodies[c as usize];
        let phase = b.wave.phase;
        b.wave = cells::Wave {
            mode: mode as u8,
            amp: amplitude as f32,
            k: std::f32::consts::TAU / (wavelength as f32).max(1e-3),
            omega: std::f32::consts::TAU * frequency as f32,
            axis: axis.normalized(),
            half_width: half_width as f32,
            bias: bias as f32,
            envelope: envelope as f32,
            phase,
            age: if b.wave.mode == mode as u8 { b.wave.age } else { 0.0 },
        };
        if mode as u8 == cells::WAVE_OFF {
            for i in 0..b.n {
                b.muscle[i] = 1.0;
            }
            for l in b.links.iter_mut() {
                l.d_design = l.d_base;
                l.ai_design = l.ai_base;
                l.aj_design = l.aj_base;
            }
        }
    }

    /// Radius muscles per cell (1 at rest), kept until set again.
    #[func]
    fn set_cell_scales(&mut self, c: i64, scales: PackedFloat32Array) {
        let b = &mut self.c.bodies[c as usize];
        for (i, &s) in scales.as_slice().iter().enumerate().take(b.n) {
            b.muscle[i] = s;
        }
    }

    #[func]
    fn centers(&self, c: i64) -> PackedVector2Array {
        PackedVector2Array::from(self.c.bodies[c as usize].pos.as_slice())
    }

    #[func]
    fn velocities(&self, c: i64) -> PackedVector2Array {
        PackedVector2Array::from(self.c.bodies[c as usize].vel.as_slice())
    }

    #[func]
    fn radii(&self, c: i64) -> PackedFloat32Array {
        PackedFloat32Array::from(self.c.bodies[c as usize].r.as_slice())
    }

    #[func]
    fn angles(&self, c: i64) -> PackedFloat32Array {
        PackedFloat32Array::from(self.c.bodies[c as usize].th.as_slice())
    }

    #[func]
    fn rest_local(&self, c: i64) -> PackedVector2Array {
        PackedVector2Array::from(self.c.bodies[c as usize].rest_local.as_slice())
    }

    #[func]
    fn types(&self, c: i64) -> PackedInt32Array {
        PackedInt32Array::from_iter(self.c.bodies[c as usize].typ.iter().map(|&t| t as i32))
    }

    #[func]
    fn uids(&self, c: i64) -> PackedInt32Array {
        PackedInt32Array::from_iter(self.c.bodies[c as usize].uid.iter().map(|&t| t as i32))
    }

    #[func]
    fn boundary(&self, c: i64) -> PackedInt32Array {
        PackedInt32Array::from_iter(self.c.bodies[c as usize].boundary.iter().map(|&t| t as i32))
    }

    #[func]
    fn outline(&self, c: i64) -> PackedInt32Array {
        PackedInt32Array::from_iter(self.c.bodies[c as usize].outline.iter().map(|&t| t as i32))
    }

    #[func]
    fn outline_surface(&self, c: i64) -> PackedVector2Array {
        let mut s = Vec::new();
        self.c.bodies[c as usize].outline_surface(&mut s);
        PackedVector2Array::from(s.as_slice())
    }

    #[func]
    fn skin(&self, c: i64, iterations: i64) -> PackedVector2Array {
        PackedVector2Array::from(self.c.skin(c as usize, iterations.max(0) as usize).as_slice())
    }

    /// Every creature's skin: [points, counts (one per slot), build µs].
    #[func]
    fn skins_all(&self, iterations: i64) -> VarArray {
        let t = std::time::Instant::now();
        let (p, counts) = self.c.skins_all(iterations.max(0) as usize);
        let us = t.elapsed().as_micros() as i64;
        let mut a = VarArray::new();
        a.push(&PackedVector2Array::from(p.as_slice()).to_variant());
        a.push(&PackedInt32Array::from(counts.as_slice()).to_variant());
        a.push(&us.to_variant());
        a
    }

    /// Links as pairs of cell indices.
    #[func]
    fn links(&self, c: i64) -> PackedInt32Array {
        let b = &self.c.bodies[c as usize];
        let mut out = Vec::with_capacity(b.links.len() * 2);
        for l in &b.links {
            out.push(l.i as i32);
            out.push(l.j as i32);
        }
        PackedInt32Array::from(out.as_slice())
    }

    /// Each link's smoothed load (the break test's number).
    #[func]
    fn link_loads(&self, c: i64) -> PackedFloat32Array {
        PackedFloat32Array::from_iter(self.c.bodies[c as usize].links.iter().map(|l| l.load))
    }

    /// Each link's strain now (length over rest − 1).
    #[func]
    fn link_strains(&self, c: i64) -> PackedFloat32Array {
        let b = &self.c.bodies[c as usize];
        PackedFloat32Array::from_iter(b.links.iter().map(|l| (b.pos[l.j as usize] - b.pos[l.i as usize]).length() / l.rest.max(1e-3) - 1.0))
    }

    /// Candidates to join: (creature a, cell, creature b, cell) × N.
    #[func]
    fn find_captures(&self, capture: f64, same: bool) -> PackedInt32Array {
        let v = self.c.find_captures(capture as f32, same);
        PackedInt32Array::from_iter(v.iter().flat_map(|p| p.iter().map(|&x| x as i32)))
    }

    /// Joins pairs as find_captures() gives them (four ints each); returns links made.
    #[func]
    fn join(&mut self, pairs: PackedInt32Array) -> i64 {
        let s = pairs.as_slice();
        let v: Vec<[u32; 4]> = s.chunks_exact(4).map(|q| [q[0] as u32, q[1] as u32, q[2] as u32, q[3] as u32]).collect();
        self.c.join(&v) as i64
    }

    #[func]
    fn add_cell(&mut self, c: i64, at: Vector2, radius: f64, typ: i64) -> i64 {
        self.c.add_cell(c as usize, at, radius as f32, typ as u8) as i64
    }

    #[func]
    fn remove_cell(&mut self, c: i64, i: i64) {
        self.c.remove_cell(c as usize, i as usize);
    }

    /// Events since the last call: (kind, creature, a, b) × N (uids; EVENT_SPLIT: parent,
    /// new creature, its cell count).
    #[func]
    fn take_events(&mut self) -> PackedInt32Array {
        let e = std::mem::take(&mut self.c.events);
        PackedInt32Array::from_iter(e.iter().flat_map(|x| x.iter().copied()))
    }

    /// [px, py, angular momentum about the origin]
    #[func]
    fn momentum(&self) -> PackedFloat64Array {
        PackedFloat64Array::from(self.c.momentum().as_slice())
    }

    #[func]
    fn state_hash(&self) -> i64 {
        self.c.state_hash()
    }

    /// [cross_overlap_max, cells_inside_other, self_overlap_max, strain_max, shape_err_max,
    /// shape_err_mean, wall_overlap_max, not_finite]
    #[func]
    fn health(&self) -> PackedFloat32Array {
        PackedFloat32Array::from(self.c.health().as_slice())
    }

    #[func]
    fn stats(&self) -> VarDictionary {
        let s = &self.c.stats;
        let mut d = VarDictionary::new();
        d.set("total_us", s.total_us as i64);
        d.set("prep_us", s.prep_us as i64);
        d.set("broad_us", s.broad_us as i64);
        d.set("solve_us", s.solve_us as i64);
        d.set("serial_us", s.serial_us as i64);
        d.set("vel_us", s.vel_us as i64);
        d.set("topo_us", s.topo_us as i64);
        d.set("cross_pairs", s.cross_pairs as i64);
        d.set("wall_pairs", s.wall_pairs as i64);
        d.set("self_pairs", s.self_pairs as i64);
        d.set("links", s.links as i64);
        d.set("build_us", s.build_us as i64);
        d
    }
}
