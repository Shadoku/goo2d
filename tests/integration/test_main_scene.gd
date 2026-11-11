extends TestCase
## Scene-level test: the main scene instantiates, enters the tree, and survives a
## few frames without errors. Any ERROR / SCRIPT ERROR printed during the test fails it.

const MAIN_SCENE := preload("res://scenes/main.tscn")

func test_main_scene_boots() -> void:
	var main := MAIN_SCENE.instantiate()
	add_child(main)
	await wait_frames(3)
	assert_true(main.is_inside_tree())
	assert_eq(main.name, "Main")
	assert_not_null(main.get_node_or_null("Arena") as Arena)
	assert_not_null(main.get_node_or_null("Game") as Game)
	assert_not_null(main.get_node_or_null("Dropper") as Dropper)
	assert_not_null(main.get_node_or_null("UI/Label") as Label)

func _start(seed: int = 7) -> Node:
	var main := MAIN_SCENE.instantiate()
	add_child(main)
	await wait_frames(1)
	var game := main.get_node("Game") as Game
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	game.controller = DropController.new(0.5, rng)
	return main

func test_launch_spawns_a_moving_blob_at_the_launch_point() -> void:
	var main: Node = await _start()
	var game := main.get_node("Game") as Game
	var arena := main.get_node("Arena") as Arena
	var expected_radius := game.next_radius()
	var launched := Vector2(300.0, 400.0)
	var blob := game.launch(launched)
	assert_not_null(blob)
	if blob == null:
		return
	assert_eq(blob.radius, expected_radius)
	assert_almost_eq(blob.center().x, arena.launch_point().x, 4.0)
	assert_almost_eq(blob.center().y, arena.launch_point().y, 4.0)
	# physics_frame fires before the step, so the second one follows one full step.
	await get_tree().physics_frame
	await get_tree().physics_frame
	var v := blob.average_velocity()
	print("launched at %s, average velocity after 1 physics step %s" % [launched, v])
	assert_almost_eq(v.x, launched.x, launched.x * 0.15, "launch x velocity lost")
	assert_almost_eq(v.y, launched.y, launched.y * 0.15, "launch y velocity lost")

func test_launch_respects_cooldown() -> void:
	var main: Node = await _start()
	var game := main.get_node("Game") as Game
	assert_not_null(game.launch(Vector2(0.0, 100.0)))
	assert_null(game.launch(Vector2(0.0, 100.0)), "second launch during cooldown should be refused")
	await wait_seconds(0.6)
	assert_not_null(game.launch(Vector2(0.0, 100.0)), "launch should work again after the cooldown")
	await wait_frames(2)
	assert_eq(game.bodies().size(), 2)

func test_fast_launch_at_wall_stays_inside() -> void:
	var main: Node = await _start()
	var game := main.get_node("Game") as Game
	var blob := game.launch(Vector2(-DropController.MAX_LAUNCH_SPEED, 0.0))
	assert_not_null(blob)
	if blob == null:
		return
	await wait_seconds(2.0)
	assert_eq(game.bodies().size(), 1)
	assert_true(is_instance_valid(blob))
	if not is_instance_valid(blob):
		return
	var c := blob.center()
	print("blob launched at the left wall rests at %s" % c)
	assert_gt(c.x, Arena.INNER_LEFT, "blob went through the left wall")
	assert_lt(c.y, Arena.FLOOR_Y + 1.0, "blob went through the floor")

func test_max_speed_launch_reaches_the_far_side() -> void:
	var main: Node = await _start()
	var game := main.get_node("Game") as Game
	var arena := main.get_node("Arena") as Arena
	var blob := game.launch(Vector2(-DropController.MAX_LAUNCH_SPEED, 0.0))
	assert_not_null(blob)
	if blob == null:
		return
	await wait_seconds(2.5)
	assert_eq(game.bodies().size(), 1)
	assert_true(is_instance_valid(blob))
	if not is_instance_valid(blob):
		return
	var c := blob.center()
	print("blob of %.1f px launched left at %.0f px/s from %s rests at %s"
		% [blob.radius, DropController.MAX_LAUNCH_SPEED, arena.launch_point(), c])
	assert_lt(c.x, arena.inner_left() + Arena.INNER_WIDTH * 0.25, "a full-speed launch reaches the far quarter")
	assert_gt(c.x, arena.inner_left(), "blob went through the left wall")
	assert_lt(c.x, arena.inner_right(), "blob went through the right wall")
	assert_lt(c.y, arena.floor_y(), "blob went through the floor")

func test_dropper_aims_with_controller_velocity() -> void:
	var main: Node = await _start()
	var game := main.get_node("Game") as Game
	var arena := main.get_node("Arena") as Arena
	var dropper := main.get_node("Dropper") as Dropper
	await wait_frames(2)
	var target := arena.launch_point() + Vector2(120.0, 90.0)
	dropper.aim_at(target)
	assert_eq(dropper.aim, Vector2(120.0, 90.0))
	assert_eq(dropper.launch_velocity, game.controller.launch_velocity(Vector2(120.0, 90.0)))
	assert_eq(dropper.launch_velocity, Vector2(360.0, 270.0))
	var t := 0.3
	var expected := arena.launch_point() + Vector2(360.0, 270.0) * t + Vector2(0.0, 0.5 * 980.0 * t * t)
	assert_almost_eq(dropper.trajectory_point(t).distance_to(expected), 0.0, 0.01)

func test_space_key_launches_one_blob() -> void:
	var main: Node = await _start()
	var game := main.get_node("Game") as Game
	await wait_frames(2)
	var press := InputEventKey.new()
	press.keycode = KEY_SPACE
	press.physical_keycode = KEY_SPACE
	press.pressed = true
	Input.parse_input_event(press)
	var release := InputEventKey.new()
	release.keycode = KEY_SPACE
	release.physical_keycode = KEY_SPACE
	release.pressed = false
	Input.parse_input_event(release)
	await wait_frames(3)
	assert_eq(game.bodies().size(), 1)
