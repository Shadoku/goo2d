extends TestCase
## Rings that sink into each other are pushed back apart by the world's overlap
## push (GooWorld2D.intrusion(): each bead that got into the other ring is
## pushed back out, and GooWorld2D.Untangler for rings threaded through each
## other), which Game applies every physics frame, also to settled pairs and
## to bodies pressed into a merging one; and a ring's skin cannot be stretched
## open by an impact (Goo2D.MAX_STRETCH, a hard constraint of the kernel).

var arena: Arena
var game: Game

func before_each() -> void:
	arena = (load("res://scenes/arena.tscn") as PackedScene).instantiate() as Arena
	add_child(arena)
	game = Game.new()
	game.arena = arena
	add_child(game)

## Spawns a blob of `radius` resting on the floor in the middle of the arena and
## lets it settle.
func _settled_on_floor(radius: float) -> Goo2D:
	var x := Arena.INNER_LEFT + Arena.INNER_WIDTH / 2.0
	var blob := game.spawn(radius, Vector2(x, Arena.FLOOR_Y - radius))
	await wait_seconds(1.0)
	return blob

func test_blob_spawned_half_inside_another_is_pushed_out() -> void:
	var r1 := GooTuning.radius_at(1.0 / 7.0)
	var r3 := GooTuning.radius_at(3.0 / 7.0)
	var big: Goo2D = await _settled_on_floor(r3)
	var touching := r1 + r3
	# Half overlapped, beside the big blob and above the floor: the worst realistic
	# case (a blob spawned across a neighbour); the game never spawns one fully
	# inside another.
	var small := game.spawn(r1, big.center() + Vector2(0.5 * touching, -r1))
	var wanted := 0.8 * touching
	var distance := 0.0
	var limit := int(1.5 * Engine.physics_ticks_per_second)
	for frame: int in limit:
		await get_tree().physics_frame
		distance = small.center().distance_to(big.center())
		if distance >= wanted:
			break
	print("radius %.1f inside radius %.1f: centre distance %.1f px (wanted >= %.1f)" % [r1, r3, distance, wanted])
	assert_true(distance >= wanted,
		"the small blob should be pushed out of the big one: %.1f < %.1f px" % [distance, wanted])

func test_small_blob_dropped_on_a_big_one_does_not_sink_in() -> void:
	var r0 := GooTuning.MIN_RADIUS
	var r6 := GooTuning.radius_at(6.0 / 7.0)
	var big: Goo2D = await _settled_on_floor(r6)
	var top := big.center() - Vector2(0.0, r6 + r0)
	var small := game.spawn(r0, top - Vector2(0.0, 150.0))
	await wait_seconds(2.0)
	var distance := small.center().distance_to(big.center())
	var surface := _top(big)
	var above := surface - small.center().y
	print("radius %.1f on radius %.1f: centre distance %.1f px (nominal radii %.1f); small centre %.1f px above the big blob's top surface (%.1f px under its nominal top)"
		% [r0, r6, distance, r6 + r0, above, surface - (big.center().y - r6)])
	# Either clear of the big blob's nominal circle (resting beside it, or rolled
	# off), or on top of its actual surface with at most half of the small blob
	# below it. A resting pressure ring flattens, so its top sits well under its
	# nominal radius and the centre distance alone would call a ring lying on top
	# "sunk in" (132 px against 152 wanted, with no bead inside the other ring).
	var beside := distance >= r6 + 0.6 * r0
	var on_top := above >= 0.5 * r0
	assert_true(beside or on_top,
		"the small blob should rest on the big one, not inside it: centre distance %.1f (wanted >= %.1f) and %.1f px above its top surface (wanted >= %.1f)"
		% [distance, r6 + 0.6 * r0, above, 0.5 * r0])

# Global y of the top of `blob`'s collision circles: the highest bead minus
# its radius.
func _top(blob: Goo2D) -> float:
	var top := INF
	for point: Vector2 in blob.bead_points():
		top = minf(top, point.y - blob.bead_radius())
	return top

func test_fast_small_blob_does_not_pass_into_a_big_one() -> void:
	timeout_sec = 15.0
	var big_radius := 140.0
	var small_radius := 40.0
	var big: Goo2D = await _settled_on_floor(big_radius)
	var big_start := big.center()
	var splits: Array[int] = [0]
	game.split.connect(func(_ra: float, _rb: float, _position: Vector2) -> void: splits[0] += 1)
	# Launched straight down at the big blob's centre from 300 px above it.
	var small := game.spawn(small_radius, big_start - Vector2(0.0, 300.0))
	small.set_velocity(Vector2(0.0, 1500.0))
	var reach := big_radius + small_radius
	var closest := INF
	var deepest := 0
	var moved := 0.0
	for frame: int in roundi(1.5 * Engine.physics_ticks_per_second):
		await get_tree().physics_frame
		var pair := _big_and_others()
		if pair.is_empty():
			continue
		var now_big: Goo2D = pair[0]
		moved = maxf(moved, _centre_without(small).distance_to(big_start))
		for other: Goo2D in pair[1]:
			closest = minf(closest, other.center().distance_to(now_big.center()) / (now_big.radius + other.radius))
			deepest = maxi(deepest, other.beads_inside(now_big, 0.0))
	var final := _big_and_others()
	assert_false(final.is_empty(), "the blobs are still there")
	if final.is_empty():
		return
	var end_big: Goo2D = final[0]
	var report := PackedStringArray()
	for other: Goo2D in final[1]:
		var distance := other.center().distance_to(end_big.center())
		var wanted := 0.75 * (end_big.radius + other.radius)
		var centre_inside := GooLoop.point_in_loop(other.center(), end_big.bead_points())
		var beads_in := other.beads_inside(end_big, 0.0)
		report.append("%.1f px blob: centre distance %.1f px (%.2f of ra + rb, wanted >= 0.75), centre inside %s, %d beads inside"
			% [other.radius, distance, distance / (end_big.radius + other.radius), centre_inside, beads_in])
		assert_false(centre_inside, "the %.1f px blob's centre ends outside the big ring" % other.radius)
		assert_eq(beads_in, 0, "no bead of the %.1f px blob ends inside the big ring" % other.radius)
		assert_true(distance >= wanted,
			"centre distance %.1f px should be at least 0.75 × (ra + rb) = %.1f px" % [distance, wanted])
	print("    %.0f px blob at 1500 px/s into a resting %.0f px blob, %d splits: after 1.5 s %s; closest approach %.2f of ra + rb, at most %d small-blob beads inside the big ring during the run; big blob (with its pieces, if it split) moved up to %.1f px (%.1f px at the end)"
		% [small_radius, big_radius, splits[0], "; ".join(report), closest, deepest, moved,
			_centre_without(small).distance_to(big_start)])
	assert_true(moved >= 10.0, "the big blob is pushed too (moved %.1f px)" % moved)

# Area-weighted centre of every live blob but `left_out` (if it is still live).
func _centre_without(left_out: Goo2D) -> Vector2:
	var total := Vector2.ZERO
	var weight := 0.0
	for blob: Goo2D in game.bodies():
		if is_instance_valid(left_out) and blob == left_out:
			continue
		total += blob.center() * blob.radius * blob.radius
		weight += blob.radius * blob.radius
	return total / weight if weight > 0.0 else Vector2.ZERO

# [the largest live blob, Array[Goo2D] of the others], or [] with no blobs.
func _big_and_others() -> Array:
	var all := game.bodies()
	if all.is_empty():
		return []
	var big := all[0]
	for blob: Goo2D in all:
		if blob.radius > big.radius:
			big = blob
	var others: Array[Goo2D] = []
	for blob: Goo2D in all:
		if blob != big:
			others.append(blob)
	return [big, others]

func test_resting_stack_of_two_is_not_pushed_apart() -> void:
	timeout_sec = 30.0
	# Measured at rest: the overlap 1 - d / (ra + rb) of two equal rings, one on
	# the other, is about 27-30% for 60 px rings and 26-34% for 120 px ones:
	# pressure rings flatten under their own and each other's weight. The old
	# centre-distance push (from 25%) acted on such a stack; the bead-loop push
	# sees no bead near the other ring's loop and leaves it alone. This checks
	# that the push on a resting stack stays a small fraction of the top ring's
	# weight and does not lift the top ring off.
	for radius: float in [60.0, 120.0]:
		game.reset()
		await wait_frames(2)
		var x := Arena.INNER_LEFT + Arena.INNER_WIDTH / 2.0
		var bottom := game.spawn(radius, Vector2(x, Arena.FLOOR_Y - radius))
		var top := game.spawn(radius, Vector2(x, Arena.FLOOR_Y - 3.0 * radius - 4.0))
		# Equal blobs would merge: keep both locked for the whole test.
		bottom.merge_lock_until = INF
		top.merge_lock_until = INF
		await wait_seconds(2.0)
		var most := 0.0
		var least := INF
		var total := 0.0
		var pushed := 0.0
		var settled_at := -1.0
		var frames := roundi(2.0 * Engine.physics_ticks_per_second)
		for frame: int in frames:
			await get_tree().physics_frame
			var overlap := 1.0 - bottom.center().distance_to(top.center()) / (2.0 * radius)
			most = maxf(most, overlap)
			least = minf(least, overlap)
			total += overlap
			var hit := GooWorld2D.intrusion(_overlap_ring(top), _overlap_ring(bottom))
			if hit.pressed:
				var up := Vector2.ZERO
				for force: Vector2 in hit.forces_a:
					up += force
				pushed = maxf(pushed, up.length())
			if settled_at < 0.0 and bottom.settled and top.settled:
				settled_at = 2.0 + frame / float(Engine.physics_ticks_per_second)
		var weight := top.body_mass() * GooTuning.gravity()
		print("    resting stack of two %.0f px blobs, from 2 s to 4 s after the drop: overlap %.1f%%..%.1f%%, mean %.1f%%; push on the top blob up to %.1f = %.1f%% of its weight %.0f; both settled %s"
			% [radius, 100.0 * least, 100.0 * most, 100.0 * total / frames,
				pushed, 100.0 * pushed / weight, weight,
				"after %.2f s" % settled_at if settled_at >= 0.0 else "not by 4 s"])
		assert_gt(least, 0.15, "the %.0f px stack stays stacked, not pushed apart" % radius)
		assert_lt(top.center().y, bottom.center().y - radius, "the top %.0f px blob is still on top" % radius)
		assert_lt(pushed, 0.1 * weight, "the push on a resting %.0f px stack stays under 10%% of its weight" % radius)

# `body` as the world's overlap push sees it.
static func _overlap_ring(body: Goo2D) -> GooWorld2D.OverlapRing:
	return GooWorld2D.OverlapRing.new(body.bead_points(), body.bead_radius(),
		body.body_mass() / body.particle_count())

# ---- Pairs the old rules skipped: settled, merging, under a pile ----

# Number of beads of either body inside the other's bead loop (0 if either is gone).
static func _inside_each_other(a: Goo2D, b: Goo2D) -> int:
	if not is_instance_valid(a) or not is_instance_valid(b):
		return 0
	if a.is_queued_for_deletion() or b.is_queued_for_deletion():
		return 0
	return a.beads_inside(b, 0.0) + b.beads_inside(a, 0.0)

# Plays up to `seconds` and returns { "apart": the time, s, at which `a` and `b`
# first had no bead inside each other (-1.0 if never), "settled_inside": whether
# both were settled on a frame while still inside each other, "gone": whether
# either was freed (merged or split) on the way }.
func _time_apart(a: Goo2D, b: Goo2D, seconds: float) -> Dictionary:
	var settled_inside := false
	var frames := roundi(seconds * Engine.physics_ticks_per_second)
	for frame: int in frames:
		await get_tree().physics_frame
		if not is_instance_valid(a) or not is_instance_valid(b) \
				or a.is_queued_for_deletion() or b.is_queued_for_deletion():
			return { "apart": -1.0, "settled_inside": settled_inside, "gone": true }
		var inside := _inside_each_other(a, b)
		if inside > 0 and a.settled and b.settled:
			settled_inside = true
		if inside == 0:
			return { "apart": (frame + 1) / float(Engine.physics_ticks_per_second),
				"settled_inside": settled_inside, "gone": false }
	return { "apart": -1.0, "settled_inside": settled_inside, "gone": false }

static func _when(seconds: float) -> String:
	return "%.2f s" % seconds if seconds >= 0.0 else "never"

func test_settled_pair_inside_each_other_is_woken_and_pushed_apart() -> void:
	# Two bodies come to rest inside each other (as under a pile's load) and fall
	# asleep there: the world must wake them and get them apart, not skip the pair
	# because both are settled. A small ring inside a big one, its beads touching
	# none of the big ring's, so no contact wakes them either. (Rings asleep
	# with their beads pressed into each other's are woken by the solver's contacts.)
	var big: Goo2D = await _settled_on_floor(120.0)
	big.merge_lock_until = INF
	var small := game.spawn(GooTuning.MIN_RADIUS, big.center())
	small.merge_lock_until = INF
	await get_tree().physics_frame
	var inside := _inside_each_other(small, big)
	assert_gt(inside, 0, "the setup puts beads inside each other")
	big._settle()
	small._settle()
	var result: Dictionary = await _time_apart(small, big, 1.0)
	print("    settled pair with %d beads inside each other: apart after %s" % [inside, _when(result["apart"])])
	assert_false(result["gone"], "neither body merged or split")
	assert_gt(result["apart"], 0.0, "the settled pair is pushed apart within 1 s")

func test_body_pressed_into_a_merging_body_is_pushed_back() -> void:
	# A third body pressed into a body that is being pulled into a merge (here
	# one flagged `merging` with no partner): only a merging pair is exempt from
	# each other, so the third body is pushed back out.
	var big: Goo2D = await _settled_on_floor(60.0)
	big.merge_lock_until = INF
	big.merging = true
	var small := game.spawn(40.0, big.center() + Vector2(0.8 * 100.0, -10.0))
	small.merge_lock_until = INF
	await get_tree().physics_frame
	var inside := _inside_each_other(small, big)
	assert_gt(inside, 0, "the setup puts beads inside each other")
	var result: Dictionary = await _time_apart(small, big, 1.0)
	print("    %d beads inside a merging body: apart after %s" % [inside, _when(result["apart"])])
	if is_instance_valid(big):
		big.merging = false
	assert_false(result["gone"], "neither body merged or split")
	assert_gt(result["apart"], 0.0, "the third body is pushed out of the merging one within 1 s")

func test_small_ring_inside_the_bottom_of_a_stack_gets_out() -> void:
	timeout_sec = 30.0
	# Six rings dropped in a column into the right-hand corner, merge-locked so
	# none merge (they slump into a packed pile against the wall and each other),
	# and a small ring spawned inside the lowest one: hemmed in by the pile it
	# must still get out, and the two never settle inside each other.
	var radius := 50.0
	var x := Arena.INNER_RIGHT - radius
	var stack: Array[Goo2D] = []
	for k: int in 6:
		var ring := game.spawn(radius, Vector2(x, Arena.FLOOR_Y - radius - 2.0 * (radius + 2.0) * k))
		ring.merge_lock_until = INF
		stack.append(ring)
	await wait_seconds(2.5)
	var bottom := stack[0]
	for ring: Goo2D in stack:
		if ring.center().y > bottom.center().y:
			bottom = ring
	var small := game.spawn(GooTuning.MIN_RADIUS, bottom.center())
	small.merge_lock_until = INF
	await get_tree().physics_frame
	var inside := _inside_each_other(small, bottom)
	assert_gt(inside, 0, "the small ring starts inside the bottom ring")
	var result: Dictionary = await _time_apart(small, bottom, 1.0)
	print("    small ring inside the bottom of a stack of six (%d beads inside): out after %s, settled inside %s"
		% [inside, _when(result["apart"]), result["settled_inside"]])
	assert_false(result["gone"], "neither body merged or split")
	assert_gt(result["apart"], 0.0, "the small ring gets out within 1 s")
	assert_false(result["settled_inside"], "the two never settle inside each other")

func test_fast_drop_does_not_tear_the_skin_open() -> void:
	timeout_sec = 15.0
	# A 36 px ring dropped at 2500 px/s onto a resting 140 px ring stretches the
	# big ring's skin under the impact; with nothing to limit the stretch two
	# neighbouring beads parted by 12-16 px, about a launch-size bead's width
	# (15 px here). With Goo2D.MAX_STRETCH (1.3) the limit itself leaves 3 px and
	# the impact's contacts within one step add 3-4 px more (measured 6-7 px;
	# 6.0 at a limit of 1.2), so the hole stays under two thirds of that bead's
	# width.
	var big: Goo2D = await _settled_on_floor(140.0)
	big.merge_lock_until = INF
	var small := game.spawn(36.0, big.center() - Vector2(0.0, 520.0))
	small.set_velocity(Vector2(0.0, 2500.0))
	var widest := -INF
	for frame: int in 150:
		await get_tree().physics_frame
		if not is_instance_valid(big) or big.is_queued_for_deletion():
			break
		var points := big.bead_points()
		for i: int in points.size():
			var gap := points[i].distance_to(points[(i + 1) % points.size()]) - 2.0 * big.bead_radius()
			widest = maxf(widest, gap)
	var limit := 2.0 / 3.0 * 2.0 * GooTuning.bead_radius(36.0)
	print("    36 px ring at 2500 px/s onto a 140 px ring: widest gap between neighbouring beads %.1f px (wanted under %.1f)"
		% [widest, limit])
	assert_lt(widest, limit, "the big ring's skin stays closed to a small body's bead")
