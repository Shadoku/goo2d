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

mod consts;
mod forces;
mod geom;
mod grid;
mod kernel;
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
