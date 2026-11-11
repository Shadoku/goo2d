extends TestCase
## The arena's blades cut a blob whose bead loop their tip gets into, along the
## blade's axis, whatever its speed: a blob sinking onto the floor blade, one
## thrown slowly into the wall blade, a launch-size one dropped on the floor
## blade. A blob resting beside a blade is left alone. No body is left on a
## tip: a cut that would leave a crumb trims the body off the tip instead, a
## tip inside a fresh piece cuts it through its split lock, and a blade gives
## no wall grip. Every measured number is printed.

const MAIN_SCENE := preload("res://scenes/main.tscn")
const STEP: float = 1.0 / 60.0

var arena: Arena
var game: Game
## [radius_a, radius_b] of every split, in order.
var splits: Array[Vector2] = []

func before_each() -> void:
	var main := MAIN_SCENE.instantiate()
	add_child(main)
	arena = main.get_node("Arena") as Arena
	game = main.get_node("Game") as Game
	splits.clear()
	game.split.connect(func(radius_a: float, radius_b: float, _position: Vector2) -> void:
		splits.append(Vector2(radius_a, radius_b)))

func _blade(blade_name: String) -> Blade:
	return arena.get_node(blade_name) as Blade

# Steps physics for up to `seconds` or until a split, then two more frames.
# Returns the seconds until the split, -1 if none.
func _watch(seconds: float) -> float:
	var start := splits.size()
	var split_time := -1.0
	for frame: int in roundi(seconds / STEP):
		await get_tree().physics_frame
		if splits.size() > start:
			split_time = (frame + 1) * STEP
			break
	await wait_frames(2)
	return split_time

# Spawns a blob of `radius` and, once its split lock (armed when a ring is
# built) has run out, throws it at `velocity`; it is spawned as far above
# `pos` as it falls during the lock, so it is near `pos` when thrown.
func _launch(radius: float, pos: Vector2, velocity: Vector2) -> Goo2D:
	var fall := 0.5 * GooTuning.gravity() * GooTuning.SPLIT_LOCK * GooTuning.SPLIT_LOCK
	var blob := game.spawn(radius, pos - Vector2(0.0, fall))
	while blob.split_lock() > 0.0:
		await get_tree().physics_frame
	blob.set_velocity(velocity)
	print("      thrown at %s from %s" % [velocity, blob.center()])
	return blob

# Checks the two pieces of one split of a blob whose area was `area` (px²),
# and prints them. Their area is measured once they have inflated
# (GooTuning.inflate_time()) and until their split lock runs out: the
# largest total over those frames, as a piece landing on the floor is squashed
# for a few frames. (Equal pieces may merge back once their merge lock is over;
# they are still both there while the merge runs.)
func _assert_pieces(label: String, split_time: float, area: float) -> void:
	assert_eq(splits.size(), 1, "split fired once")
	var pieces := game.bodies()
	assert_eq(pieces.size(), 2, "two blobs after the split")
	if pieces.size() != 2:
		return
	var total := 0.0
	var from := roundi(GooTuning.inflate_time() / STEP)
	for frame: int in roundi(GooTuning.SPLIT_LOCK / STEP) - 4:
		await get_tree().physics_frame
		if frame < from:
			continue
		var sum := 0.0
		for piece: Goo2D in pieces:
			assert_true(is_instance_valid(piece) and piece.is_inside_tree(), "the piece is still there")
			if is_instance_valid(piece):
				sum += piece.area()
		total = maxf(total, sum)
	print("    %s: split after %.2f s into %.1f + %.1f px; pieces' area %.0f of %.0f px² (%.1f%%)"
		% [label, split_time, splits[0].x, splits[0].y, total, area, 100.0 * total / area])
	assert_eq(splits.size(), 1, "the pieces are not cut again within their split lock")
	assert_almost_eq(total, area, 0.05 * area, "the pieces hold the blob's area")

func test_blob_sinking_onto_the_floor_blade_splits() -> void:
	timeout_sec = 10.0
	var blade := _blade("FloorBlade")
	var radius := GooTuning.radius_at(0.5)
	var blob := game.spawn(radius, blade.tip() - Vector2(0.0, 20.0 + radius))
	var area := blob.target_area
	var split_time := await _watch(1.0)
	assert_true(split_time >= 0.0, "a blob sinking onto the floor blade splits within 1 s")
	await _assert_pieces("radius %.1f blob sinking onto the floor blade" % radius, split_time, area)

func test_blob_resting_beside_the_floor_blade_does_not_split() -> void:
	timeout_sec = 10.0
	var blade := _blade("FloorBlade")
	var radius := GooTuning.radius_at(0.5)
	var x := blade.global_position.x - blade.base_width / 2.0 - radius - 4.0
	var blob := game.spawn(radius, Vector2(x, arena.floor_y() - radius))
	var split_time := await _watch(2.0)
	print("    radius %.1f blob beside the floor blade: %s; its top %.1f px below the tip"
		% [radius, "split after %.2f s" % split_time if split_time >= 0.0 else "no split in 2 s",
			_top(blob) - blade.tip().y if is_instance_valid(blob) else NAN])
	assert_eq(splits.size(), 0, "a blob beside the blade is not cut")
	assert_eq(game.bodies().size(), 1)

func test_blob_thrown_slowly_into_the_wall_blade_splits() -> void:
	timeout_sec = 10.0
	var blade := _blade("WallBlade")
	var radius := GooTuning.radius_at(0.5)
	var blob := await _launch(radius, blade.tip() + Vector2(radius + 20.0, -10.0), Vector2(-120.0, 0.0))
	var area := blob.target_area
	var split_time := await _watch(2.0)
	assert_true(split_time >= 0.0, "a blob thrown at 120 px/s into the wall blade splits")
	await _assert_pieces("radius %.1f blob thrown at 120 px/s into the wall blade" % radius, split_time, area)

func test_launch_size_blob_dropped_on_the_floor_blade_splits() -> void:
	timeout_sec = 10.0
	var blade := _blade("FloorBlade")
	var radius := 36.0
	var blob := game.spawn(radius, blade.tip() - Vector2(0.0, 150.0 + radius))
	var area := blob.target_area
	var split_time := await _watch(2.0)
	assert_true(split_time >= 0.0, "a 36 px blob dropped 150 px onto the floor blade splits")
	await _assert_pieces("36 px blob dropped 150 px onto the floor blade", split_time, area)
	for piece: Vector2 in splits:
		assert_true(minf(piece.x, piece.y) >= GooTuning.MIN_RADIUS * GooWorld2D.MIN_PIECE_RATIO,
			"no piece under %.1f px" % (GooTuning.MIN_RADIUS * GooWorld2D.MIN_PIECE_RATIO))

# Steps physics for `seconds` and returns the physics frames, counted from 0,
# on which some body's bead loop held `tip`.
func _frames_impaled(tip: Vector2, seconds: float) -> PackedInt32Array:
	var frames := PackedInt32Array()
	for frame: int in roundi(seconds / STEP):
		await get_tree().physics_frame
		for body: Goo2D in game.bodies():
			if GooLoop.point_in_loop(tip, body.bead_points()):
				frames.append(frame)
				break
	return frames

func test_triangle_thrown_off_centre_onto_the_floor_blade_comes_off_its_tip() -> void:
	timeout_sec = 20.0
	# tools/stability.gd impale's one stuck case: a 36 px triangle thrown down
	# 24 px left of the floor blade's tip. Every cut its tip asks for would leave
	# a corner under the sliver guard; it hung on the tip with the tip inside.
	var tip := _blade("FloorBlade").tip()
	for speed: float in [900.0, 1600.0]:
		game.reset()
		await wait_frames(2)
		var radius := 36.0
		var blob := game.spawn(radius, tip + Vector2(-24.0, -radius - 240.0), GooShape.regular(3, radius))
		blob.set_velocity(Vector2(0.0, speed))
		var frames := await _frames_impaled(tip, 3.0)
		var late := 0
		for frame: int in frames:
			if frame * STEP >= 1.0:
				late += 1
		print("    36 px triangle thrown at %.0f px/s 24 px off the floor blade's tip: tip inside a loop on %d frames (first %s, last %s), %d of them after 1 s; %d splits, %d bodies"
			% [speed, frames.size(), "%.2f s" % (frames[0] * STEP) if not frames.is_empty() else "-",
				"%.2f s" % (frames[-1] * STEP) if not frames.is_empty() else "-", late, splits.size(), game.bodies().size()])
		assert_eq(late, 0, "at %.0f px/s the tip is outside every loop from 1 s on" % speed)

func test_small_piece_dropped_on_the_wall_blade_is_not_left_on_its_tip() -> void:
	timeout_sec = 20.0
	# Every cut of an 18 px piece would leave a piece under MIN_PIECE_RATIO.
	var tip := _blade("WallBlade").tip()
	for dx: float in [-6.0, 0.0, 6.0]:
		game.reset()
		await wait_frames(2)
		game.spawn(18.0, tip + Vector2(dx, -60.0))
		var frames := await _frames_impaled(tip, 2.0)
		var late := 0
		for frame: int in frames:
			if frame * STEP >= 1.0:
				late += 1
		print("    18 px piece dropped %.0f px off the wall blade's tip: tip inside a loop on %d frames, %d after 1 s; %d bodies"
			% [dx, frames.size(), late, game.bodies().size()])
		assert_eq(late, 0, "dropped %.0f px off, the tip is outside every loop from 1 s on" % dx)

func test_cut_along_passes_the_split_lock_only_with_the_tip_inside() -> void:
	var radius := 40.0
	var blob := game.spawn(radius, Vector2(arena.inner_left() + 700.0, arena.floor_y() - radius - 10.0))
	await wait_frames(1)
	assert_gt(blob.split_lock(), 0.0, "a fresh blob is split locked")
	var points := blob.bead_points()
	var bottom := 0
	for i: int in points.size():
		if points[i].y > points[bottom].y:
			bottom = i
	var touching := points[bottom] + Vector2(0.0, 0.5 * blob.bead_radius())
	assert_false(GooLoop.point_in_loop(touching, points))
	assert_false(game.cut_along(blob, touching, Vector2.UP),
		"a tip only touching a split-locked blob does not cut it")
	assert_true(game.cut_along(blob, blob.center(), Vector2.UP),
		"a tip inside a split-locked blob cuts it")
	await wait_frames(2)
	assert_eq(splits.size(), 1, "the cut through the middle is made")
	assert_eq(game.bodies().size(), 2)

func test_a_blade_gives_no_wall_grip() -> void:
	# The world mirrors the static shapes into its kernel at its next step.
	await get_tree().physics_frame
	await get_tree().physics_frame
	var blade := _blade("FloorBlade")
	assert_true(blade.is_in_group(GooTuning.NO_GRIP_GROUP), "a blade opts out of the grip")
	# The world mirrors the blade's triangle into its kernel as a shape the goo
	# does not grip, and the arena's own shapes as ones it does.
	var goo := game.kernel()
	var blade_shapes := 0
	var gripping_shapes := 0
	for id: int in goo.static_shape_ids():
		var info: Dictionary = goo.static_shape_info(id)
		var points: PackedVector2Array = info["points"]
		if GooLoop.centroid(points).distance_to(blade.global_position + Vector2(0.0, -blade.length / 3.0)) < 1.0:
			blade_shapes += 1
			assert_false(info["grip"], "a blade's shape gives no grip")
		elif info["grip"]:
			gripping_shapes += 1
	assert_eq(blade_shapes, 1, "the floor blade's triangle is in the kernel")
	assert_eq(gripping_shapes, 4, "the floor, the walls and the wedge grip")
	# A blob sliding down the blade's side grips nothing there.
	var blob := game.spawn(GooTuning.MIN_RADIUS, blade.tip() + Vector2(-GooTuning.MIN_RADIUS - 2.0, -10.0))
	for frame: int in 20:
		await get_tree().physics_frame
		if not is_instance_valid(blob) or blob.is_queued_for_deletion():
			return
		for i: int in blob.particle_count():
			if blob.bead_gripping(i):
				assert_gt(blob.bead_position(i).y + blob.bead_radius(), arena.floor_y() - 2.0,
					"only beads on the floor grip")

# Global y of the top of `blob`'s beads.
func _top(blob: Goo2D) -> float:
	var top := INF
	for point: Vector2 in blob.bead_points():
		top = minf(top, point.y)
	return top - blob.bead_radius()
