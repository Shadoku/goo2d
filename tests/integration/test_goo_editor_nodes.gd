extends TestCase
## Goo2D nodes placed in a scene under a GooWorld2D, above a StaticBody2D floor
## on physics layer 1. scenes/goo_editor_nodes.tscn: a round one and a
## `sides = 4` square of radius 40. Each builds itself in _ready() from its
## exports, centred where it was placed, and falls onto the floor; the world
## registers both without spawn(), and a round body and a square pushed into
## each other do not merge. scenes/goo_editor_merge.tscn: two round bodies of
## radius 40 placed touching, which the world merges into one. A built body's
## beads, springs and skin are never saved with its scene (they have no owner),
## and the rest outline the editor previews is the one the body builds on.

const SCENE := preload("res://tests/integration/scenes/goo_editor_nodes.tscn")
const MERGE_SCENE := preload("res://tests/integration/scenes/goo_editor_merge.tscn")
## Top of the scenes' floor (a 40 px slab centred on y = 600), px.
const FLOOR_TOP: float = 580.0
## Physics frames the bodies fall for: 2 s, enough to land from 240 px up.
const FALL_FRAMES: int = 120
## Physics frames the round body and the square get to run into each other.
const PUSH_FRAMES: int = 120
## Physics frames two touching round bodies get to merge in.
const MERGE_FRAMES: int = 120

func test_placed_bodies_build_themselves_and_fall_onto_the_floor() -> void:
	var scene := SCENE.instantiate()
	add_child(scene)
	var world := scene.get_node("World") as GooWorld2D
	var ball := scene.get_node("World/Round") as Goo2D
	var box := scene.get_node("World/Square") as Goo2D
	assert_not_null(world, "the World node is a GooWorld2D")
	assert_not_null(ball, "the Round node is a Goo2D")
	assert_not_null(box, "the Square node is a Goo2D")
	if world == null or ball == null or box == null:
		return
	assert_gt(ball.particle_count(), 0, "the round body built its beads in _ready()")
	assert_gt(box.particle_count(), 0, "the square built its beads in _ready()")
	var ball_start := ball.center()
	var box_start := box.center()
	assert_almost_eq(ball_start.distance_to(Vector2(400.0, 300.0)), 0.0, 0.5, "built where it was placed")
	assert_almost_eq(box_start.distance_to(Vector2(700.0, 300.0)), 0.0, 0.5, "built where it was placed")

	assert_true(ball.shape.is_round(), "sides = 0 and no outline: round")
	assert_eq(ball.radius, 40.0)
	assert_eq(ball.particle_count(), GooTuning.bead_count(40.0), "a round ring of 40 px has its size's beads")
	assert_false(box.shape.is_round(), "sides = 4: a polygon")
	assert_eq(box.shape.outline.size(), 4)
	assert_almost_eq(box.radius, 40.0, 0.001)
	assert_eq(box.corner_flags().count(1), 4, "a square ring keeps four corner beads")

	assert_true(ball.id >= 0, "the world registered the placed round body (id %d)" % ball.id)
	assert_true(box.id >= 0, "the world registered the placed square (id %d)" % box.id)
	assert_ne(ball.id, box.id, "each body gets its own id")
	assert_eq(world.bodies().size(), 2)

	for _frame: int in FALL_FRAMES:
		await get_tree().physics_frame
	var ball_end := ball.center()
	var box_end := box.center()
	print("  round: y %.1f -> %.1f, square: y %.1f -> %.1f (floor top %.0f)"
		% [ball_start.y, ball_end.y, box_start.y, box_end.y, FLOOR_TOP])
	assert_gt(ball_end.y - ball_start.y, 100.0, "the round body fell")
	assert_gt(box_end.y - box_start.y, 100.0, "the square fell")
	assert_lt(ball_end.y, FLOOR_TOP, "the round body rests above the floor")
	assert_lt(box_end.y, FLOOR_TOP, "the square rests above the floor")

	# Thrown up and into each other: they touch, and a round body and a square
	# never merge by the rules (GooWorld2D.can_merge()).
	var touches: Array[int] = [0]
	ball.touched.connect(func(other: Goo2D) -> void:
		if other == box:
			touches[0] += 1)
	var merges: Array[float] = []
	world.merged.connect(func(radius: float, _position: Vector2) -> void: merges.append(radius))
	ball.set_velocity(Vector2(400.0, -300.0))
	box.set_velocity(Vector2(-400.0, -300.0))
	for _frame: int in PUSH_FRAMES:
		await get_tree().physics_frame
	print("  round and square pushed together: %d contact report(s), %d merge(s), %d bodies"
		% [touches[0], merges.size(), world.bodies().size()])
	assert_gt(touches[0], 0, "the round body and the square touched")
	assert_eq(merges.size(), 0, "a round body and a square do not merge")
	assert_eq(world.bodies().size(), 2)

func test_placed_round_bodies_touching_merge() -> void:
	var scene := MERGE_SCENE.instantiate()
	add_child(scene)
	var world := scene.get_node("World") as GooWorld2D
	var left := scene.get_node("World/Left") as Goo2D
	var right := scene.get_node("World/Right") as Goo2D
	assert_not_null(world, "the World node is a GooWorld2D")
	if world == null or left == null or right == null:
		return
	assert_true(left.id >= 0 and right.id >= 0, "both placed bodies are registered (ids %d, %d)" % [left.id, right.id])
	assert_eq(world.bodies().size(), 2)
	var merges: Array[float] = []
	world.merged.connect(func(radius: float, _position: Vector2) -> void: merges.append(radius))
	var merged_at := -1
	for frame: int in MERGE_FRAMES:
		await get_tree().physics_frame
		if merged_at < 0 and not merges.is_empty():
			merged_at = frame + 1
	print("  two placed 40 px round bodies: merged after %d physics frames into %s"
		% [merged_at, merges])
	assert_eq(merges.size(), 1, "one merge")
	assert_eq(world.bodies().size(), 1, "the pair became one body")
	if merges.size() == 1:
		assert_almost_eq(merges[0], GooTuning.merged_radius(40.0, 40.0), 0.001, "the merged body holds both areas")
	if world.bodies().size() == 1:
		var merged := world.bodies()[0]
		assert_true(merged.id >= 0, "the merged body is registered too")
		assert_lt(merged.center().y, FLOOR_TOP, "the merged body is above the floor")

func test_packed_scene_never_holds_beads_springs_or_skin() -> void:
	var scene := SCENE.instantiate()
	add_child(scene)
	var ball := scene.get_node("World/Round") as Goo2D
	var box := scene.get_node("World/Square") as Goo2D
	assert_gt(ball.particle_count(), 0, "the round body is built")
	assert_gt(box.particle_count(), 0, "the square is built")
	var packed := PackedScene.new()
	assert_eq(packed.pack(scene), OK)
	var state := packed.get_state()
	var names: Array[String] = []
	for i: int in state.get_node_count():
		names.append(String(state.get_node_name(i)))
	print("  packed nodes: %s" % [names])
	assert_eq(names, ["GooEditorNodes", "Floor", "Shape", "World", "Round", "Square"] as Array[String],
		"the scene's own nodes and nothing a body built")

	var alone := PackedScene.new()
	assert_eq(alone.pack(box), OK)
	assert_eq(alone.get_state().get_node_count(), 1, "a built Goo2D packs as the Goo2D alone")

	# Instanced again, the packed bodies build themselves once, from their exports.
	var again := packed.instantiate()
	add_child(again)
	for path: String in ["World/Round", "World/Square"]:
		var body := again.get_node(path) as Goo2D
		assert_not_null(body, path)
		if body == null:
			continue
		assert_gt(body.particle_count(), 0, "%s rebuilt itself" % path)
		assert_eq(body.get_child_count(), 1, "%s has its Skin once" % path)
	var square := again.get_node("World/Square") as Goo2D
	assert_eq(square.sides, 4, "the export was saved")
	assert_false(square.shape.is_round())

func test_preview_outline_is_the_rest_outline_the_body_builds_on() -> void:
	var body := Goo2D.new()
	add_child(body)
	assert_eq(body.particle_count(), 0, "a script-made body is not built by _ready()")
	body.radius = 40.0
	var circle := body.preview_outline()
	assert_eq(circle.size(), GooShape.ROUND_OUTLINE_POINTS, "round: the shape's preview circle")
	for point: Vector2 in circle:
		assert_almost_eq(point.length(), 40.0, 0.001)

	body.sides = 4
	var square := body.preview_outline()
	assert_eq(square.size(), 4, "sides = 4: a square")
	assert_almost_eq(GooLoop.area(square), PI * 40.0 * 40.0, 0.01, "of the equivalent radius")
	assert_almost_eq(square[0].y, square[1].y, 0.001, "resting on a side")

	body.outline = PackedVector2Array([Vector2(0, 0), Vector2(200, 0), Vector2(200, 100), Vector2(0, 100)])
	var custom := body.preview_outline()
	assert_eq(custom.size(), 4, "the custom outline overrides sides")
	assert_almost_eq(GooLoop.area(custom), PI * 40.0 * 40.0, 0.01, "scaled to the equivalent radius")
	assert_almost_eq(GooLoop.centroid(custom).length(), 0.0, 0.001, "centred on the body's origin")
	var bounds := Rect2(custom[0], Vector2.ZERO)
	for point: Vector2 in custom:
		bounds = bounds.expand(point)
	assert_almost_eq(bounds.size.x / bounds.size.y, 2.0, 0.001, "its proportions kept")
