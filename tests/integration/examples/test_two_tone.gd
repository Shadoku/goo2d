extends TestCase
## The two_tone example (examples/two_tone/): a box of blobs in the colour
## merge example's palette, in a world with GooWorld2D.two_tone_merges on whose
## blobs merge whatever their colours (up to TwoToneWorld.MAX_MERGED_RADIUS):
## a merge of two colours makes a body drawn in both, and its pieces keep both.
## The opening drops six blobs and starts one already two-tone, rolling, at
## frame 0 (what the render stage draws); Space or a click drops another.

const SCENE := preload("res://examples/two_tone/two_tone.tscn")
const MERGE_TIMEOUT: float = 2.0

var scene: TwoTone
var world: TwoToneWorld

# Instantiates the example with a seeded RNG and, unless `opening`, no blobs.
func _start(opening: bool = false, seed: int = 7) -> void:
	scene = SCENE.instantiate() as TwoTone
	scene.rng.seed = seed
	scene.opening = opening
	add_child(scene)
	world = scene.world()
	await wait_frames(1)

func _middle() -> float:
	return (TwoTone.INNER_LEFT + TwoTone.INNER_RIGHT) * 0.5

# A blob of `radius` in palette colour `index`, resting on the floor at `x`.
func _on_floor(radius: float, x: float, index: int) -> Goo2D:
	return scene.drop(radius, Vector2(x, TwoTone.FLOOR_Y - radius), ColorMergeWorld.PALETTE[index])

func test_the_scene_boots_with_a_two_tone_body_at_once() -> void:
	scene = SCENE.instantiate() as TwoTone
	scene.rng.seed = 3
	add_child(scene)
	world = scene.world()
	assert_not_null(world, "the scene has a TwoToneWorld")
	assert_true(world.two_tone_merges, "the switch is on")
	var two_tone := world.bodies().filter(func(b: Goo2D) -> bool: return b.is_two_tone())
	assert_eq(two_tone.size(), 1, "one body is two-tone from the first frame")
	assert_eq(world.bodies().size(), 1 + TwoTone.OPENING.size(), "and the opening's blobs are dropped")
	assert_not_null(scene.get_node_or_null("Walls") as StaticBody2D, "a floor and two walls")
	assert_not_null(scene.get_node_or_null("UI/Label") as Label)
	await wait_frames(10)
	assert_true(scene.is_inside_tree())

func test_a_merge_of_two_colours_makes_a_two_tone_body() -> void:
	await _start()
	_on_floor(50.0, _middle() - 48.0, 0)
	_on_floor(45.0, _middle() + 45.0, 3)
	var merged := await await_signal(world.merged, MERGE_TIMEOUT)
	assert_true(merged, "a red and a blue blob merge within %.1f s" % MERGE_TIMEOUT)
	await wait_frames(2)
	assert_eq(world.bodies().size(), 1)
	if world.bodies().size() != 1:
		return
	var body := world.bodies()[0]
	assert_true(body.is_two_tone())
	assert_eq(body.color_set().size(), 2, "drawn in two colours")
	assert_true(body.color_set().has(ColorMergeWorld.PALETTE[0]), "red")
	assert_true(body.color_set().has(ColorMergeWorld.PALETTE[3]), "and blue")
	assert_eq(body.dominant_color(), ColorMergeWorld.PALETTE[0], "the bigger, red, owns more")
	assert_eq(scene.merges, 1, "the label's count")

func test_a_split_keeps_both_colours() -> void:
	await _start()
	var body := _on_floor(60.0, _middle(), 1)
	body.set_two_tone(ColorMergeWorld.PALETTE[1], ColorMergeWorld.PALETTE[2], Vector2.UP, 0.0)
	await wait_frames(5)
	var points := body.bead_points()
	world.cut(body, 0, points.size() / 2)
	assert_eq(world.bodies().size(), 2, "the cut is made")
	for piece: Goo2D in world.bodies():
		assert_true(piece.is_two_tone(), "a piece is two-tone")
		assert_eq(piece.color, ColorMergeWorld.PALETTE[1])
		assert_eq(piece.second_color, ColorMergeWorld.PALETTE[2])

func test_space_drops_a_blob_of_a_palette_colour() -> void:
	await _start()
	var key := InputEventKey.new()
	key.keycode = KEY_SPACE
	key.pressed = true
	Input.parse_input_event(key)
	await wait_frames(2)
	assert_eq(world.bodies().size(), 1, "one blob dropped")
	if world.bodies().size() == 1:
		assert_has(ColorMergeWorld.PALETTE, world.bodies()[0].color)

func test_reset_empties_the_box() -> void:
	await _start(true)
	await wait_frames(2)
	assert_gt(world.bodies().size(), 0)
	scene.reset()
	assert_eq(world.bodies().size(), 0)
	assert_eq(scene.merges, 0)
