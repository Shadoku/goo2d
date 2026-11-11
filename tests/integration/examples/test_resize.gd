extends TestCase
## The resize example (examples/resize/): three bodies (round, square,
## triangle) breathing between two sizes with Goo2D.resize(), one squashing
## with Goo2D.set_rest_deform() every frame, in a world where nothing merges;
## the mouse wheel (or + / -) resizes the body under the pointer.

const SCENE := preload("res://examples/resize/resize.tscn")

var scene: ResizeExample
var world: ResizeWorld

func before_each() -> void:
	GooTuning.unit = 1.0
	scene = SCENE.instantiate() as ResizeExample
	add_child(scene)
	world = scene.world()

func test_the_scene_boots_with_four_bodies_breathing_and_squashing() -> void:
	assert_not_null(world)
	assert_eq(world.bodies().size(), ResizeExample.BREATHERS.size() + 1)
	var squasher := scene.squasher()
	assert_not_null(squasher)
	assert_lt(float(squasher.rest_deform()["squash"]), 1.0, "squashed at frame 0")
	var breathers := world.bodies().filter(func(b: Goo2D) -> bool: return scene.is_breathing(b))
	assert_eq(breathers.size(), 3)
	var shapes := breathers.map(func(b: Goo2D) -> int: return 0 if b.shape.is_round() else b.shape.outline.size())
	assert_eq(shapes, [0, 4, 3], "a round body, a square and a triangle")
	var rebuilt := [0]
	world.body_rebuilt.connect(func(_b: Goo2D) -> void: rebuilt[0] += 1)
	var start: Array[float] = []
	for body: Goo2D in breathers:
		start.append(body.eased_radius())
	await wait_seconds(2.0)
	for k: int in breathers.size():
		assert_gt((breathers[k] as Goo2D).eased_radius(), start[k] * 1.2, "breather %d grew" % k)
	assert_gt(rebuilt[0], 0, "and rebuilt its ring where its count changed")
	assert_eq(world.bodies().size(), 4, "nothing merged or split")
	print("    after 2 s: radii %s, %d rebuilds, squash %.2f" % [
		world.bodies().map(func(b: Goo2D) -> String: return "%.0f" % b.eased_radius()), rebuilt[0],
		float(squasher.rest_deform()["squash"])])

func test_the_wheel_resizes_the_body_under_the_pointer() -> void:
	await wait_frames(2)
	var squasher := scene.squasher()
	var before := squasher.radius
	assert_eq(scene.step_size_at(squasher.center(), 2), squasher)
	assert_almost_eq(squasher.radius, before * pow(1.0 + ResizeExample.WHEEL_STEP, 2), 0.001)
	var breather: Goo2D = world.bodies()[0]
	scene.step_size_at(breather.center(), -1)
	assert_false(scene.is_breathing(breather), "a body the wheel resized stops breathing")
	assert_null(scene.step_size_at(Vector2(960.0, 300.0), 1), "nothing under the pointer")

func test_reset_puts_the_four_back() -> void:
	await wait_seconds(0.5)
	scene.reset()
	await wait_frames(2)
	assert_eq(world.bodies().size(), 4)
	for body: Goo2D in world.bodies():
		assert_true(scene.is_breathing(body) or body == scene.squasher())
