extends TestCase
## The skin's bubble field and two-tone division stay on the body's material
## while the body changes size or shape: a resize within a bead count and
## across several re-rings, growing and shrinking, round and polygon; a rest
## deformation (squash and area pulse) set every frame; both together; a merged
## body and cut pieces inflating, then resized. A material point keeps its
## place in the field (GooSkin.field_point(), the shader's map) within a small
## tolerance (the beads wobble a fraction of a pixel about their rest places
## anyway), with no jump at a re-ring or at a birth. And a plain body that is
## never resized or deformed keeps the identity basis through a normal game
## (falling, bouncing, then merging and being cut: its merged and cut bodies'
## fields follow their inflate). Played at unit 1, in zero gravity unless a test
## says otherwise; every measured number is printed.
##
## How a body is measured: its collision outline (each bead pushed out a bead
## radius along its normal: the goo's edge, which unlike the bead centres does
## not move against the goo when a re-ring changes the bead size), each point's
## field coordinates, in the field's own px (GooSkin.field_point() × the skin's
## bubble_cell), against the loop those points drew in the field before
## anything changed: the outline's material stays where it was in the field
## when every point stays on that loop. `rms` is the root mean square over the beads of each one's
## distance to it (any bead count: across re-rings too); where the count stays,
## `track` is each bead's distance from its own field coordinates then.

## Tolerance, px (rms over the outline), on the outline's field coordinates
## for a gentle change and once a body has settled after one.
const FIELD_TOLERANCE: float = 1.5
## Tolerance, px, while a body changes fast: the field is the best affine map
## of the outline's motion, and what an affine map cannot follow remains (a
## ring shrunk from 80 to 30 px in a second buckles a little; a squash pulsed
## once a second between 0.6 and 1.6 wobbles the outline unevenly).
const MOTION_TOLERANCE: float = 5.0
## Tolerance, px, on any frame-to-frame jump of the rms (a re-ring, a birth).
const JUMP_TOLERANCE: float = 1.5

var world: GooWorld2D
# The outline's field coordinates when _deform_through() began.
var _outline_start: PackedVector2Array = PackedVector2Array()

## A world whose bodies never merge.
class NoMergeWorld extends GooWorld2D:
	func may_merge(_a: Goo2D, _b: Goo2D) -> bool:
		return false

func before_each() -> void:
	GooTuning.unit = 1.0

func after_each() -> void:
	GooTuning.unit = 1.0

func _make_world(merges: bool = false, zero_g: bool = true) -> GooWorld2D:
	world = GooWorld2D.new() if merges else NoMergeWorld.new()
	if zero_g:
		world.gravity_scale = 0.0
	add_child(world)
	return world

func _floor(top: float) -> void:
	var ground := StaticBody2D.new()
	var collision := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = Vector2(8000.0, 100.0)
	collision.shape = rect
	ground.add_child(collision)
	ground.position = Vector2(960.0, top + 50.0)
	add_child(ground)

func _frames(n: int) -> void:
	for _frame: int in n:
		await get_tree().physics_frame

static func _material(body: Goo2D) -> ShaderMaterial:
	return (body.get_node(^"Skin") as Polygon2D).material as ShaderMaterial

# Pushes the body's skin uniforms from where the kernel has it now.
static func _sync(body: Goo2D) -> void:
	body._process(0.0)

## `point` (global) in `body`'s bubble field, in the field's own px.
static func _field(body: Goo2D, point: Vector2) -> Vector2:
	return GooSkin.field_point(_material(body), point) * body._goo.bubble_cell

# `body`'s collision outline, global: each bead pushed out a bead radius along
# the mean of its two edges' normals.
static func _outline(body: Goo2D) -> PackedVector2Array:
	var points := body.bead_points()
	var count := points.size()
	var normals := GooLoop.edge_normals(points)
	var out := PackedVector2Array()
	for i: int in count:
		out.append(points[i] + (normals[(i + count - 1) % count].normalized() + normals[i].normalized()).normalized()
			* body.bead_radius())
	return out

# The rms distance of `body`'s outline points, in its field, from the loop
# `outline` (field px; see the head).
static func _outline_rms(body: Goo2D, outline: PackedVector2Array) -> float:
	var squares := 0.0
	var points := _outline(body)
	for point: Vector2 in points:
		var at := _field(body, point)
		var best := INF
		for i: int in outline.size():
			var nearest := Geometry2D.get_closest_point_to_segment(at, outline[i], outline[(i + 1) % outline.size()])
			best = minf(best, at.distance_squared_to(nearest))
		squares += best
	return sqrt(squares / points.size())

# The rms offset of `body`'s outline points from the field coordinates `start`
# they had.
static func _track_rms(body: Goo2D, start: PackedVector2Array) -> float:
	var points := _outline(body)
	var squares := 0.0
	for i: int in start.size():
		squares += _field(body, points[i]).distance_squared_to(start[i])
	return sqrt(squares / start.size())

static func _field_coordinates(body: Goo2D) -> PackedVector2Array:
	var out := PackedVector2Array()
	for point: Vector2 in _outline(body):
		out.append(_field(body, point))
	return out

# Sets every bead's velocity to a rigid spin of `spin` rad/s about its centre.
static func _spin(body: Goo2D, spin: float) -> void:
	var centre := body.center()
	for i: int in body.particle_count():
		body.set_bead_velocity(i, (body.bead_position(i) - centre).rotated(PI / 2.0) * spin)

# The worst rms and frame-to-frame jump of a run.
class Worst:
	var rms: float = 0.0
	var jump: float = 0.0
	var _last: float = NAN

	func add(value: float) -> void:
		rms = maxf(rms, value)
		if not is_nan(_last):
			jump = maxf(jump, absf(value - _last))
		_last = value

	func text() -> String:
		return "rms %.3f px, largest jump %.3f px" % [rms, jump]

# A body of `radius` at `at`: round, or a regular polygon of `sides`.
func _body(radius: float, at: Vector2, sides: int = 0) -> Goo2D:
	return world.spawn(radius, at, GooShape.regular(sides, radius) if sides >= 3 else null)

# Resizes `body` from its size to each of `sizes` in turn (`time` s each,
# then `hold` frames), spinning it at 1 rad/s, measuring the outline rms every
# frame. Returns [Worst, the field area at the end over the start's, re-rings,
# the rms at the end].
func _resize_through(body: Goo2D, sizes: Array[float], time: float, hold: int) -> Array:
	await _frames(10)
	_sync(body)
	var outline := _field_coordinates(body)
	var rerings := [0]
	body.rebuilt.connect(func(_old: PackedVector2Array) -> void: rerings[0] += 1)
	var worst := Worst.new()
	for size: float in sizes:
		body.resize(size, time)
		for _frame: int in int(time * 60.0) + hold:
			_spin(body, 1.0)
			await get_tree().physics_frame
			_sync(body)
			worst.add(_outline_rms(body, outline))
	return [worst, GooLoop.signed_area(_field_coordinates(body)) / GooLoop.signed_area(outline), rerings[0],
		_outline_rms(body, outline)]

func _assert_resize(label: String, radius: float, sizes: Array[float], sides: int, time: float,
		want_rerings: bool) -> void:
	_make_world()
	var body := _body(radius, Vector2(600.0, 500.0), sides)
	var result: Array = await _resize_through(body, sizes, time, 60)
	var worst: Worst = result[0]
	print("  %s: during %s; back at its size %.3f px, the field area %.4f of the start's; %d re-rings; bubble_cell %.2f -> pushed %.2f px" % [
		label, worst.text(), result[3], result[1], result[2], body._goo.bubble_cell,
		float(_material(body).get_shader_parameter(&"bubble_cell"))])
	if want_rerings:
		assert_gt(result[2], 1, "%s: re-rung more than once" % label)
	else:
		assert_eq(result[2], 0, "%s: not re-rung" % label)
	assert_lt(worst.rms, MOTION_TOLERANCE, "%s: the outline stays near its place in the field" % label)
	assert_lt(worst.jump, JUMP_TOLERANCE, "%s: no jump" % label)
	assert_lt(result[3], FIELD_TOLERANCE, "%s: back at its size, the outline is where it was in the field" % label)
	assert_almost_eq(result[1], 1.0, 0.05, "%s: and encloses what it did" % label)

func test_a_resize_within_a_bead_count_keeps_the_field_on_the_body() -> void:
	var count := GooTuning.bead_count(30.0)
	var target := 30.0
	while GooTuning.bead_count(target + 0.5) == count and target < 60.0:
		target += 0.5
	await _assert_resize("round 30 -> %.1f px within its count" % target, 30.0, [target, 30.0] as Array[float],
		0, 0.5, false)

func test_a_round_body_grown_and_shrunk_across_re_rings_keeps_the_field_on_it() -> void:
	await _assert_resize("round 30 -> 80 -> 30 px", 30.0, [80.0, 30.0] as Array[float], 0, 1.0, true)

func test_a_square_grown_and_shrunk_across_re_rings_keeps_the_field_on_it() -> void:
	await _assert_resize("square 32 -> 72 -> 32 px", 32.0, [72.0, 32.0] as Array[float], 4, 1.0, true)

func test_a_triangle_shrunk_and_grown_keeps_the_field_on_it() -> void:
	await _assert_resize("triangle 60 -> 30 -> 60 px", 60.0, [30.0, 60.0] as Array[float], 3, 1.0, true)

# Deforms `body` every frame for `frames` frames with `deform` (frame -> [squash,
# axis, area]) and, with `resize_to` > 0, resizes it there at the start;
# returns [outline Worst, track Worst (empty with a resize: re-rings)].
func _deform_through(body: Goo2D, frames: int, deform: Callable, resize_to: float = 0.0) -> Array:
	await _frames(10)
	_sync(body)
	var outline := _field_coordinates(body)
	_outline_start = outline
	if resize_to > 0.0:
		body.resize(resize_to, 1.0)
	var worst := Worst.new()
	var track := Worst.new()
	for frame: int in frames:
		var values: Array = deform.call(frame)
		body.set_rest_deform(values[0], values[1], values[2])
		await get_tree().physics_frame
		_sync(body)
		worst.add(_outline_rms(body, outline))
		if body.particle_count() == outline.size():
			track.add(_track_rms(body, outline))
	return [worst, track]

# A squash between 0.6 and 1.6 and an area between 0.7 and 1.4, each a second
# round, out of phase, its axis turning a quarter turn every 2 s.
static func _pulse(frame: int) -> Array:
	var t := frame / 60.0
	return [1.1 + 0.5 * sin(TAU * t), Vector2.RIGHT.rotated(PI / 4.0 * t), 1.05 + 0.35 * sin(TAU * t + 1.3)]

func test_a_body_squashed_and_pulsed_every_frame_keeps_the_field_on_it() -> void:
	_make_world()
	for sides: int in [0, 4]:
		var body := _body(32.0, Vector2(400.0 + 400.0 * sides / 4, 500.0), sides)
		var result: Array = await _deform_through(body, 180, _pulse)
		var worst: Worst = result[0]
		var basis: Transform2D = _material(body).get_shader_parameter(&"bubble_basis")
		print("  %s 32 px squashed and pulsed: outline %s; track %s; bubble_basis now %s (det %.4f)" % [
			"round" if sides == 0 else "square", worst.text(), (result[1] as Worst).text(), basis, basis.determinant()])
		assert_lt(worst.rms, MOTION_TOLERANCE, "the outline stays near its place in the field")
		assert_lt(worst.jump, JUMP_TOLERANCE, "no jump")
		assert_lt((result[1] as Worst).rms, MOTION_TOLERANCE, "each outline point stays near its place")
		assert_almost_eq(basis.determinant(), 1.0, 1e-4, "the basis keeps the area: the scale is in the cell")
		# Cleared: the beads settle back to their rest places, the field with them.
		body.clear_rest_deform()
		await _frames(60)
		_sync(body)
		var back: Transform2D = body._goo.field_matrix()
		var settled := _track_rms(body, _outline_start)
		print("    cleared, a second later: field matrix %s; the outline %.3f px from its place" % [back, settled])
		assert_lt((back.x - Vector2.RIGHT).length() + (back.y - Vector2.DOWN).length(), 0.05,
			"cleared: back near the identity")
		assert_lt(settled, FIELD_TOLERANCE, "and the outline back on its place")

func test_a_resize_and_a_deformation_together_keep_the_field_on_the_body() -> void:
	_make_world()
	var body := _body(30.0, Vector2(600.0, 500.0))
	var result: Array = await _deform_through(body, 150, _pulse, 64.0)
	var worst: Worst = result[0]
	print("  round 30 -> 64 px while squashed and pulsed: %s" % worst.text())
	assert_lt(worst.rms, MOTION_TOLERANCE, "the outline stays near its place in the field")
	assert_lt(worst.jump, JUMP_TOLERANCE, "no jump")

# The field coordinates, in the field `material` shows (its skin's cell
# `cell`), of the world points `points`.
static func _field_of_points(material: ShaderMaterial, cell: float, points: PackedVector2Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	for point: Vector2 in points:
		out.append(GooSkin.field_point(material, point) * cell)
	return out

# The largest distance between matching points of two lists.
static func _largest_gap(a: PackedVector2Array, b: PackedVector2Array) -> float:
	var gap := 0.0
	for i: int in mini(a.size(), b.size()):
		gap = maxf(gap, a[i].distance_to(b[i]))
	return gap

# Follows the new body `child` from its birth over `frames` frames: how far the
# area its beads enclose in its field strays from what it was at birth (a
# fraction: the material neither grows nor shrinks in the field while the
# body inflates; its shape may change, a cut piece rounding off), and its real
# area's growth; then resizes it to `resize_to` and follows its outline rms.
# Returns [the area's largest stray, the real area's growth, resize Worst].
func _follow_child(child: Goo2D, frames: int, resize_to: float) -> Array:
	_sync(child)
	var start := _field_coordinates(child)
	var start_area := GooLoop.signed_area(start)
	var real_area := child.area()
	var stray := 0.0
	for _frame: int in frames:
		await get_tree().physics_frame
		_sync(child)
		stray = maxf(stray, absf(GooLoop.signed_area(_field_coordinates(child)) / start_area - 1.0))
	var growth := child.area() / real_area
	_sync(child)
	var outline := _field_coordinates(child)
	var resized := Worst.new()
	child.resize(resize_to, 0.5)
	for _frame: int in 45:
		await get_tree().physics_frame
		_sync(child)
		resized.add(_outline_rms(child, outline))
	return [stray, growth, resized]

func test_cut_pieces_take_the_field_without_a_jump_and_grow_with_it() -> void:
	_make_world()
	var body := _body(50.0, Vector2(600.0, 500.0))
	await _frames(10)
	_spin(body, 0.8)
	await _frames(10)
	body.set_rest_deform(1.3, Vector2(1.0, 1.0), 0.9)
	await _frames(10)
	_sync(body)
	var parent := _material(body)
	var parent_cell := body._goo.bubble_cell
	var spawned: Array[Goo2D] = []
	world.body_spawned.connect(func(piece: Goo2D) -> void: spawned.append(piece))
	var points := body.bead_points()
	world.cut(body, 0, points.size() / 2)
	assert_eq(spawned.size(), 2, "cut in two")
	if spawned.size() != 2:
		return
	for piece: Goo2D in spawned:
		_sync(piece)
		var beads := piece.bead_points()
		var gap := _largest_gap(_field_of_points(_material(piece), piece._goo.bubble_cell, beads),
			_field_of_points(parent, parent_cell, beads))
		print("  a cut piece of a squashed, turning body at birth: its beads %.4f px from where the parent's field had them" % gap)
		assert_lt(gap, 0.01, "no jump at birth")
	var result: Array = await _follow_child(spawned[0], 40, spawned[0].radius * 1.4)
	print("  the piece inflating: its real area ×%.3f, its area in the field off by %.4f at most; then resized ×1.4: %s" % [
		result[1], result[0], (result[2] as Worst).text()])
	assert_lt(result[0], 0.05, "the inflating piece's material keeps its size in the field")
	assert_lt((result[2] as Worst).rms, FIELD_TOLERANCE, "and while it is resized")

func test_a_merged_body_takes_the_field_without_a_jump_and_grows_with_it() -> void:
	# Lone bodies (no world: Goo2D.make() and make_merged() as a world would
	# call them), the bigger one squashed and turning, so the field it hands on
	# is deformed.
	var blobs := Node2D.new()
	add_child(blobs)
	var small_radius := GooTuning.radius_at(0.25)
	var big_radius := GooTuning.radius_at(0.3)
	var small := Goo2D.make(small_radius, Vector2(500.0, 500.0), blobs)
	var big := Goo2D.make(big_radius, Vector2(500.0 + small_radius + big_radius, 500.0), blobs)
	await _frames(5)
	big.set_rest_deform(1.3, Vector2(1.0, 0.5), 0.9)
	_spin(big, 0.6)
	await _frames(20)
	_sync(big)
	var parent := _material(big)
	var parent_cell := big._goo.bubble_cell
	var probes := _outline(big)
	var from: Array[Goo2D] = [small, big]
	var merged := Goo2D.make_merged(GooTuning.merged_radius(small_radius, big_radius), blobs, from)
	assert_not_null(merged)
	if merged == null:
		return
	_sync(merged)
	var gap := _largest_gap(_field_of_points(_material(merged), merged._goo.bubble_cell, probes),
		_field_of_points(parent, parent_cell, probes))
	print("  a merged body of a squashed, turning parent at birth: the parent's outline %.4f px from where its field had it" % gap)
	assert_lt(gap, 0.01, "no jump at birth")
	small.queue_free()
	big.queue_free()
	var result: Array = await _follow_child(merged, 40, merged.radius * 1.3)
	var cell := float(_material(merged).get_shader_parameter(&"bubble_cell"))
	print("  the merged body inflating: its real area ×%.3f, its area in the field off by %.4f at most; then resized ×1.3: %s; cell %.2f -> pushed %.2f px" % [
		result[1], result[0], (result[2] as Worst).text(), merged._goo.bubble_cell, cell])
	assert_lt(result[0], 0.05, "the inflating body's material keeps its size in the field")
	assert_lt((result[2] as Worst).rms, FIELD_TOLERANCE, "and while it is resized")

# ---- The two-tone division ----

# The shader's signed distance (px, toward the second colour) of the global
# `point` from `body`'s division, from the uniforms its skin pushed.
static func _across(body: Goo2D, point: Vector2) -> float:
	var material := _material(body)
	var rest := (point - (material.get_shader_parameter(&"center") as Vector2)).rotated(
		-float(material.get_shader_parameter(&"rotation")))
	return rest.dot(material.get_shader_parameter(&"division_axis")) \
		- float(material.get_shader_parameter(&"division_offset"))

# The global point at `cells` of `body`'s bubble field: field_point()'s inverse.
static func _from_field(body: Goo2D, cells: Vector2) -> Vector2:
	var material := _material(body)
	var basis: Transform2D = material.get_shader_parameter(&"bubble_basis")
	var lp := cells * float(material.get_shader_parameter(&"bubble_cell"))
	var rest := basis.basis_xform(lp.rotated(float(material.get_shader_parameter(&"bubble_turn"))))
	return (material.get_shader_parameter(&"bubble_origin") as Vector2) \
		+ rest.rotated(float(material.get_shader_parameter(&"rotation")))

# The division as the field holds it: points of the field on it stay on it, and
# points off it keep their side, while the body grows across re-rings, is
# squashed and turns (the field itself follows the material: the tests above).
func test_a_two_tone_division_stays_on_the_material_through_a_resize_and_a_squash() -> void:
	_make_world()
	var body := _body(30.0, Vector2(600.0, 500.0))
	await _frames(10)
	body.set_two_tone(Color.RED, Color.BLUE, Vector2(0.6, 0.8), 6.0)
	_sync(body)
	# Points of the field on the division and 8 px either side of it.
	var probes: Array[Vector2] = []
	var sides: Array[float] = []
	var axis := Vector2(0.6, 0.8)
	for along: float in [-15.0, 0.0, 15.0]:
		for off: float in [-8.0, 0.0, 8.0]:
			var at := body.center() + (axis * (6.0 + off) + axis.orthogonal() * along).rotated(body.ring_rotation())
			probes.append(GooSkin.field_point(_material(body), at))
			sides.append(off)
	var worst_on := 0.0
	var wrong_side := 0
	body.resize(60.0, 0.8)
	var rerings := [0]
	body.rebuilt.connect(func(_old: PackedVector2Array) -> void: rerings[0] += 1)
	for frame: int in 90:
		body.set_rest_deform(1.0 + 0.4 * sin(TAU * frame / 60.0), Vector2(1.0, -0.3), 1.0 + 0.2 * sin(TAU * frame / 45.0))
		_spin(body, 0.7)
		await get_tree().physics_frame
		_sync(body)
		for k: int in probes.size():
			var across := _across(body, _from_field(body, probes[k]))
			if sides[k] == 0.0:
				worst_on = maxf(worst_on, absf(across))
			elif signf(across) != signf(sides[k]) or absf(across) < 2.0:
				wrong_side += 1
	print("  a two-tone body grown 30 -> 60 px across %d re-rings while squashed, pulsed and turning: the field's points on the division %.4f px off it at worst; %d probe-frames off their side" % [
		rerings[0], worst_on, wrong_side])
	assert_gt(rerings[0], 0, "re-rung")
	assert_lt(worst_on, 0.01, "the division stays where the field (the material) has it")
	assert_eq(wrong_side, 0, "and the points off it keep their side")

# ---- What following costs ----

func test_what_a_measure_of_the_field_costs() -> void:
	_make_world()
	var round_body := _body(30.0, Vector2(400.0, 500.0))
	var square := _body(100.0, Vector2(900.0, 500.0), 4)
	await _frames(5)
	for body: Goo2D in [round_body, square]:
		var turn := body.ring_rotation()
		body._capture_field_refs(turn, body.bead_radius())
		var started := Time.get_ticks_usec()
		for _i: int in 1000:
			body._measure_field(turn, 0.0)
		var measure := (Time.get_ticks_usec() - started) / 1000.0
		started = Time.get_ticks_usec()
		for _i: int in 1000:
			body.ring_rotation()
		print("  a measure of the field of a body of %d beads: %.1f µs (its ring_rotation() alone: %.1f µs)" % [
			body.particle_count(), measure, (Time.get_ticks_usec() - started) / 1000.0])
	assert_true(true)

# ---- A plain body draws as before ----

func test_plain_bodies_keep_the_identity_through_a_fall_a_bounce_a_merge_and_a_split() -> void:
	_make_world(true, false)
	_floor(900.0)
	var radius := GooTuning.radius_at(0.25)
	var bodies: Array[Goo2D] = [_body(radius, Vector2(500.0, 600.0)), _body(radius, Vector2(510.0, 400.0))]
	var spawned_ids := {}
	for body: Goo2D in bodies:
		spawned_ids[body.id] = true
	var merges := [0]
	var splits := [0]
	world.merged.connect(func(_r: float, _p: Vector2) -> void: merges[0] += 1)
	world.split.connect(func(_a: float, _b: float, _p: Vector2) -> void: splits[0] += 1)
	var not_identity: Array[String] = []
	var largest_scale := 0.0
	var cut := false
	for frame: int in 240:
		await get_tree().physics_frame
		for body: Goo2D in world.bodies():
			_sync(body)
			var material := _material(body)
			var pushed := float(material.get_shader_parameter(&"bubble_cell"))
			if not spawned_ids.has(body.id):
				# A merged or cut body: its field follows its inflate.
				largest_scale = maxf(largest_scale, absf(pushed / body._goo.bubble_cell - 1.0))
				continue
			if material.get_shader_parameter(&"bubble_basis") != Transform2D.IDENTITY:
				not_identity.append("frame %d body %d basis %s" % [frame, body.id, material.get_shader_parameter(&"bubble_basis")])
			if material.get_shader_parameter(&"division_axis") != Vector2.RIGHT \
					or float(material.get_shader_parameter(&"division_offset")) != 0.0:
				not_identity.append("frame %d body %d division" % [frame, body.id])
			if pushed != maxf(body._goo.bubble_cell, 1.0):
				not_identity.append("frame %d body %d cell %f of %f" % [frame, body.id, pushed, body._goo.bubble_cell])
			if body._goo.field_matrix() != Transform2D.IDENTITY:
				not_identity.append("frame %d body %d field matrix" % [frame, body.id])
		if not cut and merges[0] > 0 and frame > 150:
			var merged := world.bodies()[0]
			var points := merged.bead_points()
			world.cut(merged, 0, points.size() / 2)
			cut = true
	print("  plain bodies: %d merges, %d splits; spawned bodies' frames off the identity: %d; merged / cut bodies' cell scale off 1 by %.4f at most (their inflate)" % [
		merges[0], splits[0], not_identity.size(), largest_scale])
	assert_gt(merges[0], 0, "a merge happened")
	assert_gt(splits[0], 0, "a split happened")
	assert_eq(not_identity.slice(0, 8), [] as Array[String], "the identity basis, the division as set, the cell as born")
