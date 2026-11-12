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
    /// "slop", "bond_scale"; adhesion's (docs/colony-adhesion.md): "adhesion" (bool),
    /// "capture" (px), "join_reach" (px), "stick_scale", "anchor_scale", "creep" (/s),
    /// "break_force", "load_time" (s), "break_rest" (s), "ask" (bool: first touches wait for answer()), "capture_paused"
    /// (bool, the whole colony).
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
                "adhesion" => o.ad.enabled = value.try_to::<bool>().unwrap_or(number != 0.0),
                "capture" => o.ad.capture = (number as f32).max(0.0),
                "join_reach" => o.ad.join_reach = (number as f32).max(0.0),
                "stick_scale" => o.ad.stick_scale = (number as f32).max(1e-6),
                "anchor_scale" => o.ad.anchor_scale = (number as f32).max(1e-6),
                "creep" => o.ad.creep = (number as f32).max(0.0),
                "break_force" => o.ad.break_force = number as f32,
                "load_time" => o.ad.load_time = (number as f32).max(0.0),
                "break_rest" => o.ad.break_rest = (number as f32).max(0.0),
                "ask" => o.ad.ask = value.try_to::<bool>().unwrap_or(number != 0.0),
                "capture_paused" => o.ad.paused = value.try_to::<bool>().unwrap_or(number != 0.0),
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
            "not_finite",
        ];
        for (k, name) in names.iter().enumerate() {
            put(&mut d, name, h[k] as f64);
        }
        d
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
}
