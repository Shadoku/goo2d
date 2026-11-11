extends TestCase
## A Goo2D built by Goo2D.make(): a pressure ring, a closed ring of beads in
## its kernel held by skin and bending constraints, inflated toward its
## circle's area and pulled weakly toward its rest shape. It lands
## where it was asked in its size's colour, takes impulses and velocities on
## every bead, holds its area under load, flattens a little, sleeps when calm
## and wakes on contact, reports a body it touches once per frame while
## touching (`touched`, outside the physics flush), squeezes through gaps without folding through itself,
## and rebuilds two rings into one for merges. Every measured number is printed.

const STEP: float = 1.0 / 60.0
const SPAWN := Vector2(360.0, 500.0)

## Radii the printed numbers were first measured at: the old fixed sizes 0, 1,
## 2 and 6 (28 × 1.3^n).
var r0: float = GooTuning.MIN_RADIUS
var r1: float = GooTuning.radius_at(1.0 / 7.0)
var r2: float = GooTuning.radius_at(2.0 / 7.0)
var r6: float = GooTuning.radius_at(6.0 / 7.0)

func test_the_goo_needs_no_physics_engine() -> void:
	# The goo's kernel moves the beads; the project runs on Godot's own 2D
	# physics (the default), which steps nothing of the goo.
	assert_eq(ProjectSettings.get_setting("physics/2d/physics_engine"), "DEFAULT")
	assert_false(ClassDB.class_exists("RapierPhysicsServer2D"), "no physics extension should be loaded")
	assert_true(ClassDB.class_exists("GooKernel"), "the goo's kernel should be loaded")

# A fresh Arena and a Blobs container under a new root added to the test.
func _make_world() -> Node2D:
	var root := Node2D.new()
	var arena := (load("res://scenes/arena.tscn") as PackedScene).instantiate() as Arena
	root.add_child(arena)
	var blobs := Node2D.new()
	blobs.name = "Blobs"
	root.add_child(blobs)
	add_child(root)
	return root

func _spawn(root: Node2D, radius: float, pos: Vector2) -> Goo2D:
	return Goo2D.make(radius, pos, root.get_node("Blobs"))

# Middle of the arena, resting on the floor.
func _on_floor(radius: float) -> Vector2:
	return Vector2((Arena.INNER_LEFT + Arena.INNER_RIGHT) / 2.0, Arena.FLOOR_Y - radius)

# Bounding box of the beads' collision circles: the drawn blob.
func _extent(blob: Goo2D) -> Rect2:
	var radius := blob.bead_radius()
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for point: Vector2 in blob.bead_points():
		lo = lo.min(point - Vector2(radius, radius))
		hi = hi.max(point + Vector2(radius, radius))
	return Rect2(lo, hi - lo)

# Fastest bead speed, in px/s, from how far the beads moved since `before`
# (their positions one physics frame ago).
func _max_speed(blob: Goo2D, before: PackedVector2Array) -> float:
	var now := blob.bead_points()
	var fastest := 0.0
	for i: int in mini(now.size(), before.size()):
		fastest = maxf(fastest, now[i].distance_to(before[i]) / STEP)
	return fastest

# Fraction of its target area the ring encloses (its collision outline).
func _area_ratio(blob: Goo2D) -> float:
	return blob.area() / GooTuning.target_area(blob.radius)

func _all_still(blob: Goo2D) -> bool:
	for velocity: Vector2 in blob.bead_velocities():
		if velocity != Vector2.ZERO:
			return false
	return true

func test_builds_a_closed_ring_of_beads() -> void:
	for i: int in [0, 3, 7]:
		var radius := GooTuning.radius_at(i / 7.0)
		var pos := Vector2(360.0, 400.0 + 1000.0 * i)
		var blob: Goo2D = Goo2D.make(radius, pos, self)
		var count := GooTuning.bead_count(radius)
		var points := blob.bead_points()
		var ratio := _area_ratio(blob)
		print("    radius %.1f: %d beads, area %.1f%% of target before any physics frame, centre off %.2f px"
			% [radius, blob.particle_count(), 100.0 * ratio, blob.center().distance_to(pos)])
		assert_eq(blob.get_children().map(func(node: Node) -> String: return String(node.name)),
			["Skin"], "the beads live in the kernel: the Skin is the only child")
		assert_eq(blob.radius, radius)
		assert_eq(blob.name, "Blob%d" % roundi(radius))
		assert_eq(blob.particle_count(), count)
		assert_eq(points.size(), count)
		assert_eq(blob.bead_velocities().size(), count)
		assert_true(_all_still(blob), "built at rest")
		assert_almost_eq(ratio, 1.0, 0.02, "radius %.1f area before any physics frame" % radius)
		assert_true(GooLoop.is_ccw(points), "the ring runs counter-clockwise on screen")
		assert_false(GooLoop.self_intersects(points))
		assert_true(blob.center().distance_to(pos) <= 0.01, "centre on the requested position")
		assert_almost_eq(blob.target_area, GooTuning.target_area(radius), 0.01)
		assert_eq(blob.rest_shape.size(), count)
		assert_true(GooLoop.centroid(blob.rest_shape).length() < 0.001, "rest shape about its centroid")
		var skin := blob.get_node("Skin") as Polygon2D
		assert_not_null(skin)
		assert_true(skin.antialiased)
		assert_gt(skin.polygon.size(), count, "the skin is the smoothed ring")
		assert_eq(blob.get_tint(), GooTuning.color(radius))
		assert_almost_eq(blob.bead_radius(), GooTuning.bead_radius(radius), 0.0001)
		assert_almost_eq(blob.body_mass(), GooTuning.bead_mass(radius) * count, 0.0001,
			"body_mass() is the beads' total")
		assert_eq(Goo2D.find(skin), blob, "the skin finds its body")
		for k: int in count:
			assert_eq(blob.bead_position(k), points[k])
		blob.free()

func test_rests_flattened_holds_its_area_and_sleeps_until_hit() -> void:
	timeout_sec = 15.0
	var root := _make_world()
	var blob := _spawn(root, r2, _on_floor(r2))
	var settle_at := -1.0
	var area_at_2s := 0.0
	var flatten_at_2s := 0.0
	var elapsed := 0.0
	while elapsed < 3.0:
		await get_tree().physics_frame
		elapsed += STEP
		if settle_at < 0.0 and blob.settled:
			settle_at = elapsed
		if area_at_2s == 0.0 and elapsed >= 2.0:
			var box := _extent(blob)
			area_at_2s = _area_ratio(blob)
			flatten_at_2s = box.size.x / box.size.y
	print("    radius %.1f on the floor at 2 s: area %.1f%% of target, width/height %.3f; settled after %.2f s"
		% [blob.radius, 100.0 * area_at_2s, flatten_at_2s, settle_at])
	assert_true(area_at_2s >= 0.85, "area %.1f%% should hold at 85%% or more" % (100.0 * area_at_2s))
	assert_true(flatten_at_2s >= 1.10, "a resting ring should flatten: width/height %.3f" % flatten_at_2s)
	assert_true(settle_at > 0.0, "the ring should settle within 3 s")
	await get_tree().physics_frame
	assert_true(_all_still(blob), "a settled ring's beads all stand still")
	# Drop another ring onto it: the contact must wake it.
	var top := _extent(blob).position.y
	var other := _spawn(root, r0, Vector2(_on_floor(r2).x, top - r0 - 60.0))
	# Lambdas capture locals by value, so the clock they read is an array.
	var clock := [elapsed]
	var contact := [-1.0]
	other.touched.connect(func(_b: Goo2D) -> void:
		if contact[0] < 0.0:
			contact[0] = clock[0])
	var woke_at := -1.0
	var limit := elapsed + 2.0
	while elapsed < limit:
		await get_tree().physics_frame
		elapsed += STEP
		clock[0] = elapsed
		if woke_at < 0.0 and not blob.settled:
			woke_at = elapsed
		if contact[0] >= 0.0 and woke_at >= 0.0:
			break
	print("    dropped ring touched at %.2f s, the resting ring woke at %.2f s" % [contact[0], woke_at])
	assert_true(contact[0] >= 0.0, "the dropped ring should land on the resting one")
	assert_true(woke_at >= 0.0 and woke_at - contact[0] <= 0.5,
		"the resting ring should wake within 0.5 s of the contact")
	root.free()

func test_impulse_wobble_decays() -> void:
	timeout_sec = 15.0
	var root := _make_world()
	var blob := _spawn(root, r0, _on_floor(r0))
	await wait_seconds(1.5)
	var per_bead := blob.body_mass() / blob.particle_count()
	blob.apply_impulse(Vector2(0.0, -60.0) * per_bead)
	assert_false(blob.settled, "an impulse wakes the ring")
	var elapsed := 0.0
	var last_fast := 0.0
	var peak := 0.0
	var before := blob.bead_points()
	while elapsed < 3.5:
		await get_tree().physics_frame
		elapsed += STEP
		var speed := _max_speed(blob, before)
		before = blob.bead_points()
		peak = maxf(peak, speed)
		if speed >= 5.0:
			last_fast = elapsed
	print("    radius %.1f kicked up at 60 px/s: peak bead speed %.1f px/s, under 5 px/s for good after %.2f s"
		% [blob.radius, peak, last_fast])
	assert_true(last_fast < 2.5, "wobble should die out within 2.5 s, took %.2f s" % last_fast)
	root.free()

func test_squeezes_through_a_narrow_gap() -> void:
	timeout_sec = 15.0
	var root := _make_world()
	var diameter := 2.0 * r0
	var gap := 0.8 * diameter
	var middle := (Arena.INNER_LEFT + Arena.INNER_RIGHT) / 2.0
	var box_top := 500.0
	var box_height := 40.0
	for side: float in [-1.0, 1.0]:
		var width := 200.0
		var box := _static_box(Vector2(middle + side * (gap + width) / 2.0, box_top + box_height / 2.0),
			Vector2(width, box_height))
		root.add_child(box)
	var start := Vector2(middle, box_top - r0 - 20.0)
	var blob := _spawn(root, r0, start)
	blob.set_velocity(Vector2(0.0, 600.0))
	var elapsed := 0.0
	var passed_at := -1.0
	var narrowest := INF
	var lowest_area := INF
	while elapsed < 3.0:
		await get_tree().physics_frame
		elapsed += STEP
		var centre := blob.center()
		if absf(centre.y - (box_top + box_height / 2.0)) < box_height:
			narrowest = minf(narrowest, _extent(blob).size.x)
			lowest_area = minf(lowest_area, _area_ratio(blob))
		if centre.y > box_top + box_height:
			passed_at = elapsed
			break
	print("    radius %.0f (%.0f px) through a %.1f px gap: centre below the boxes after %.2f s, narrowest %.1f px, lowest area %.1f%%"
		% [blob.radius, diameter, gap, passed_at, narrowest, 100.0 * lowest_area])
	assert_true(passed_at > 0.0, "the ring should squeeze through the gap within 3 s")
	root.free()

func test_self_collision_keeps_a_squeezed_ring_from_folding() -> void:
	timeout_sec = 20.0
	var root := _make_world()
	var radius := r2
	var blob := _spawn(root, radius, Vector2(Arena.INNER_LEFT + radius + 1.0, Arena.FLOOR_Y - radius))
	await wait_seconds(0.5)
	var slab := AnimatableBody2D.new()
	slab.collision_layer = GooTuning.LAYER_WALLS
	slab.collision_mask = 0
	var shape := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	var slab_width := 40.0
	rect.size = Vector2(slab_width, 500.0)
	shape.shape = rect
	slab.add_child(shape)
	var open_face := Arena.INNER_LEFT + 2.6 * radius
	var closed_face := Arena.INNER_LEFT + 0.4 * 2.0 * radius
	var y := Arena.FLOOR_Y - 1.0 - rect.size.y / 2.0
	slab.position = Vector2(open_face + slab_width / 2.0, y)
	root.add_child(slab)
	var lowest_area := INF
	var folded := 0
	var narrowest := INF
	var phases := [[1.0, open_face, closed_face], [0.5, closed_face, closed_face], [0.5, closed_face, open_face]]
	for phase: Array in phases:
		var duration: float = phase[0]
		var t := 0.0
		while t < duration:
			t += STEP
			var face: float = lerpf(phase[1], phase[2], clampf(t / duration, 0.0, 1.0))
			slab.position = Vector2(face + slab_width / 2.0, y)
			await get_tree().physics_frame
			var points := blob.bead_points()
			lowest_area = minf(lowest_area, _area_ratio(blob))
			narrowest = minf(narrowest, _extent(blob).size.x)
			if GooLoop.self_intersects(points):
				folded += 1
	await wait_seconds(1.5)
	var recovered := _area_ratio(blob)
	print("    radius %.1f squeezed to a %.1f px gap: narrowest %.1f px, lowest area %.1f%%, %d folded frames; area 1.5 s after release %.1f%%"
		% [radius, closed_face - Arena.INNER_LEFT, narrowest, 100.0 * lowest_area, folded, 100.0 * recovered])
	assert_true(lowest_area >= 0.25, "squeezed area %.1f%% under 25%%" % (100.0 * lowest_area))
	assert_eq(folded, 0, "the ring must never fold through itself")
	assert_true(recovered >= 0.85, "area %.1f%% should recover to 85%%" % (100.0 * recovered))
	root.free()

func test_small_ring_on_a_big_one_stays_outside_it() -> void:
	timeout_sec = 15.0
	var root := _make_world()
	var big := _spawn(root, r6, _on_floor(r6))
	await wait_seconds(1.0)
	var top := _extent(big).position.y
	var small := _spawn(root, r0, Vector2(_on_floor(r6).x, top - r0 - 150.0))
	await wait_seconds(2.0)
	var inside := _beads_inside(small, big)
	var reverse := _beads_inside(big, small)
	print("    radius %.1f on radius %.1f: %d small beads inside the big ring, %d big beads inside the small ring; centre distance %.1f px"
		% [small.radius, big.radius, inside, reverse, small.center().distance_to(big.center())])
	assert_eq(inside, 0, "no bead of the small ring may sink into the big one")
	assert_eq(reverse, 0, "no bead of the big ring may be inside the small one")
	root.free()

func test_big_ring_on_a_small_one_stays_outside_it() -> void:
	timeout_sec = 15.0
	var root := _make_world()
	var small := _spawn(root, r0, _on_floor(r0))
	await wait_seconds(1.0)
	var big := _spawn(root, r6, Vector2(_on_floor(r0).x, _extent(small).position.y - r6 - 40.0))
	await wait_seconds(2.0)
	var inside := _beads_inside(small, big)
	var reverse := _beads_inside(big, small)
	print("    radius %.1f on radius %.1f: %d small beads inside the big ring, %d big beads inside the small ring; small ring area %.1f%%"
		% [big.radius, small.radius, inside, reverse, 100.0 * _area_ratio(small)])
	assert_eq(inside, 0, "the small ring must not end up inside the big one")
	assert_eq(reverse, 0, "no bead of the big ring may be inside the small one")
	root.free()

func test_touched_fires_once_per_frame_while_touching_outside_the_flush() -> void:
	var root := _make_world()
	var low := _spawn(root, r1, _on_floor(r1))
	var high := _spawn(root, r0, _on_floor(r1) - Vector2(0.0, 2.0 * r1 + r0 + 4.0))
	var per_frame: Dictionary[int, int] = {}
	low.touched.connect(func(other: Goo2D) -> void:
		if other == high:
			var frame := Engine.get_physics_frames()
			per_frame[frame] = per_frame.get(frame, 0) + 1
			# Outside the physics flush: adding (and freeing) a physics node is allowed.
			var probe := StaticBody2D.new()
			root.add_child(probe)
			probe.free())
	for frame: int in 90:
		await get_tree().physics_frame
	var most := 0
	for count: int in per_frame.values():
		most = maxi(most, count)
	print("    small ring resting on a bigger one: touched on %d of 90 frames, at most %d per frame"
		% [per_frame.size(), most])
	assert_eq(most, 1, "touched fires at most once per frame and other body")
	assert_gt(per_frame.size(), 30, "touched keeps firing while the rings touch")
	root.free()

func test_rebuild_from_two_rings_inflates_into_the_merged_size() -> void:
	timeout_sec = 15.0
	var root := _make_world()
	var r := r0
	var merged_r := GooTuning.merged_radius(r, r)
	# Pressed into each other (centres 1.4 r apart), as a transition leaves a
	# pair: their union has lost about a tenth of their area to the overlap.
	# (Two discs just touching make a union whose creases the rebuilt ring fills,
	# Goo2D.MERGE_CLOSE_BEADS, which starts it within 1% of its circle's area.)
	var a := _spawn(root, r0, _on_floor(r0) - Vector2(0.7 * r, 0.0))
	var b := _spawn(root, r0, _on_floor(r0) + Vector2(0.7 * r, 0.0))
	a.set_velocity(Vector2(50.0, 0.0))
	b.set_velocity(Vector2(50.0, 0.0))
	var before := (a.body_mass() * a.center() + b.body_mass() * b.center()) / (a.body_mass() + b.body_mass())
	var merged := Goo2D.make_merged(merged_r, root.get_node("Blobs"), [a, b] as Array[Goo2D])
	a.get_parent().remove_child(a)
	b.get_parent().remove_child(b)
	a.queue_free()
	b.queue_free()
	assert_not_null(merged)
	if merged == null:
		return
	var start_ratio := merged.target_area / GooTuning.target_area(merged_r)
	var start_area := merged.area()
	print("    rebuilt radius %.1f: %d beads, centre moved %.1f px, start velocity %s, target area starts at %.1f%% of its circle's"
		% [merged_r, merged.particle_count(), merged.center().distance_to(before), merged.average_velocity(), 100.0 * start_ratio])
	assert_eq(merged.particle_count(), GooTuning.bead_count(merged_r))
	assert_true(GooLoop.is_ccw(merged.bead_points()))
	assert_almost_eq(merged.average_velocity().x, 50.0, 0.01, "the beads keep the old beads' velocity")
	# The merged disc holds exactly the two discs' area (merges conserve area),
	# and the ring rebuilt around the pair's outline starts a few percent off it;
	# either way the target starts at the ring's own area and tweens from there.
	assert_almost_eq(merged.target_area, start_area, 0.001, "the target starts at the rebuilt ring's area")
	assert_true(absf(start_ratio - 1.0) > 0.02, "the rebuilt ring starts away from its circle's area")
	assert_lt(merged.center().distance_to(before), 6.0, "the new ring sits where the old pair was")
	await wait_seconds(GooTuning.inflate_time() + 0.05)
	assert_almost_eq(merged.target_area, GooTuning.target_area(merged_r), 0.01, "target area inflated")
	await wait_seconds(1.0)
	var box := _extent(merged)
	print("    1 s after inflating: area %.1f%%, %.1f x %.1f px" % [100.0 * _area_ratio(merged), box.size.x, box.size.y])
	assert_true(_area_ratio(merged) >= 0.85, "the merged ring should inflate to its circle's area")
	root.free()

func test_spread_apart_parts_beads_across_a_thin_loop() -> void:
	# A thin lens of 12 beads, its two sides 4 px apart: every two beads more
	# than two apart along it end up at least the distance apart (they would
	# collide in the kernel), the loop stays simple, and a loop already apart
	# is left as it is.
	var lens := PackedVector2Array()
	for i: int in 6:
		lens.append(Vector2(8.0 * i, 0.0))
	for i: int in 6:
		lens.append(Vector2(40.0 - 8.0 * i, -4.0))
	var distance := 9.0
	var spread := Goo2D.spread_apart(lens, distance)
	var closest := INF
	for i: int in spread.size():
		for j: int in range(i + 3, spread.size()):
			if j - i <= spread.size() - 3:
				closest = minf(closest, spread[i].distance_to(spread[j]))
	print("    a 4 px thick lens of 12 beads spread to %.1f px (asked %.1f), area %.0f -> %.0f px²"
		% [closest, distance, absf(GooLoop.area(lens)), absf(GooLoop.area(spread))])
	assert_gt(closest, 0.95 * distance, "the beads across the lens are spread apart")
	assert_false(GooLoop.self_intersects(spread), "the spread loop does not cross itself")
	var circle := GooLoop.circle_points(Vector2.ZERO, 40.0, 16)
	assert_eq(Goo2D.spread_apart(circle, distance), circle, "beads already apart stay put")

func test_pass_through_excludes_and_restores_the_pair() -> void:
	var a: Goo2D = Goo2D.make(r0, Vector2(360.0, 500.0), self)
	var b: Goo2D = Goo2D.make(r0, Vector2(360.0, 800.0), self)
	a.set_pass_through(b, true)
	assert_true(a.passes_through(b))
	assert_true(b.passes_through(a), "both ways")
	a.set_pass_through(b, false)
	assert_false(a.passes_through(b))
	a.set_bead_pass_through(3, b, true)
	assert_true(a._kernel.bead_passes_through(a.get_instance_id(), 3, b.get_instance_id()))
	assert_false(a._kernel.bead_passes_through(a.get_instance_id(), 4, b.get_instance_id()))
	a.set_bead_pass_through(3, b, false)
	assert_false(a._kernel.bead_passes_through(a.get_instance_id(), 3, b.get_instance_id()))

func test_beads_inside_counts_beads_within_the_other_ring() -> void:
	var a: Goo2D = Goo2D.make(r1, Vector2(360.0, 500.0), self)
	var near: Goo2D = Goo2D.make(r1, Vector2(360.0 + r1, 500.0), self)
	var far: Goo2D = Goo2D.make(r1, Vector2(360.0 + 3.0 * r1, 500.0), self)
	var touching: Goo2D = Goo2D.make(r1, Vector2(360.0, 500.0 + 2.0 * r1), self)
	assert_gt(near.beads_inside(a, 0.0), 0, "a ring half inside another has beads inside it")
	assert_eq(far.beads_inside(a, 0.0), 0)
	assert_eq(touching.beads_inside(a, 0.0), 0, "touching outlines put no bead inside")
	assert_gt(touching.beads_inside(a, 2.0 * a.bead_radius() + 1.0), 0,
		"the margin grows the other ring's loop")

func test_frictionless_switches_the_kernel_ring_and_back() -> void:
	var blob: Goo2D = Goo2D.make(r1, Vector2(360.0, 500.0), self)
	blob.set_frictionless(true)
	blob.set_frictionless(true)
	assert_true(blob.is_frictionless())
	assert_true(blob._kernel.is_frictionless(blob.get_instance_id()))
	blob.set_frictionless(false)
	assert_false(blob.is_frictionless())
	assert_false(blob._kernel.is_frictionless(blob.get_instance_id()))

func test_tint_is_the_skin_colour() -> void:
	var a: Goo2D = Goo2D.make(r0, Vector2(360.0, 500.0), self)
	a.set_tint(Color.WHITE)
	assert_eq((a.get_node("Skin") as Polygon2D).color, Color.WHITE)
	assert_eq(a.get_tint(), Color.WHITE)

# Number of `blob`'s beads inside `other`'s bead loop.
func _beads_inside(blob: Goo2D, other: Goo2D) -> int:
	var loop := other.bead_points()
	var count := 0
	for point: Vector2 in blob.bead_points():
		if GooLoop.point_in_loop(point, loop):
			count += 1
	return count

func _static_box(centre: Vector2, size: Vector2) -> StaticBody2D:
	var box := StaticBody2D.new()
	box.collision_layer = GooTuning.LAYER_WALLS
	box.collision_mask = 0
	box.position = centre
	var shape := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = size
	shape.shape = rect
	box.add_child(shape)
	return box

func test_benchmark_forty_drops() -> void:
	timeout_sec = 60.0
	# 40 launch-size rings dropped across the arena, one every 0.1 s, then 3 s
	# of the pile settling: prints the physics frame time (Godot's
	# TIME_PHYSICS_PROCESS monitor: scripts' _physics_process, the kernel's step
	# included), to compare tuning changes.
	var root := _make_world()
	var rng := RandomNumberGenerator.new()
	rng.seed = 40
	var samples := PackedFloat64Array()
	var dropped := 0
	var frames := 0
	var started := Time.get_ticks_usec()
	while dropped < 40 or frames < 40 * 6 + 180:
		if dropped < 40 and frames % 6 == 0:
			var radius := rng.randf_range(DropController.DROP_MIN_RADIUS, DropController.DROP_MAX_RADIUS)
			var x := rng.randf_range(Arena.INNER_LEFT + radius + 4.0, Arena.INNER_RIGHT - radius - 4.0)
			_spawn(root, radius, Vector2(x, Arena.DROP_Y))
			dropped += 1
		await get_tree().physics_frame
		frames += 1
		samples.append(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0)
	var wall_ms := (Time.get_ticks_usec() - started) / 1000.0
	var total := 0.0
	var worst := 0.0
	for sample: float in samples:
		total += sample
		worst = maxf(worst, sample)
	var sorted := samples.duplicate()
	sorted.sort()
	print("    40 drops, %d physics frames: physics %.2f ms per frame on average (median %.2f, worst %.2f); %.0f ms wall clock in all"
		% [frames, total / samples.size(), sorted[sorted.size() / 2], worst, wall_ms])
	assert_eq(root.get_node("Blobs").get_child_count(), 40)

func test_particle_counts_grow_with_size() -> void:
	var counts: Array[int] = []
	var radii: Array[int] = []
	for i: int in 8:
		var radius := GooTuning.radius_at(i / 7.0)
		var pos := Vector2(360.0, 400.0 + 1000.0 * i)
		var blob: Goo2D = Goo2D.make(radius, pos, self)
		counts.append(blob.particle_count())
		radii.append(roundi(radius))
		var tolerance := maxf(4.0, radius * 0.05)
		assert_true(blob.center().distance_to(pos) <= tolerance,
			"radius %.1f center off by %s" % [radius, blob.center() - pos])
		blob.free()
	print("    particles per radius %s: %s" % [radii, counts])
	assert_gt(counts[0], 6, "the smallest blob needs at least 7 particles to read as soft")
	assert_lt(counts[7], 41, "the largest blob should stay at or under ~40 particles")
	assert_gt(counts[7], counts[0], "bigger blobs should get more particles")

func test_blob_settles_on_floor_without_exploding() -> void:
	var floor_body := StaticBody2D.new()
	floor_body.collision_layer = 1
	floor_body.collision_mask = 0
	var shape := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = Vector2(2000.0, 40.0)
	shape.shape = rect
	shape.position = Vector2(360.0, 1020.0)
	floor_body.add_child(shape)
	add_child(floor_body)
	var radius := GooTuning.radius_at(2.0 / 7.0)
	var blob: Goo2D = Goo2D.make(radius, Vector2(360.0, 800.0), self)
	await wait_seconds(3.0)
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for point: Vector2 in blob.bead_points():
		lo = lo.min(point)
		hi = hi.max(point)
	var height := hi.y - lo.y
	var width := hi.x - lo.x
	print("    radius %.1f at rest: width %.1f height %.1f speed %.1f (rest diameter of particle centres ~%.1f)"
		% [radius, width, height, blob.average_velocity().length(), 2.0 * radius])
	assert_lt(blob.average_velocity().length(), 5.0, "blob should come to rest")
	assert_lt(hi.y, 1000.0 + 1.0, "no particle should sink through the floor")
	assert_gt(height, width * 0.6, "blob should squash a little, not flatten")
	assert_lt(height, width * 1.05, "resting blob should not be taller than wide")

func test_skins_find_their_blob() -> void:
	var blob: Goo2D = Goo2D.make(r1, SPAWN, self)
	var other: Goo2D = Goo2D.make(r1, SPAWN + Vector2(0.0, 400.0), self)
	assert_eq(Goo2D.find(blob.get_node("Skin")), blob)
	assert_eq(Goo2D.find(other.get_node("Skin")), other)
	assert_null(Goo2D.find(self), "a node outside any blob has no blob")

func test_a_body_out_of_the_tree_keeps_its_beads() -> void:
	var blob: Goo2D = Goo2D.make(r1, SPAWN, self)
	blob.set_velocity(Vector2(30.0, -10.0))
	var points := blob.bead_points()
	remove_child(blob)
	assert_null(blob._kernel, "out of the tree it is in no kernel")
	assert_eq(blob.bead_points(), points, "it keeps its beads' positions")
	assert_eq(blob.bead_velocity(0), Vector2(30.0, -10.0), "and velocities")
	add_child(blob)
	assert_not_null(blob._kernel, "back in the tree it is a ring of a kernel again")
	assert_eq(blob.bead_points(), points)
	assert_eq(blob.bead_velocity(5), Vector2(30.0, -10.0))
	blob.free()

func test_impulse_and_velocity_reach_every_particle() -> void:
	var blob: Goo2D = Goo2D.make(GooTuning.MIN_RADIUS, SPAWN, self)
	blob.set_velocity(Vector2(120.0, -40.0))
	for i: int in blob.particle_count():
		assert_eq(blob.bead_velocity(i), Vector2(120.0, -40.0))
	blob.set_bead_velocity(2, Vector2(1.0, 2.0))
	assert_eq(blob.bead_velocity(2), Vector2(1.0, 2.0))
	assert_eq(blob.bead_velocities()[2], Vector2(1.0, 2.0))
	blob.set_bead_velocity(2, Vector2(120.0, -40.0))
	assert_almost_eq(blob.average_velocity().x, 120.0, 0.001)
	assert_almost_eq(blob.average_velocity().y, -40.0, 0.001)
	blob.set_velocity(Vector2.ZERO)
	var per_particle := blob.body_mass() / blob.particle_count()
	blob.apply_impulse(Vector2(100.0 * per_particle, 0.0))
	# physics_frame fires before the step, so the second one sees the impulse integrated.
	await get_tree().physics_frame
	await get_tree().physics_frame
	assert_gt(blob.average_velocity().x, 50.0, "an impulse on every particle should move the blob")
