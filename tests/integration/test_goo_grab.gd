extends TestCase
## GooWorld2D's grab: a spring from a point to the beads of a body nearest it
## (grab(), move_grab(), release_grab(), grabbed(), grab_body(), grab_point())
## and body_at(), the body whose outline holds a point (Goo2D.has_point()).
## A grabbed body's grab point follows a moved point within a few frames and
## within a bead radius, the body dangling below it; it never settles while
## held; released with a velocity it flies with it, without one it falls; a
## split, a merge, a despawn or a clear releases the grab; several grabs hold
## at once. Played in the demo's arena with a plain world, at unit 1, clear
## of its floor blade (x 700) and wedge (x 1300).

## Physics frames a grab point may take, once its point stopped, to be within
## a bead radius of it.
const FOLLOW_FRAMES: int = 15
## Physics frames a drag lasts (a pointer's move, one step a frame).
const DRAG_FRAMES: int = 15

var arena: Arena
var world: GooWorld2D

func before_each() -> void:
	arena = (load("res://scenes/arena.tscn") as PackedScene).instantiate() as Arena
	add_child(arena)
	world = GooWorld2D.new()
	add_child(world)

# Steps `n` physics frames.
func _physics_frames(n: int) -> void:
	for _frame: int in n:
		await get_tree().physics_frame

# A body of `radius` resting on the floor with its centre at `x`.
func _on_floor(radius: float, x: float) -> Goo2D:
	return world.spawn(radius, Vector2(x, arena.floor_y() - radius))

# The highest bead of `body` (the least y).
func _top(body: Goo2D) -> Vector2:
	var top := Vector2(0.0, INF)
	for point: Vector2 in body.bead_points():
		if point.y < top.y:
			top = point
	return top

func test_body_at_finds_the_body_under_a_point() -> void:
	var a := _on_floor(40.0, 900.0)
	var b := _on_floor(60.0, 1100.0)
	await _physics_frames(2)
	assert_eq(world.body_at(a.center()), a, "a's centre")
	assert_eq(world.body_at(b.center()), b, "b's centre")
	assert_eq(world.body_at(_top(b) + Vector2(0.0, -b.bead_radius() * 0.5)), b,
		"within a bead radius above b's top bead: inside its outline")
	assert_true(b.has_point(_top(b)))
	assert_null(world.body_at(_top(b) + Vector2(0.0, -b.bead_radius() * 2.0)), "beside b's outline")
	assert_null(world.body_at(Vector2(1000.0, arena.floor_y() - 40.0)), "between the two")
	assert_false(a.has_point(b.center()))

func test_a_grab_starts_where_it_was_pressed() -> void:
	var body := _on_floor(40.0, 900.0)
	await _physics_frames(2)
	assert_false(world.grabbed(body))
	var point := body.center()
	var handle := world.grab(body, point)
	assert_true(handle >= 0, "a handle")
	assert_true(world.grabbed(body))
	assert_eq(world.grab_body(handle), body)
	assert_lt(world.grab_point(handle).distance_to(point), 0.01, "the grab point is the point pressed")
	var other := world.grab(body, _top(body))
	assert_ne(other, handle, "a second grab has a handle of its own")

func test_the_grab_point_follows_a_moved_point() -> void:
	var body := _on_floor(40.0, 900.0)
	await _physics_frames(30)
	var start := _top(body)
	var handle := world.grab(body, start)
	# Dragged by its top bead as a pointer would: 160 px up and right over
	# DRAG_FRAMES frames (about 640 px/s).
	var target := start + Vector2(60.0, -150.0)
	for frame: int in DRAG_FRAMES:
		world.move_grab(handle, start.lerp(target, float(frame + 1) / DRAG_FRAMES))
		await get_tree().physics_frame
	var frames := -1
	for frame: int in 60:
		if world.grab_body(handle) == null:
			break
		if world.grab_point(handle).distance_to(target) <= body.bead_radius():
			frames = frame
			break
		await get_tree().physics_frame
	assert_eq(world.grab_body(handle), body, "dragged, the body holds together")
	if world.grab_body(handle) == null:
		return
	print("    the grab point within a bead radius (%.1f px) %d frames after the point stopped"
		% [body.bead_radius(), frames])
	assert_true(frames >= 0 and frames <= FOLLOW_FRAMES,
		"within a bead radius of the target %d frames after it stopped, got %d" % [FOLLOW_FRAMES, frames])
	await _physics_frames(60)
	var gap := world.grab_point(handle).distance_to(target)
	print("    held still for 1 s: the grab point %.1f px off, the centre %.1f px below it"
		% [gap, body.center().y - target.y])
	assert_lt(gap, body.bead_radius(), "held, the grab point stays within a bead radius")
	assert_gt(body.center().y, target.y + body.radius * 0.5, "the body dangles below its top bead")
	assert_false(body.settled, "a held body never settles")

func test_a_held_body_never_settles() -> void:
	var body := _on_floor(40.0, 900.0)
	world.grab(body, body.center())
	await wait_seconds(GooTuning.SETTLE_TIME * 4.0)
	assert_false(body.settled, "held for %.1f s, still awake" % (GooTuning.SETTLE_TIME * 4.0))

func test_released_with_a_velocity_it_flies() -> void:
	var body := _on_floor(40.0, 900.0)
	await _physics_frames(10)
	var handle := world.grab(body, body.center())
	world.move_grab(handle, body.center() + Vector2(0.0, -200.0))
	await _physics_frames(30)
	var throw := Vector2(500.0, -300.0)
	assert_true(world.release_grab(handle, throw), "a held grab is released")
	assert_false(world.grabbed(body))
	assert_null(world.grab_body(handle))
	assert_false(world.release_grab(handle), "released once")
	assert_lt(body.average_velocity().distance_to(throw), 1.0, "the body's velocity is the throw's")
	var start := body.center()
	await _physics_frames(10)
	var moved := body.center() - start
	print("    thrown at %s: moved %s in 10 frames" % [throw, moved])
	assert_gt(moved.x, 60.0, "it flies the throw's way")

func test_released_without_a_velocity_it_falls() -> void:
	var body := _on_floor(40.0, 900.0)
	var handle := world.grab(body, body.center())
	var held := body.center() + Vector2(0.0, -300.0)
	world.move_grab(handle, held)
	await _physics_frames(40)
	assert_lt(body.center().distance_to(held), body.radius * 0.5, "lifted")
	world.release_grab(handle)
	await _physics_frames(20)
	assert_gt(body.center().y, held.y + 50.0, "let go, it falls")

func test_a_cut_releases_the_grab() -> void:
	var body := _on_floor(60.0, 900.0)
	await _physics_frames(5)
	var handle := world.grab(body, body.center())
	var pieces: Array[Goo2D] = []
	world.body_split.connect(func(_id: int, made: Array[Goo2D]) -> void: pieces.append_array(made))
	assert_true(world.cut_along(body, body.center(), Vector2.UP), "a cut asked for")
	assert_eq(world.grab_body(handle), body, "held until the cut is made, at the end of the frame")
	await wait_frames(1)
	assert_eq(pieces.size(), 2, "cut in two")
	assert_null(world.grab_body(handle), "the grab went with the body")
	for piece: Goo2D in pieces:
		assert_false(world.grabbed(piece), "no piece is held")
	world.move_grab(handle, Vector2(100.0, 100.0))
	assert_false(world.release_grab(handle), "nothing to release")
	await _physics_frames(5)

func test_a_merge_releases_the_grab() -> void:
	var a := _on_floor(40.0, 900.0)
	var b := _on_floor(40.0, 1150.0)
	await _physics_frames(30)
	var handle := world.grab(a, a.center())
	world.move_grab(handle, b.center() + Vector2(-60.0, -20.0))
	var merged: Array[Goo2D] = []
	world.bodies_merged.connect(func(_ids: PackedInt32Array, body: Goo2D) -> void: merged.append(body))
	for _frame: int in 180:
		await get_tree().physics_frame
		if not merged.is_empty():
			break
	assert_eq(merged.size(), 1, "dragged onto b, a merges with it")
	assert_null(world.grab_body(handle), "the merge released the grab")
	if not merged.is_empty():
		assert_false(world.grabbed(merged[0]), "the merged body is not held")

func test_despawn_and_clear_release_grabs() -> void:
	var a := _on_floor(40.0, 400.0)
	var b := _on_floor(40.0, 900.0)
	var c := _on_floor(40.0, 1500.0)
	var handle_a := world.grab(a, a.center())
	var handle_b := world.grab(b, b.center())
	var handle_c := world.grab(c, c.center())
	world.despawn(a)
	assert_null(world.grab_body(handle_a), "despawn")
	assert_eq(world.grab_body(handle_b), b, "the others held")
	world.clear()
	assert_null(world.grab_body(handle_b), "clear")
	assert_null(world.grab_body(handle_c), "clear")
	await _physics_frames(2)

func test_several_grabs_hold_at_once() -> void:
	var a := _on_floor(40.0, 900.0)
	var b := _on_floor(50.0, 1550.0)
	await _physics_frames(10)
	var handle_a := world.grab(a, a.center())
	var handle_b := world.grab(b, b.center())
	var target_a := a.center() + Vector2(-100.0, -250.0)
	var target_b := b.center() + Vector2(120.0, -150.0)
	world.move_grab(handle_a, target_a)
	world.move_grab(handle_b, target_b)
	await _physics_frames(40)
	assert_lt(world.grab_point(handle_a).distance_to(target_a), a.bead_radius(), "a follows its grab")
	assert_lt(world.grab_point(handle_b).distance_to(target_b), b.bead_radius(), "b follows its own")
	# Two grabs on one body, by its left and right sides, pull it apart,
	# dragged as two pointers would.
	world.release_grab(handle_b)
	var width := b.bead_bounds().size.x
	var left := b.center() - Vector2(b.radius * 0.8, 0.0)
	var right := b.center() + Vector2(b.radius * 0.8, 0.0)
	var handle_left := world.grab(b, left)
	var handle_right := world.grab(b, right)
	var apart := Vector2(b.radius * 0.6, 0.0)
	for frame: int in DRAG_FRAMES:
		var k := float(frame + 1) / DRAG_FRAMES
		world.move_grab(handle_left, left - apart * k)
		world.move_grab(handle_right, right + apart * k)
		await get_tree().physics_frame
	await _physics_frames(15)
	assert_eq(world.grab_body(handle_left), b, "b holds together")
	if world.grab_body(handle_left) == null:
		return
	print("    b %.0f px wide, %.0f px pulled by both sides" % [width, b.bead_bounds().size.x])
	assert_gt(b.bead_bounds().size.x, width + b.radius * 0.25, "two grabs stretch it")

func test_a_body_that_is_not_the_worlds_cannot_be_grabbed() -> void:
	allow_errors = true
	var other_world := GooWorld2D.new()
	add_child(other_world)
	var stranger := other_world.spawn(40.0, Vector2(600.0, 500.0))
	assert_eq(world.grab(stranger, stranger.center()), -1, "not this world's")
	assert_eq(world.grab(null, Vector2.ZERO), -1, "nothing")
	assert_false(world.grabbed(stranger))
	assert_eq(world.grab_point(12345), Vector2.INF, "no such grab")
