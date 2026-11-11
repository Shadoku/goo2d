extends TestCase
## Unit tests for GooKernel, Goo2D's native kernel (the Rust GDExtension in
## addons/goo2d/native/, loaded through addons/goo2d/goo2d.gdextension).
##
## Stage 0 of docs/native-kernel-plan.md: the class is registered and data
## crosses the GDScript/Rust boundary both ways. Stage 1: the kernel runs the
## goo's per-frame math, and its static functions (the same math on plain
## arrays) must agree with the GDScript reference implementations on random
## loops, round, squashed, dented, pinched into a waist and folded: Goo2D's
## find_pinch(), hull_depths(), skin_offset(), skin_pieces() and
## short_axis_beads(), GooWorld2D.intrusion() and Untangler.push(), and the
## GooLoop statics. Vectors are 32-bit on both sides but GDScript's scalars are
## 64-bit, so the two agree to rounding, not bit for bit: compared within
## TOLERANCE (relative for forces). Stage 2: the kernel owns the beads; its
## solver is checked here on rings added straight to a kernel (gravity, a static
## floor, the stretch limit, swept contacts, pass-through, sleeping), and the
## integration tests check it driving real bodies.

const TOLERANCE: float = 1e-3

var kernel: RefCounted

func before_each() -> void:
	GooTuning.unit = 1.0
	kernel = ClassDB.instantiate("GooKernel") as RefCounted if ClassDB.class_exists("GooKernel") else null

func after_each() -> void:
	GooTuning.unit = 1.0

func test_class_is_registered() -> void:
	assert_true(ClassDB.class_exists("GooKernel"),
		"GooKernel is not registered: build the library with bash tools/build_native.sh")
	assert_eq(ClassDB.get_parent_class("GooKernel"), &"RefCounted")
	assert_not_null(kernel)

func test_version_is_not_empty() -> void:
	assert_not_null(kernel)
	if kernel == null:
		return
	var version: String = kernel.call("version")
	assert_ne(version, "")
	assert_eq(version.split(".").size(), 3, "a semantic version, got '%s'" % version)

func test_sum_round_trip() -> void:
	assert_not_null(kernel)
	if kernel == null:
		return
	assert_almost_eq(kernel.call("sum", PackedFloat32Array([1.5, 2.25, -0.75, 4.0])), 7.0, 1e-6)
	assert_almost_eq(kernel.call("sum", PackedFloat32Array()), 0.0, 1e-6, "an empty array sums to 0")
	var values := PackedFloat32Array()
	var expected: float = 0.0
	for i: int in 1000:
		values.append(i * 0.5)
		expected += i * 0.5
	assert_almost_eq(kernel.call("sum", values), expected, 1e-3, "a thousand values")

# ---- Fixtures ----

# A ring of `count` beads of radius `radius` around (400, 600), squashed to
# `squash` of its height, with `dents` (Vector3(angle, depth as a fraction of the
# radius, width in radians)) pushed in and `noise` px of jitter.
static func _ring(rng: RandomNumberGenerator, count: int, radius: float, squash: float,
		dents: Array[Vector3], noise: float, centre: Vector2 = Vector2(400.0, 600.0)) -> PackedVector2Array:
	var points := PackedVector2Array()
	for i: int in count:
		var angle := -TAU * i / count
		var r := radius
		for dent: Vector3 in dents:
			var off := absf(wrapf(angle - dent.x, -PI, PI))
			if off < dent.z:
				r -= radius * dent.y * (0.5 + 0.5 * cos(PI * off / dent.z))
		var point := Vector2(cos(angle) * r, sin(angle) * r * squash)
		points.append(centre + point + Vector2(rng.randf_range(-noise, noise), rng.randf_range(-noise, noise)))
	return points

# A random loop of every kind the tests use: case k picks round, dented, a waist
# or (every 7th) folded through itself.
static func _random_loop(rng: RandomNumberGenerator, k: int) -> PackedVector2Array:
	var count: int = [12, 16, 23, 30, 40, 60][k % 6]
	var radius := rng.randf_range(20.0, 120.0)
	var dents: Array[Vector3] = []
	for _d: int in rng.randi_range(0, 3):
		dents.append(Vector3(rng.randf_range(-PI, PI), rng.randf_range(0.0, 1.6), rng.randf_range(0.2, 1.4)))
	if k % 4 == 0:
		var at := rng.randf_range(-PI, PI)
		var depth := rng.randf_range(0.5, 1.0)
		dents = [Vector3(at, depth, 1.0), Vector3(at + PI, depth, 1.0)] as Array[Vector3]
	var points := _ring(rng, count, radius, rng.randf_range(0.3, 1.0), dents,
		rng.randf_range(0.0, 3.0) if k % 3 != 0 else 0.0)
	if k % 7 == 6:
		var centre := GooLoop.centroid(points)
		for i: int in [count - 2, count - 1, 0, 1]:
			points[i] = centre - (points[i] - centre) * 1.3
	return points

func _assert_points_near(got: PackedVector2Array, want: PackedVector2Array, tolerance: float, what: String) -> bool:
	assert_eq(got.size(), want.size(), "%s: point count" % what)
	if got.size() != want.size():
		return false
	var worst := 0.0
	for i: int in got.size():
		worst = maxf(worst, got[i].distance_to(want[i]))
	assert_lt(worst, tolerance, "%s: points up to %.6f px apart" % [what, worst])
	return worst < tolerance

static func _largest(forces: PackedVector2Array) -> float:
	var largest := 0.0
	for force: Vector2 in forces:
		largest = maxf(largest, force.length())
	return largest

# ---- Constants ----

func test_constants_match_the_gdscript_ones() -> void:
	var constants: Dictionary = GooKernel.constants()
	var want := {
		"MAX_PRESSURE_RATIO": Goo2D.MAX_PRESSURE_RATIO, "MIN_AREA_RATIO": Goo2D.MIN_AREA_RATIO,
		"SKIN_SMOOTHING": Goo2D.SKIN_SMOOTHING, "SKIN_KINK_TURN": Goo2D.SKIN_KINK_TURN,
		"SKIN_KINK_REACH": Goo2D.SKIN_KINK_REACH, "SKIN_KINK_CLEARANCE": Goo2D.SKIN_KINK_CLEARANCE,
		"SKIN_REPAIR_GROW": Goo2D.SKIN_REPAIR_GROW, "SKIN_MAX_SPLITS": Goo2D.SKIN_MAX_SPLITS,
		"GROUP_CHECK_INTERVAL": Goo2D.GROUP_CHECK_INTERVAL,
		"MAX_STRETCH": Goo2D.MAX_STRETCH, "PINCH_SCAN_FRAMES": Goo2D.PINCH_SCAN_FRAMES,
		"PINCH_CONSTRICTION": Goo2D.PINCH_CONSTRICTION, "SPLIT_HOLD": GooTuning.SPLIT_HOLD,
		"SPLAT_HOLD_FRAMES": GooTuning.SPLAT_HOLD_FRAMES, "SPLIT_LOCK": GooTuning.SPLIT_LOCK,
		"INTRUSION_MARGIN_BEADS": GooWorld2D.INTRUSION_MARGIN_BEADS,
		"INTRUSION_FREQUENCY": GooWorld2D.INTRUSION_FREQUENCY,
		"STRENGTH": GooWorld2D.Untangler.STRENGTH, "SEPARATION_SPEED": GooWorld2D.Untangler.SEPARATION_SPEED,
		"RELEASE_MARGIN": GooWorld2D.Untangler.RELEASE_MARGIN,
		"MIN_OVERLAP_RATIO": GooWorld2D.Untangler.MIN_OVERLAP_RATIO, "MAX_POINTS": GooSkin.MAX_POINTS,
	}
	assert_eq(constants.size(), want.size(), "the kernel names every constant it uses")
	for name: String in want:
		assert_true(constants.has(name), "the kernel has %s" % name)
		assert_almost_eq(float(constants.get(name, NAN)), float(want[name]), 1e-6, name)

# ---- Loop math (GooLoop) ----

func test_loop_statics_agree_with_gooloop() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	for k: int in 60:
		var points := _random_loop(rng, k)
		var rest := _random_loop(rng, k)
		var what := "loop %d" % k
		_assert_points_near(GooKernel.edge_normals(points), GooLoop.edge_normals(points), TOLERANCE, what + " normals")
		assert_almost_eq(GooKernel.signed_area(points), GooLoop.signed_area(points),
			TOLERANCE * maxf(1.0, absf(GooLoop.signed_area(points))), what + " signed area")
		assert_lt(GooKernel.centroid(points).distance_to(GooLoop.centroid(points)), TOLERANCE, what + " centroid")
		assert_almost_eq(GooKernel.outline_area(points, 4.0), GooTuning.outline_area(points, 4.0),
			TOLERANCE * GooTuning.outline_area(points, 4.0), what + " outline area")
		assert_almost_eq(GooKernel.best_fit_rotation(rest, points), GooLoop.best_fit_rotation(rest, points),
			TOLERANCE, what + " best-fit rotation")
		_assert_points_near(GooKernel.goal_positions(rest, points), GooLoop.goal_positions(rest, points),
			TOLERANCE * 10.0, what + " goal positions")
		_assert_points_near(GooKernel.chaikin(points, 2), GooLoop.chaikin(points, 2), TOLERANCE, what + " chaikin")
		var keep := PackedByteArray()
		for i: int in points.size():
			keep.append(1 if rng.randf() < 0.2 else 0)
		_assert_points_near(GooKernel.chaikin_keeping(points, 2, keep), GooLoop.chaikin_keeping(points, 2, keep),
			TOLERANCE, what + " chaikin keeping")
		_assert_points_near(GooKernel.resample(points, 32), GooLoop.resample(points, 32), TOLERANCE * 10.0,
			what + " resample")
		assert_eq(GooKernel.convex_hull(points), Geometry2D.convex_hull(points), what + " convex hull")
		var box := Rect2(points[0], Vector2.ZERO)
		for point: Vector2 in points:
			box = box.expand(point)
		var mismatches := 0
		for _p: int in 50:
			var probe := Vector2(rng.randf_range(box.position.x, box.end.x), rng.randf_range(box.position.y, box.end.y))
			if GooKernel.point_in_polygon(probe, points) != Geometry2D.is_point_in_polygon(probe, points):
				mismatches += 1
		assert_eq(mismatches, 0, what + " point in polygon")

# ---- Split detection ----

func test_hull_depths_and_find_pinch_agree_with_goo2d() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261015
	var necks := 0
	var ties := 0
	var cases := 0
	for k: int in 240:
		var points := _random_loop(rng, k)
		var what := "loop %d (%d beads)" % [k, points.size()]
		var want_depths := Goo2D.hull_depths(points)
		var got_depths := GooKernel.hull_depths(points)
		assert_eq(got_depths.size(), want_depths.size(), what + " depth count")
		for i: int in mini(got_depths.size(), want_depths.size()):
			assert_almost_eq(got_depths[i], want_depths[i], TOLERANCE, "%s depth %d" % [what, i])
		var bead := rng.randf_range(2.0, 12.0)
		var rest := PackedVector2Array()
		var min_rest := 0.0
		var rest_depths := PackedFloat32Array()
		if k % 5 == 1:
			rest = _random_loop(rng, k)
			min_rest = rng.randf_range(0.0, 60.0)
		elif k % 5 == 2:
			rest_depths = Goo2D.hull_depths(_random_loop(rng, k))
		var want := Goo2D.find_pinch(points, bead, Goo2D.PINCH_CONSTRICTION, rest, min_rest, rest_depths)
		var got: Dictionary = GooKernel.find_pinch(points, bead, Goo2D.PINCH_CONSTRICTION, rest, min_rest, rest_depths)
		cases += 1
		if int(want["a"]) >= 0:
			necks += 1
		if int(got["a"]) == int(want["a"]) and int(got["b"]) == int(want["b"]):
			if int(want["a"]) >= 0:
				assert_almost_eq(float(got["gap"]), float(want["gap"]), TOLERANCE, what + " gap")
				assert_almost_eq(float(got["constriction"]), float(want["constriction"]), TOLERANCE, what + " constriction")
			continue
		# Another pair: only a tie the rounding broke the other way (as narrow).
		ties += 1
		assert_almost_eq(float(got["gap"]), float(want["gap"]), TOLERANCE,
			"%s: kernel neck %d-%d, GDScript %d-%d" % [what, got["a"], got["b"], want["a"], want["b"]])
	print("    %d loops, %d with a neck, %d ties broken the other way" % [cases, necks, ties])
	assert_gt(necks, 20, "the loops should include plenty of necks")
	assert_lt(ties, cases / 50 + 1, "the kernel finds the same neck on (nearly) every loop")

func test_short_axis_beads_agree_with_goo2d() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	for k: int in 60:
		var points := _random_loop(rng, k)
		assert_eq(GooKernel.short_axis_beads(points), Goo2D.short_axis_beads(points), "loop %d" % k)

# ---- Skin ----

func test_skin_offset_and_outline_agree_with_goo2d() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 77
	var repaired := 0
	for k: int in 120:
		var points := _random_loop(rng, k)
		var bead := rng.randf_range(2.0, 10.0)
		var what := "loop %d" % k
		_assert_points_near(GooKernel.skin_offset(points, bead), Goo2D.skin_offset(points, bead), TOLERANCE,
			what + " offset")
		var flags := PackedByteArray()
		if k % 3 == 0:
			for i: int in points.size():
				flags.append(1 if rng.randf() < 0.15 else 0)
		var want := Goo2D.skin_pieces(points, bead, flags)
		var got: Array = GooKernel.skin_pieces(points, bead, flags)
		var smooth := GooLoop.chaikin_keeping(Goo2D.skin_offset(points, bead), Goo2D.SKIN_SMOOTHING, flags)
		if want.size() == 1 and want[0].size() == smooth.size():
			assert_eq(got.size(), 1, what + ": one polygon")
			if got.size() == 1:
				_assert_points_near(got[0], want[0], TOLERANCE, what + " outline")
			continue
		# Cut at its crossings or repaired by Clipper (folded loops): the same
		# polygons, give or take rounding.
		repaired += 1
		assert_eq(got.size(), want.size(), what + ": as many polygons")
		for m: int in mini(got.size(), want.size()):
			var piece: PackedVector2Array = got[m]
			assert_false(Geometry2D.triangulate_polygon(piece).is_empty(), what + ": the kernel's polygon %d triangulates" % m)
			assert_true(GooLoop.is_ccw(piece), what + ": the kernel's polygon %d is CCW" % m)
			assert_almost_eq(GooLoop.area(piece), GooLoop.area(want[m]), 0.01 * GooLoop.area(want[m]) + 1e-3,
				what + " polygon %d area" % m)
	print("    %d folded or repaired outlines" % repaired)

func test_split_at_crossings_agrees_with_goo_loop() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 78
	var split := 0
	for k: int in 80:
		var points := _random_loop(rng, k)
		# Fold a run of beads through the loop so it crosses itself.
		var centre := GooLoop.centroid(points)
		var start := rng.randi_range(0, points.size() - 1)
		for n: int in rng.randi_range(1, 4):
			var i := (start + n) % points.size()
			points[i] = centre - (points[i] - centre) * rng.randf_range(0.5, 1.4)
		var want := GooLoop.split_at_crossings(points, Goo2D.SKIN_MAX_SPLITS)
		var got: Array = GooKernel.split_at_crossings(points, Goo2D.SKIN_MAX_SPLITS)
		var what := "loop %d" % k
		assert_eq(got.size(), want.size(), what + ": as many loops")
		if want.size() > 1:
			split += 1
		for j: int in mini(got.size(), want.size()):
			_assert_points_near(got[j], want[j], TOLERANCE, what + " loop %d" % j)
	assert_gt(split, 20, "the folds should have made loops that cross themselves")
	print("    %d of 80 loops cut at crossings" % split)

func test_crushed_ring_skin_matches_the_reference() -> void:
	# The crushed ring of test_goo2d_skin.gd, whose unclamped skin did not triangulate.
	var crushed := PackedVector2Array([
		Vector2(681.96606, 848.4465), Vector2(676.6991, 849.83704), Vector2(674.9478, 844.3505),
		Vector2(670.1119, 846.3146), Vector2(670.3651, 851.29315), Vector2(670.6065, 856.22003),
		Vector2(675.4398, 858.0508), Vector2(679.3799, 854.9852), Vector2(683.8622, 856.4266),
		Vector2(688.4101, 857.8498), Vector2(692.4426, 853.9098), Vector2(691.0869, 848.38855),
		Vector2(688.10474, 843.97296), Vector2(685.85205, 839.25586), Vector2(680.3205, 839.09924),
		Vector2(680.6642, 843.6374)])
	var bead := 3.60509729687567
	var got: Array = GooKernel.skin_pieces(crushed, bead, PackedByteArray())
	assert_eq(got.size(), 1)
	if got.size() != 1:
		return
	_assert_points_near(got[0], Goo2D.skin_pieces(crushed, bead, PackedByteArray())[0], TOLERANCE, "crushed ring")
	assert_false(Geometry2D.triangulate_polygon(got[0]).is_empty())

func test_shader_outline_is_what_gooskin_pushes() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 3
	for count: int in [3, 16, 32, 33, 60]:
		var raw := _ring(rng, count, 50.0, 0.8, [] as Array[Vector3], 1.0)
		var skin := GooSkin.new()
		skin.update(raw, Vector2(400.0, 600.0), 50.0, Vector2.ZERO, 0.0)
		var want: PackedVector2Array = skin.material.get_shader_parameter("points")
		_assert_points_near(GooKernel.shader_outline(raw, Vector2(400.0, 600.0)), want, TOLERANCE * 10.0,
			"%d points" % count)
	var empty := GooKernel.shader_outline(PackedVector2Array(), Vector2(5.0, 6.0))
	assert_eq(empty.size(), GooSkin.MAX_POINTS)
	assert_eq(empty[0], Vector2(5.0, 6.0), "an empty outline is padded with the centre")

# ---- The solver ----

# A round ring of `radius` from GooTuning.tuning() added to `goo` at `centre`,
# under the key `key`; returns the tuning.
static func _add_round(goo: GooKernel, key: int, radius: float, centre: Vector2) -> Dictionary:
	var tuning := GooTuning.tuning(radius)
	var count: int = tuning["bead_count"]
	var rest := GooLoop.circle_points(Vector2.ZERO, tuning["ring_radius"], count)
	var edges := PackedFloat32Array()
	for i: int in count:
		edges.append(rest[i].distance_to(rest[(i + 1) % count]))
	var points := PackedVector2Array()
	for point: Vector2 in rest:
		points.append(point + centre)
	var params := tuning.duplicate()
	params["min_neck_rest"] = 0.0
	params["split_lock"] = GooTuning.SPLIT_LOCK
	goo.add_ring(key, points, rest, edges, PackedFloat32Array(), PackedByteArray(), params)
	return tuning

# A kernel with GooTuning's solver settings and a static floor whose top face is
# at y = `top`, `grip` or not.
static func _kernel_on_floor(top: float, grip: bool = true) -> GooKernel:
	var goo := GooTuning.make_kernel()
	goo.add_static_shape(1, Transform2D(0.0, Vector2(0.0, top + 20.0)),
		GooStatics.shape_points(_rect(Vector2(4000.0, 40.0))), 0.4, 0.3, grip)
	return goo

static func _rect(size: Vector2) -> RectangleShape2D:
	var rect := RectangleShape2D.new()
	rect.size = size
	return rect

static func _lowest(points: PackedVector2Array) -> float:
	var lowest := -INF
	for point: Vector2 in points:
		lowest = maxf(lowest, point.y)
	return lowest

func test_a_ring_falls_under_gravity() -> void:
	var goo := GooTuning.make_kernel()
	_add_round(goo, 1, 40.0, Vector2(0.0, 0.0))
	var before := goo.center(1)
	goo.step(1.0 / 60.0)
	var velocity := goo.average_velocity(1)
	print("    after one step: centre moved %s, mean velocity %s" % [goo.center(1) - before, velocity])
	assert_almost_eq(velocity.y, GooTuning.gravity() / 60.0, 0.5, "gravity, less a little damping")
	assert_almost_eq(velocity.x, 0.0, 0.001)
	assert_gt(goo.center(1).y, before.y, "it moved down")
	assert_eq(goo.solver()["last_substeps"], GooTuning.SUBSTEPS)

func test_a_ring_comes_to_rest_on_a_static_shape_and_grips_it() -> void:
	var goo := _kernel_on_floor(500.0)
	var tuning := _add_round(goo, 1, 40.0, Vector2(0.0, 400.0))
	var bead: float = tuning["bead_radius"]
	var deepest := -INF
	for frame: int in 240:
		goo.step(1.0 / 60.0)
		deepest = maxf(deepest, _lowest(goo.points(1)) + bead - 500.0)
	var gripping := 0
	for i: int in tuning["bead_count"]:
		if goo.bead_gripping(1, i):
			gripping += 1
	var area := goo.area(1) / float(tuning["target_area"])
	print("    40 px ring dropped 60 px onto a floor: deepest overlap %.2f px, at rest %.2f px/s, %d beads grip, area %.3f, settled %s"
		% [deepest, goo.average_velocity(1).length(), gripping, area, goo.is_settled(1)])
	assert_lt(deepest, 1.0, "no bead sinks into the floor")
	assert_lt(goo.average_velocity(1).length(), 5.0, "it comes to rest")
	assert_gt(gripping, 2, "the beads on the floor grip it")
	assert_gt(area, 0.9, "the pressure holds its area")
	var slippery := _kernel_on_floor(500.0, false)
	_add_round(slippery, 1, 40.0, Vector2(0.0, 400.0))
	for frame: int in 60:
		slippery.step(1.0 / 60.0)
	for i: int in tuning["bead_count"]:
		assert_false(slippery.bead_gripping(1, i), "a shape that does not grip gives no grip")

func test_the_stretch_limit_is_hard() -> void:
	var goo := GooTuning.make_kernel()
	var tuning := _add_round(goo, 1, 120.0, Vector2.ZERO)
	var count: int = tuning["bead_count"]
	var points := goo.points(1)
	# Bead 0 pulled far out: its two edges at about three times their rest length.
	points[0] *= 1.6
	goo.set_points(1, points)
	goo.step(1.0 / 60.0)
	points = goo.points(1)
	var rest := GooLoop.circle_points(Vector2.ZERO, tuning["ring_radius"], count)
	var worst := 0.0
	for i: int in count:
		var ratio := points[i].distance_to(points[(i + 1) % count]) / rest[i].distance_to(rest[(i + 1) % count])
		worst = maxf(worst, ratio)
	print("    longest edge after one step: %.3f × its rest length (limit %.1f)" % [worst, Goo2D.MAX_STRETCH])
	assert_lt(worst, Goo2D.MAX_STRETCH + 0.05, "no edge stays past the limit")

func test_rest_blend_holds_the_placed_loop_and_eases_into_the_rest_lengths() -> void:
	# A round ring placed on a circle 1.4 times its rest ring's radius, as a
	# merged ring is placed on its pair's union, longer around than its circle;
	# the pressure aims at the area it has, so only the skin and bending pull.
	var tuning := GooTuning.tuning(40.0)
	var count: int = tuning["bead_count"]
	var rest := GooLoop.circle_points(Vector2.ZERO, tuning["ring_radius"], count)
	var edges := PackedFloat32Array()
	var placed := PackedVector2Array()
	for i: int in count:
		edges.append(rest[i].distance_to(rest[(i + 1) % count]))
		placed.append(rest[i] * 1.4)
	var params := tuning.duplicate()
	params["min_neck_rest"] = 0.0
	params["split_lock"] = GooTuning.SPLIT_LOCK
	var after: Dictionary = {}
	for blend: float in [1.0, 0.5, 0.0]:
		var goo := GooTuning.make_kernel()
		goo.add_ring(1, placed, rest, edges, PackedFloat32Array(), PackedByteArray(), params)
		goo.set_ring_param(1, &"target_area", goo.area(1))
		if blend < 1.0:
			goo.set_ring_param(1, &"rest_blend", blend)
		goo.step(1.0 / 60.0)
		after[blend] = GooLoop.perimeter(goo.points(1)) / GooLoop.perimeter(placed)
	print("    perimeter after one step, over the placed loop's: blend 1 %.3f, 0.5 %.3f, 0 %.3f" % [after[1.0], after[0.5], after[0.0]])
	assert_lt(after[1.0], 0.93, "at 1 (the default) the skin snaps toward its rest lengths")
	assert_gt(after[0.0], 0.98, "at 0 the ring holds the loop it was placed on")
	assert_true(after[1.0] < after[0.5] and after[0.5] < after[0.0], "a blend in between pulls in between")

func test_a_fast_ring_does_not_tunnel_through_a_thin_wall() -> void:
	var goo := GooTuning.make_kernel()
	# Uncapped: the swept contacts must hold at twice GooTuning.MAX_BEAD_SPEED too.
	goo.set_solver({ "gravity": Vector2.ZERO, "max_bead_speed": 0.0 })
	goo.add_static_shape(1, Transform2D(0.0, Vector2(200.0, 0.0)), GooStatics.shape_points(_rect(Vector2(4.0, 600.0))),
		0.4, 0.3, true)
	var tuning := _add_round(goo, 1, GooTuning.MIN_RADIUS, Vector2.ZERO)
	goo.set_velocities(1, PackedVector2Array([Vector2(6000.0, 0.0)]))
	for frame: int in 30:
		goo.step(1.0 / 60.0)
	var rightmost := -INF
	for point: Vector2 in goo.points(1):
		rightmost = maxf(rightmost, point.x)
	print("    smallest ring thrown at 6000 px/s at a 4 px wall: rightmost bead at x %.1f (wall face at 198)" % rightmost)
	assert_lt(rightmost + float(tuning["bead_radius"]), 198.5, "every bead stays on the near side")

static func _fastest(goo: GooKernel, key: int) -> float:
	var fastest := 0.0
	for velocity: Vector2 in goo.velocities(key):
		fastest = maxf(fastest, velocity.length())
	return fastest

func test_no_bead_moves_faster_than_the_cap() -> void:
	var cap := GooTuning.MAX_BEAD_SPEED
	var goo := GooTuning.make_kernel()
	_add_round(goo, 1, 40.0, Vector2.ZERO)
	goo.set_velocities(1, PackedVector2Array([Vector2(10000.0, 0.0)]))
	assert_almost_eq(_fastest(goo, 1), cap, 0.01, "a velocity set from GDScript is capped")
	goo.step(1.0 / 60.0)
	print("    ring given 10000 px/s: fastest bead %.1f px/s after one step (cap %.0f)" % [_fastest(goo, 1), cap])
	assert_lt(_fastest(goo, 1), cap + 0.01, "no bead is faster than the cap after a step")
	goo.set_bead_velocity(1, 0, Vector2(0.0, -9000.0))
	assert_almost_eq(goo.bead_velocity(1, 0).length(), cap, 0.01, "set_bead_velocity() is capped")
	goo.apply_impulse(1, Vector2(1.0e6, 0.0))
	assert_lt(_fastest(goo, 1), cap + 0.01, "apply_impulse() is capped")

func test_the_cap_holds_a_ring_its_own_constraints_throw() -> void:
	# A ring built wrong (its beads on a loop three times the size its rest
	# edges fit, as a split given the other piece's rest shape was): the hard
	# stretch limit and the skin constraints pull it in within a step, faster
	# than the cap.
	var fastest: Array[float] = []
	for cap: float in [0.0, GooTuning.MAX_BEAD_SPEED]:
		var goo := GooTuning.make_kernel()
		goo.set_solver({ "max_bead_speed": cap })
		_add_round(goo, 1, 120.0, Vector2.ZERO)
		var points := goo.points(1)
		for i: int in points.size():
			points[i] *= 3.0
		goo.set_points(1, points)
		goo.step(1.0 / 60.0)
		fastest.append(_fastest(goo, 1))
	print("    ring built at three times its rest size: fastest bead %.0f px/s uncapped, %.0f capped" % [fastest[0], fastest[1]])
	assert_gt(fastest[0], GooTuning.MAX_BEAD_SPEED, "uncapped, the constraints throw the bead past the cap")
	assert_lt(fastest[1], GooTuning.MAX_BEAD_SPEED + 0.01, "capped, it stays at the cap")

func test_a_thrown_ring_is_not_capped() -> void:
	# The same throw (DropController's fastest is 1600 px/s) with and without
	# the cap moves the beads to the very same places: nothing reaches it.
	var runs: Array[GooKernel] = []
	for cap: float in [0.0, GooTuning.MAX_BEAD_SPEED]:
		var goo := _kernel_on_floor(600.0)
		goo.set_solver({ "max_bead_speed": cap })
		_add_round(goo, 1, 36.0, Vector2(0.0, 300.0))
		goo.set_velocities(1, PackedVector2Array([Vector2(1500.0, -400.0)]))
		runs.append(goo)
	var speed := 0.0
	var worst := 0.0
	for frame: int in 120:
		for goo: GooKernel in runs:
			goo.step(1.0 / 60.0)
		if frame == 0:
			speed = runs[1].average_velocity(1).length()
		worst = maxf(worst, _fastest(runs[0], 1))
		assert_eq(runs[1].points(1), runs[0].points(1), "frame %d: the cap changed nothing" % frame)
	print("    ring thrown at 1550 px/s at a floor: %.0f px/s after one step, fastest bead in two seconds of flight and landing %.0f px/s" % [speed, worst])
	assert_almost_eq(speed, Vector2(1500.0, -400.0).length(), 40.0, "about the throw's speed, less gravity and damping")

func test_the_solver_takes_the_untanglers_speeds() -> void:
	var goo := GooKernel.new()
	var defaults := goo.solver()
	assert_almost_eq(float(defaults["untangle_strength"]), GooWorld2D.Untangler.STRENGTH, 0.0001,
		"a kernel made without settings untangles with the Untangler's strength")
	assert_almost_eq(float(defaults["untangle_separation_speed"]), GooWorld2D.Untangler.SEPARATION_SPEED, 0.0001,
		"and up to its separation speed")
	goo.set_solver({ "untangle_strength": 123.0, "untangle_separation_speed": 456.0 })
	var applied := goo.solver()
	assert_almost_eq(float(applied["untangle_strength"]), 123.0, 0.0001)
	assert_almost_eq(float(applied["untangle_separation_speed"]), 456.0, 0.0001)

func test_the_untangler_parts_rings_up_to_the_solver_speed() -> void:
	# Two rings spawned nearly on top of each other in a world's kernel (pair
	# passes on): the Untangler lets them through each other and pushes them
	# apart, never past the separation speed the solver was given.
	var parting: Array[float] = []
	for speed: float in [GooWorld2D.Untangler.SEPARATION_SPEED, 100.0]:
		var goo := GooTuning.make_kernel()
		goo.set_pair_passes(true)
		goo.set_solver({ "gravity": Vector2.ZERO, "untangle_separation_speed": speed })
		_add_round(goo, 1, 40.0, Vector2.ZERO)
		_add_round(goo, 2, 40.0, Vector2(8.0, 0.0))
		var fastest := 0.0
		for frame: int in 10:
			goo.step(1.0 / 60.0)
			fastest = maxf(fastest, goo.average_velocity(2).x - goo.average_velocity(1).x)
		parting.append(fastest)
	print("    two 40 px rings 8 px apart: parting at up to %.0f px/s (separation speed %.0f), %.0f px/s (100)"
		% [parting[0], GooWorld2D.Untangler.SEPARATION_SPEED, parting[1]])
	assert_gt(parting[0], 300.0, "the default push parts them fast")
	assert_lt(parting[1], 130.0, "a lower separation speed parts them slower")

func test_a_ring_falls_at_half_gravity_at_half_unit() -> void:
	GooTuning.unit = 0.5
	var goo := GooTuning.make_kernel()
	_add_round(goo, 1, 20.0, Vector2.ZERO)
	goo.step(1.0 / 60.0)
	var velocity := goo.average_velocity(1)
	assert_almost_eq(velocity.y, 490.0 / 60.0, 0.25, "half gravity, less a little damping")
	assert_almost_eq(float(goo.solver()["max_bead_speed"]), 0.5 * GooTuning.MAX_BEAD_SPEED, 0.001)

func test_rings_collide_unless_they_pass_through() -> void:
	for through: bool in [false, true]:
		var goo := GooTuning.make_kernel()
		goo.set_solver({ "gravity": Vector2.ZERO })
		var tuning := _add_round(goo, 1, 40.0, Vector2(-60.0, 0.0))
		_add_round(goo, 2, 40.0, Vector2(60.0, 0.0))
		goo.set_velocities(1, PackedVector2Array([Vector2(300.0, 0.0)]))
		goo.set_velocities(2, PackedVector2Array([Vector2(-300.0, 0.0)]))
		goo.set_pass_through(1, 2, through)
		assert_eq(goo.passes_through(2, 1), through)
		var touched := false
		for frame: int in 30:
			goo.step(1.0 / 60.0)
			var events := goo.take_events()
			for i: int in range(0, events.size(), 4):
				touched = touched or (events[i] == Goo2D.EVENT_TOUCHED and events[i + 1] == 1 and events[i + 2] == 2)
		var gap := goo.center(2).x - goo.center(1).x
		print("    two 40 px rings thrown at each other%s: centres %.1f px apart, touched %s"
			% [" passing through" if through else "", gap, touched])
		if through:
			assert_lt(gap, 0.0, "rings passing through each other cross")
			assert_false(touched, "and never touch")
		else:
			assert_gt(gap, 2.0 * float(tuning["ring_radius"]), "colliding rings stay apart")
			assert_true(touched, "and report touching")
			for point: Vector2 in goo.points(1):
				assert_false(GooLoop.point_in_loop(point, goo.points(2)), "no bead inside the other ring")

func test_a_settled_ring_stays_put_until_hit() -> void:
	var goo := _kernel_on_floor(500.0)
	_add_round(goo, 1, 40.0, Vector2(0.0, 460.0))
	for frame: int in 180:
		goo.step(1.0 / 60.0)
	goo.settle(1)
	goo.take_events()
	var rest := goo.points(1)
	for frame: int in 30:
		goo.step(1.0 / 60.0)
	assert_eq(goo.points(1), rest, "a settled ring does not move")
	assert_true(goo.is_settled(1))
	_add_round(goo, 2, GooTuning.MIN_RADIUS, Vector2(0.0, 300.0))
	goo.set_velocities(2, PackedVector2Array([Vector2(0.0, 600.0)]))
	var woke := -1
	for frame: int in 60:
		goo.step(1.0 / 60.0)
		var events := goo.take_events()
		for i: int in range(0, events.size(), 4):
			if events[i] == Goo2D.EVENT_WOKE and events[i + 1] == 1 and woke < 0:
				woke = frame
	print("    a ring thrown onto a settled one woke it after %d frames" % woke)
	assert_gt(woke, -1, "a hard hit wakes it")

func test_static_shapes_follow_their_transform() -> void:
	var goo := GooTuning.make_kernel()
	goo.add_static_shape(7, Transform2D(0.0, Vector2(100.0, 50.0)), GooStatics.shape_points(_rect(Vector2(20.0, 10.0))),
		0.4, 0.3, true)
	assert_eq(goo.static_shape_ids(), PackedInt64Array([7]))
	var points := goo.static_shape_points(7)
	assert_true(points.has(Vector2(90.0, 45.0)) and points.has(Vector2(110.0, 55.0)), "placed by its transform: %s" % points)
	goo.set_static_transform(7, Transform2D(PI / 2.0, Vector2.ZERO))
	points = goo.static_shape_points(7)
	assert_lt(points[0].distance_to(Vector2(5.0, -10.0)), 0.001, "and moved with it: %s" % points)
	goo.remove_static_shape(7)
	assert_eq(goo.static_shape_ids().size(), 0)

# ---- Pair passes ----

func test_intrusion_agrees_with_gooworld2d() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 31
	var pressed := 0
	var deep := 0
	for k: int in 120:
		var a := _random_loop(rng, k)
		var b := _random_loop(rng, k + 3)
		# Moved so the two overlap by anything from nothing to one inside the other.
		var shift := GooLoop.centroid(a) - GooLoop.centroid(b) + Vector2.from_angle(rng.randf() * TAU) * rng.randf_range(0.0, 220.0)
		for i: int in b.size():
			b[i] += shift
		var va := PackedVector2Array()
		for i: int in a.size():
			va.append(Vector2(rng.randf_range(-200.0, 200.0), rng.randf_range(-200.0, 200.0)))
		var vb := PackedVector2Array()
		if k % 3 != 0:
			for i: int in b.size():
				vb.append(Vector2(rng.randf_range(-200.0, 200.0), rng.randf_range(-200.0, 200.0)))
		var radius_a := rng.randf_range(2.0, 10.0)
		var radius_b := rng.randf_range(2.0, 10.0)
		var mass_a := rng.randf_range(0.1, 2.0)
		var mass_b := rng.randf_range(0.1, 2.0)
		var want := GooWorld2D.intrusion(GooWorld2D.OverlapRing.new(a, radius_a, mass_a, va),
			GooWorld2D.OverlapRing.new(b, radius_b, mass_b, vb))
		var got: Dictionary = GooKernel.intrusion(a, va, radius_a, mass_a, b, vb, radius_b, mass_b)
		var what := "pair %d" % k
		assert_eq(got["pressed"], want.pressed, what + " pressed")
		assert_eq(got["inside_a"], want.inside_a, what + " inside a")
		assert_eq(got["inside_b"], want.inside_b, what + " inside b")
		assert_eq(got["beads_in_a"], want.beads_in_a, what + " beads in a")
		assert_eq(got["beads_in_b"], want.beads_in_b, what + " beads in b")
		assert_eq(got["reach_a"], want.reach_a, what + " reach a")
		assert_eq(got["reach_b"], want.reach_b, what + " reach b")
		assert_eq(got["centre_in_a"], want.centre_in_a, what + " centre in a")
		assert_eq(got["centre_in_b"], want.centre_in_b, what + " centre in b")
		assert_eq(got["deep"], want.deep(), what + " deep")
		var scale := maxf(1.0, maxf(_largest(want.forces_a), _largest(want.forces_b)))
		_assert_points_near(got["forces_a"], want.forces_a, TOLERANCE * scale, what + " forces a")
		_assert_points_near(got["forces_b"], want.forces_b, TOLERANCE * scale, what + " forces b")
		if want.pressed:
			pressed += 1
		if want.deep():
			deep += 1
	print("    %d pairs, %d pressed, %d deep" % [120, pressed, deep])
	assert_gt(pressed, 30, "plenty of pairs press")
	assert_gt(deep, 5, "and some are deep inside each other")

func test_untangle_push_agrees_with_the_untangler() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 41
	for k: int in 60:
		var ca := Vector2(rng.randf_range(0.0, 400.0), rng.randf_range(0.0, 400.0))
		var cb := ca + Vector2.from_angle(rng.randf() * TAU) * rng.randf_range(0.0, 150.0) if k > 0 else ca
		var args := [ca, rng.randf_range(20.0, 120.0), rng.randf_range(1.0, 20.0),
			cb, rng.randf_range(20.0, 120.0), rng.randf_range(1.0, 20.0), 1.0 / 60.0,
			Vector2(rng.randf_range(-900.0, 900.0), rng.randf_range(-900.0, 900.0)),
			Vector2(rng.randf_range(-900.0, 900.0), rng.randf_range(-900.0, 900.0))]
		var want: Array[Vector2] = GooWorld2D.Untangler.push.callv(args)
		var got: PackedVector2Array = GooKernel.untangle_push.callv(args)
		_assert_points_near(got, PackedVector2Array(want), TOLERANCE * maxf(1.0, want[0].length()), "case %d" % k)

# beads_inside() as Goo2D computed it: the other loop grown along its vertex
# normals, its box, point in polygon.
static func _reference_inside(points: PackedVector2Array, other: PackedVector2Array, margin: float) -> int:
	var loop := other
	if margin > 0.0:
		var normals := GooLoop.edge_normals(other)
		var count := other.size()
		loop = PackedVector2Array()
		for i: int in count:
			loop.append(other[i] + (normals[(i + count - 1) % count] + normals[i]).normalized() * margin)
	var inside := 0
	for point: Vector2 in points:
		if Geometry2D.is_point_in_polygon(point, loop):
			inside += 1
	return inside

func test_count_inside_agrees_with_the_reference() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 51
	for k: int in 60:
		var a := _random_loop(rng, k)
		var b := _random_loop(rng, k + 1)
		var shift := Vector2.from_angle(rng.randf() * TAU) * rng.randf_range(0.0, 200.0)
		for i: int in b.size():
			b[i] += shift
		var margin := 0.0 if k % 2 == 0 else rng.randf_range(1.0, 12.0)
		assert_eq(GooKernel.count_inside(a, b, margin), _reference_inside(a, b, margin), "pair %d" % k)

# ---- The kernel driving rings ----

func test_a_ring_joins_its_world_kernel_and_leaves_it_with_the_tree() -> void:
	var world := GooWorld2D.new()
	add_child(world)
	var body := world.spawn(40.0, Vector2(300.0, 300.0))
	var goo := world.kernel()
	var key := body.get_instance_id()
	assert_true(goo.has_ring(key), "a body built under a world is a ring of its kernel")
	assert_eq(goo.points(key), body.bead_points())
	assert_lt(body.center().distance_to(Vector2(300.0, 300.0)), 0.01)
	var lone := Goo2D.make(40.0, Vector2(600.0, 300.0), self)
	assert_false(goo.has_ring(lone.get_instance_id()), "a lone body is not")
	assert_true(lone.split_lock() > 0.0, "a lone body has a kernel of its own")
	world.remove_child(body)
	assert_false(goo.has_ring(key), "a body out of the tree leaves the kernel")
	world.add_child(body)
	assert_true(goo.has_ring(key), "and joins it again when it comes back")
	body.free()
	assert_eq(goo.ring_count(), 0)

# ---- Resizing (Goo2D.resize(), set_rest_deform()) ----

func test_set_rest_changes_the_rings_rest_lengths_in_place() -> void:
	var goo := GooTuning.make_kernel()
	var tuning := _add_round(goo, 1, 40.0, Vector2.ZERO)
	var count: int = tuning["bead_count"]
	var rest := GooLoop.circle_points(Vector2.ZERO, tuning["ring_radius"], count)
	var before := goo.rest_edges(1)
	assert_almost_eq(before[0], rest[0].distance_to(rest[1]), 0.001, "precondition: the rest edges")
	var bead: float = tuning["bead_radius"]
	assert_true(goo.set_rest(1, GooLoop.scaled(rest, 1.5), bead * 1.5))
	var after := goo.rest_edges(1)
	for i: int in count:
		assert_almost_eq(after[i], before[i] * 1.5, 0.001, "edge %d × 1.5" % i)
	assert_almost_eq(goo.ring_param(1, &"bead_radius"), bead * 1.5, 0.0001, "the bead radius follows")
	assert_eq(goo.rest_points(1).size(), count)
	assert_almost_eq(goo.rest_points(1)[0].x, rest[0].x * 1.5, 0.001, "shape matching's rest shape")
	assert_eq(goo.particle_count(), count, "the ring was not rebuilt")
	# With the rest blend half way the solver holds half way between the placed
	# loop's lengths (here the original rest) and the new rest shape's.
	goo.set_ring_param(1, &"rest_blend", 0.5)
	assert_almost_eq(goo.rest_edges(1)[0], before[0] * 1.25, 0.001, "blended with the placed loop")
	goo.set_ring_param(1, &"rest_blend", 1.0)
	# The ring then grows into it: its target area set to the bigger circle's.
	goo.set_ring_param(1, &"target_area", float(tuning["target_area"]) * 2.25)
	goo.set_solver({ "gravity": Vector2.ZERO })
	for frame: int in 60:
		goo.step(1.0 / 60.0)
	var grown := goo.area(1) / float(tuning["target_area"])
	print("    area after set_rest × 1.5 and a second: %.3f × the old target (2.25 wanted)" % grown)
	assert_almost_eq(grown, 2.25, 0.05, "the beads follow the new rest shape")

func test_set_rest_refuses_another_count() -> void:
	allow_errors = true
	var goo := GooTuning.make_kernel()
	var tuning := _add_round(goo, 1, 40.0, Vector2.ZERO)
	var rest := GooLoop.circle_points(Vector2.ZERO, tuning["ring_radius"], int(tuning["bead_count"]) + 1)
	assert_false(goo.set_rest(1, rest, 0.0), "a rest of another length is refused")

func test_set_ring_params_sets_the_tuning_in_place() -> void:
	var goo := GooTuning.make_kernel()
	_add_round(goo, 1, 40.0, Vector2.ZERO)
	var values := { "bead_mass": 2.5, "pressure_k": 77.0, "shape_match_k": 12.0, "skin_stiffness": 900.0,
		"skin_damping": 3.0, "bending_stiffness": 270.0, "bending_damping": 0.9, "internal_damp": 6.0,
		"linear_damp": 0.2, "bounce": 0.3, "friction": 0.15, "split_neck": 9.0, "splat_area_ratio": 0.7,
		"settle_speed": 3.0, "settle_time": 0.4, "radius": 55.0, "spacing": 1.0, "bead_count": 99 }
	goo.set_ring_params(1, values)
	for key: String in values:
		if key in ["spacing", "bead_count"]:
			continue
		assert_almost_eq(goo.ring_param(1, StringName(key)), float(values[key]), 0.0001, key)
	assert_eq(goo.particle_count(), int(GooTuning.bead_count(40.0)), "shaping keys are skipped")
	# The inverse mass follows the bead mass: an impulse moves heavier beads less.
	goo.apply_impulse(1, Vector2(10.0, 0.0))
	assert_almost_eq(goo.average_velocity(1).x, 10.0 / 2.5, 0.001)

# ---- Links ----

# Two rings of `radius` added to a gravity-free kernel side by side, their
# facing beads `gap` px apart, linked as link `id` at `strength` (GooLink.patch()
# and kernel_params()); returns the link's patch.
func _linked_pair(goo: GooKernel, radius: float, strength: float, gap_beads: float = 1.0) -> Dictionary:
	goo.set_solver({ "gravity": Vector2.ZERO })
	var tuning := GooTuning.tuning(radius)
	var ring: float = tuning["ring_radius"]
	var bead: float = tuning["bead_radius"]
	var apart := 2.0 * ring + gap_beads * 2.0 * bead
	_add_round(goo, 1, radius, Vector2(0.0, 0.0))
	_add_round(goo, 2, radius, Vector2(apart, 0.0))
	var rest := GooLoop.circle_points(Vector2.ZERO, ring, int(tuning["bead_count"]))
	var patch := GooLink.patch(rest, Vector2(ring, 0.0), rest, Vector2(-ring, 0.0), strength, radius, radius)
	assert_true(goo.add_link(7, 1, 2, patch["pairs"], patch["through_a"], patch["through_b"],
		GooLink.kernel_params(bead, bead, strength, 0.0)), "the kernel takes the link")
	return patch

func test_a_link_holds_its_beads_at_their_rest_lengths() -> void:
	var goo := GooTuning.make_kernel()
	var patch := _linked_pair(goo, 40.0, 1.0, 2.0)
	assert_true(goo.has_link(7))
	assert_eq(goo.link_ids(), PackedInt64Array([7]))
	# Pulled apart for a moment, then let go.
	goo.set_velocities(1, PackedVector2Array([Vector2(-300.0, 0.0)]))
	goo.set_velocities(2, PackedVector2Array([Vector2(300.0, 0.0)]))
	for frame: int in 120:
		goo.step(1.0 / 60.0)
	var info := goo.link_info(7)
	assert_almost_eq(float(info["ease"]), 1.0, 0.0001, "eased in")
	var pairs: PackedInt32Array = info["pairs"]
	var rest: PackedFloat32Array = info["rest_lengths"]
	assert_eq(pairs, patch["pairs"])
	var worst := 0.0
	for k: int in rest.size():
		var length := goo.bead_position(1, pairs[2 * k]).distance_to(goo.bead_position(2, pairs[2 * k + 1]))
		worst = maxf(worst, absf(length - rest[k]))
	print("    %d pairs, rest %.1f px, worst off by %.2f px after a pull" % [rest.size(), rest[rest.size() / 2], worst])
	assert_gt(rest.size(), 2, "a wide patch")
	assert_lt(worst, 2.0, "every pair within 2 px of its rest length")

func test_removing_a_ring_removes_its_links() -> void:
	var goo := GooTuning.make_kernel()
	_linked_pair(goo, 40.0, 0.5)
	goo.remove_ring(2)
	assert_false(goo.has_link(7))
	assert_eq(goo.link_ids().size(), 0)
	goo.step(1.0 / 60.0)
	assert_false(goo.add_link(8, 1, 2, PackedInt32Array([0, 0]), PackedInt32Array(), PackedInt32Array(), {}),
		"no link to a missing ring")
	assert_false(goo.add_link(8, 1, 1, PackedInt32Array([0, 1]), PackedInt32Array(), PackedInt32Array(), {}),
		"nor from a ring to itself")

func test_a_links_beads_pass_through_until_it_is_removed() -> void:
	var goo := GooTuning.make_kernel()
	var patch := _linked_pair(goo, 40.0, 0.5)
	var through_a: PackedInt32Array = patch["through_a"]
	var through_b: PackedInt32Array = patch["through_b"]
	var tied: int = (patch["pairs"] as PackedInt32Array)[0]
	assert_true(through_a.has(tied), "the tied beads pass through")
	assert_eq(through_a.size(), (patch["pairs"] as PackedInt32Array).size() / 2 + 2 * GooTuning.LINK_THROUGH_BEADS,
		"and LINK_THROUGH_BEADS beyond either end")
	for bead: int in through_a:
		assert_true(goo.bead_passes_through(1, bead, 2), "bead %d of a" % bead)
	for bead: int in through_b:
		assert_true(goo.bead_passes_through(2, bead, 1), "bead %d of b" % bead)
	var far := posmod(tied + 10, 18)
	assert_false(goo.bead_passes_through(1, far, 2), "a bead far from the patch collides")
	assert_false(goo.bead_passes_through(1, posmod(tied - 1 - GooTuning.LINK_THROUGH_BEADS, 18), 2),
		"so does one just beyond it")
	goo.remove_link(7)
	for bead: int in through_a:
		assert_false(goo.bead_passes_through(1, bead, 2), "bead %d collides again" % bead)

func test_a_rest_angle_turns_the_second_ring_its_way() -> void:
	for angle: float in [0.5, -0.5]:
		var goo := GooTuning.make_kernel()
		_linked_pair(goo, 40.0, 1.0)
		for frame: int in 30:
			goo.step(1.0 / 60.0)
		var before: float = goo.link_info(7)["bend"]
		goo.set_link_param(7, &"rest_angle", angle)
		for frame: int in 120:
			goo.step(1.0 / 60.0)
		var info := goo.link_info(7)
		var bend: float = info["bend"]
		print("    rest angle %+.1f: bend %+.3f -> %+.3f rad" % [angle, before, bend])
		assert_lt(absf(before), 0.05, "unbent at rest angle 0")
		assert_almost_eq(bend, angle, 0.15, "the joint bends to its rest angle")
		# The second ring turned by the angle about the neck: seen from the
		# first ring's frame (its patch facing +x), its centre swung off the
		# axis, below it (+y) for a positive (clockwise on screen) turn.
		var rest := GooLoop.circle_points(Vector2.ZERO, GooTuning.ring_radius(40.0), GooTuning.bead_count(40.0))
		var turn_a := GooLoop.best_fit_rotation(rest, goo.points(1))
		var seen := (goo.center(2) - goo.center(1)).rotated(-turn_a)
		assert_eq(signf(seen.y), signf(angle), "b swings the turn's way")
		assert_almost_eq(seen.angle(), angle * 0.5, 0.15, "about the neck (half the turn seen from a's centre)")
