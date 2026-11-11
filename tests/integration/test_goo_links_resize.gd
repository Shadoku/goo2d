extends TestCase
## Links and live resizing together: a link holds while one of its bodies is
## resized within its bead count and across it (the ring rebuilt in place),
## round and polygon, and the neck follows the body's new size.

var world: GooWorld2D
var unlinked: int = 0

func before_each() -> void:
	GooTuning.unit = 1.0
	world = GooWorld2D.new()
	world.gravity_scale = 0.0
	add_child(world)
	unlinked = 0
	world.bodies_unlinked.connect(func(_handle: int, _a: int, _b: int) -> void: unlinked += 1)

func after_each() -> void:
	GooTuning.unit = 1.0

func _frames(n: int) -> void:
	for _frame: int in n:
		await get_tree().physics_frame

func _body(radius: float, at: Vector2, sides: int = 0) -> Goo2D:
	return world.spawn(radius, at, GooShape.regular(sides, radius) if sides >= 3 else null)

static func _sound(body: Goo2D, slack: float = 0.35) -> bool:
	for point: Vector2 in body.bead_points():
		if not point.is_finite():
			return false
	var ratio := body.area() / body.target_area
	return ratio > 1.0 - slack and ratio < 1.0 + slack

# The gap between the two bodies' outlines along the line of their centres.
static func _gap(a: Goo2D, b: Goo2D) -> float:
	return a.center().distance_to(b.center()) - a.eased_radius() - b.eased_radius()

func _linked_pair(sides_a: int, sides_b: int) -> Array:
	var a := _body(40.0, Vector2(560.0, 400.0), sides_a)
	var b := _body(40.0, Vector2(642.0, 400.0), sides_b)
	var handle := world.link(a, b, 0.8)
	return [a, b, handle]

func _assert_holds_through(sides_a: int, sides_b: int, target: float) -> void:
	var made := _linked_pair(sides_a, sides_b)
	var a: Goo2D = made[0]
	var b: Goo2D = made[1]
	var handle: int = made[2]
	await _frames(40)
	var count := a.particle_count()
	a.resize(target, 0.6)
	var worst_gap := 0.0
	for _frame: int in 150:
		await get_tree().physics_frame
		assert_true(_sound(a) and _sound(b), "both bodies stay sound")
		worst_gap = maxf(worst_gap, _gap(a, b))
	assert_eq(unlinked, 0)
	assert_eq(world.linked(a, b), handle)
	assert_true(world.kernel().has_link(handle), "the kernel holds the link again")
	assert_lt(worst_gap, 40.0, "the pair never drifts apart")
	if GooTuning.resize_count(a.shape, target) != count:
		assert_ne(a.particle_count(), count, "the ring was rebuilt with another count")
	# Still a joint: pulled apart, the pair comes back.
	a.set_velocity(Vector2(-250.0, 0.0))
	b.set_velocity(Vector2(250.0, 0.0))
	await _frames(120)
	assert_lt(_gap(a, b), 30.0)
	assert_eq(world.linked(a, b), handle)

func test_a_link_holds_while_a_round_body_grows_past_its_bead_count() -> void:
	await _assert_holds_through(0, 0, 120.0)

func test_a_link_holds_while_a_round_body_shrinks() -> void:
	await _assert_holds_through(0, 0, GooTuning.min_radius())

func test_a_link_holds_while_a_square_grows_beside_a_triangle() -> void:
	await _assert_holds_through(4, 3, 110.0)

func test_a_link_holds_through_a_small_resize_without_a_rebuild() -> void:
	await _assert_holds_through(0, 0, 44.0)

func test_the_neck_follows_the_new_size() -> void:
	var made := _linked_pair(0, 0)
	var a: Goo2D = made[0]
	var b: Goo2D = made[1]
	var handle: int = made[2]
	await _frames(40)
	var before := world.link_info(handle).pairs.size()
	a.resize(120.0, 0.5)
	b.resize(120.0, 0.5)
	await _frames(200)
	assert_eq(world.linked(a, b), handle)
	var info := world.link_info(handle)
	assert_gt(info.pairs.size(), before, "a neck between bigger bodies ties more beads")
	# Every tied bead index is one of the ring it is on.
	for k: int in range(0, info.pairs.size() - 1, 2):
		assert_lt(info.pairs[k], a.particle_count())
		assert_lt(info.pairs[k + 1], b.particle_count())
	assert_lt(_gap(a, b), 30.0)

func test_a_chain_breathing_stays_linked() -> void:
	var bodies: Array[Goo2D] = []
	for i: int in 5:
		bodies.append(_body(36.0, Vector2(400.0 + 74.0 * i, 400.0), 4 if i == 2 else 0))
	for i: int in 4:
		world.link(bodies[i], bodies[i + 1], 0.7)
	for frame: int in 360:
		for i: int in bodies.size():
			bodies[i].resize(50.0 + 20.0 * sin(frame * 0.05 + i), 0.2)
		await get_tree().physics_frame
		for body: Goo2D in bodies:
			assert_true(_sound(body, 0.4), "every body stays sound")
	assert_eq(unlinked, 0)
	assert_eq(world.links().size(), 4)
	for i: int in 4:
		assert_lt(_gap(bodies[i], bodies[i + 1]), 30.0)
