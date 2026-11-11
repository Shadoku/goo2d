extends TestCase
## The `shaders` example (examples/shaders/): three GooWorld2D columns fed the
## same seeded drops, each drawing its bodies with its own skin shader (the
## addon's goo, cel, gem). Headless never compiles a shader, so these tests check
## which shader each body's Skin material holds; the render stage of check.py
## compiles them.

const SCENE_PATH := "res://examples/shaders/shaders.tscn"
const CEL_PATH := "res://assets/goo/cel.gdshader"
const GEM_PATH := "res://assets/goo/gem.gdshader"

func _start(auto_drop: bool = false) -> ShadersExample:
	var scene := load(SCENE_PATH) as PackedScene
	assert_not_null(scene, "the example's scene loads")
	if scene == null:
		return null
	var example := scene.instantiate() as ShadersExample
	assert_not_null(example, "the scene's root is a ShadersExample")
	if example == null:
		return null
	example.auto_drop = auto_drop
	add_child(example)
	await wait_frames(2)
	return example

# The shader a body's Skin draws with, or null.
func _drawn_with(body: Goo2D) -> Shader:
	var skin := body.get_node_or_null("Skin") as Polygon2D
	if skin == null or skin.material == null:
		return null
	return (skin.material as ShaderMaterial).shader

# The resource path of the shader `column` is meant to draw with.
func _expected_path(column: int) -> String:
	return [GooSkin.SHADER_PATH, CEL_PATH, GEM_PATH][column]

func test_the_scene_boots_with_three_columns() -> void:
	var example: ShadersExample = await _start()
	if example == null:
		return
	await wait_frames(10)
	assert_eq(example.worlds().size(), 3)
	assert_null(example.world(0).skin_shader, "the left column draws with the addon's goo")
	assert_eq(example.world(1).skin_shader.resource_path, CEL_PATH)
	assert_eq(example.world(2).skin_shader.resource_path, GEM_PATH)
	var label := example.get_node_or_null("UI/Label") as Label
	assert_not_null(label)
	if label != null:
		assert_true(label.text.contains("cel"), "the label names the columns")
		assert_true(label.text.contains("R"), "the label names the controls")

func test_every_column_draws_its_bodies_with_its_shader() -> void:
	var example: ShadersExample = await _start()
	if example == null:
		return
	for i: int in 4:
		var dropped := example.drop_next()
		assert_eq(dropped.size(), 3, "one body per column")
		await wait_seconds(0.3)
	for column: int in 3:
		var bodies := example.world(column).bodies()
		assert_gt(bodies.size(), 0, "column %d has bodies" % column)
		for body: Goo2D in bodies:
			var shader := _drawn_with(body)
			assert_not_null(shader)
			if shader != null:
				assert_eq(shader.resource_path, _expected_path(column),
					"column %d body %s" % [column, body.name])

func test_the_columns_get_the_same_drops() -> void:
	var example: ShadersExample = await _start()
	if example == null:
		return
	for i: int in 6:
		var dropped := example.drop_next()
		assert_eq(dropped.size(), 3)
		if dropped.size() != 3:
			return
		for column: int in 3:
			assert_eq(dropped[column].radius, dropped[0].radius)
			assert_eq(dropped[column].shape == null or dropped[column].shape.is_round(),
				dropped[0].shape == null or dropped[0].shape.is_round())
			var offset := dropped[column].center() - example.column_center(column)
			var offset_0 := dropped[0].center() - example.column_center(0)
			assert_almost_eq(offset.distance_to(offset_0), 0.0, 1.0, "same place in its column")
		await wait_seconds(0.2)

func test_a_piece_cut_in_the_gem_column_keeps_the_gem_shader() -> void:
	var example: ShadersExample = await _start()
	if example == null:
		return
	var world := example.world(2)
	# column_center() is the middle of the floor: the body starts above it.
	var body := world.spawn(100.0, example.column_center(2) + Vector2(0.0, -300.0))
	await wait_seconds(0.5)
	assert_true(is_instance_valid(body), "the body is still there")
	if not is_instance_valid(body):
		return
	var points := body.bead_points()
	var top := 0
	for i: int in points.size():
		if points[i].y < points[top].y:
			top = i
	world.cut(body, top, (top + points.size() / 2) % points.size())
	await wait_frames(2)
	var bodies := world.bodies()
	assert_eq(bodies.size(), 2, "the body was cut in two")
	for piece: Goo2D in bodies:
		var shader := _drawn_with(piece)
		assert_not_null(shader)
		if shader != null:
			assert_eq(shader.resource_path, GEM_PATH)

func test_a_click_drops_in_the_column_under_the_mouse() -> void:
	var example: ShadersExample = await _start()
	if example == null:
		return
	var at := example.column_center(1) + Vector2(40.0, 400.0)
	assert_eq(example.column_at(at.x), 1)
	assert_eq(example.column_at(example.column_center(0).x), 0)
	assert_eq(example.column_at(example.column_center(2).x), 2)
	var body := example.drop_at(at)
	assert_not_null(body)
	if body == null:
		return
	assert_eq(body.get_parent(), example.world(1))
	assert_almost_eq(body.center().x, at.x, 4.0)
	assert_eq(example.world(0).bodies().size(), 0)
	assert_eq(example.world(2).bodies().size(), 0)

func test_reset_clears_every_column() -> void:
	var example: ShadersExample = await _start()
	if example == null:
		return
	example.drop_next()
	await wait_frames(3)
	example.reset()
	await wait_frames(2)
	for column: int in 3:
		assert_eq(example.world(column).bodies().size(), 0)

func test_seeded_drops_run_without_errors_and_the_cap_holds() -> void:
	timeout_sec = 20.0
	var example: ShadersExample = await _start()
	if example == null:
		return
	example.rng.seed = 11
	example.drop_interval = 0.3
	example.auto_drop = true
	var most := 0
	var frames := 0
	var start := Time.get_ticks_msec()
	while Time.get_ticks_msec() - start < 5000:
		await get_tree().physics_frame
		frames += 1
		for world: GooWorld2D in example.worlds():
			var count := world.bodies().size()
			most = maxi(most, count)
			assert_true(count <= ShadersExample.MAX_BODIES,
				"%s holds %d bodies" % [world.name, count])
	print("%d drops over %d physics frames, at most %d bodies in a column" % [example.drops, frames, most])
	assert_gt(example.drops, ShadersExample.MAX_BODIES, "more drops than the cap")
	assert_true(most >= ShadersExample.MAX_BODIES - 2, "the columns filled up to the cap")
	for world: GooWorld2D in example.worlds():
		for body: Goo2D in world.bodies():
			assert_true(body.center().is_finite())
			assert_lt(body.center().y, ShadersExample.FLOOR_Y + 1.0, "%s fell through the floor" % body.name)
