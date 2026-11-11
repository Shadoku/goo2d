extends TestCase
## GooWorld2D's links (link(), unlink(), set_link_strength(),
## set_link_rest_angle(), links_of(), linked(), link_bodies(), bodies_linked,
## bodies_unlinked) on real bodies: a linked pair pulled apart comes back and
## an unlinked one does not; a chain of ten whipped about holds for ten
## seconds without a body blowing up or a bead tunnelling into its partner, at
## unit 1 and 0.5; every combination of round and polygon bodies holds; a weak
## link stretches more than a strong one; bodies linked apart are drawn
## together without overshooting; a swept rest angle bends a joint and stays
## stable; linked bodies never merge; a despawn, a cut, a merge with a third
## body and clear() release links; a chain hung from a grab under gravity holds;
## the editor's GooLink2D links its bodies; the bridge skin is drawn.

const FRAME: float = 1.0 / 60.0

var world: GooWorld2D
var unlinked: Array[Vector3i] = []

func before_each() -> void:
	GooTuning.unit = 1.0
	world = GooWorld2D.new()
	world.gravity_scale = 0.0
	add_child(world)
	unlinked.clear()
	world.bodies_unlinked.connect(func(handle: int, a_id: int, b_id: int) -> void:
		unlinked.append(Vector3i(handle, a_id, b_id)))

func after_each() -> void:
	GooTuning.unit = 1.0

# Steps `n` physics frames.
func _frames(n: int) -> void:
	for _frame: int in n:
		await get_tree().physics_frame

# A body of `radius` at `at`: round, or a regular polygon of `sides`.
func _body(radius: float, at: Vector2, sides: int = 0) -> Goo2D:
	return world.spawn(radius, at, GooShape.regular(sides, radius) if sides >= 3 else null)

# Two bodies of `radius` side by side along x around `at`, their outlines
# `gap` px apart, linked at `strength`; [a, b, handle].
func _pair(radius: float, strength: float, gap: float = 2.0, at: Vector2 = Vector2(600.0, 400.0),
		sides_a: int = 0, sides_b: int = 0) -> Array:
	var a := _body(radius, at - Vector2(radius + gap * 0.5, 0.0), sides_a)
	var b := _body(radius, at + Vector2(radius + gap * 0.5, 0.0), sides_b)
	var handle := world.link(a, b, strength)
	return [a, b, handle]

# True if every bead of `body` is finite and its area is within `slack` of
# its target area.
static func _sound(body: Goo2D, slack: float = 0.3) -> bool:
	for point: Vector2 in body.bead_points():
		if not point.is_finite():
			return false
	var ratio := body.area() / body.target_area
	return ratio > 1.0 - slack and ratio < 1.0 + slack

# The most beads of either body inside the other's bead loop.
static func _tunnelled(a: Goo2D, b: Goo2D) -> int:
	return maxi(a.beads_inside(b, 0.0), b.beads_inside(a, 0.0))

## A world whose bodies never merge (a chain's bodies touching one beyond
## their neighbour would otherwise merge, being of one size).
class NoMergeWorld extends GooWorld2D:
	func may_merge(_a: Goo2D, _b: Goo2D) -> bool:
		return false

# Steps `world` `n` physics frames at once, without waiting for the engine's
# frames (its own physics processing off meanwhile): a long run in a moment.
func _step_now(n: int) -> void:
	world.set_physics_process(false)
	for _frame: int in n:
		world._physics_process(FRAME)
	world.set_physics_process(true)

func test_a_link_is_made_and_listed() -> void:
	var made: Array = []
	world.bodies_linked.connect(func(handle: int, a: Goo2D, b: Goo2D) -> void: made.append([handle, a, b]))
	var pair := _pair(40.0, 1.0)
	var a: Goo2D = pair[0]
	var b: Goo2D = pair[1]
	var handle: int = pair[2]
	assert_true(handle >= 0, "a handle")
	assert_eq(made.size(), 1, "bodies_linked once")
	assert_eq(made[0], [handle, a, b])
	assert_eq(world.linked(a, b), handle)
	assert_eq(world.linked(b, a), handle, "either way round")
	assert_eq(world.links_of(a), PackedInt32Array([handle]))
	assert_eq(world.link_bodies(handle), [a, b] as Array[Goo2D])
	assert_eq(world.links(), PackedInt32Array([handle]))
	assert_true(world.kernel().has_link(handle))
	assert_almost_eq(world.link_strength(handle), 1.0, 0.0001)
	var wide := (world.link_info(handle).pairs as PackedInt32Array).size()
	world.set_link_strength(handle, 0.1)
	assert_eq(world.link_info(handle).pairs.size(), 2, "a thread at 0.1")
	assert_gt(wide, 2)
	world.set_link_rest_angle(handle, 0.3)
	assert_almost_eq(world.link_rest_angle(handle), 0.3, 0.0001)
	assert_true(world.unlink(handle))
	assert_false(world.unlink(handle), "released once")
	assert_eq(unlinked, [Vector3i(handle, a.id, b.id)] as Array[Vector3i])
	assert_eq(world.linked(a, b), -1)
	assert_false(world.kernel().has_link(handle))

func test_bad_links_are_refused() -> void:
	allow_errors = true
	var a := _body(40.0, Vector2(500.0, 400.0))
	var b := _body(40.0, Vector2(600.0, 400.0))
	var other_world := GooWorld2D.new()
	add_child(other_world)
	var stranger := other_world.spawn(40.0, Vector2(800.0, 400.0))
	assert_eq(world.link(a, a), -1, "a body to itself")
	assert_eq(world.link(a, stranger), -1, "a body of another world")
	assert_eq(world.link(a, null), -1, "nothing")
	var handle := world.link(a, b)
	assert_true(handle >= 0)
	assert_eq(world.link(b, a), -1, "a pair linked already")
	assert_eq(world.links().size(), 1)

func test_a_linked_pair_pulled_apart_comes_back() -> void:
	for gravity: float in [0.0, 1.0]:
		for linked: bool in [true, false]:
			world.clear()
			world.gravity_scale = gravity
			var a := _body(40.0, Vector2(560.0, 300.0))
			var b := _body(40.0, Vector2(642.0, 300.0))
			if linked:
				world.link(a, b, 1.0)
			_step_now(30)
			var rest := a.center().distance_to(b.center())
			a.set_velocity(Vector2(-500.0, 0.0))
			b.set_velocity(Vector2(500.0, 0.0))
			var widest := 0.0
			for frame: int in 90:
				_step_now(1)
				widest = maxf(widest, a.center().distance_to(b.center()))
			var final := a.center().distance_to(b.center())
			print("    %s, gravity %.0f: %.1f px apart at rest, at most %.1f, %.1f after 1.5 s"
				% ["linked" if linked else "unlinked", gravity, rest, widest, final])
			if linked:
				assert_lt(widest, rest + 40.0, "linked: held within 40 px of rest")
				assert_lt(absf(final - rest), 8.0, "and back")
				assert_true(_sound(a) and _sound(b), "neither blew up")
			else:
				assert_gt(final, rest + 200.0, "unlinked: they fly apart")

func test_a_chain_of_ten_holds_when_whipped() -> void:
	for unit: float in [1.0, 0.5]:
		world.queue_free()
		GooTuning.unit = unit
		world = NoMergeWorld.new()
		world.gravity_scale = 0.0
		add_child(world)
		var radius := 30.0 * unit
		var chain: Array[Goo2D] = []
		for k: int in 10:
			chain.append(_body(radius, Vector2(300.0 + k * (2.0 * radius + 2.0 * unit), 500.0)))
		for k: int in 9:
			world.link(chain[k], chain[k + 1], 0.8)
		_step_now(20)
		var grab := world.grab(chain[0], chain[0].center())
		var start := chain[0].center()
		var worst_tunnel := 0
		var fastest_tail := 0.0
		var broken := ""
		var unsound := ""
		for frame: int in 600:
			var t := frame * FRAME
			# Whipped: round a 200 px circle once a second, jerked aside for
			# 0.1 s every 2 s.
			var point := start + Vector2(cos(TAU * t) - 1.0, sin(TAU * t)) * 200.0 * unit
			if frame % 120 < 6:
				point += Vector2(150.0, -150.0) * unit
			world.move_grab(grab, point)
			_step_now(1)
			if broken == "" and (world.links().size() != 9 or world.bodies().size() != 10):
				broken = "frame %d: %d links, %d bodies" % [frame, world.links().size(), world.bodies().size()]
				break
			fastest_tail = maxf(fastest_tail, chain[9].average_velocity().length())
			if frame % 5 == 0:
				for k: int in 10:
					if unsound == "" and not _sound(chain[k]):
						unsound = "body %d at frame %d: area ratio %.2f" % [k, frame, chain[k].area() / chain[k].target_area]
				for k: int in 9:
					worst_tunnel = maxi(worst_tunnel, _tunnelled(chain[k], chain[k + 1]))
		print("    unit %.1f: a chain of 10 whipped for 10 s: links %d, bodies %d, worst beads inside a partner %d, tail up to %.0f px/s%s%s"
			% [unit, world.links().size(), world.bodies().size(), worst_tunnel, fastest_tail,
			(", " + unsound) if unsound != "" else "", (", broke at " + broken) if broken != "" else ""])
		assert_eq(broken, "", "unit %.1f: every link and body held" % unit)
		assert_eq(unsound, "", "unit %.1f: no body blew up" % unit)
		assert_lt(worst_tunnel, 3, "unit %.1f: no bead tunnelled into its partner" % unit)
		assert_gt(fastest_tail, 300.0 * unit, "unit %.1f: the chain's tail was whipped about" % unit)
		await get_tree().process_frame

func test_every_shape_combination_links_and_holds() -> void:
	var combinations: Array[Vector2i] = [Vector2i(0, 0), Vector2i(0, 4), Vector2i(0, 3), Vector2i(4, 4),
		Vector2i(4, 3), Vector2i(3, 3)]
	for sides: Vector2i in combinations:
		world.clear()
		var pair := _pair(40.0, 0.8, 2.0, Vector2(600.0, 400.0), sides.x, sides.y)
		var a: Goo2D = pair[0]
		var b: Goo2D = pair[1]
		var handle: int = pair[2]
		assert_true(handle >= 0, "%s linked" % sides)
		_step_now(30)
		var rest := a.center().distance_to(b.center())
		a.set_velocity(Vector2(-400.0, -100.0))
		b.set_velocity(Vector2(400.0, 100.0))
		var widest := 0.0
		for frame: int in 90:
			_step_now(1)
			widest = maxf(widest, a.center().distance_to(b.center()))
		var final := a.center().distance_to(b.center())
		var bridge := world.link_info(handle).bridge
		print("    sides %d and %d: %.1f px apart at rest, at most %.1f, %.1f after 1.5 s" % [sides.x, sides.y, rest, widest, final])
		assert_lt(widest, rest + 50.0, "%s held" % sides)
		assert_lt(absf(final - rest), 10.0, "%s came back" % sides)
		assert_true(_sound(a) and _sound(b), "%s: neither blew up" % sides)
		assert_lt(_tunnelled(a, b), 3, "%s: no bead inside the partner" % sides)
		assert_not_null(bridge, "%s: a bridge" % sides)
		if bridge != null:
			assert_gt(bridge.polygon.size(), 2, "%s: the bridge is drawn" % sides)

func test_a_weak_link_stretches_more() -> void:
	var stretch: Array[float] = []
	for strength: float in [0.1, 1.0]:
		world.clear()
		var pair := _pair(40.0, strength)
		var a: Goo2D = pair[0]
		var b: Goo2D = pair[1]
		_step_now(30)
		var rest := a.center().distance_to(b.center())
		var widest := 0.0
		for frame: int in 60:
			a.apply_force(Vector2(-a.body_mass() * 1500.0, 0.0))
			b.apply_force(Vector2(b.body_mass() * 1500.0, 0.0))
			_step_now(1)
			widest = maxf(widest, a.center().distance_to(b.center()))
		stretch.append(widest - rest)
		assert_true(world.linked(a, b) >= 0, "strength %.1f held" % strength)
	print("    stretched by the same pull: %.1f px at strength 0.1, %.1f px at 1" % [stretch[0], stretch[1]])
	assert_gt(stretch[0], stretch[1], "a weak link stretches more")

func test_bodies_linked_apart_are_drawn_together() -> void:
	var a := _body(40.0, Vector2(450.0, 400.0))
	var b := _body(40.0, Vector2(750.0, 400.0))
	_step_now(5)
	world.link(a, b, 1.0)
	var distances: Array[float] = []
	var fastest := 0.0
	for frame: int in 120:
		_step_now(1)
		distances.append(a.center().distance_to(b.center()))
		fastest = maxf(fastest, maxf(a.average_velocity().length(), b.average_velocity().length()))
	var final: float = distances[distances.size() - 1]
	var closest: float = distances.min()
	print("    linked 300 px apart: %.1f px after 2 s, closest %.1f, fastest %.0f px/s" % [final, closest, fastest])
	assert_lt(final, 110.0, "drawn together")
	assert_gt(closest, final - 15.0, "without overshooting far into each other")
	assert_lt(fastest, 2500.0, "nor flying at each other")
	assert_true(_sound(a) and _sound(b))

func test_a_swept_rest_angle_bends_the_joint() -> void:
	var pair := _pair(40.0, 1.0)
	var a: Goo2D = pair[0]
	var b: Goo2D = pair[1]
	var handle: int = pair[2]
	_step_now(30)
	var most := 0.0
	var least := 0.0
	var follows := 0
	for frame: int in 300:
		var target := 0.6 * sin(TAU * frame * FRAME)
		world.set_link_rest_angle(handle, target)
		_step_now(1)
		var bend := world.link_bend(handle)
		most = maxf(most, bend)
		least = minf(least, bend)
		if absf(bend - target) < 0.25:
			follows += 1
		assert_true(_sound(a) and _sound(b), "stable at frame %d" % frame)
		if not (_sound(a) and _sound(b)):
			return
	print("    rest angle swept ±0.6 rad at 1 Hz for 5 s: bend %.2f .. %.2f, within 0.25 rad of the target %d of 300 frames"
		% [least, most, follows])
	assert_gt(most, 0.4, "bends one way")
	assert_lt(least, -0.4, "and the other")
	assert_gt(follows, 240, "following the sweep")
	assert_eq(world.bodies().size(), 2)

func test_linked_bodies_never_merge() -> void:
	for linked: bool in [true, false]:
		world.clear()
		var a := _body(40.0, Vector2(560.0, 400.0))
		var b := _body(40.0, Vector2(640.0, 400.0))
		assert_true(GooWorld2D.can_merge(a, b), "the default rule would merge them")
		if linked:
			world.link(a, b, 1.0)
		a.set_velocity(Vector2(200.0, 0.0))
		b.set_velocity(Vector2(-200.0, 0.0))
		await _frames(150)
		print("    %s: %d bodies after 2.5 s pressed together" % ["linked" if linked else "unlinked", world.bodies().size()])
		assert_eq(world.bodies().size(), 2 if linked else 1, "linked never merge; unlinked do")

func test_leaving_the_world_releases_links() -> void:
	# A despawn.
	var pair := _pair(40.0, 1.0)
	var a: Goo2D = pair[0]
	var b: Goo2D = pair[1]
	var handle: int = pair[2]
	var a_id := a.id
	world.despawn(a)
	assert_eq(unlinked, [Vector3i(handle, a_id, b.id)] as Array[Vector3i], "despawn")
	assert_eq(world.links().size(), 0)
	assert_false(world.kernel().has_link(handle))
	await _frames(2)
	# A cut.
	unlinked.clear()
	world.clear()
	pair = _pair(50.0, 1.0)
	a = pair[0]
	await _frames(5)
	world.cut(a, 0, a.particle_count() / 2)
	assert_eq(unlinked.size(), 1, "a cut")
	assert_eq(world.links().size(), 0)
	assert_eq(world.bodies().size(), 3, "the cut body's pieces and its partner")
	# A merge with a third body.
	unlinked.clear()
	world.clear()
	pair = _pair(40.0, 1.0)
	a = pair[0]
	var third := _body(40.0, a.center() - Vector2(84.0, 0.0))
	third.set_velocity(Vector2(150.0, 0.0))
	var merged := false
	for frame: int in 180:
		await get_tree().physics_frame
		if world.bodies().size() == 2:
			merged = true
			break
	assert_true(merged, "a merged with the third body")
	assert_eq(unlinked.size(), 1, "the merge released a's link")
	assert_eq(world.links().size(), 0)
	# clear().
	unlinked.clear()
	world.clear()
	var chain: Array[Goo2D] = []
	for k: int in 3:
		chain.append(_body(30.0, Vector2(400.0 + k * 62.0, 400.0)))
	world.link(chain[0], chain[1])
	world.link(chain[1], chain[2])
	world.clear()
	assert_eq(unlinked.size(), 2, "clear() releases every link")
	assert_eq(world.links().size(), 0)
	assert_eq(world.kernel().link_ids().size(), 0)

func test_a_hanging_chain_does_not_tear() -> void:
	world.gravity_scale = 1.0
	var chain: Array[Goo2D] = []
	for k: int in 5:
		chain.append(_body(36.0, Vector2(600.0, 200.0 + k * 74.0)))
	for k: int in 4:
		world.link(chain[k], chain[k + 1], 1.0)
	var grab := world.grab(chain[0], chain[0].center())
	var hold := chain[0].center()
	_step_now(5)
	var rest := chain[0].center().distance_to(chain[4].center())
	var longest := 0.0
	for frame: int in 240:
		world.move_grab(grab, hold + Vector2(sin(TAU * frame * FRAME * 0.5) * 60.0, 0.0))
		_step_now(1)
		longest = maxf(longest, chain[0].center().distance_to(chain[4].center()))
	print("    a chain of 5 hung from a grab for 4 s: %d links, %d bodies, %.0f px long at most (%.0f at the start)"
		% [world.links().size(), world.bodies().size(), longest, rest])
	assert_eq(world.links().size(), 4, "every link held")
	assert_eq(world.bodies().size(), 5, "no body tore")
	assert_lt(longest, rest * 1.6, "hanging, not stretched out")
	for body: Goo2D in chain:
		assert_true(_sound(body), "no body blew up")

func test_the_editor_link_node_links_its_bodies() -> void:
	world.queue_free()
	var scene := (load("res://tests/integration/scenes/goo_editor_links.tscn") as PackedScene).instantiate()
	add_child(scene)
	await _frames(3)
	var placed := scene.get_node("World") as GooWorld2D
	var thread := scene.get_node("World/Thread") as GooLink2D
	var neck := scene.get_node("World/Neck") as GooLink2D
	assert_true(thread.handle >= 0, "the thread is linked")
	assert_true(neck.handle >= 0, "the neck is linked")
	assert_eq(placed.links().size(), 2)
	assert_eq(placed.linked(scene.get_node("World/Round"), scene.get_node("World/Square")), neck.handle)
	assert_almost_eq(placed.link_strength(thread.handle), 0.1, 0.0001)
	assert_almost_eq(placed.link_rest_angle(neck.handle), 0.3, 0.0001)
	neck.rest_angle = -0.2
	assert_almost_eq(placed.link_rest_angle(neck.handle), -0.2, 0.0001, "a changed rest angle reaches the world")
	var handle := thread.handle
	thread.queue_free()
	await _frames(1)
	assert_eq(placed.linked(scene.get_node("World/Round"), scene.get_node("World/Small")), -1,
		"freeing the node unlinks")
	assert_false(placed.kernel().has_link(handle))

func test_the_bridge_is_drawn_under_the_bodies() -> void:
	var pair := _pair(40.0, 0.6)
	var handle: int = pair[2]
	await _frames(3)
	var held := world.link_info(handle)
	assert_not_null(held.bridge)
	assert_gt(held.bridge.polygon.size(), 2)
	assert_eq(held.bridge.get_parent().get_parent(), world, "in the world's bridge holder")
	assert_false(world.get_children().has(held.bridge.get_parent()), "an internal child: not among the bodies")
	assert_eq(held.bridge.color, (pair[0] as Goo2D).get_tint(), "in the larger body's tint")
	assert_not_null(held.skin)
	world.unlink(handle)
	await _frames(1)
	assert_false(is_instance_valid(held.bridge) and held.bridge.is_inside_tree(), "unlinking frees the bridge")
