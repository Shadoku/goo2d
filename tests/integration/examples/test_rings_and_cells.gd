extends TestCase
## The rings-and-cells example (examples/rings_and_cells/): a top-down tank of seven ring
## bodies (a GooWorld2D) and three creatures of cells (a GooCellWorld2D coupled to it through
## its ring_world, docs/cells.md "Rings and cells"). The worlds are coupled with the cells
## stepping after the rings although they come first in the tree; the creatures push the
## rings about and never end up inside one, nor a ring's bead inside a creature; the mouse
## drags a ring; R rebuilds.

const SCENE := preload("res://examples/rings_and_cells/rings_and_cells.tscn")
const INSIDE := Rect2(240, 140, 1440, 880)

var scene: RingsAndCellsExample

func before_each() -> void:
	scene = SCENE.instantiate() as RingsAndCellsExample
	add_child(scene)

func test_the_scene_boots_coupled() -> void:
	assert_eq(scene.rings().bodies().size(), 7)
	assert_eq(scene.cells().creatures().size(), 3)
	assert_eq(scene.cells().coupled_world(), scene.rings())
	assert_gt(scene.cells().process_physics_priority, scene.rings().process_physics_priority, "the cells step after the rings")
	await wait_frames(2)
	assert_true(scene.cells().coupling_stats()["on"])
	assert_eq(scene.cells().coupling_stats()["rings"], 7)

# Cell centres inside any ring's bead loop, plus beads inside any creature's outline.
func _tangled() -> int:
	var n := 0
	var outlines: Array[PackedVector2Array] = []
	for c: GooCellCreature in scene.cells().creatures():
		var pos := c.positions()
		var loop := PackedVector2Array()
		for i: int in c.outline():
			loop.append(pos[i])
		outlines.append(loop)
		for b: Goo2D in scene.rings().bodies():
			var beads := b.bead_points()
			for p: Vector2 in pos:
				if Geometry2D.is_point_in_polygon(p, beads):
					n += 1
	for b: Goo2D in scene.rings().bodies():
		for p: Vector2 in b.bead_points():
			for loop: PackedVector2Array in outlines:
				if loop.size() >= 3 and Geometry2D.is_point_in_polygon(p, loop):
					n += 1
	return n

func test_the_creatures_shove_the_rings() -> void:
	var start: Dictionary = {}
	for b: Goo2D in scene.rings().bodies():
		start[b] = b.center()
	var worm_start := scene.worm.center()
	var tangled := 0
	var touching := 0
	var worst := 0.0
	var outside := 0
	for frame: int in 480:
		await get_tree().physics_frame
		var s := scene.cells().coupling_stats()
		if s["touched"] > 0:
			touching += 1
		worst = maxf(worst, s["worst"])
		if frame % 10 == 0:
			tangled += _tangled()
			for b: Goo2D in scene.rings().bodies():
				if not INSIDE.grow(4.0).has_point(b.center()):
					outside += 1
	var pushed := 0.0
	for b: Goo2D in scene.rings().bodies():
		pushed += b.center().distance_to(start[b])
	var worm_moved := scene.worm.center().distance_to(worm_start)
	print("    in 8 s: the worm swam %.0f px; the rings were moved %.0f px in all; %d frames with a ring touched, worst overlap found %.1f px; tangled samples %d, ring centres outside the tank %d" % [worm_moved, pushed, touching, worst, tangled, outside])
	assert_gt(worm_moved, 300.0, "the worm swims")
	assert_gt(touching, 30, "creatures and rings meet")
	assert_gt(pushed, 100.0, "the rings are shoved about")
	assert_eq(tangled, 0, "never inside each other")
	assert_eq(outside, 0)
	assert_eq(scene.rings().bodies().size(), 7)
	assert_eq(scene.cells().creatures().size(), 3)

func test_the_mouse_drags_a_ring_and_r_rebuilds() -> void:
	await wait_frames(2)
	var ring := scene.rings().bodies()[0]
	var from := ring.center()
	var to := from + Vector2(0, -150)
	_mouse_button(from, true)
	for k: int in 30:
		_mouse_motion(from.lerp(to, (k + 1) / 30.0))
		await get_tree().physics_frame
	await wait_frames(20)
	assert_lt(ring.center().distance_to(to), 40.0, "the ring followed the mouse")
	_mouse_button(to, false)
	var key := InputEventKey.new()
	key.keycode = KEY_R
	key.pressed = true
	Input.parse_input_event(key)
	await wait_frames(2)
	assert_eq(scene.rings().bodies().size(), 7)
	assert_eq(scene.cells().creatures().size(), 3)

func _mouse_button(at: Vector2, pressed: bool) -> void:
	var e := InputEventMouseButton.new()
	e.button_index = MOUSE_BUTTON_LEFT
	e.pressed = pressed
	e.position = get_viewport().get_screen_transform() * at
	e.global_position = e.position
	Input.parse_input_event(e)

func _mouse_motion(at: Vector2) -> void:
	var e := InputEventMouseMotion.new()
	e.position = get_viewport().get_screen_transform() * at
	e.global_position = e.position
	Input.parse_input_event(e)
