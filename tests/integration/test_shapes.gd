extends TestCase
## Bodies of other shapes than round (GooShape): Goo2D.make() builds a polygon
## ring on its shape's bead loop (a bead on every inset corner) with a rest
## shape to match, round blobs stay exactly the bodies they were, the skin keeps
## a polygon's corners sharp, and a launch-size square and triangle dropped from
## the launch point land and settle on the floor holding their shape without
## splitting. The game launches the shape the drop controller rolled, and Tab
## cycles it. Every measured number is printed.

const STEP: float = 1.0 / 60.0
const MAIN_SCENE := preload("res://scenes/main.tscn")
## Largest per-bead RMS distance, as a fraction of the equivalent radius, between
## a settled ring's beads and its rest shape fitted onto them.
const SHAPE_TOLERANCE: float = 0.15

var arena: Arena
var game: Game
var splits: int = 0

func before_each() -> void:
	arena = (load("res://scenes/arena.tscn") as PackedScene).instantiate() as Arena
	add_child(arena)
	game = Game.new()
	game.arena = arena
	add_child(game)
	splits = 0
	game.split.connect(func(_a: float, _b: float, _position: Vector2) -> void:
		splits += 1)

# Per-bead RMS distance, px, between the beads and the rest shape moved rigidly
# onto them (the shape matching's goals).
static func _shape_error(blob: Goo2D) -> float:
	var points := blob.bead_points()
	var goals := GooLoop.goal_positions(blob.rest_shape, points)
	var total := 0.0
	for i: int in points.size():
		total += points[i].distance_squared_to(goals[i])
	return sqrt(total / maxi(points.size(), 1))

func test_make_builds_a_polygon_ring_on_its_bead_loop() -> void:
	for sides: int in [3, 4]:
		var radius := 40.0
		var pos := Vector2(360.0, 400.0 + 300.0 * sides)
		var blob := Goo2D.make(radius, pos, game, GooShape.regular(sides, 10.0))
		var tuning := GooTuning.tuning_for(GooShape.regular(sides, radius))
		var count: int = tuning["bead_count"]
		var label := "%d-gon" % sides
		print("    %s of radius %.1f: %d beads of radius %.2f px (a round blob gets %d of %.2f), target area %.1f%% of the outline's, shape_match_k %.1f"
			% [label, radius, count, tuning["bead_radius"], GooTuning.bead_count(radius),
				GooTuning.bead_radius(radius), 100.0 * float(tuning["target_area"]) / (PI * radius * radius),
				tuning["shape_match_k"]])
		assert_eq(blob.radius, radius, label + ": the blob's radius is its equivalent radius")
		assert_not_null(blob.shape)
		assert_eq(blob.shape.kind, GooShape.Kind.POLYGON, label)
		assert_almost_eq(blob.shape.radius(), radius, 0.001, label + ": the shape is scaled to the radius")
		assert_eq(blob.particle_count(), count, label)
		assert_eq(blob.rest_shape.size(), count, label)
		assert_true(GooLoop.centroid(blob.rest_shape).length() < 0.001, label + ": rest shape about its centroid")
		assert_almost_eq(blob.center().distance_to(pos), 0.0, 0.01, label + ": centre on the requested position")
		var points := blob.bead_points()
		assert_true(GooLoop.is_ccw(points), label)
		assert_almost_eq(blob.bead_radius(), float(tuning["bead_radius"]), 0.0001, label)
		assert_almost_eq(blob.target_area, float(tuning["target_area"]), 0.01, label)
		assert_almost_eq(blob.area() / blob.target_area, 1.0, 0.001, label + ": built at rest, at its target area")
		var mean := GooLoop.centroid(points)
		for i: int in count:
			assert_almost_eq(points[i].distance_to(mean + blob.rest_shape[i]), 0.0, 0.01,
				label + ": bead %d sits on the rest shape" % i)
		assert_lt(_shape_error(blob), 0.001, label + ": built in its rest shape")
		assert_eq(blob.corner_flags().count(1), sides, label + ": one corner bead per polygon corner")
		assert_eq(blob.get_tint(), GooTuning.color(radius))

func test_round_blobs_are_the_same_bodies_with_or_without_a_shape() -> void:
	var radius := 37.0
	var plain := Goo2D.make(radius, Vector2(200.0, 400.0), game)
	var shaped := Goo2D.make(radius, Vector2(200.0, 400.0), game, GooShape.round(12.0))
	for blob: Goo2D in [plain, shaped]:
		assert_true(blob.shape.is_round())
		assert_eq(blob.shape.radius(), radius)
		assert_eq(blob.corner_flags().count(1), 0, "a round ring has no corners")
	assert_eq(shaped.bead_points(), plain.bead_points())
	assert_eq(shaped.rest_shape, plain.rest_shape)
	assert_eq(shaped.tuning, GooTuning.tuning(radius))
	assert_eq(plain.tuning, GooTuning.tuning(radius))
	assert_eq((shaped.get_node("Skin") as Polygon2D).polygon, (plain.get_node("Skin") as Polygon2D).polygon)

func test_skin_keeps_a_square_corners_sharp() -> void:
	var blob := Goo2D.make(40.0, Vector2(360.0, 400.0), game, GooShape.regular(4, 40.0))
	var skin := (blob.get_node("Skin") as Polygon2D).polygon
	var points := blob.bead_points()
	var flags := blob.corner_flags()
	var found := 0
	for i: int in points.size():
		if flags[i] == 0:
			continue
		# The corner bead pushed out by one bead radius along its corner's bisector.
		var outward := (points[i] - blob.center()).normalized()
		var corner := points[i] + outward * blob.bead_radius()
		var nearest := INF
		for point: Vector2 in skin:
			nearest = minf(nearest, point.distance_to(corner))
		assert_lt(nearest, 0.5, "the skin keeps corner %s" % corner)
		found += 1
	assert_eq(found, 4)
	# 96.7% with 12-22-bead rings (97% and more with 16-30): fewer, bigger beads
	# along each side leave deeper scallops for the skin's smoothing to cut.
	assert_gt(GooLoop.area(skin), 0.96 * blob.target_area, "the skin covers the body, corners included")

# Drops a blob of `shape` scaled to `radius` from the launch point, steps
# physics until it has settled (or `seconds` ran out), and returns
# { settled_at (s, -1 if never), error (shape error at the end, px), worst
# (largest shape error after landing, px), area (area / target at the end),
# angle (best-fit rotation, deg), bottom (lowest bead's y + bead radius) }.
func _drop(shape: GooShape, radius: float, seconds: float) -> Dictionary:
	var blob := game.spawn(radius, arena.launch_point(), shape)
	var stats := { "settled_at": -1.0, "error": INF, "worst": 0.0, "area": 0.0, "angle": 0.0, "bottom": 0.0 }
	var landed := false
	for frame: int in roundi(seconds / STEP):
		await get_tree().physics_frame
		if not is_instance_valid(blob) or not blob.is_inside_tree():
			break
		var lowest := -INF
		for point: Vector2 in blob.bead_points():
			lowest = maxf(lowest, point.y)
		if lowest + blob.bead_radius() > arena.floor_y() - 2.0:
			landed = true
		if landed:
			stats["worst"] = maxf(stats["worst"], _shape_error(blob))
		if blob.settled:
			stats["settled_at"] = frame * STEP
			break
	if is_instance_valid(blob) and blob.is_inside_tree():
		stats["error"] = _shape_error(blob)
		stats["area"] = blob.area() / blob.target_area
		stats["angle"] = rad_to_deg(GooLoop.best_fit_rotation(blob.rest_shape, blob.bead_points()))
		var lowest := -INF
		for point: Vector2 in blob.bead_points():
			lowest = maxf(lowest, point.y)
		stats["bottom"] = lowest + blob.bead_radius()
	return stats

func _assert_holds_shape(sides: int) -> void:
	for radius: float in [DropController.DROP_MIN_RADIUS, DropController.DROP_MAX_RADIUS]:
		game.reset()
		splits = 0
		var label := "%d-gon of radius %.1f" % [sides, radius]
		var stats: Dictionary = await _drop(GooShape.regular(sides, radius), radius, 6.0)
		print("    %s dropped from the launch point: settled after %.2f s, shape error %.2f px (%.1f%% of its radius; worst after landing %.1f%%), area %.1f%% of target, turned %.1f°, bottom at %.1f (floor %.1f)"
			% [label, stats["settled_at"], stats["error"], 100.0 * float(stats["error"]) / radius,
				100.0 * float(stats["worst"]) / radius, 100.0 * float(stats["area"]), stats["angle"],
				stats["bottom"], arena.floor_y()])
		assert_eq(splits, 0, label + " should not split")
		assert_eq(game.bodies().size(), 1, label + " should stay one body")
		assert_gt(float(stats["settled_at"]), 0.0, label + " should settle")
		assert_lt(float(stats["error"]), SHAPE_TOLERANCE * radius, label + " should hold its shape at rest")
		assert_almost_eq(float(stats["bottom"]), arena.floor_y(), 3.0, label + " should rest on the floor")

func test_launch_size_square_settles_holding_its_shape() -> void:
	timeout_sec = 20.0
	await _assert_holds_shape(4)

func test_launch_size_triangle_settles_holding_its_shape() -> void:
	timeout_sec = 20.0
	await _assert_holds_shape(3)

func test_spawn_without_a_shape_is_round() -> void:
	var blob := game.spawn(35.0, Vector2(300.0, 500.0))
	assert_true(blob.shape.is_round())
	assert_eq(blob.shape.radius(), 35.0)
	var square := game.spawn(35.0, Vector2(500.0, 500.0), GooShape.regular(4, 35.0))
	assert_eq(square.shape.kind, GooShape.Kind.POLYGON)
	assert_eq(square.shape.outline.size(), 4)

func test_launch_takes_the_controller_next_shape() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 3
	game.controller = DropController.new(0.0, rng)
	for i: int in 12:
		var expected_radius := game.next_radius()
		var expected := game.next_shape()
		var blob := game.launch(Vector2.ZERO)
		assert_not_null(blob)
		if blob == null:
			return
		assert_eq(blob.radius, expected_radius)
		assert_eq(blob.shape.kind, expected.kind)
		assert_eq(blob.shape.outline.size(), expected.outline.size())
		game.reset()

func test_rest_loop_given_to_build_from_loop_becomes_the_rest_shape() -> void:
	var shape := GooShape.regular(4, 40.0)
	var tuning := GooTuning.tuning_for(shape)
	var count: int = tuning["bead_count"]
	var rest := shape.bead_loop(count, tuning["bead_radius"])
	var pos := Vector2(360.0, 500.0)
	for i: int in rest.size():
		rest[i] += pos
	# The beads go on a squashed circle; the rest shape is the square.
	var current := GooLoop.circle_points(pos, 30.0, 23)
	for i: int in current.size():
		current[i].y = pos.y + (current[i].y - pos.y) * 0.7
	var velocities := PackedVector2Array()
	velocities.resize(current.size())
	var blob := Goo2D.new()
	game.add_child(blob)
	blob.build_from_loop(current, velocities, 40.0, tuning, rest)
	assert_eq(blob.particle_count(), count)
	assert_eq(blob.rest_shape.size(), count)
	var centre := GooLoop.centroid(rest)
	for i: int in count:
		assert_almost_eq(blob.rest_shape[i].distance_to(rest[i] - centre), 0.0, 0.001, "rest point %d" % i)
	assert_eq(blob.corner_flags().count(1), 4)
	var points := blob.bead_points()
	assert_true(GooLoop.is_ccw(points))
	var nearest := INF
	for point: Vector2 in current:
		nearest = minf(nearest, point.distance_to(rest[0]))
	assert_almost_eq(points[0].distance_to(rest[0]), nearest, 0.001, "bead 0 starts at the loop's point nearest rest point 0")

func test_rest_loop_given_to_rebuild_from_becomes_the_rest_shape() -> void:
	var a := Goo2D.make(30.0, Vector2(330.0, 500.0), game)
	var b := Goo2D.make(30.0, Vector2(390.0, 500.0), game)
	var shape := GooShape.regular(4, GooTuning.merged_radius(30.0, 30.0))
	var tuning := GooTuning.tuning_for(shape)
	var count: int = tuning["bead_count"]
	var rest := shape.bead_loop(count, tuning["bead_radius"])
	for i: int in rest.size():
		rest[i] += Vector2(360.0, 500.0)
	var merged := Goo2D.new()
	game.add_child(merged)
	merged.rebuild_from([a, b] as Array[Goo2D], shape.radius(), tuning, rest)
	assert_eq(merged.particle_count(), count)
	var centre := GooLoop.centroid(rest)
	for i: int in count:
		assert_almost_eq(merged.rest_shape[i].distance_to(rest[i] - centre), 0.0, 0.001, "rest point %d" % i)
	assert_eq(merged.corner_flags().count(1), 4)
	assert_true(GooLoop.is_ccw(merged.bead_points()))
	assert_lt(merged.bead_points()[0].distance_to(rest[0]), 20.0, "bead 0 starts near rest point 0")

func test_tab_cycles_the_next_shape_and_the_label_says_so() -> void:
	var main := MAIN_SCENE.instantiate()
	add_child(main)
	await wait_frames(1)
	var main_game := main.get_node("Game") as Game
	var label := main.get_node("UI/Label") as Label
	assert_true(label.text.contains("Tab"), "the UI label documents Tab")
	var seen: Array[int] = []
	for i: int in DropController.SHAPE_SIDES.size():
		seen.append(main_game.next_shape().outline.size() if not main_game.next_shape().is_round() else 0)
		var radius := main_game.next_radius()
		var press := InputEventKey.new()
		press.keycode = KEY_TAB
		press.physical_keycode = KEY_TAB
		press.pressed = true
		Input.parse_input_event(press)
		var release := InputEventKey.new()
		release.keycode = KEY_TAB
		release.physical_keycode = KEY_TAB
		release.pressed = false
		Input.parse_input_event(release)
		await wait_frames(2)
		assert_eq(main_game.next_radius(), radius, "Tab keeps the next radius")
		assert_almost_eq(main_game.next_shape().radius(), radius, 0.001, "the next shape has the next radius")
	seen.sort()
	var expected: Array[int] = []
	expected.assign(DropController.SHAPE_SIDES)
	expected.sort()
	assert_eq(seen, expected, "Tab steps through every shape")
	assert_eq(main_game.bodies().size(), 0, "Tab launches nothing")

func test_pinch_skips_pairs_close_together_in_the_rest_shape() -> void:
	# An hourglass: its waist is a neck between beads far apart along the loop.
	var loop := PackedVector2Array()
	for i: int in 24:
		var angle := -TAU * i / 24.0
		var point := Vector2(cos(angle) * 60.0, sin(angle) * 30.0)
		point.y *= 0.3 + 0.7 * absf(point.x) / 60.0
		loop.append(point)
	var neck := Goo2D.find_pinch(loop, 3.0, 0.3)
	assert_ne(neck["a"], -1, "the hourglass has a neck")
	var rest_distance := loop[neck["a"]].distance_to(loop[neck["b"]])
	assert_eq(Goo2D.find_pinch(loop, 3.0, 0.3, loop, 0.0), neck, "no minimum: the same neck")
	assert_eq(Goo2D.find_pinch(loop, 3.0, 0.3, loop, rest_distance - 0.01), neck)
	var skipped := Goo2D.find_pinch(loop, 3.0, 0.3, loop, 1000.0)
	assert_eq(skipped["a"], -1, "every pair is too close in the rest shape")
	assert_eq(Goo2D.find_pinch(loop, 3.0, 0.3, PackedVector2Array(), 1000.0), neck,
		"no rest shape: nothing skipped")
