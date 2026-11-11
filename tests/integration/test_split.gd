extends TestCase
## Pressure rings split in two: pinched by sharp geometry (the arena's wedge, a
## thin post, a wall's top corner) or crushed by a hard impact, never by a
## gentle landing or the weight of a pile. Pieces share the ring's area, take
## their own size's colour and cannot split again or merge back for
## GooTuning.SPLIT_LOCK seconds. A static tip inside a ring (GooWorld2D.pierce(),
## the wedge's apex in the arena) cuts it along the tip's axis even once it has
## settled, and a cut that would leave a crumb trims the ring off the tip
## instead (`trimmed`). Every measured number is printed.

const STEP: float = 1.0 / 60.0

var arena: Arena
var game: Game
## [radius_a, radius_b] of every split, in order.
var splits: Array[Vector2] = []
## Radius of every trimmed body, in order.
var trims: Array[float] = []

func before_each() -> void:
	arena = (load("res://scenes/arena.tscn") as PackedScene).instantiate() as Arena
	add_child(arena)
	game = Game.new()
	game.arena = arena
	add_child(game)
	splits.clear()
	trims.clear()
	game.split.connect(func(radius_a: float, radius_b: float, _position: Vector2) -> void:
		splits.append(Vector2(radius_a, radius_b)))
	game.trimmed.connect(func(radius: float, _position: Vector2) -> void: trims.append(radius))

# X, in global space, of open floor away from the walls and the wedge: as far
# from the left wall's inner face as the tests were first tuned at (220 px).
func _floor_x() -> float:
	return arena.inner_left() + 220.0

# Steps physics for up to `seconds` or until `blob` splits, sampling it every
# physics frame. Returns { split_time (s, -1 if it did not split), min_ratio
# (lowest area / target_area), min_gap (smallest pinch() gap, px), neck (the
# blob's split_neck), neck_time (longest stretch, s, with the gap under
# split_neck) }.
func _watch(blob: Goo2D, seconds: float) -> Dictionary:
	var stats := {
		"split_time": -1.0, "min_ratio": INF, "min_gap": INF,
		"neck": float(blob.tuning["split_neck"]), "splat": float(blob.tuning["splat_area_ratio"]),
		"neck_time": 0.0,
	}
	var under := 0
	var start := splits.size()
	for frame: int in roundi(seconds / STEP):
		await get_tree().physics_frame
		if splits.size() > start:
			stats["split_time"] = frame * STEP
			break
		if not is_instance_valid(blob) or not blob.is_inside_tree():
			break
		stats["min_ratio"] = minf(stats["min_ratio"], blob.area() / blob.target_area)
		var gap := float(blob.pinch()["gap"])
		stats["min_gap"] = minf(stats["min_gap"], gap)
		under = under + 1 if gap < float(stats["neck"]) else 0
		stats["neck_time"] = maxf(stats["neck_time"], under * STEP)
	await wait_frames(2)
	return stats

# Spawns a blob of `radius` and, once its split lock (armed when a ring is
# built) has run out, throws it at `velocity`; it is spawned as far above
# `pos` as it falls during the lock, so it is near `pos` when thrown. Prints
# where it was thrown from.
func _launch(radius: float, pos: Vector2, velocity: Vector2) -> Goo2D:
	var fall := 0.5 * GooTuning.gravity() * GooTuning.SPLIT_LOCK * GooTuning.SPLIT_LOCK
	var blob := game.spawn(radius, pos - Vector2(0.0, fall))
	while blob.split_lock() > 0.0:
		await get_tree().physics_frame
	blob.set_velocity(velocity)
	print("      thrown at %s from %s, %.0f px above the floor"
		% [velocity, blob.center(), arena.floor_y() - blob.center().y - radius])
	return blob

func _report(label: String, radius: float, stats: Dictionary) -> void:
	print("    %s: radius %.1f, %s, lowest area ratio %.3f (splat at %.3f), smallest neck gap %.1f px (split under %.1f for %.2f s; held under it for %.2f s)"
		% [label, radius,
			"split after %.2f s" % stats["split_time"] if stats["split_time"] >= 0.0 else "no split",
			stats["min_ratio"], stats["splat"], stats["min_gap"], stats["neck"], GooTuning.SPLIT_HOLD,
			stats["neck_time"]])

# Checks the two pieces left by one split of a blob of `radius`.
func _assert_pieces(radius: float) -> void:
	assert_eq(splits.size(), 1, "split fired once")
	var pieces := game.bodies()
	assert_eq(pieces.size(), 2, "two blobs after the split")
	if pieces.size() != 2:
		return
	var ra := pieces[0].radius
	var rb := pieces[1].radius
	print("      pieces %.1f + %.1f px: ra² + rb² = %.0f of r² = %.0f (%.1f%%)"
		% [ra, rb, ra * ra + rb * rb, radius * radius, 100.0 * (ra * ra + rb * rb) / (radius * radius)])
	assert_almost_eq(ra * ra + rb * rb, radius * radius, 0.1 * radius * radius, "the pieces hold the blob's area")
	for piece: Goo2D in pieces:
		assert_eq(piece.get_tint(), GooTuning.color(piece.radius), "piece of %.1f px in its own colour" % piece.radius)

func test_wedge_splits_a_big_blob() -> void:
	timeout_sec = 15.0
	var radius := GooTuning.radius_at(0.9)
	var apex := arena.wedge_apex()
	var x := minf(apex.x, arena.inner_right() - radius - 2.0)
	var blob := game.spawn(radius, Vector2(x, apex.y - 200.0 - radius))
	var stats := await _watch(blob, 3.0)
	_report("big blob on the wedge (centre x %.0f, apex x %.0f)" % [x, apex.x], radius, stats)
	assert_true(stats["split_time"] >= 0.0, "a big blob landing on the wedge splits within 3 s")
	_assert_pieces(radius)

func test_wedge_does_not_split_a_small_blob() -> void:
	timeout_sec = 15.0
	var radius := GooTuning.MIN_RADIUS
	var apex := arena.wedge_apex()
	var blob := game.spawn(radius, Vector2(apex.x, apex.y - 200.0 - radius))
	var stats := await _watch(blob, 3.0)
	_report("smallest blob dropped 200 px onto the wedge (pieces may not be under %.1f px)"
		% (GooTuning.MIN_RADIUS * GooWorld2D.MIN_PIECE_RATIO), radius, stats)
	assert_eq(splits.size(), 0, "the smallest blob never splits")
	assert_eq(game.bodies().size(), 1)

func test_thin_post_splits_a_big_blob() -> void:
	timeout_sec = 15.0
	var post := StaticBody2D.new()
	post.collision_layer = 1
	post.collision_mask = 0
	var shape := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = Vector2(12.0, 160.0)
	shape.shape = rect
	post.add_child(shape)
	var post_x := arena.inner_left() + 170.0
	post.position = Vector2(post_x, Arena.FLOOR_Y - 80.0)
	add_child(post)
	var radius := GooTuning.radius_at(0.9)
	var blob := game.spawn(radius, Vector2(post_x, Arena.FLOOR_Y - 160.0 - 200.0 - radius))
	var stats := await _watch(blob, 3.0)
	_report("big blob on a 12 px post", radius, stats)
	assert_true(stats["split_time"] >= 0.0, "a big blob dropped on a thin post splits within 3 s")
	_assert_pieces(radius)

func test_wall_corner_splits_a_blob_landing_across_it() -> void:
	timeout_sec = 15.0
	var radius := GooTuning.radius_at(0.85)
	var corner := Vector2(arena.inner_left(), arena.global_position.y + Arena.WALL_TOP_Y)
	# Thrown up and left from inside the arena, 320 px from the left wall, it
	# comes down with its centre over the corner (measured: x ≈ 167, the corner
	# + 7, when it passes y = 50 on the way down; printed below).
	var blob := game.spawn(radius, Vector2(arena.inner_left() + 320.0, 700.0))
	blob.set_velocity(Vector2(-250.0, -1300.0))
	# The callback holds the blob's id, not the blob: a lambda capturing a freed
	# blob (split) prints an error.
	var pass_over: Array[float] = [NAN]
	var blob_id := blob.get_instance_id()
	var on_frame := func() -> void:
		var thrown := instance_from_id(blob_id) as Goo2D
		if is_nan(pass_over[0]) and thrown != null and thrown.is_inside_tree() \
				and thrown.average_velocity().y > 0.0 and thrown.center().y >= 50.0:
			pass_over[0] = thrown.center().x
	get_tree().physics_frame.connect(on_frame)
	var stats := await _watch(blob, 3.5)
	get_tree().physics_frame.disconnect(on_frame)
	print("      centre passed y = 50 on the way down at x = %.1f (corner x %.1f, %+.1f px)"
		% [pass_over[0], corner.x, pass_over[0] - corner.x])
	_report("blob thrown onto the left wall's top corner %s" % corner, radius, stats)
	assert_true(stats["split_time"] >= 0.0, "a blob landing across the wall's top corner splits")
	_assert_pieces(radius)
	var inside := 0
	for piece: Goo2D in game.bodies():
		print("      piece %.1f px at %s" % [piece.radius, piece.center()])
		if piece.center().x > corner.x:
			inside += 1
	assert_eq(inside, 1, "one piece falls back into the arena, the other off the wall's outside")

func test_impact_splits_a_fast_blob() -> void:
	timeout_sec = 10.0
	var radius := GooTuning.radius_at(0.5)
	var blob := await _launch(radius, Vector2(_floor_x(), Arena.FLOOR_Y - 400.0 - radius), Vector2(0.0, 1500.0))
	var stats := await _watch(blob, 1.0)
	_report("blob thrown down at 1500 px/s from 400 px", radius, stats)
	assert_true(stats["split_time"] >= 0.0, "a hard impact splits the blob within 1 s")
	_assert_pieces(radius)

func test_gentle_landing_does_not_split() -> void:
	timeout_sec = 10.0
	var radius := GooTuning.radius_at(0.5)
	var blob := game.spawn(radius, Vector2(_floor_x(), Arena.FLOOR_Y - 150.0 - radius))
	var stats := await _watch(blob, 2.0)
	_report("blob dropped from 150 px", radius, stats)
	assert_eq(splits.size(), 0, "a gentle landing does not split")
	assert_eq(game.bodies().size(), 1)
	assert_gt(stats["min_ratio"], stats["splat"], "its area stays above the splat ratio")

func test_bottom_of_a_pile_does_not_split() -> void:
	timeout_sec = 10.0
	# Equal blobs would merge in a Game (which registers every Goo2D added under
	# it), so the pile is built straight with Goo2D.make() under a plain node
	# beside it and every ring's own `pinched` is watched instead.
	var pile_root := Node2D.new()
	add_child(pile_root)
	var radius := GooTuning.radius_at(0.5)
	var pile: Array[Goo2D] = []
	var pinches: Array[int] = [0]
	for level: int in 4:
		var pos := Vector2(_floor_x() + 6.0 * (level % 2), Arena.FLOOR_Y - radius - level * (2.0 * radius + 2.0))
		var blob := Goo2D.make(radius, pos, pile_root)
		blob.pinched.connect(func(_a: int, _b: int) -> void: pinches[0] += 1)
		pile.append(blob)
	var bottom := pile[0]
	var lowest := INF
	var narrowest := INF
	for frame: int in roundi(3.0 / STEP):
		await get_tree().physics_frame
		lowest = minf(lowest, bottom.area() / bottom.target_area)
		narrowest = minf(narrowest, float(bottom.pinch()["gap"]))
	print("    bottom of a pile of 4 radius %.1f blobs over 3 s: lowest area ratio %.3f (splat at %.3f), smallest neck gap %.1f px (split under %.1f), %d pinches"
		% [radius, lowest, bottom.tuning["splat_area_ratio"], narrowest, bottom.tuning["split_neck"], pinches[0]])
	assert_eq(pinches[0], 0, "no ring of the pile asks to split")
	assert_gt(lowest, float(bottom.tuning["splat_area_ratio"]))

func test_impact_speed_sweep() -> void:
	timeout_sec = 60.0
	# Clear of the wall blade's tip: the biggest blob at _floor_x() would be
	# spawned around it, and a tip inside a blob cuts it even while split locked.
	var blade_tip := (arena.get_node("WallBlade") as Blade).tip()
	for t: float in [0.1, 0.5, 0.9]:
		var radius := GooTuning.radius_at(t)
		var x := maxf(_floor_x(), blade_tip.x + radius + 20.0)
		var lowest_speed := -1.0
		var ratios := PackedStringArray()
		for speed: float in [600.0, 900.0, 1200.0, 1500.0, 1800.0]:
			game.reset()
			splits.clear()
			await wait_frames(2)
			var blob := await _launch(radius, Vector2(x, Arena.FLOOR_Y - 100.0 - radius), Vector2(0.0, speed))
			var stats := await _watch(blob, 1.0)
			ratios.append("%.0f: %.3f%s" % [speed, stats["min_ratio"], " split" if stats["split_time"] >= 0.0 else ""])
			if stats["split_time"] >= 0.0:
				lowest_speed = speed
				break
		print("    radius %.1f (size_t %.1f, splat at %.3f): %s; lowest splitting launch speed %s"
			% [radius, t, GooTuning.splat_area_ratio(radius), ", ".join(ratios),
				"%.0f px/s" % lowest_speed if lowest_speed > 0.0 else "none up to 1800 px/s"])

func test_pieces_neither_split_again_nor_merge_back_within_the_lock() -> void:
	timeout_sec = 10.0
	var radius := GooTuning.radius_at(0.5)
	var blob := await _launch(radius, Vector2(_floor_x(), Arena.FLOOR_Y - 400.0 - radius), Vector2(0.0, 1500.0))
	var stats := await _watch(blob, 1.0)
	assert_true(stats["split_time"] >= 0.0, "the impact splits the blob")
	var pieces := game.bodies()
	assert_eq(pieces.size(), 2)
	for piece: Goo2D in pieces:
		assert_gt(piece.split_lock(), 0.0, "a new piece starts split-locked")
		assert_true(game.merge_locked(piece), "a new piece starts merge-locked")
	var merges: Array[int] = [0]
	game.merged.connect(func(_radius: float, _position: Vector2) -> void: merges[0] += 1)
	var fewest := 2
	var most := 2
	var merges_in_lock := 0
	var lock_frames := roundi((GooWorld2D.MERGE_LOCK - 2.0 * STEP) / STEP)
	for frame: int in roundi((GooTuning.SPLIT_LOCK - 2.0 * STEP) / STEP):
		await get_tree().physics_frame
		if frame < lock_frames:
			fewest = mini(fewest, game.bodies().size())
			merges_in_lock = merges[0]
		most = maxi(most, game.bodies().size())
	print("    after the split: %d..2 blobs and %d merges within the %.2f s merge lock; at most %d blobs and %d splits within the %.2f s split lock"
		% [fewest, merges_in_lock, GooWorld2D.MERGE_LOCK, most, splits.size(), GooTuning.SPLIT_LOCK])
	assert_eq(fewest, 2, "the pieces do not merge back within MERGE_LOCK")
	assert_eq(merges_in_lock, 0)
	assert_eq(most, 2, "the pieces do not split again within SPLIT_LOCK")
	assert_eq(splits.size(), 1)

func test_equal_pieces_side_by_side_do_not_merge_within_the_merge_lock() -> void:
	timeout_sec = 10.0
	var radius := 50.0
	var blob := game.spawn(radius, Vector2(_floor_x(), Arena.FLOOR_Y - radius))
	await wait_seconds(0.6)
	# Cut down the middle, from the top bead to the one opposite it along the
	# ring: two equal pieces side by side.
	var points := blob.bead_points()
	var top := 0
	for i: int in points.size():
		if points[i].y < points[top].y:
			top = i
	game.cut(blob, top, (top + points.size() / 2) % points.size())
	assert_eq(splits.size(), 1, "the cut is made")
	var pieces := game.bodies()
	assert_eq(pieces.size(), 2)
	if pieces.size() != 2:
		return
	assert_true(GooTuning.can_merge(pieces[0].radius, pieces[1].radius), "the pieces are of mergeable sizes")
	var touched_at: Array[int] = [-1]
	var start := Engine.get_physics_frames()
	pieces[0].touched.connect(func(_other: Goo2D) -> void:
		if touched_at[0] < 0:
			touched_at[0] = Engine.get_physics_frames() - start)
	var merged_at := -1
	for frame: int in roundi(1.5 / STEP):
		await get_tree().physics_frame
		var merging := false
		for piece: Goo2D in pieces:
			merging = merging or (is_instance_valid(piece) and piece.merging)
		if merging or game.bodies().size() != 2:
			merged_at = Engine.get_physics_frames() - start
			break
	print("    pieces %.1f + %.1f px side by side: first touch after %s, merge started after %s (lock %.2f s)"
		% [pieces[0].radius, pieces[1].radius,
			"%.3f s" % (touched_at[0] * STEP) if touched_at[0] >= 0 else "never",
			"%.3f s" % (merged_at * STEP) if merged_at >= 0 else "no merge within 1.5 s", GooWorld2D.MERGE_LOCK])
	assert_true(merged_at < 0 or merged_at * STEP >= GooWorld2D.MERGE_LOCK - STEP,
		"the pieces do not start merging within the %.2f s merge lock" % GooWorld2D.MERGE_LOCK)

func test_near_end_pinch_does_not_split() -> void:
	var radius := GooTuning.radius_at(0.5)
	var blob := game.spawn(radius, Vector2(_floor_x(), Arena.FLOOR_Y - radius))
	await wait_frames(2)
	game.cut(blob, 0, 2)
	await wait_frames(2)
	assert_eq(splits.size(), 0, "a cut two beads long would leave a crumb: no split")
	assert_eq(game.bodies().size(), 1)
	assert_true(is_instance_valid(blob) and blob.is_inside_tree())

func test_resting_ring_has_no_neck() -> void:
	timeout_sec = 10.0
	for t: float in [0.0, 0.5, 0.9, 1.0]:
		game.reset()
		await wait_frames(2)
		var radius := GooTuning.radius_at(t)
		var blob := game.spawn(radius, Vector2(_floor_x(), Arena.FLOOR_Y - radius))
		await wait_seconds(1.0)
		var neck: Dictionary = blob.pinch()
		var thickness: Dictionary = Goo2D.find_pinch(blob.bead_points(), blob.bead_radius(), 0.0)
		print("    resting radius %.1f ring: narrowest neck gap %.1f px (split under %.1f px); flattened thickness gap %.1f px"
			% [radius, neck["gap"], blob.tuning["split_neck"], thickness["gap"]])
		assert_gt(float(neck["gap"]), 2.0 * float(blob.tuning["split_neck"]), "a resting ring is nowhere near a neck")
		assert_eq(splits.size(), 0)

func test_wedge_point_splits_launch_size_blobs() -> void:
	timeout_sec = 90.0
	# Launch-size blobs (DropController.DROP_MIN_RADIUS .. DROP_MAX_RADIUS) landing
	# centred on the wedge's apex at launch speeds: a 40 px blob from 800 px/s up
	# and a 48 px one from 500 px/s up must split within 2 s.
	var apex := arena.wedge_apex()
	var results: Dictionary[Vector2, Dictionary] = {}
	for radius: float in [28.0, 40.0, 48.0]:
		var row := PackedStringArray()
		for speed: float in [500.0, 800.0, 1200.0]:
			game.reset()
			splits.clear()
			await wait_frames(2)
			var blob := await _launch(radius, apex - Vector2(0.0, radius + 4.0), Vector2(0.0, speed))
			var stats := await _watch(blob, 2.0)
			results[Vector2(radius, speed)] = stats
			row.append("%4.0f px/s: %s, smallest neck gap %.1f px (split under %.1f, under it for %.2f s)"
				% [speed, "split after %.2f s into %.1f + %.1f px" % [stats["split_time"], splits[-1].x, splits[-1].y]
						if stats["split_time"] >= 0.0 else "no split",
					stats["min_gap"], stats["neck"], stats["neck_time"]])
		print("    radius %.0f on the wedge apex: %s" % [radius, "; ".join(row)])
	for key: Vector2 in results:
		var must := (key.x >= 40.0 and key.y >= 800.0) or (key.x >= 48.0 and key.y >= 500.0)
		if must:
			assert_true(float(results[key]["split_time"]) >= 0.0,
				"a %.0f px blob landing on the wedge apex at %.0f px/s splits within 2 s" % [key.x, key.y])

func test_drop_from_the_launch_point_onto_the_floor_does_not_split() -> void:
	timeout_sec = 30.0
	# Launch-size blobs let go at the launch point with no launch speed fall
	# about 800 px onto the flat floor, away from the wedge: none may split.
	for radius: float in [DropController.DROP_MIN_RADIUS, 34.0, 40.0, 44.0, DropController.DROP_MAX_RADIUS]:
		game.reset()
		splits.clear()
		await wait_frames(2)
		var blob := game.spawn(radius, Vector2(_floor_x(), arena.launch_point().y))
		var stats := await _watch(blob, 2.0)
		_report("radius %.0f let go at the launch point's height" % radius, radius, stats)
		assert_eq(splits.size(), 0, "a %.0f px blob dropped from the launch point does not split" % radius)
		assert_eq(game.bodies().size(), 1)

# Spawns a body of `radius` (of `shape`, if given) resting on open floor and
# waits up to 3 s for it to settle. Returns it, or null if it never settled.
func _settled_on_floor(radius: float, shape: GooShape = null) -> Goo2D:
	var blob := game.spawn(radius, Vector2(_floor_x(), Arena.FLOOR_Y - radius), shape)
	for frame: int in roundi(3.0 / STEP):
		await get_tree().physics_frame
		if blob.settled:
			return blob
	return null

# A point inside the bead loop of `blob`, 0.7 bead radii in from its
# right-most bead centre, level with its centre: a vertical cut through it
# leaves a crumb on the right. (With 16-30-bead rings that was one bead radius
# in, 10.4 px for a settled 40 px blob where 1.5 bead radii left 14.6 px, a
# viable piece; a 12-22-bead ring's beads are a third bigger.)
static func _near_right_edge(blob: Goo2D) -> Vector2:
	var right := -INF
	for point: Vector2 in blob.bead_points():
		right = maxf(right, point.x)
	return Vector2(right - 0.7 * blob.bead_radius(), blob.center().y)

# True if `point` is inside the bead loop of any body of the game.
func _inside_any(point: Vector2) -> bool:
	for body: Goo2D in game.bodies():
		if GooLoop.point_in_loop(point, body.bead_points()):
			return true
	return false

func test_tip_near_the_edge_of_a_settled_blob_trims_it_off_the_tip() -> void:
	timeout_sec = 10.0
	var radius := 40.0
	var blob := await _settled_on_floor(radius)
	assert_not_null(blob, "the blob settles")
	if blob == null:
		return
	var tip := _near_right_edge(blob)
	assert_true(GooLoop.point_in_loop(tip, blob.bead_points()), "the tip is inside the loop")
	assert_eq(game.pierce(tip, Vector2.UP), 1, "the settled blob is cut")
	await wait_frames(2)
	print("    tip %.1f px right of a settled %.0f px blob's centre: %d trims %s, %d splits, %d bodies"
		% [tip.x - _floor_x(), radius, trims.size(), trims, splits.size(), game.bodies().size()])
	assert_eq(splits.size(), 0, "a cut leaving a crumb is no split")
	assert_eq(trims.size(), 1, "the blob is trimmed instead")
	assert_eq(game.bodies().size(), 1)
	if game.bodies().size() != 1:
		return
	var trimmed := game.bodies()[0]
	assert_almost_eq(trimmed.radius, radius, 0.001, "the trimmed body keeps the whole area")
	assert_true(trimmed.shape.is_round())
	assert_false(GooLoop.point_in_loop(tip, trimmed.bead_points()), "the tip is outside the new ring")
	await wait_seconds(1.0)
	assert_eq(game.bodies().size(), 1)
	if game.bodies().size() == 1:
		print("      after 1 s: area %.0f of %.0f px²" % [game.bodies()[0].area(), PI * radius * radius])
		assert_almost_eq(game.bodies()[0].area(), PI * radius * radius, 0.1 * PI * radius * radius,
			"it inflates back to the whole area")

func test_tip_near_the_edge_of_a_settled_square_trims_it_into_a_polygon_of_its_area() -> void:
	timeout_sec = 10.0
	var radius := 44.0
	var blob := await _settled_on_floor(radius, GooShape.regular(4, radius))
	assert_not_null(blob, "the square settles")
	if blob == null:
		return
	var tip := _near_right_edge(blob)
	assert_eq(game.pierce(tip, Vector2.UP), 1, "the settled square is cut")
	await wait_frames(2)
	assert_eq(splits.size(), 0, "a cut leaving a sliver is no split")
	assert_eq(trims.size(), 1, "the square is trimmed instead")
	assert_eq(game.bodies().size(), 1)
	if game.bodies().size() != 1:
		return
	var trimmed := game.bodies()[0]
	print("    tip near a settled %.0f px square's right side: trimmed into a %d-gon of radius %.1f, %d beads"
		% [radius, trimmed.shape.outline.size(), trimmed.radius, trimmed.particle_count()])
	assert_false(trimmed.shape.is_round(), "still a polygon")
	assert_eq(trimmed.shape.outline.size(), 4, "a square trimmed by a vertical line is a rectangle")
	assert_almost_eq(trimmed.shape.area(), PI * radius * radius, 0.01 * PI * radius * radius,
		"its rest outline holds the whole area")
	assert_eq(trimmed.rest_shape.size(), trimmed.particle_count())
	assert_false(GooLoop.point_in_loop(tip, trimmed.bead_points()), "the tip is outside the new ring")

func test_tip_through_the_middle_of_a_settled_blob_splits_it() -> void:
	timeout_sec = 10.0
	var blob := await _settled_on_floor(40.0)
	assert_not_null(blob, "the blob settles")
	if blob == null:
		return
	assert_eq(game.pierce(blob.center(), Vector2.UP), 1)
	await wait_frames(2)
	assert_eq(splits.size(), 1, "cut in two")
	assert_eq(trims.size(), 0)
	assert_eq(game.bodies().size(), 2)

func test_pierce_leaves_a_blob_the_tip_only_touches() -> void:
	timeout_sec = 10.0
	var blob := await _settled_on_floor(40.0)
	assert_not_null(blob, "the blob settles")
	if blob == null:
		return
	var right := _near_right_edge(blob) + Vector2(2.0 * blob.bead_radius(), 0.0)
	assert_false(GooLoop.point_in_loop(right, blob.bead_points()))
	assert_eq(game.pierce(right, Vector2.UP), 0, "a tip outside the bead loop cuts nothing")
	await wait_frames(2)
	assert_eq(splits.size() + trims.size(), 0)
	assert_true(is_instance_valid(blob) and blob.settled, "and leaves it asleep")

func test_direct_cut_leaving_a_crumb_is_still_refused() -> void:
	var blob := game.spawn(40.0, Vector2(_floor_x(), Arena.FLOOR_Y - 40.0))
	await wait_frames(2)
	game.cut(blob, 0, 2)
	await wait_frames(2)
	assert_eq(splits.size() + trims.size(), 0, "cut() itself never trims")
	assert_true(is_instance_valid(blob) and blob.is_inside_tree())

func test_wedge_cuts_a_blob_with_its_apex_inside() -> void:
	timeout_sec = 10.0
	# A blob put down with the wedge's apex 10 px inside its bead loop, split
	# locked as every new body is: the game cuts it along the wedge's axis at once.
	var radius := 48.0
	var apex := arena.wedge_apex()
	var ring_radius: float = GooTuning.tuning(radius)["ring_radius"]
	game.spawn(radius, apex - Vector2(0.0, ring_radius - 10.0))
	assert_true(_inside_any(apex), "the apex starts inside the loop")
	await wait_frames(3)
	print("    %.0f px blob with the wedge's apex inside: %d splits %s, %d trims, %d bodies"
		% [radius, splits.size(), splits, trims.size(), game.bodies().size()])
	assert_eq(splits.size() + trims.size(), 1, "cut along the wedge's axis within 3 frames")
	assert_false(_inside_any(apex), "the apex is outside every loop")
	assert_eq(arena.wedge_axis(), Vector2.UP)
