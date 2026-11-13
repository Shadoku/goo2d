extends TestCase
## The godot_physics example (examples/godot_physics/): goo meeting Godot's physics nodes.
## Every goo body and the creature have a proxy; the sensor lights up while the paddle
## carries the small blob through it and goes dark when it carries it out; the crate rests
## on the square blob; the character walks into the creature, is stopped by it and turns
## round, never inside it.

const SCENE := preload("res://examples/godot_physics/godot_physics.tscn")

var scene: GodotPhysicsExample

func before_each() -> void:
	scene = SCENE.instantiate() as GodotPhysicsExample
	add_child(scene)

func test_the_scene_boots_with_proxies() -> void:
	await wait_frames(3)
	var w := scene.world()
	assert_true(w.physics_proxies and w.push_bodies)
	assert_eq(w.proxies().count(), w.bodies().size(), "a proxy per ring body")
	assert_eq(scene.cell_world().proxies().count(), 1, "the creature's proxy")
	assert_true(w.proxies().excepted().has(scene.crate.get_rid()), "the crate is the goo's to push, not the proxies'")

func test_the_sensor_crate_and_character() -> void:
	var lit_frames := 0
	var dark_after_lit := false
	var crate_low := INF
	var crate_high := -INF
	var turned := false
	var walk_left_most := INF
	var creature := scene.cell_world().creatures()[0]
	var deepest := -INF
	var last_x := scene.character.position.x
	for f: int in 360:
		await get_tree().physics_frame
		if not scene.inside.is_empty():
			lit_frames += 1
		elif lit_frames > 0:
			dark_after_lit = true
		if f >= 120:
			crate_low = minf(crate_low, scene.crate.position.y)
			crate_high = maxf(crate_high, scene.crate.position.y)
		var x := scene.character.position.x
		if x > last_x + 0.5:
			turned = true
		last_x = x
		walk_left_most = minf(walk_left_most, x)
		var half := GodotPhysicsExample.CHARACTER_SIZE / 2.0
		var radii := creature.radii()
		var points := creature.positions()
		for i: int in points.size():
			var q := (points[i] - scene.character.position).abs()
			var outside := Vector2(maxf(q.x - half.x, 0.0), maxf(q.y - half.y, 0.0))
			var d := outside.length() if outside != Vector2.ZERO else -minf(half.x - q.x, half.y - q.y)
			deepest = maxf(deepest, radii[i] - d)
	print("sensor lit %d of 360 frames (lit %d times, dark again %s); crate y %.1f .. %.1f from 2 s; character got to x %.1f, turned %s, deepest cell into it %.2f px" % [lit_frames, scene.lit_count, dark_after_lit, crate_low, crate_high, walk_left_most, turned, deepest])
	assert_gt(lit_frames, 30, "the sensor lit up")
	assert_true(dark_after_lit, "and went dark again")
	assert_lt(crate_high - crate_low, 4.0, "the crate rests on the square")
	assert_true(turned, "the character turned round at the creature")
	assert_lt(walk_left_most, 1700.0, "it walked toward the creature")
	assert_lt(deepest, 1.0, "never inside the creature")
