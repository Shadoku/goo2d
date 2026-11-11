extends TestCase
## The color_merge example (examples/color_merge/): blobs come in four palette
## colours and merge only with blobs of their own colour, whatever their sizes;
## a hopper drops blobs of random sizes and colours, a click drops one where
## the mouse is (keys 1-4 pick its colour), R empties the world.

const SCENE := preload("res://examples/color_merge/color_merge.tscn")

## Seconds a merge of two touching blobs may take: settling, then the transition.
const MERGE_TIMEOUT: float = 1.5

var scene: ColorMerge
var world: ColorMergeWorld

# Instantiates the example with a seeded RNG and, unless `hopper`, its hopper off.
func _start(hopper: bool = false, seed: int = 7) -> void:
	scene = SCENE.instantiate() as ColorMerge
	scene.rng.seed = seed
	scene.hopper_enabled = hopper
	add_child(scene)
	world = scene.world()
	await wait_frames(1)

# A blob of `radius` in palette colour `index`, resting on the floor at `x`.
func _on_floor(radius: float, x: float, index: int) -> Goo2D:
	return scene.drop(radius, Vector2(x, ColorMerge.FLOOR_Y - radius), ColorMergeWorld.PALETTE[index])

func _middle() -> float:
	return (ColorMerge.INNER_LEFT + ColorMerge.INNER_RIGHT) * 0.5

func test_the_scene_boots_with_its_parts() -> void:
	await _start(true)
	await wait_frames(10)
	assert_true(scene.is_inside_tree())
	assert_not_null(world, "the scene has a ColorMergeWorld")
	assert_not_null(scene.get_node_or_null("Walls") as StaticBody2D, "a floor and two walls")
	assert_not_null(scene.get_node_or_null("UI/Label") as Label)
	assert_has((scene.get_node("UI/Label") as Label).text, "Merges: 0")
	assert_eq(ColorMergeWorld.PALETTE.size(), 4)

func test_the_world_merges_by_colour_up_to_the_largest_size() -> void:
	await _start()
	var red := _on_floor(40.0, _middle() - 300.0, 0)
	var other_red := _on_floor(90.0, _middle(), 0)
	var blue := _on_floor(40.0, _middle() + 300.0, 3)
	assert_true(world.may_merge(red, other_red), "one colour, sizes the default rule keeps apart")
	assert_false(world.may_merge(red, blue), "two colours, one size")
	var huge := _on_floor(160.0, _middle() - 500.0, 0)
	assert_false(world.may_merge(huge, other_red), "a merge past GooTuning.MAX_RADIUS")
	assert_eq(world.merged_color(red, other_red), ColorMergeWorld.PALETTE[0])

func test_blobs_of_one_colour_and_different_sizes_merge_into_that_colour() -> void:
	await _start()
	var green: Color = ColorMergeWorld.PALETTE[2]
	_on_floor(40.0, _middle() - 63.0, 2)
	_on_floor(90.0, _middle() + 63.0, 2)
	var merged := await await_signal(world.merged, MERGE_TIMEOUT)
	assert_true(merged, "touching blobs of one colour merge within %.1f s" % MERGE_TIMEOUT)
	await wait_frames(2)
	assert_eq(world.bodies().size(), 1)
	if world.bodies().size() != 1:
		return
	var body := world.bodies()[0]
	assert_almost_eq(body.radius, GooTuning.merged_radius(40.0, 90.0), 0.01)
	assert_eq(body.color, green, "the merged blob has the pair's colour")
	assert_eq(scene.merges, 1, "the scene counts the merge")
	assert_has((scene.get_node("UI/Label") as Label).text, "Merges: 1")
	await wait_seconds(GooTuning.MERGE_FLASH + 0.1)
	assert_eq(body.get_tint(), green, "after its flash it is drawn in that colour")

func test_blobs_of_different_colours_resting_on_each_other_do_not_merge() -> void:
	await _start()
	var lower := _on_floor(40.0, _middle(), 0)
	var upper := scene.drop(40.0, Vector2(_middle(), ColorMerge.FLOOR_Y - 40.0 * 3.0 + 4.0), ColorMergeWorld.PALETTE[1])
	var merged := await await_signal(world.merged, 2.0)
	assert_false(merged, "a yellow blob resting on a red one stays apart for 2 s")
	assert_eq(world.bodies().size(), 2)
	assert_lt(upper.center().y, lower.center().y, "the yellow blob rests on top")
	assert_eq(lower.color, ColorMergeWorld.PALETTE[0])
	assert_eq(upper.color, ColorMergeWorld.PALETTE[1])

func test_a_piece_cut_from_a_coloured_blob_keeps_its_colour() -> void:
	await _start()
	var blue: Color = ColorMergeWorld.PALETTE[3]
	var body := _on_floor(70.0, _middle(), 3)
	await wait_frames(5)
	var points := body.bead_points()
	var top := 0
	for i: int in points.size():
		if points[i].y < points[top].y:
			top = i
	world.cut(body, top, (top + points.size() / 2) % points.size())
	var pieces := world.bodies()
	assert_eq(pieces.size(), 2, "the blob is cut in two")
	for piece: Goo2D in pieces:
		assert_eq(piece.color, blue, "a piece keeps the colour")
		assert_eq(piece.get_tint(), blue, "and is drawn in it")
	await wait_frames(5)

func test_the_hopper_drops_blobs_of_palette_colours_and_sizes() -> void:
	await _start(true, 3)
	var drops: Array[Goo2D] = []
	scene.dropped.connect(func(body: Goo2D) -> void: drops.append(body))
	await wait_seconds(4.0)
	print("    hopper: %d drops in 4 s, %d bodies, %d merges" % [drops.size(), world.bodies().size(), scene.merges])
	assert_gt(drops.size(), 2, "the hopper drops every %.1f s" % ColorMerge.HOPPER_INTERVAL)
	for body: Goo2D in drops:
		assert_has(ColorMergeWorld.PALETTE, body.color, "a drop is in a palette colour")
		assert_true(body.radius >= ColorMerge.DROP_MIN_RADIUS and body.radius <= ColorMerge.DROP_MAX_RADIUS,
			"a drop's radius %.1f is within the drop sizes" % body.radius)
	for body: Goo2D in world.bodies():
		assert_has(ColorMergeWorld.PALETTE, body.color, "every body in the world is in a palette colour")
		assert_true(body.center().x > ColorMerge.INNER_LEFT and body.center().x < ColorMerge.INNER_RIGHT,
			"every body is between the walls")

func test_the_same_seed_drops_the_same_sequence() -> void:
	var seen: Array[String] = []
	for run: int in 2:
		await _start(true, 11)
		var drops: Array[String] = []
		scene.dropped.connect(func(body: Goo2D) -> void:
			drops.append("%.2f %s %.0f" % [body.radius, body.color, body.global_position.x]))
		await wait_seconds(2.6)
		seen.append(" | ".join(drops))
		scene.queue_free()
		await wait_frames(2)
	assert_ne(seen[0], "", "the hopper dropped something")
	assert_eq(seen[0], seen[1], "a seeded hopper drops the same blobs")

func test_keys_pick_the_colour_and_a_click_drops_a_blob_there() -> void:
	await _start()
	var drops: Array[Goo2D] = []
	scene.dropped.connect(func(body: Goo2D) -> void: drops.append(body))
	var key := InputEventKey.new()
	key.keycode = KEY_3
	key.pressed = true
	Input.parse_input_event(key)
	await wait_frames(2)
	assert_eq(scene.next_color, ColorMergeWorld.PALETTE[2], "key 3 picks the third colour")
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	# An event's position is in window pixels: the root viewport stretches the
	# 1920x1080 canvas onto whatever window the run has.
	click.position = get_tree().root.get_final_transform() * Vector2(_middle() - 200.0, 400.0)
	click.global_position = click.position
	Input.parse_input_event(click)
	await wait_frames(2)
	assert_eq(drops.size(), 1, "a click drops one blob")
	if drops.size() != 1:
		return
	assert_eq(drops[0].color, ColorMergeWorld.PALETTE[2], "in the picked colour")
	assert_almost_eq(drops[0].center().x, _middle() - 200.0, 4.0, "where the mouse is")
	assert_almost_eq(drops[0].center().y, 400.0, 20.0)

func test_a_click_outside_the_walls_drops_inside_them() -> void:
	await _start()
	var body := scene.drop_at(Vector2(20.0, 1070.0))
	assert_not_null(body)
	assert_true(body.center().x - body.radius >= ColorMerge.INNER_LEFT - 1.0, "clear of the left wall")
	assert_true(body.center().y + body.radius <= ColorMerge.FLOOR_Y + 1.0, "above the floor")

func test_reset_empties_the_world() -> void:
	await _start(true)
	for i: int in 4:
		_on_floor(40.0, ColorMerge.INNER_LEFT + 120.0 + 300.0 * i, i)
	await wait_seconds(1.5)
	assert_gt(world.bodies().size(), 0)
	var key := InputEventKey.new()
	key.keycode = KEY_R
	key.pressed = true
	Input.parse_input_event(key)
	await wait_frames(2)
	assert_eq(world.bodies().size(), 0, "R empties the world")
	assert_eq(scene.merges, 0, "and the merge count starts over")
	assert_has((scene.get_node("UI/Label") as Label).text, "Merges: 0")

func test_a_blob_that_leaves_the_screen_is_removed() -> void:
	await _start()
	var body := scene.drop(40.0, Vector2(_middle(), ColorMerge.OUT_Y + 100.0), ColorMergeWorld.PALETTE[0])
	await wait_frames(4)
	assert_false(is_instance_valid(body) and body.is_inside_tree(), "a blob below the screen is despawned")
	assert_eq(world.bodies().size(), 0)
