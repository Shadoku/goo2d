extends TestCase
## The cells example (examples/cells/): a top-down tank (a GooCellWorld2D inside walls with
## a concave rock) of four creatures made of cells: a worm swimming by its swim drive under
## a gentle pose wave and steered toward waypoints by the wave's bias, a blob turned by the spin servo and pushed by its thruster cells, a
## mixed-size creature from mixed.tres, a crawler of three shape-matched segments whose
## joints swing; the water swirls (per cell). They swim where they are sent, stay in one
## piece and out of the walls, their skins are drawn, the mouse drags one and R rebuilds.

const SCENE := preload("res://examples/cells/cells.tscn")

var scene: CellsExample
var world: GooCellWorld2D

func before_each() -> void:
	scene = SCENE.instantiate() as CellsExample
	add_child(scene)
	world = scene.world()

## The tank's open water (the walls' inner edges).
const INSIDE := Rect2(240, 140, 1440, 880)

func test_the_scene_boots() -> void:
	assert_not_null(world)
	assert_almost_eq(world.gravity_scale, 0.0, 0.0001, "top-down")
	assert_eq(world.creatures().size(), 4)
	var cells := 0
	for c: GooCellCreature in world.creatures():
		cells += c.cell_count()
	assert_eq(cells, 120 + 61 + scene.MIXED.cell_count() + 36, "the worm, the blob, the mixed one and the crawler")
	assert_gt(scene.MIXED.radii.size(), 0)
	var smallest := INF
	var largest := 0.0
	for r: float in scene.MIXED.radii:
		smallest = minf(smallest, r)
		largest = maxf(largest, r)
	assert_gt(largest, 1.5 * smallest, "mixed sizes")
	await wait_frames(2)
	assert_eq(world.wall_count(), 4 + 5, "four slabs and the rock's convex pieces")
	assert_gt(int(world.draw_stats["triangles"]), 100, "the skins are drawn")

func test_they_swim_and_hold_together() -> void:
	var worm_start := scene.worm.center()
	var blob_start := scene.blob.center()
	var blob_turned := 0.0
	var last_turn := scene.blob.turn()
	var crawler_bent := 0.0
	var worst_wall := 0.0
	var outside := 0
	for frame: int in 420:
		await get_tree().physics_frame
		blob_turned += absf(wrapf(scene.blob.turn() - last_turn, -PI, PI))
		last_turn = scene.blob.turn()
		if frame % 10 == 0:
			worst_wall = maxf(worst_wall, world.cells().health()[6])
			for c: GooCellCreature in world.creatures():
				for p: Vector2 in c.positions():
					if not INSIDE.has_point(p):
						outside += 1
			# The crawler's two ends against its middle: the joints swing it out of line.
			var p := scene.crawler.positions()
			var head := p[11] - p[5]
			var tail := p[0] - p[5]
			crawler_bent = maxf(crawler_bent, absf(wrapf(head.angle() - (-tail).angle(), -PI, PI)))
	var worm_moved := scene.worm.center().distance_to(worm_start)
	var blob_moved := scene.blob.center().distance_to(blob_start)
	print("    in 7 s: the worm swam %.0f px, the blob %.0f px turning %.2f rad, the crawler bent %.2f rad; deepest in a wall %.1f px, %d cell samples outside the tank" % [worm_moved, blob_moved, blob_turned, crawler_bent, worst_wall, outside])
	assert_gt(worm_moved, 400.0, "the worm swims")
	assert_gt(blob_moved, 300.0, "the blob's thrusters push it")
	assert_gt(blob_turned, 2.0, "and its twist turns it toward its goal")
	assert_gt(crawler_bent, 0.3, "the crawler's joints swing")
	assert_eq(world.creatures().size(), 4, "nothing split or merged")
	assert_lt(worst_wall, 3.0, "out of the walls")
	assert_eq(outside, 0, "inside the tank")

func test_the_mouse_drags_a_creature() -> void:
	await wait_frames(2)
	var target := scene.mixed
	var from := target.positions()[0]
	var to := from + Vector2(-200, 120)
	_mouse_button(from, true)
	await wait_frames(1)
	assert_true(scene._grab >= 0, "the press grabbed it")
	var motion := InputEventMouseMotion.new()
	motion.position = _on_screen(to)
	motion.global_position = motion.position
	Input.parse_input_event(motion)
	await wait_frames(60)
	var moved := target.center().distance_to(from)
	var at_pointer := INF
	for p: Vector2 in target.positions():
		at_pointer = minf(at_pointer, p.distance_to(to))
	_mouse_button(to, false)
	await wait_frames(2)
	print("    dragged: a cell %.1f px from the pointer after 1 s" % at_pointer)
	assert_lt(at_pointer, 40.0, "a cell follows the pointer")
	assert_gt(moved, 60.0)
	assert_eq(world.creatures().size(), 4)

func test_r_rebuilds_the_tank() -> void:
	var first := scene.worm
	world.despawn(scene.blob)
	assert_eq(world.creatures().size(), 3)
	var key := InputEventKey.new()
	key.keycode = KEY_R
	key.pressed = true
	Input.parse_input_event(key)
	await wait_frames(2)
	assert_eq(world.creatures().size(), 4)
	assert_false(first.is_alive(), "the old worm went")
	assert_true(scene.worm.is_alive())

func _mouse_button(at: Vector2, pressed: bool) -> void:
	var e := InputEventMouseButton.new()
	e.button_index = MOUSE_BUTTON_LEFT
	e.pressed = pressed
	e.position = _on_screen(at)
	e.global_position = e.position
	Input.parse_input_event(e)

## A canvas point in the window's pixels, where parsed input events are (the scene
## stretches its 1920 × 1080 canvas into whatever window the tests have).
func _on_screen(at: Vector2) -> Vector2:
	return get_viewport().get_screen_transform() * at
