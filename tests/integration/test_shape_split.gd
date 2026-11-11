extends TestCase
## Polygon bodies split in rest space (GooShape.cut_ring()): a square cut
## along a chord becomes two polygon bodies whose outlines are the two sides of
## its rest outline cut along the chord's fitted rest points, sharing its area
## exactly; a cut that would leave a sliver is not made; round blobs still
## split into round pieces. A square dropped onto the wedge splits into two
## polygon pieces that hold their shape once they settle. Concave shapes (two
## squares fused, a U) cut across a junction or an arm, a small tip cut off a
## fused shape's corner and a small cap cut off a round blob give pieces that
## are born sane: their area holds and no bead is thrown. Every measured number
## is printed.

const STEP: float = 1.0 / 60.0
## Largest per-bead RMS distance, as a fraction of the equivalent radius,
## between a settled ring's beads and its rest shape fitted onto them: the
## tolerance test_shapes.gd holds dropped squares and triangles to.
const SHAPE_TOLERANCE: float = 0.15

var arena: Arena
var game: Game
## One entry per split: { "radii": Vector2, "pieces": Array of { "kind",
## "vertices", "area", "radius", "beads", "rest", "corners" } }, recorded when
## the split is announced.
var splits: Array[Dictionary] = []
## When set, pieces never merge: what this file tests is the split, and which
## pieces may merge, and into what, is GooWorld2D.can_merge()'s business.
var keep_pieces: bool = false

func before_each() -> void:
	arena = (load("res://scenes/arena.tscn") as PackedScene).instantiate() as Arena
	add_child(arena)
	game = Game.new()
	game.arena = arena
	add_child(game)
	splits.clear()
	game.split.connect(_on_split)

# Records the two newest blobs, the pieces the split just registered.
func _on_split(radius_a: float, radius_b: float, _position: Vector2) -> void:
	var all := game.bodies()
	var pieces: Array[Dictionary] = []
	for piece: Goo2D in all.slice(maxi(all.size() - 2, 0)):
		if keep_pieces:
			piece.merge_lock_until = INF
		pieces.append({
			"kind": piece.shape.kind,
			"vertices": piece.shape.outline.size(),
			"area": piece.shape.area(),
			"radius": piece.radius,
			"shape_radius": piece.shape.radius(),
			"beads": piece.particle_count(),
			"rest": piece.rest_shape.size(),
			"corners": piece.corner_flags().count(1),
			"bead_loop": piece.shape.bead_loop(piece.particle_count(), piece.bead_radius()).size(),
		})
	splits.append({ "radii": Vector2(radius_a, radius_b), "pieces": pieces })

# Per-bead RMS distance, px, between the beads and the rest shape moved rigidly
# onto them (the shape matching's goals).
static func _shape_error(blob: Goo2D) -> float:
	var points := blob.bead_points()
	var goals := GooLoop.goal_positions(blob.rest_shape, points)
	var total := 0.0
	for i: int in points.size():
		total += points[i].distance_squared_to(goals[i])
	return sqrt(total / maxi(points.size(), 1))

# Checks the pieces of one recorded split of a polygon body of `area`.
func _assert_polygon_pieces(record: Dictionary, area: float, label: String) -> void:
	var pieces: Array[Dictionary] = record["pieces"]
	assert_eq(pieces.size(), 2, label + ": two pieces")
	if pieces.size() != 2:
		return
	var total := 0.0
	var vertices := 0
	for piece: Dictionary in pieces:
		assert_eq(piece["kind"], GooShape.Kind.POLYGON, label + ": a polygon piece")
		assert_almost_eq(float(piece["radius"]), float(piece["shape_radius"]), 0.001,
			label + ": radius is the piece's equivalent radius")
		assert_eq(piece["rest"], piece["beads"], label + ": one rest point per bead")
		assert_eq(piece["bead_loop"], piece["beads"], label + ": the piece's own bead loop fits its beads")
		assert_true(int(piece["vertices"]) >= 3 and int(piece["vertices"]) <= 5,
			label + ": a straight cut of a square leaves 3 to 5 corners, got %d" % piece["vertices"])
		assert_true(int(piece["corners"]) >= 3, label + ": corner beads kept sharp")
		total += float(piece["area"])
		vertices += int(piece["vertices"])
	# A line across a square: through two corners 3 + 3, through one corner and
	# a side 3 + 4, across two sides 3 + 5 or 4 + 4.
	assert_true(vertices >= 6 and vertices <= 8, label + ": %d corners in all is not a straight cut of a square" % vertices)
	assert_almost_eq(total / area, 1.0, 0.03, label + ": the pieces share the square's area")

func test_square_cut_on_its_diagonal_becomes_two_triangles() -> void:
	var radius := 44.0
	var blob := game.spawn(radius, Vector2(300.0, Arena.FLOOR_Y - radius - 10.0), GooShape.regular(4, radius))
	await wait_seconds(0.6)
	var corners := PackedInt32Array()
	var flags := blob.corner_flags()
	for i: int in flags.size():
		if flags[i] == 1:
			corners.append(i)
	assert_eq(corners.size(), 4)
	game.cut(blob, corners[0], corners[2])
	assert_eq(splits.size(), 1, "the diagonal cut is made")
	if splits.size() != 1:
		return
	_assert_polygon_pieces(splits[0], PI * radius * radius, "diagonal cut")
	for piece: Dictionary in splits[0]["pieces"]:
		print("    diagonal cut of a %.0f px square: %d-gon of radius %.1f (%.1f%% of the area), %d beads, %d corner beads"
			% [radius, piece["vertices"], piece["radius"], 100.0 * float(piece["area"]) / (PI * radius * radius),
				piece["beads"], piece["corners"]])
		assert_eq(piece["vertices"], 3, "a triangle")
		assert_eq(piece["corners"], 3, "three corner beads")
		assert_almost_eq(float(piece["area"]), PI * radius * radius / 2.0, 0.01 * PI * radius * radius, "half the square")
	assert_eq(game.bodies().size(), 2)
	for piece: Goo2D in game.bodies():
		assert_eq(piece.get_tint(), GooTuning.color(piece.radius), "piece of %.1f px in its own colour" % piece.radius)
		assert_true(game.merge_locked(piece), "a new piece starts merge-locked")
		assert_gt(piece.split_lock(), 0.0, "a new piece starts split-locked")

func test_sliver_cut_is_not_made() -> void:
	var radius := 48.0
	var blob := game.spawn(radius, Vector2(300.0, Arena.FLOOR_Y - radius - 10.0), GooShape.regular(4, radius))
	await wait_seconds(0.6)
	# The beads of the left and right sides nearest a line a fifth of the way
	# down (in the rest shape, which sits square on the floor): the strip above
	# it is big enough by area (equivalent radius 21 px), far too thin for its
	# beads.
	var rest := blob.rest_shape
	var side := sqrt(PI) * radius
	var y := -side / 2.0 + side / 5.0
	var left := -1
	var right := -1
	for i: int in rest.size():
		if rest[i].x < -side / 4.0 and (left < 0 or absf(rest[i].y - y) < absf(rest[left].y - y)):
			left = i
		if rest[i].x > side / 4.0 and (right < 0 or absf(rest[i].y - y) < absf(rest[right].y - y)):
			right = i
	game.cut(blob, left, right)
	await wait_frames(2)
	assert_eq(splits.size(), 0, "a sliver is not cut off")
	assert_eq(game.bodies().size(), 1)
	assert_true(is_instance_valid(blob) and blob.is_inside_tree())

func test_round_blob_still_splits_into_round_pieces() -> void:
	var radius := 50.0
	var blob := game.spawn(radius, Vector2(300.0, Arena.FLOOR_Y - radius))
	await wait_seconds(0.6)
	var points := blob.bead_points()
	game.cut(blob, 0, points.size() / 2)
	assert_eq(splits.size(), 1, "the cut is made")
	for piece: Goo2D in game.bodies():
		assert_true(piece.shape.is_round(), "a round blob's piece re-rounds")
		assert_eq(piece.tuning, GooTuning.tuning(piece.radius), "tuned as a round ring")
		assert_eq(piece.corner_flags().count(1), 0)

# Drops a square of `radius` onto the wedge's apex, `dx` px right of it, thrown
# down at `speed` once its split lock has run out; steps up to `seconds` and
# returns the blobs left, after they settle.
func _drop_on_wedge(radius: float, dx: float, speed: float, seconds: float) -> void:
	var apex := arena.wedge_apex()
	var fall := 0.5 * GooTuning.gravity() * GooTuning.SPLIT_LOCK * GooTuning.SPLIT_LOCK
	var blob := game.spawn(radius, Vector2(apex.x + dx, apex.y - radius - 60.0 - fall), GooShape.regular(4, radius))
	while is_instance_valid(blob) and blob.split_lock() > 0.0:
		await get_tree().physics_frame
	if is_instance_valid(blob) and blob.is_inside_tree():
		blob.set_velocity(Vector2(0.0, speed))
	var calm := 0
	for frame: int in roundi(seconds / STEP):
		await get_tree().physics_frame
		var all_settled := not splits.is_empty()
		for piece: Goo2D in game.bodies():
			all_settled = all_settled and piece.settled
		calm = calm + 1 if all_settled else 0
		if calm > 10:
			break

func test_square_on_the_wedge_splits_into_polygon_pieces_that_hold_their_shape() -> void:
	timeout_sec = 60.0
	keep_pieces = true
	for config: Vector3 in [Vector3(DropController.DROP_MAX_RADIUS, 0.0, 300.0), Vector3(40.0, 0.0, 800.0)]:
		game.reset()
		splits.clear()
		await wait_frames(2)
		var radius := config.x
		var label := "%.0f px square thrown at %.0f px/s onto the wedge" % [radius, config.z]
		await _drop_on_wedge(radius, config.y, config.z, 8.0)
		assert_false(splits.is_empty(), label + " splits")
		if splits.is_empty():
			continue
		var first: Dictionary = splits[0]
		var pieces: Array[Dictionary] = first["pieces"]
		var described := PackedStringArray()
		for piece: Dictionary in pieces:
			described.append("%d-gon of %.1f px" % [piece["vertices"], piece["radius"]])
		print("    %s: %d split(s), first into %s; %d blobs at the end"
			% [label, splits.size(), " + ".join(described), game.bodies().size()])
		_assert_polygon_pieces(first, PI * radius * radius, label)
		for blob: Goo2D in game.bodies():
			var error := _shape_error(blob)
			print("      %s %s of radius %.1f at %s: %s, shape error %.2f px (%.1f%% of its radius)"
				% ["polygon" if not blob.shape.is_round() else "round", "%d-gon" % blob.shape.outline.size(),
					blob.radius, blob.center(), "settled" if blob.settled else "moving", error, 100.0 * error / blob.radius])
			assert_false(blob.shape.is_round(), label + ": every piece stays a polygon")
			assert_true(blob.settled, label + ": the pieces settle")
			assert_lt(error, SHAPE_TOLERANCE * blob.radius, label + ": a settled piece holds its shape")

# ---- Concave shapes: the pieces are born sane ----
# A piece built with the rest shape of the other side of the cut (the line
# through a concave outline's chord crossing another arm) collapses or blows
# up within a frame, its beads at 3000-4000 px/s in the game. A sound small
# piece still grows a little at first: its beads are cut from the parent's
# loop, a bead radius of the parent's (larger) beads in from the outline, so
# they start at 0.5-0.9 × its rest loop's area and inflate.

## Time a merge may take: physics settling plus the merge transition.
const MERGE_TIMEOUT: float = 3.0 + GooWorld2D.MergeTransition.DURATION
## Physics frames a fresh piece is watched for.
const BIRTH_FRAMES: int = 5
## Largest relative change of a piece's area() in any of its first BIRTH_FRAMES.
const BIRTH_AREA_TOLERANCE: float = 0.3
## Fastest a fresh piece's bead may move over its first BIRTH_FRAMES, px/s.
const BIRTH_SPEED_LIMIT: float = 1500.0

# Index of the point of `points` nearest `target`.
static func _nearest(points: PackedVector2Array, target: Vector2) -> int:
	var best := 0
	for i: int in points.size():
		if points[i].distance_squared_to(target) < points[best].distance_squared_to(target):
			best = i
	return best

# Cuts `body` along the chord from its bead `a` to its bead `b` and asserts the
# cut is made, that over its first BIRTH_FRAMES each piece's area() stays
# within BIRTH_AREA_TOLERANCE of what it was at birth, and that no bead moves
# faster than BIRTH_SPEED_LIMIT in any of those frames.
func _assert_born_sane(body: Goo2D, a: int, b: int, label: String) -> void:
	var born: Array[Goo2D] = []
	var areas: Array[float] = []
	var fits: Array[float] = []
	var on_split := func(_radius_a: float, _radius_b: float, _position: Vector2) -> void:
		var all := game.bodies()
		for piece: Goo2D in all.slice(maxi(all.size() - 2, 0)):
			born.append(piece)
			areas.append(piece.area())
			fits.append(GooLoop.area(piece.bead_points()) / GooLoop.area(piece.rest_shape))
	game.split.connect(on_split)
	game.cut(body, a, b)
	game.split.disconnect(on_split)
	assert_eq(born.size(), 2, label + ": the cut is made")
	if born.size() != 2:
		return
	for piece: Goo2D in born:
		assert_eq(piece.rest_blend, 0.0, label + ": a piece starts with the lengths of the loop it is placed on")
	var fastest := 0.0
	var extremes: Array[Vector2] = [Vector2(1.0, 1.0), Vector2(1.0, 1.0)]
	for frame: int in BIRTH_FRAMES:
		await get_tree().physics_frame
		for k: int in 2:
			var piece := born[k]
			if not is_instance_valid(piece) or not piece.is_inside_tree():
				continue
			var ratio := piece.area() / areas[k]
			extremes[k] = Vector2(minf(extremes[k].x, ratio), maxf(extremes[k].y, ratio))
			for i: int in piece.particle_count():
				fastest = maxf(fastest, piece.bead_velocity(i).length())
	for k: int in 2:
		var piece := born[k]
		assert_true(is_instance_valid(piece) and piece.is_inside_tree(), label + ": piece %d stays" % k)
		if not is_instance_valid(piece) or not piece.is_inside_tree():
			continue
		var ratio := piece.area() / areas[k]
		print("    %s: piece %d, %d-gon of radius %.1f, %d beads, bead loop %.2f × its rest loop; area %.0f px² at birth, %.0f%% of it after %d frames (%.0f%% … %.0f%% on the way)"
			% [label, k, piece.shape.outline.size(), piece.radius, piece.particle_count(), fits[k], areas[k],
				100.0 * ratio, BIRTH_FRAMES, 100.0 * extremes[k].x, 100.0 * extremes[k].y])
		assert_gt(extremes[k].x, 1.0 - BIRTH_AREA_TOLERANCE, label + ": piece %d has not collapsed" % k)
		assert_lt(extremes[k].y, 1.0 + BIRTH_AREA_TOLERANCE, label + ": piece %d has not blown up" % k)
	print("    %s: fastest bead %.0f px/s" % [label, fastest])
	assert_lt(fastest, BIRTH_SPEED_LIMIT, label + ": no bead is thrown")

# Two squares of `radius_a` (left) and `radius_b` (right) side by side on the
# floor, merged into one fused shape and left to settle; returns it, or null.
func _fused_pair(radius_a: float, radius_b: float) -> Goo2D:
	var x := arena.inner_left() + Arena.INNER_WIDTH / 2.0
	var side_a := sqrt(PI) * radius_a
	var side_b := sqrt(PI) * radius_b
	game.spawn(radius_a, Vector2(x - side_a / 2.0 + 1.0, arena.floor_y() - side_a / 2.0), GooShape.regular(4, radius_a))
	game.spawn(radius_b, Vector2(x + side_b / 2.0 - 1.0, arena.floor_y() - side_b / 2.0), GooShape.regular(4, radius_b))
	var fired := await await_signal(game.merged, MERGE_TIMEOUT)
	assert_true(fired, "the squares merge")
	await wait_seconds(1.0)
	assert_eq(game.bodies().size(), 1, "into one body")
	if not fired or game.bodies().size() != 1:
		return null
	var fused := game.bodies()[0]
	assert_false(fused.shape.is_round(), "a fused shape")
	return fused

func test_a_fused_shape_cut_across_its_junction_is_born_sane() -> void:
	timeout_sec = 20.0
	keep_pieces = true
	var radius_a := 30.0
	var radius_b := 44.0
	var fused := await _fused_pair(radius_a, radius_b)
	if fused == null:
		return
	# The junction, where the left square's right side was: from the top of the
	# smaller (left) square down to the floor.
	var points := fused.bead_points()
	var box := fused.bead_bounds()
	var left := box.position.x - fused.bead_radius()
	var junction := left + sqrt(PI) * radius_a
	var top := arena.floor_y() - sqrt(PI) * minf(radius_a, radius_b)
	var a := _nearest(points, Vector2(junction, top))
	var b := _nearest(points, Vector2(junction, arena.floor_y()))
	await _assert_born_sane(fused, a, b, "fused %d-gon cut across its junction" % fused.shape.outline.size())

func test_a_u_cut_across_one_arm_is_born_sane() -> void:
	timeout_sec = 20.0
	keep_pieces = true
	# A U standing on its base, arms up, the right arm wider: the line across
	# the left arm near its root runs on through the right arm, whose top is
	# larger than the left arm's (the piece a cut by the whole line's
	# half-planes took for the left arm's tip: its beads then sat in 0.31 × and
	# 1.54 × their rest loops' areas and the tip blew up to 212% in 5 frames).
	var outline := PackedVector2Array([Vector2(0, 0), Vector2(0, 240), Vector2(400, 240), Vector2(400, 0),
		Vector2(200, 0), Vector2(200, 140), Vector2(120, 140), Vector2(120, 0)])
	var factor := 0.6
	var shape := GooShape.polygon(outline)
	var origin := GooShape.area_centroid(outline)
	var centre := Vector2(arena.inner_left() + Arena.INNER_WIDTH / 2.0, arena.floor_y() - 2.0 - (240.0 - origin.y) * factor)
	var u := game.spawn(shape.radius() * factor, centre, shape)
	await wait_seconds(1.0)
	# Where the U's own points are now: its outline fitted onto its beads
	# (vertex for vertex the outline above, scaled).
	var points := u.bead_points()
	var fitted := u.shape.fitted_outline(u.rest_shape, points, u.bead_radius())
	assert_eq(fitted.size(), outline.size(), "the U keeps its 8 corners")
	if fitted.size() != outline.size():
		return
	var turn := (outline[1] - outline[0]).angle_to(fitted[1] - fitted[0])
	var place := func(local: Vector2) -> Vector2: return fitted[0] + ((local - outline[0]) * factor).rotated(turn)
	var a := _nearest(points, place.call(Vector2(0, 125)))
	var b := _nearest(points, place.call(Vector2(120, 125)))
	await _assert_born_sane(u, a, b, "U cut across its left arm")

# ---- Small pieces: they take their size gently ----
# A small piece's beads are cut from its parent's loop, a bead radius of the
# parent's (larger) beads in from the outline, so its bead loop starts well
# inside its rest loop (0.35-0.6 of its area for a small tip or cap). Built
# with its rest shape's skin and bending lengths at once, a polygon tip snapped
# out to them in its first frame and overshot (a fused square's corner: 155%
# of its birth area, 589 px/s); it now starts with the lengths of the loop it is
# placed on and eases into its rest shape's over inflate_time (Goo2D.rest_blend),
# as its target area does. A round ring's cap is cut so thin that beads across
# it sat within half a bead diameter of each other, and the self-collision threw
# them apart in the first frame (146-158%); build_from_loop() now spreads them
# apart first (Goo2D.spread_apart()).

func test_a_small_tip_cut_off_a_fused_shape_is_born_sane() -> void:
	timeout_sec = 30.0
	keep_pieces = true
	for depth: float in [0.7, 0.85]:
		game.reset()
		await wait_frames(2)
		var fused := await _fused_pair(30.0, 44.0)
		if fused == null:
			return
		# The bigger (right) square's top right corner, cut off `depth` of its
		# side down each edge.
		var points := fused.bead_points()
		var box := fused.bead_bounds()
		var right := box.end.x + fused.bead_radius()
		var side := sqrt(PI) * 44.0
		var top := arena.floor_y() - side
		var a := _nearest(points, Vector2(right - depth * side, top))
		var b := _nearest(points, Vector2(right, top + depth * side))
		await _assert_born_sane(fused, b, a, "fused %d-gon's corner cut %.0f%% down its sides"
			% [fused.shape.outline.size(), 100.0 * depth])

func test_a_small_round_piece_is_born_sane() -> void:
	timeout_sec = 20.0
	keep_pieces = true
	for config: Vector2 in [Vector2(50.0, 3.0), Vector2(70.0, 3.0), Vector2(70.0, 4.0)]:
		game.reset()
		await wait_frames(2)
		var radius := config.x
		var blob := game.spawn(radius, Vector2(arena.inner_left() + Arena.INNER_WIDTH / 2.0, arena.floor_y() - radius))
		await wait_seconds(1.0)
		# A chord across a third (or a quarter) of the beads: its side is a cap
		# of about a fifth (a tenth) of the blob.
		var count := blob.particle_count()
		await _assert_born_sane(blob, 0, roundi(count / config.y),
			"round %.0f cut across 1/%d of its beads" % [radius, config.y])
	# The pieces' skins ease into their rest shapes' lengths over inflate_time.
	await wait_seconds(GooTuning.inflate_time() + 0.05)
	for piece: Goo2D in game.bodies():
		assert_eq(piece.rest_blend, 1.0, "a piece ends at its rest shape's lengths")
