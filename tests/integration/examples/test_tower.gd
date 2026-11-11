extends TestCase
## The tower example (examples/tower/): stiff square blocks that do not merge
## drop from a hopper onto a narrow platform; blocks that fall off are
## despawned; the game is won once the stack stands above the goal line; R
## (reset()) starts over.

const SCENE := preload("res://examples/tower/tower.tscn")

## Seconds a dropped block may take to fall from the hopper and settle.
const SETTLE_TIMEOUT: float = 8.0

var scene: TowerExample
var world: TowerWorld

# Instantiates the example with a seeded RNG and, unless `demo`, no demo drops.
func _start(demo: bool = false, seed: int = 3) -> void:
	scene = SCENE.instantiate() as TowerExample
	scene.rng.seed = seed
	scene.demo = demo
	add_child(scene)
	world = scene.world()
	await wait_frames(1)

# Side of a block, in px.
func _side() -> float:
	return sqrt(PI) * scene.block_radius()

# The platform's centre x.
func _centre_x() -> float:
	return world.platform().global_rect().get_center().x

# Steps physics until every body in the world is settled (after at least
# `least` seconds) or `timeout` seconds passed. Returns the seconds it took, or
# -1 if they did not all settle.
func _settle(timeout: float = SETTLE_TIMEOUT, least: float = 0.3) -> float:
	var frames := 0
	var least_frames := roundi(least * Engine.physics_ticks_per_second)
	while frames < roundi(timeout * Engine.physics_ticks_per_second):
		await get_tree().physics_frame
		frames += 1
		if frames < least_frames:
			continue
		var all_settled := true
		for body: Goo2D in world.bodies():
			all_settled = all_settled and body.settled
		if all_settled:
			return float(frames) / Engine.physics_ticks_per_second
	return -1.0

# A block of the scene's size resting on the platform with its bottom at `bottom_y`.
func _place(bottom_y: float, colour: Color) -> Goo2D:
	var radius := scene.block_radius()
	var body := world.spawn(radius, Vector2(_centre_x(), bottom_y - _side() * 0.5), GooShape.regular(4, radius))
	body.color = colour
	return body

func test_the_scene_boots_with_its_parts() -> void:
	await _start(true)
	# The demo drops its first block after DEMO_REST seconds of physics time;
	# wait_frames() counts process frames, which run ahead of physics headless,
	# so wait for the drop itself.
	assert_true(await await_signal(scene.dropped, 5.0), "the demo dropped a block")
	await wait_frames(2)
	assert_true(scene.is_inside_tree())
	assert_not_null(world, "the scene has a TowerWorld")
	assert_not_null(world.platform(), "the world found the platform through its NodePath")
	assert_not_null(world.goal_line(), "the world found the goal line through its NodePath")
	assert_not_null(scene.get_node_or_null("Floor") as TowerSlab, "a floor")
	assert_not_null(scene.hopper(), "a hopper")
	assert_gt(world.goal_height(), 0.0, "the goal line is above the platform")
	assert_lt(world.platform().global_rect().size.x, 3.0 * _side(), "the platform is narrow: under three blocks wide")
	assert_gt(world.bodies().size(), 0, "the demo dropped a block")
	var label := (scene.get_node("UI/Label") as Label).text
	assert_has(label, "px of %d px" % roundi(world.goal_height()))
	assert_has(label, "Click")

func test_blocks_are_stiff_squares() -> void:
	await _start()
	assert_gt(world.stiffness, 1.0)
	var block := scene.drop(_centre_x())
	assert_false(block.shape.is_round(), "a block is a polygon")
	assert_eq(block.shape.outline.size(), 4, "a square")
	assert_almost_eq(block.radius, scene.block_radius(), 0.001)
	var plain := GooTuning.tuning_for(block.shape)
	assert_almost_eq(float(block.tuning["skin_stiffness"]), world.stiffness * float(plain["skin_stiffness"]),
		0.001 * float(plain["skin_stiffness"]), "skin stiffness is stiffness × GooTuning's")
	assert_almost_eq(float(block.tuning["bending_stiffness"]), world.stiffness * float(plain["bending_stiffness"]),
		0.001 * float(plain["bending_stiffness"]))
	assert_almost_eq(float(block.tuning["shape_match_k"]),
		world.stiffness * world.shape_hold * float(plain["shape_match_k"]), 0.001 * float(plain["shape_match_k"]))
	for key: String in ["bead_count", "bead_radius", "spacing", "target_area"]:
		assert_eq(block.tuning[key], plain[key], "%s stays GooTuning's" % key)
	assert_eq(block.color, TowerExample.PALETTE[0], "the first block takes the first palette colour")
	assert_eq(scene.drop(_centre_x()).color, TowerExample.PALETTE[1], "the next block the next one")

func test_two_stacked_blocks_do_not_merge() -> void:
	await _start()
	var top := world.platform_top()
	var lower := _place(top - 1.0, TowerExample.PALETTE[0])
	var upper := _place(top - _side() - 3.0, TowerExample.PALETTE[1])
	await wait_frames(2)
	assert_false(world.may_merge(lower, upper), "may_merge() says no")
	var merged := await await_signal(world.merged, 3.0)
	assert_false(merged, "two blocks resting on each other stay apart for 3 s")
	assert_eq(world.bodies().size(), 2)
	assert_lt(upper.center().y, lower.center().y, "one rests on the other")
	assert_eq(world.stack().size(), 2, "both make up the stack")

func test_allow_merging_fuses_stacked_blocks() -> void:
	await _start()
	world.allow_merging = true
	var top := world.platform_top()
	var lower := _place(top - 1.0, TowerExample.PALETTE[0])
	var upper := _place(top - _side() - 3.0, TowerExample.PALETTE[0])
	await wait_frames(2)
	assert_true(world.may_merge(lower, upper), "with allow_merging the default rule decides: flat face to flat face")
	var merged := await await_signal(world.merged, 3.0)
	assert_true(merged, "the designer's fused variant: the two blocks merge")

func test_a_block_dropped_beside_the_platform_is_despawned() -> void:
	await _start()
	var rect := world.platform().global_rect()
	var x := rect.position.x - _side()
	assert_lt(scene.hopper().clamp_x(x), rect.position.x, "the hopper reaches past the platform's edge")
	var block := scene.drop(x)
	var counts: Array[int] = []
	world.count_changed.connect(func(count: int) -> void: counts.append(count))
	var changed := await await_signal(world.count_changed, 4.0)
	assert_true(changed, "count_changed fired")
	assert_eq(counts, [0] as Array[int], "it reported the world empty")
	assert_eq(world.bodies().size(), 0)
	assert_false(is_instance_valid(block) and block.is_inside_tree(), "the block left the world")

func test_a_tower_above_the_goal_line_wins_once() -> void:
	timeout_sec = 30.0
	await _start()
	# A goal line low enough for three blocks: 2.4 sides above the platform.
	var goal := scene.goal_line()
	goal.global_position.y = world.platform_top() - 2.4 * _side()
	var wins: Array[int] = [0]
	world.won.connect(func() -> void: wins[0] += 1)
	for i: int in 3:
		assert_false(world.has_won, "not won with %d blocks" % i)
		scene.drop(_centre_x())
		var settled := await _settle()
		print("    block %d: settled after %.2f s, stack %d, tower %.0f px (goal %.0f px)" % [i + 1, settled,
			world.stack().size(), world.tower_height(), world.goal_height()])
		assert_true(settled >= 0.0, "block %d settled" % (i + 1))
	assert_eq(world.stack().size(), 3, "three blocks stand")
	assert_gt(world.tower_height(), world.goal_height(), "the tower is above the goal line")
	if wins[0] == 0:
		await await_signal(world.won, TowerWorld.WIN_HOLD + 1.0)
	await wait_seconds(1.0)
	assert_eq(wins[0], 1, "won fired exactly once")
	assert_true(world.has_won)
	assert_true(goal.reached, "the goal line is drawn reached")
	await wait_frames(2)
	assert_has((scene.get_node("UI/Label") as Label).text, "you win")
	var before := scene.drops
	var space := InputEventKey.new()
	space.keycode = KEY_SPACE
	space.pressed = true
	Input.parse_input_event(space)
	await wait_frames(3)
	assert_eq(scene.drops, before, "no drops once won, until reset")

func test_reset_empties_the_world_and_clears_the_win() -> void:
	timeout_sec = 15.0
	await _start()
	var goal := scene.goal_line()
	goal.global_position.y = world.platform_top() - 0.5 * _side()
	_place(world.platform_top() - 1.0, TowerExample.PALETTE[0])
	var won := await await_signal(world.won, TowerWorld.WIN_HOLD + 3.0)
	assert_true(won, "one block above a line half a block up wins")
	var key := InputEventKey.new()
	key.keycode = KEY_R
	key.pressed = true
	Input.parse_input_event(key)
	await wait_frames(3)
	assert_eq(world.bodies().size(), 0, "R emptied the world")
	assert_false(world.has_won, "and cleared the win")
	assert_eq(world.tower_height(), 0.0)
	assert_eq(scene.drops, 0)
	assert_false(goal.reached)
	assert_false((scene.get_node("UI/Label") as Label).text.contains("you win"))
	# The game goes on: a new win fires won again.
	_place(world.platform_top() - 1.0, TowerExample.PALETTE[0])
	won = await await_signal(world.won, TowerWorld.WIN_HOLD + 3.0)
	assert_true(won, "after reset() the game can be won again")
