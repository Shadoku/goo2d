extends TestCase
## The links example (examples/links/): a top-down tank of bodies joined by
## GooWorld2D.link(): a chain of five, a round body linked to a square and a
## triangle, three pairs at strengths 0.2, 0.6 and 1, and a chain of three
## whose first link's rest angle swings. Everything is linked at once, every
## link is drawn with a bridge, nothing merges or comes apart, and the swung
## joint bends both ways.

const SCENE := preload("res://examples/links/links.tscn")

var scene: LinksExample
var world: LinksWorld

func before_each() -> void:
	scene = SCENE.instantiate() as LinksExample
	add_child(scene)
	world = scene.world()

func test_the_scene_boots_linked() -> void:
	assert_not_null(world)
	assert_almost_eq(world.gravity_scale, 0.0, 0.0001, "top-down")
	assert_eq(world.bodies().size(), 5 + 3 + 6 + 3, "the chain, the cluster, the pairs and the waving chain")
	assert_eq(world.links().size(), 4 + 2 + 3 + 2)
	var strengths: Array[float] = []
	for handle: int in world.links():
		strengths.append(world.link_strength(handle))
	for strength: float in LinksExample.PAIR_STRENGTHS:
		assert_true(strengths.has(strength), "a link of strength %.1f" % strength)
	var shapes := 0
	for body: Goo2D in world.bodies():
		if body.shape != null and not body.shape.is_round():
			shapes += 1
	assert_eq(shapes, 2, "a square and a triangle")
	await wait_frames(3)
	for handle: int in world.links():
		var bridge := world.link_info(handle).bridge
		assert_true(bridge != null and bridge.polygon.size() > 2, "link %d has a bridge" % handle)

func test_it_holds_together_and_the_joint_swings() -> void:
	var most := 0.0
	var least := 0.0
	for frame: int in 150:
		await get_tree().physics_frame
		var bend := world.link_bend(scene.waver)
		most = maxf(most, bend)
		least = minf(least, bend)
	print("    the swung joint bent %.2f .. %.2f rad over 2.5 s" % [least, most])
	assert_eq(world.bodies().size(), 17, "no body merged, split or left")
	assert_eq(world.links().size(), 11, "no link released")
	assert_gt(most, 0.3, "bends one way")
	assert_lt(least, -0.3, "and the other")

func test_r_rebuilds_the_tank() -> void:
	world.despawn(world.bodies()[0])
	assert_eq(world.links().size(), 10, "a despawn released a link")
	var key := InputEventKey.new()
	key.keycode = KEY_R
	key.pressed = true
	Input.parse_input_event(key)
	await wait_frames(2)
	assert_eq(world.bodies().size(), 17)
	assert_eq(world.links().size(), 11)
