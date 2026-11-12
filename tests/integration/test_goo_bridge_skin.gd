extends TestCase
## A link's bridge skin (GooLink.draw_bridge()): its bubble field rides the
## pair. A material point of the neck (the midpoint of a tied bead pair) keeps
## its place in the bridge's field (GooSkin.field_point()) while the pair turns
## through several full turns, is pulled apart and pushed together, bends at a
## joint swept by set_link_rest_angle(), and while one body is resized across
## a re-ring (the link re-attached). And the bridge follows its larger body's
## look when a look uniform is changed on it after the bridge was first drawn.
## At unit 1 in zero gravity; every measured number is printed.

## Tolerance, px, on a neck point's field coordinates. The field is the best
## affine map of the neck's beads: a bent joint shears the neck unevenly (one
## side pressed, the other pulled), which no affine map follows exactly.
const NECK_TOLERANCE: float = 3.0
## Tolerance, px, on a point of the neck on the body that keeps its size while
## the other body grows 40 -> 64 px: the neck grows on one side only, and the
## affine map grows it evenly, about halfway.
const UNEVEN_TOLERANCE: float = 8.0

var world: GooWorld2D

func before_each() -> void:
	GooTuning.unit = 1.0
	world = GooWorld2D.new()
	world.gravity_scale = 0.0
	add_child(world)

func after_each() -> void:
	GooTuning.unit = 1.0

func _frames(n: int) -> void:
	for _frame: int in n:
		await get_tree().physics_frame

# Two round bodies of `radius` side by side, linked; [a, b, handle].
func _pair(radius: float, radius_b: float = -1.0) -> Array:
	var rb := radius if radius_b <= 0.0 else radius_b
	var a := world.spawn(radius, Vector2(600.0, 500.0))
	var b := world.spawn(rb, Vector2(600.0 + radius + rb + 2.0, 500.0))
	return [a, b, world.link(a, b, 1.0)]

# The neck point of `link`: the middle of its first tied bead pair, global.
static func _neck(link: GooLink) -> Vector2:
	return (link.a.bead_position(link.pairs[0]) + link.b.bead_position(link.pairs[1])) * 0.5

# The neck point's place in the bridge's field, in the field's own px.
static func _neck_field(link: GooLink) -> Vector2:
	return GooSkin.field_point(link.skin.material, _neck(link)) * link.skin.bubble_cell

# Sets every bead of both bodies to a rigid motion: `velocity` plus a spin of
# `spin` rad/s about the pair's middle; `apart` px/s more along the a → b axis
# for b (and as much against it for a).
static func _drive(a: Goo2D, b: Goo2D, velocity: Vector2, spin: float, apart: float) -> void:
	var middle := (a.center() + b.center()) * 0.5
	var axis := (b.center() - a.center()).normalized()
	for body: Goo2D in [a, b]:
		var push := axis * apart * (1.0 if body == b else -1.0)
		for i: int in body.particle_count():
			body.set_bead_velocity(i, velocity + push + (body.bead_position(i) - middle).rotated(PI / 2.0) * spin)

func test_a_neck_point_stays_put_in_the_bridges_field_as_the_pair_turns_and_bends() -> void:
	timeout_sec = 40.0
	var pair := _pair(40.0)
	var a: Goo2D = pair[0]
	var b: Goo2D = pair[1]
	var handle: int = pair[2]
	await _frames(40)
	var link := world.link_info(handle)
	assert_not_null(link.skin, "the bridge is drawn")
	if link.skin == null:
		return
	var start := _neck_field(link)
	var worst := {"turn": 0.0, "pull": 0.0, "bend": 0.0}
	var turned := 0.0
	var last := (b.center() - a.center()).angle()
	# Several full turns, at 3 rad/s for 5 s.
	for _frame: int in 300:
		_drive(a, b, Vector2(20.0, 0.0), 3.0, 0.0)
		await get_tree().physics_frame
		turned += angle_difference(last, (b.center() - a.center()).angle())
		last = (b.center() - a.center()).angle()
		worst["turn"] = maxf(worst["turn"], _neck_field(link).distance_to(start))
	# Pulled apart and pushed together, still turning.
	for frame: int in 120:
		_drive(a, b, Vector2.ZERO, 1.0, 120.0 * sin(TAU * frame / 40.0))
		await get_tree().physics_frame
		worst["pull"] = maxf(worst["pull"], _neck_field(link).distance_to(start))
	# The joint swept from 0 to 0.8 rad, to −0.8 and back.
	for frame: int in 180:
		world.set_link_rest_angle(handle, 0.8 * sin(TAU * frame / 180.0))
		await get_tree().physics_frame
		worst["bend"] = maxf(worst["bend"], _neck_field(link).distance_to(start))
	print("  a linked pair turned %.2f rad: the neck point moved %.3f px in the bridge's field; pulled about %.3f px; bent ±0.8 rad %.3f px" % [
		turned, worst["turn"], worst["pull"], worst["bend"]])
	assert_gt(absf(turned), 4.0 * PI, "two full turns at least")
	assert_lt(worst["turn"], NECK_TOLERANCE, "turning: the neck's bubbles turn with the pair")
	assert_lt(worst["pull"], NECK_TOLERANCE, "pulled about")
	assert_lt(worst["bend"], NECK_TOLERANCE, "bent at the joint")

func test_a_neck_point_stays_put_while_a_body_is_re_rung() -> void:
	var pair := _pair(40.0)
	var a: Goo2D = pair[0]
	var b: Goo2D = pair[1]
	var handle: int = pair[2]
	await _frames(40)
	var link := world.link_info(handle)
	var rerings := [0]
	b.rebuilt.connect(func(_old: PackedVector2Array) -> void: rerings[0] += 1)
	# A material point of the neck that the re-ring leaves alone: a's first tied
	# bead (b's beads, and so the pairs, are rebuilt and tied again).
	var bead_a := link.pairs[0]
	var neck := func() -> Vector2:
		return GooSkin.field_point(link.skin.material, a.bead_position(bead_a)) * link.skin.bubble_cell
	var start: Vector2 = neck.call()
	var worst := 0.0
	var jump := 0.0
	var last := start
	b.resize(64.0, 1.0)
	for _frame: int in 90:
		_drive(a, b, Vector2.ZERO, 1.0, 0.0)
		await get_tree().physics_frame
		var now: Vector2 = neck.call()
		worst = maxf(worst, now.distance_to(start))
		jump = maxf(jump, now.distance_to(last))
		last = now
	print("  one body resized 40 -> 64 px across %d re-rings: a's tied bead moved %.3f px in the bridge's field, %.3f px at most in a frame" % [
		rerings[0], worst, jump])
	assert_gt(rerings[0], 0, "re-rung")
	assert_lt(jump, 1.0, "no jump at a re-ring")
	assert_lt(worst, UNEVEN_TOLERANCE, "the neck's field grows with it, about halfway on this side")

func test_the_bridge_follows_its_larger_bodys_look() -> void:
	var pair := _pair(40.0, 34.0)
	var a: Goo2D = pair[0]
	var handle: int = pair[2]
	await _frames(5)
	var link := world.link_info(handle)
	var big := (a.get_node(^"Skin") as Polygon2D).material as ShaderMaterial
	big.set_shader_parameter(&"rim_width", 33.0)
	big.set_shader_parameter(&"bubble_wobble", 0.0)
	big.set_shader_parameter(&"bubble_lag", 0.0)
	await _frames(2)
	assert_eq(link.skin.material.get_shader_parameter(&"rim_width"), 33.0, "a look uniform changed later reaches the bridge")
	assert_eq(link.skin.material.get_shader_parameter(&"bubble_wobble"), 0.0, "bubble_wobble too")
	assert_eq(link.skin.material.get_shader_parameter(&"bubble_lag"), 0.0, "and bubble_lag")
	# Its own per-body uniforms stay its own.
	assert_ne(link.skin.material.get_shader_parameter(&"center"), big.get_shader_parameter(&"center"))
	# The cost of following: what draw_bridge() spends a frame comparing.
	var started := Time.get_ticks_usec()
	for _i: int in 1000:
		link.follow_look()
	print("  following the look: %.2f µs a bridge a frame" % ((Time.get_ticks_usec() - started) / 1000.0))
