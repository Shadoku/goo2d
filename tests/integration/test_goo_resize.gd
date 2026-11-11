extends TestCase
## Goo2D.resize() and set_rest_deform(): a live body changes size, round or
## polygon, smoothly, while moving, resting, held or squeezed, from the smallest
## size to the largest and back, and deforms its rest outline every frame. Its
## ring is rebuilt in place only where its bead count must change (`rebuilt`,
## GooWorld2D.body_rebuilt): the same node, id, tags, colour, children; its
## velocity and grabs kept. Played on a wide floor of its own (no blades, no
## wedge) under gravity, or in a world with gravity_scale 0; at unit 1 unless a
## test says otherwise (GooTuning.unit is reset after each). Every measured
## number is printed.

## Where the floor's top face is.
const FLOOR_Y: float = 1000.0
## Area within this fraction of the target counts as reached.
const AREA_TOLERANCE: float = 0.1

var world: GooWorld2D
var splits: int = 0
var merges: int = 0
var rebuilds: Array[Goo2D] = []

## A world whose bodies never merge (stacked ones of one size would).
class NoMergeWorld extends GooWorld2D:
	func may_merge(_a: Goo2D, _b: Goo2D) -> bool:
		return false

func before_each() -> void:
	GooTuning.unit = 1.0
	splits = 0
	merges = 0
	rebuilds.clear()

func after_each() -> void:
	GooTuning.unit = 1.0

# A world (`kind`'s instance) added to the test, counting its splits, merges
# and rebuilt bodies; with `floor_on`, over a wide floor; with `zero_g`, no
# gravity.
func _make_world(floor_on: bool, zero_g: bool = false, plain: bool = true) -> GooWorld2D:
	if floor_on:
		var ground := StaticBody2D.new()
		var collision := CollisionShape2D.new()
		var rect := RectangleShape2D.new()
		rect.size = Vector2(8000.0, 100.0)
		collision.shape = rect
		ground.add_child(collision)
		ground.position = Vector2(960.0, FLOOR_Y + 50.0)
		add_child(ground)
	world = GooWorld2D.new() if plain else NoMergeWorld.new()
	if zero_g:
		world.gravity_scale = 0.0
	add_child(world)
	world.split.connect(func(_a: float, _b: float, _p: Vector2) -> void: splits += 1)
	world.merged.connect(func(_r: float, _p: Vector2) -> void: merges += 1)
	world.body_rebuilt.connect(func(body: Goo2D) -> void: rebuilds.append(body))
	return world

# A static wall (layer 1) of `size` centred on `centre`.
func _wall(centre: Vector2, size: Vector2) -> void:
	var wall := StaticBody2D.new()
	var collision := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = size
	collision.shape = rect
	wall.add_child(collision)
	wall.position = centre
	add_child(wall)

func _frames(n: int) -> void:
	for _frame: int in n:
		await get_tree().physics_frame

# The body's extent along the unit `axis` (world space): its beads' spread
# along it plus a bead diameter.
static func _extent(body: Goo2D, axis: Vector2) -> float:
	var low := INF
	var high := -INF
	for point: Vector2 in body.bead_points():
		low = minf(low, point.dot(axis))
		high = maxf(high, point.dot(axis))
	return high - low + 2.0 * body.bead_radius()

static func _finite(body: Goo2D) -> bool:
	for point: Vector2 in body.bead_points():
		if not point.is_finite():
			return false
	return true

# True if the body's skin is drawn: its polygon (each of its sub-polygons)
# triangulates, as Polygon2D needs to draw it.
static func _drawable(body: Goo2D) -> bool:
	var skin := body.get_node("Skin") as Polygon2D
	if skin.polygon.size() < 3:
		return false
	if skin.polygons.is_empty():
		return not Geometry2D.triangulate_polygon(skin.polygon).is_empty()
	for indices: PackedInt32Array in skin.polygons:
		var piece := PackedVector2Array()
		for i: int in indices:
			piece.append(skin.polygon[i])
		if Geometry2D.triangulate_polygon(piece).is_empty():
			return false
	return true

static func _ones(flags: PackedByteArray) -> int:
	return flags.count(1)

func test_a_resize_within_one_bead_count_reaches_its_area() -> void:
	_make_world(true)
	var body := world.spawn(40.0, Vector2(900.0, FLOOR_Y - 40.0))
	await _frames(30)
	var heard: Array = []
	body.resized.connect(func(old: float, new: float) -> void: heard.append([old, new]))
	var count := body.particle_count()
	assert_eq(GooTuning.bead_count(44.0), count, "precondition: 40 and 44 px have one count")
	body.resize(44.0)
	assert_eq(heard, [[40.0, 44.0]], "resized(old, new)")
	assert_eq(body.radius, 44.0, "radius is the new size at once")
	assert_true(body.is_resizing())
	await _frames(60)
	var ratio := body.area() / (PI * 44.0 * 44.0)
	print("    40 -> 44 px on the floor: area %.3f of the new circle's, eased radius %.2f" % [ratio, body.eased_radius()])
	assert_almost_eq(ratio, 1.0, AREA_TOLERANCE, "the area of the new size")
	assert_false(body.is_resizing())
	assert_almost_eq(body.eased_radius(), 44.0, 0.0001)
	assert_eq(body.particle_count(), count, "no rebuild")
	assert_eq(rebuilds.size(), 0)
	assert_almost_eq(float(body.tuning["target_area"]), PI * 44.0 * 44.0, 0.01, "its tuning is the new size's")

func test_a_resize_across_bead_counts_rebuilds_the_ring_in_place() -> void:
	_make_world(false, true)
	var body := world.spawn(30.0, Vector2(900.0, 500.0), null, [&"earth"])
	body.color = Color.ORANGE
	body.name = "Creature"
	var eye := Node2D.new()
	eye.name = "Eye"
	body.add_child(eye)
	await _frames(5)
	var node_id := body.get_instance_id()
	var id := body.id
	var heard: Array[PackedVector2Array] = []
	body.rebuilt.connect(func(old_points: PackedVector2Array) -> void: heard.append(old_points))
	body.resize(120.0, 1.0)
	await _frames(150)
	print("    30 -> 120 px floating: %d rebuilds, %d beads (GooTuning: %d), area %.3f"
		% [heard.size(), body.particle_count(), GooTuning.bead_count(120.0), body.area() / (PI * 120.0 * 120.0)])
	assert_gt(heard.size(), 0, "rebuilt")
	assert_eq(rebuilds.size(), heard.size(), "the world's body_rebuilt with each")
	assert_eq(body.particle_count(), GooTuning.bead_count(120.0), "the new size's bead count")
	assert_eq(body.get_instance_id(), node_id, "the same node")
	assert_eq(body.id, id, "the same id")
	assert_eq(body.tags, [&"earth"])
	assert_eq(body.color, Color.ORANGE)
	assert_eq(body.name, &"Creature")
	assert_eq(body.get_node_or_null("Eye"), eye, "its children")
	assert_has(world.bodies(), body)
	assert_eq(world.bodies().size(), 1)
	assert_almost_eq(body.area() / (PI * 120.0 * 120.0), 1.0, AREA_TOLERANCE)
	assert_eq(splits + merges, 0)

func test_a_rebuild_keeps_the_bodys_velocity() -> void:
	_make_world(false, true)
	var body := world.spawn(40.0, Vector2(300.0, 500.0))
	await _frames(2)
	body.set_velocity(Vector2(300.0, 0.0))
	var compared := [0]
	var worst := [0.0]
	var last := [body.average_velocity()]
	body.rebuilt.connect(func(_old: PackedVector2Array) -> void:
		var now := body.average_velocity()
		worst[0] = maxf(worst[0], now.distance_to(last[0]) / last[0].length())
		compared[0] += 1)
	body.resize(100.0, 0.5)
	for frame: int in 90:
		last[0] = body.average_velocity()
		await get_tree().physics_frame
	print("    40 -> 100 px at 300 px/s: %d rebuilds, worst change of the mean velocity across one %.1f%%, %.0f px/s at the end"
		% [compared[0], worst[0] * 100.0, body.average_velocity().length()])
	assert_gt(compared[0], 0, "precondition: rebuilt")
	assert_lt(worst[0], 0.1, "the mean velocity kept within 10% across a rebuild")
	# Linear damping (about 0.5 /s for the smallest body) slows it on its own.
	assert_gt(body.average_velocity().x, 120.0, "still flying")

# Sweeps bodies of each shape from the smallest size to the largest and back
# over 4 s (2 s each way), checking every frame; then compares each with a body
# spawned at the smallest size.
func _sweep(on_floor: bool) -> void:
	timeout_sec = 30.0
	_make_world(on_floor, not on_floor)
	var smallest := GooTuning.min_radius()
	var largest := GooTuning.max_radius()
	var shapes: Array[GooShape] = [null, GooShape.regular(4, smallest), GooShape.regular(3, smallest)]
	var bodies: Array[Goo2D] = []
	for k: int in shapes.size():
		var x := 400.0 + 560.0 * k * GooTuning.unit
		var y := FLOOR_Y - smallest - 2.0 if on_floor else 500.0 * GooTuning.unit
		bodies.append(world.spawn(smallest, Vector2(x, y), shapes[k]))
	await _frames(20)
	var corner_counts: Array[int] = []
	for body: Goo2D in bodies:
		corner_counts.append(_ones(body.corner_flags()))
		body.resize(largest, 2.0)
	var worst_area := 0.0
	var undrawable := 0
	var nonfinite := 0
	for frame: int in 280:
		if frame == 125:
			for body: Goo2D in bodies:
				body.resize(smallest, 2.0)
		await get_tree().physics_frame
		for body: Goo2D in bodies:
			if not _finite(body):
				nonfinite += 1
				continue
			worst_area = maxf(worst_area, absf(body.area() / body.target_area - 1.0))
			if frame % 5 == 0 and not _drawable(body):
				undrawable += 1
	await _frames(70)
	print("    sweep %s at unit %.1f: worst area off its eased target %.1f%%, %d undrawable skins, %d frames not finite, %d rebuilds, %d splits, %d merges"
		% ["on the floor" if on_floor else "floating", GooTuning.unit, worst_area * 100.0, undrawable, nonfinite,
		rebuilds.size(), splits, merges])
	assert_eq(nonfinite, 0, "every bead finite")
	assert_lt(worst_area, 0.35, "the area within 35% of its eased target every frame")
	assert_eq(undrawable, 0, "the skin drawable")
	assert_eq(splits, 0, "no split")
	assert_eq(merges, 0, "no merge")
	assert_eq(world.bodies().size(), 3)
	for k: int in bodies.size():
		var body := bodies[k]
		var fresh := world.spawn(smallest, Vector2(-2000.0 - 600.0 * k, 0.0), shapes[k])
		var label := "shape %d" % k
		assert_eq(body.particle_count(), fresh.particle_count(), label + " bead count of a fresh body")
		assert_eq(body.tuning.keys(), fresh.tuning.keys(), label + " tuning keys")
		for key: String in fresh.tuning:
			assert_almost_eq(float(body.tuning[key]), float(fresh.tuning[key]), 0.001 * maxf(absf(float(fresh.tuning[key])), 1.0),
				label + " " + key)
		assert_almost_eq(body.target_area / fresh.target_area, 1.0, 0.001, label + " target area")
		assert_almost_eq(body.area() / fresh.target_area, 1.0, 0.15, label + " area")
		assert_eq(_ones(body.corner_flags()), corner_counts[k], label + " corners")
		assert_eq(body.shape.is_round(), shapes[k] == null, label + " shape kind")
		world.despawn(fresh)

func test_a_sweep_on_the_floor_from_smallest_to_largest_and_back() -> void:
	await _sweep(true)

func test_a_sweep_floating_from_smallest_to_largest_and_back() -> void:
	await _sweep(false)

func test_a_sweep_on_the_floor_at_half_unit() -> void:
	GooTuning.unit = 0.5
	await _sweep(true)

func test_a_new_target_every_frame_is_stable() -> void:
	timeout_sec = 20.0
	_make_world(true)
	# One body hovering across a bead count's boundary, one swinging over six.
	var boundary := GooTuning.radius_at(0.25)
	var hover := world.spawn(boundary, Vector2(500.0, FLOOR_Y - boundary))
	var swing := world.spawn(40.0, Vector2(1300.0, FLOOR_Y - 40.0))
	await _frames(10)
	var hover_rebuilds := [0]
	var swing_rebuilds := [0]
	hover.rebuilt.connect(func(_old: PackedVector2Array) -> void: hover_rebuilds[0] += 1)
	swing.rebuilt.connect(func(_old: PackedVector2Array) -> void: swing_rebuilds[0] += 1)
	var worst := 0.0
	for frame: int in 180:
		var t := frame / 60.0
		hover.resize(GooTuning.radius_at(0.25 + 0.02 * sin(TAU * t)))
		swing.resize(70.0 + 30.0 * sin(TAU * 0.5 * t))
		await get_tree().physics_frame
		for body: Goo2D in [hover, swing]:
			assert_true(_finite(body), "finite")
			worst = maxf(worst, absf(body.area() / body.target_area - 1.0))
	var crossings := 0
	for k: int in range(GooTuning.bead_count(40.0), GooTuning.bead_count(100.0)):
		crossings += 1
	print("    a new target every frame for 3 s: hovering at a boundary %d rebuilds, swinging 40-100 px %d (%d boundaries in its range), worst area off target %.1f%%"
		% [hover_rebuilds[0], swing_rebuilds[0], crossings, worst * 100.0])
	assert_lt(hover_rebuilds[0], 3, "hovering at a boundary hardly rebuilds")
	assert_lt(swing_rebuilds[0], crossings * 3 + 2, "swinging rebuilds about once per boundary crossed")
	assert_lt(worst, 0.35)
	assert_eq(splits + merges, 0)

func test_a_grabbed_body_resized_stays_held() -> void:
	timeout_sec = 15.0
	_make_world(true)
	var body := world.spawn(40.0, Vector2(900.0, FLOOR_Y - 40.0))
	await _frames(20)
	var top := Vector2(0.0, INF)
	for point: Vector2 in body.bead_points():
		if point.y < top.y:
			top = point
	var handle := world.grab(body, top)
	var target := top + Vector2(0.0, -300.0)
	world.move_grab(handle, target)
	await _frames(40)
	body.resize(90.0, 1.0)
	await _frames(120)
	var off := world.grab_point(handle).distance_to(target)
	print("    held by its top and grown 40 -> 90 px: %d rebuilds, grab point %.1f px off its point, area %.3f"
		% [rebuilds.size(), off, body.area() / (PI * 90.0 * 90.0)])
	assert_gt(rebuilds.size(), 0, "precondition: rebuilt")
	assert_true(world.grabbed(body), "still held")
	assert_lt(off, 2.0 * body.bead_radius(), "near the grab's point")
	assert_gt(body.area() / (PI * 90.0 * 90.0), 0.8, "and grown")
	assert_eq(splits, 0)
	# A body held at its centre grows too (the grab's offsets scale with it).
	var held := world.spawn(40.0, Vector2(400.0, 400.0))
	await _frames(2)
	var centre_handle := world.grab(held, held.center())
	held.resize(80.0, 1.0)
	await _frames(100)
	print("    held at its centre and grown 40 -> 80 px: area %.3f" % (held.area() / (PI * 80.0 * 80.0)))
	assert_gt(held.area() / (PI * 80.0 * 80.0), 0.85)
	assert_true(world.grabbed(held))
	assert_lt(world.grab_point(centre_handle).distance_to(Vector2(400.0, 400.0)), 2.0 * held.bead_radius())

func test_a_settled_body_wakes_to_resize() -> void:
	timeout_sec = 15.0
	_make_world(true)
	var body := world.spawn(60.0, Vector2(900.0, FLOOR_Y - 60.0))
	for frame: int in 480:
		await get_tree().physics_frame
		if body.settled:
			break
	assert_true(body.settled, "precondition: settled")
	body.resize(70.0)
	await _frames(2)
	assert_false(body.settled, "woken")
	await _frames(60)
	assert_almost_eq(body.area() / (PI * 70.0 * 70.0), 1.0, AREA_TOLERANCE, "and grown")

func test_a_growing_body_lifts_the_one_on_it() -> void:
	timeout_sec = 15.0
	_make_world(true, false, false)
	# Squares, so the upper rests on a flat face instead of rolling off.
	var lower := world.spawn(40.0, Vector2(900.0, FLOOR_Y - 40.0), GooShape.regular(4, 40.0))
	var upper := world.spawn(40.0, Vector2(900.0, FLOOR_Y - 115.0), GooShape.regular(4, 40.0))
	await _frames(90)
	var before := upper.center().y
	lower.resize(90.0, 1.0)
	var inside := 0
	for frame: int in 150:
		await get_tree().physics_frame
		inside = maxi(inside, upper.beads_inside(lower, 0.0) + lower.beads_inside(upper, 0.0))
	var lifted := before - upper.center().y
	print("    lower body grown 40 -> 90 px: the upper lifted %.1f px, most beads inside the other %d" % [lifted, inside])
	assert_gt(lifted, 0.6 * sqrt(PI) * 50.0, "lifted by most of the growth of the lower's side (√π × 50 = 89 px; a bigger body sags more)")
	assert_lt(upper.center().y, lower.center().y, "still on top")
	assert_eq(inside, 0, "nothing gets inside the other")
	assert_true(_finite(upper) and _finite(lower))

func test_a_body_growing_in_a_narrow_gap_stays_stable() -> void:
	timeout_sec = 15.0
	_make_world(true)
	# Two walls 120 px apart, the body grown to 200 px across between them.
	_wall(Vector2(840.0, FLOOR_Y - 300.0), Vector2(40.0, 600.0))
	_wall(Vector2(1000.0 + 0.0, FLOOR_Y - 300.0), Vector2(40.0, 600.0))
	var body := world.spawn(40.0, Vector2(920.0, FLOOR_Y - 40.0))
	await _frames(20)
	body.resize(100.0, 1.0)
	var fastest := 0.0
	var escaped := 0
	for frame: int in 180:
		await get_tree().physics_frame
		assert_true(_finite(body), "finite")
		for velocity: Vector2 in body.bead_velocities():
			fastest = maxf(fastest, velocity.length())
		for point: Vector2 in body.bead_points():
			if point.x < 860.0 - 1.0 or point.x > 980.0 + 1.0:
				escaped += 1
	print("    grown to 200 px across in a 120 px gap for 3 s: fastest bead %.0f px/s, %d bead-frames through a wall, %d splits, height %.0f px"
		% [fastest, escaped, splits, _extent(body, Vector2.UP)])
	assert_eq(escaped, 0, "no bead through a wall")
	assert_lt(fastest, 1500.0, "no explosion")
	assert_eq(splits, 0)
	assert_gt(_extent(body, Vector2.UP), 150.0, "it grows up the gap instead")

func test_shrinking_to_the_smallest_size_does_not_split() -> void:
	timeout_sec = 15.0
	_make_world(true)
	var body := world.spawn(150.0, Vector2(900.0, FLOOR_Y - 150.0))
	await _frames(30)
	body.resize(GooTuning.min_radius(), 0.0)
	await _frames(150)
	var ratio := body.area() / (PI * GooTuning.min_radius() * GooTuning.min_radius())
	print("    150 -> 28 px as fast as allowed (%.2f s): %d splits, area %.3f, %d beads" %
		[GooTuning.resize_time(150.0, GooTuning.min_radius(), 0.0), splits, ratio, body.particle_count()])
	assert_eq(splits, 0)
	assert_almost_eq(ratio, 1.0, 0.15)
	assert_eq(body.particle_count(), GooTuning.MIN_BEADS)

func test_a_resized_square_stays_a_square_and_cuts_as_one() -> void:
	timeout_sec = 15.0
	_make_world(true)
	var body := world.spawn(40.0, Vector2(900.0, FLOOR_Y - 40.0), GooShape.regular(4, 40.0))
	await _frames(20)
	body.resize(70.0, 0.5)
	await _frames(90)
	print("    square 40 -> 70 px: %d beads, %d corners, %d rebuilds" % [body.particle_count(), _ones(body.corner_flags()), rebuilds.size()])
	assert_false(body.shape.is_round())
	assert_eq(body.shape.outline.size(), 4, "a square's outline")
	assert_almost_eq(body.shape.radius(), 70.0, 0.01)
	assert_eq(_ones(body.corner_flags()), 4, "four corners")
	assert_eq(body.particle_count(), GooTuning.resize_count(body.shape, 70.0))
	var made: Array[Goo2D] = []
	world.body_split.connect(func(_id: int, pieces: Array[Goo2D]) -> void: made.append_array(pieces))
	world.cut(body, 0, body.particle_count() / 2)
	assert_eq(made.size(), 2, "cut in two")
	for piece: Goo2D in made:
		assert_false(piece.shape.is_round(), "each piece a polygon")

func test_resized_squares_merge_as_polygons() -> void:
	timeout_sec = 15.0
	_make_world(true)
	var a := world.spawn(40.0, Vector2(800.0, FLOOR_Y - 40.0), GooShape.regular(4, 40.0))
	var b := world.spawn(40.0, Vector2(1100.0, FLOOR_Y - 40.0), GooShape.regular(4, 40.0))
	await _frames(10)
	a.resize(55.0, 0.5)
	b.resize(55.0, 0.5)
	await _frames(60)
	var fused: Array[Goo2D] = []
	world.bodies_merged.connect(func(_ids: PackedInt32Array, body: Goo2D) -> void: fused.append(body))
	# Pushed into each other, flat face to flat face.
	for frame: int in 120:
		if fused.is_empty():
			if is_instance_valid(a) and a.get_parent() == world:
				a.apply_force(Vector2(4000.0, 0.0))
			if is_instance_valid(b) and b.get_parent() == world:
				b.apply_force(Vector2(-4000.0, 0.0))
		await get_tree().physics_frame
	assert_eq(fused.size(), 1, "merged")
	if not fused.is_empty():
		assert_false(fused[0].shape.is_round(), "into a fused polygon")

func test_merging_reads_the_new_radius() -> void:
	timeout_sec = 15.0
	_make_world(true)
	var small := world.spawn(40.0, Vector2(860.0, FLOOR_Y - 40.0))
	var big := world.spawn(60.0, Vector2(965.0, FLOOR_Y - 60.0))
	await _frames(60)
	assert_eq(merges, 0, "precondition: 40 and 60 px do not merge")
	small.resize(60.0, 0.5)
	for frame: int in 120:
		if merges > 0:
			break
		if is_instance_valid(small) and small.get_parent() == world:
			small.apply_force(Vector2(2000.0, 0.0))
		await get_tree().physics_frame
	assert_eq(merges, 1, "once it is 60 px they merge")

func test_a_merging_body_resized_still_merges() -> void:
	timeout_sec = 10.0
	_make_world(true)
	var a := world.spawn(40.0, Vector2(860.0, FLOOR_Y - 40.0))
	var b := world.spawn(40.0, Vector2(940.0, FLOOR_Y - 40.0))
	for frame: int in 60:
		await get_tree().physics_frame
		if a.merging:
			break
	assert_true(a.merging, "precondition: merging")
	a.resize(44.0)
	await _frames(60)
	assert_eq(merges, 1)
	assert_eq(world.bodies().size(), 1)

func test_a_piece_still_inflating_resizes_without_a_jump() -> void:
	_make_world(false, true)
	var body := world.spawn(60.0, Vector2(900.0, 500.0))
	await _frames(5)
	var made: Array[Goo2D] = []
	world.body_split.connect(func(_id: int, pieces: Array[Goo2D]) -> void: made.append_array(pieces))
	world.cut(body, 0, body.particle_count() / 2)
	assert_eq(made.size(), 2, "precondition: cut")
	await _frames(3)
	var piece := made[0]
	assert_lt(piece.rest_blend, 1.0, "precondition: still easing into its rest lengths")
	var before := piece.target_area
	piece.resize(50.0, 0.5)
	await _frames(1)
	print("    a piece inflating, resized: target area %.0f -> %.0f px² over a frame" % [before, piece.target_area])
	assert_lt(absf(piece.target_area / before - 1.0), 0.08, "no jump of the target area")
	await _frames(60)
	assert_almost_eq(piece.rest_blend, 1.0, 0.0001, "its rest lengths eased in")
	assert_almost_eq(piece.area() / (PI * 50.0 * 50.0), 1.0, AREA_TOLERANCE)

func test_a_squash_flattens_the_body_along_its_axis() -> void:
	_make_world(false, true)
	var body := world.spawn(60.0, Vector2(900.0, 500.0))
	await _frames(10)
	var axis := Vector2.RIGHT.rotated(body.ring_rotation())
	var along := _extent(body, axis)
	var across := _extent(body, axis.orthogonal())
	body.set_rest_deform(0.6, Vector2.RIGHT)
	assert_eq(body.rest_deform()["squash"], 0.6)
	await _frames(60)
	axis = Vector2.RIGHT.rotated(body.ring_rotation())
	var squashed_along := _extent(body, axis) / along
	var squashed_across := _extent(body, axis.orthogonal()) / across
	body.clear_rest_deform()
	await _frames(60)
	axis = Vector2.RIGHT.rotated(body.ring_rotation())
	var back := _extent(body, axis) / along
	print("    squash 0.6: %.3f as long along its axis, %.3f across; cleared %.3f; area %.3f"
		% [squashed_along, squashed_across, back, body.area() / (PI * 3600.0)])
	assert_lt(squashed_along, 0.8, "shorter along the axis")
	assert_gt(squashed_across, 1.2, "longer across it")
	assert_almost_eq(back, 1.0, 0.05, "cleared, back to round")
	assert_eq(body.particle_count(), GooTuning.bead_count(60.0), "never rebuilt")
	assert_eq(rebuilds.size(), 0)

func test_an_area_pulse_changes_the_area() -> void:
	_make_world(false, true)
	var body := world.spawn(60.0, Vector2(900.0, 500.0))
	await _frames(10)
	body.set_rest_deform(1.0, Vector2.RIGHT, 1.5)
	await _frames(60)
	var big := body.area() / (PI * 3600.0)
	body.set_rest_deform(1.0, Vector2.RIGHT, 0.7)
	await _frames(60)
	var small := body.area() / (PI * 3600.0)
	body.set_rest_deform(1.0, Vector2.RIGHT, 9.0)
	assert_eq(body.rest_deform()["area_scale"], GooTuning.DEFORM_AREA_MAX, "clamped")
	print("    area scale 1.5: area %.3f; 0.7: %.3f" % [big, small])
	assert_almost_eq(big, 1.5, 1.5 * AREA_TOLERANCE)
	assert_almost_eq(small, 0.7, 0.7 * AREA_TOLERANCE)
	assert_eq(splits, 0)

# A squash oscillated at 2 Hz for 5 s on a body resting on the floor and one
# floating: stable, never split.
func test_a_squash_oscillated_for_five_seconds_is_stable() -> void:
	timeout_sec = 20.0
	_make_world(true)
	var resting := world.spawn(50.0, Vector2(600.0, FLOOR_Y - 50.0))
	var floating := world.spawn(50.0, Vector2(1300.0, 300.0))
	floating.set_velocity(Vector2.ZERO)
	await _frames(30)
	var worst := 0.0
	var turn_jump := 0.0
	var last_turn := [resting.ring_rotation(), floating.ring_rotation()]
	for frame: int in 300:
		var t := frame / 60.0
		var squash := 1.0 + 0.4 * sin(TAU * 2.0 * t)
		resting.set_rest_deform(squash, Vector2.RIGHT, 1.0 + 0.2 * sin(TAU * 2.0 * t + 1.0))
		floating.set_rest_deform(squash, Vector2.UP, 1.0)
		if floating.center().y > FLOOR_Y - 200.0:
			floating.apply_force(Vector2(0.0, -2.0 * GooTuning.gravity() * floating.body_mass()))
		await get_tree().physics_frame
		var bodies: Array[Goo2D] = [resting, floating]
		for k: int in 2:
			var body := bodies[k]
			assert_true(_finite(body), "finite")
			worst = maxf(worst, absf(body.area() / body.target_area - 1.0))
			var turn := body.ring_rotation()
			turn_jump = maxf(turn_jump, absf(wrapf(turn - last_turn[k], -PI, PI)))
			last_turn[k] = turn
	print("    squash at 2 Hz for 5 s: worst area off target %.1f%%, biggest turn in a frame %.3f rad, %d splits"
		% [worst * 100.0, turn_jump, splits])
	assert_eq(splits, 0)
	assert_lt(worst, 0.35)
	assert_lt(turn_jump, 0.2, "ring_rotation() does not jump")
	assert_true(_drawable(resting) and _drawable(floating))

func test_a_squash_during_a_resize_composes() -> void:
	_make_world(false, true)
	var body := world.spawn(40.0, Vector2(900.0, 500.0))
	await _frames(5)
	body.resize(60.0, 1.0)
	await _frames(10)
	body.set_rest_deform(0.7, Vector2.RIGHT)
	await _frames(90)
	var axis := Vector2.RIGHT.rotated(body.ring_rotation())
	var ratio := _extent(body, axis) / _extent(body, axis.orthogonal())
	var area := body.area() / (PI * 3600.0)
	print("    resized 40 -> 60 px with a squash of 0.7 on top: along / across %.3f, area %.3f" % [ratio, area])
	assert_almost_eq(area, 1.0, AREA_TOLERANCE, "the new size's area")
	assert_lt(ratio, 0.7, "squashed (0.7 / 1.43 = 0.49 in the rest outline)")
	assert_eq(body.particle_count(), GooTuning.bead_count(60.0))

func test_ring_rotation_is_continuous_through_a_rebuild_and_a_squash() -> void:
	_make_world(false, true)
	var body := world.spawn(40.0, Vector2(900.0, 500.0))
	await _frames(2)
	# Spinning: each bead moving around the centre at 2 rad/s.
	var centre := body.center()
	for i: int in body.particle_count():
		body.set_bead_velocity(i, (body.bead_position(i) - centre).orthogonal() * -2.0)
	body.resize(140.0, 1.5)
	var last := body.ring_rotation()
	var worst := 0.0
	for frame: int in 120:
		body.set_rest_deform(1.0 + 0.3 * sin(frame * 0.2), Vector2.RIGHT)
		await get_tree().physics_frame
		var turn := body.ring_rotation()
		worst = maxf(worst, absf(wrapf(turn - last, -PI, PI)))
		last = turn
	print("    spinning, grown 40 -> 140 px under a squash: %d rebuilds, biggest turn in a frame %.3f rad" % [rebuilds.size(), worst])
	assert_gt(rebuilds.size(), 0, "precondition: rebuilt")
	assert_lt(worst, 0.2, "no jump")

func test_out_of_range_sizes_are_clamped_with_a_warning() -> void:
	_make_world(false, true)
	var body := world.spawn(40.0, Vector2(900.0, 500.0))
	await _frames(2)
	body.resize(1000.0)
	assert_eq(body.radius, GooTuning.max_radius(), "clamped to the largest")
	body.resize(1.0)
	assert_eq(body.radius, GooTuning.min_radius(), "clamped to the smallest")
	var unbuilt := Goo2D.new()
	add_child(unbuilt)
	unbuilt.resize(50.0)
	assert_eq(unbuilt.radius, 50.0, "an unbuilt body takes the radius it will be built at")
	assert_eq(unbuilt.particle_count(), 0)
