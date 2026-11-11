extends TestCase
## Shapes stick flat face to flat face (GooWorld2D.can_merge()): two
## squares side by side on the floor fuse into one polygon body (the union of
## their outlines, its creases filled within the contact range,
## GooShape.fused()) holding both their areas, whatever their sizes; a square
## never merges with a round blob; a square landing corner first on another's
## top face does not merge on that contact; and a fused body resting with a
## notch in its outline does not split itself there (find_pinch() reads the
## notch against the rest shape's own). Every measured number is printed.

## Time a merge may take: physics settling plus the longest merge transition.
const MERGE_TIMEOUT: float = 3.0 + GooWorld2D.MergeTransition.MAX_DURATION
const STEP: float = 1.0 / 60.0
## A launch-size square's equivalent radius, px.
const R: float = 34.0

var arena: Arena
var game: Game
var merges: Array[float] = []
var splits: int = 0

func before_each() -> void:
	arena = (load("res://scenes/arena.tscn") as PackedScene).instantiate() as Arena
	add_child(arena)
	game = Game.new()
	game.arena = arena
	add_child(game)
	merges.clear()
	splits = 0
	game.merged.connect(func(radius: float, _position: Vector2) -> void: merges.append(radius))
	game.split.connect(func(_a: float, _b: float, _position: Vector2) -> void: splits += 1)

# Side, px, of the square of equivalent radius `radius`.
static func _side(radius: float) -> float:
	return sqrt(PI) * radius

# Spawns a square of `radius` standing on the floor, centred on `x`.
func _square_on_floor(radius: float, x: float) -> Goo2D:
	var side := _side(radius)
	return game.spawn(radius, Vector2(x, arena.floor_y() - side / 2.0), GooShape.regular(4, radius))

# Width and height, px, of the bounding box of `points`.
static func _extent(points: PackedVector2Array) -> Vector2:
	var box := Rect2(points[0], Vector2.ZERO)
	for point: Vector2 in points:
		box = box.expand(point)
	return box.size

# Angle, degrees, between the sides of `a`'s and `b`'s outlines as fitted onto
# their beads, folded into -45 … 45 (a square looks the same every 90°): 0
# when their faces are parallel, ±45 when one stands on its corner on the other.
static func _relative_turn(a: Goo2D, b: Goo2D) -> float:
	var outline_a := a.shape.fitted_outline(a.rest_shape, a.bead_points(), a.bead_radius())
	var outline_b := b.shape.fitted_outline(b.rest_shape, b.bead_points(), b.bead_radius())
	var side_a := (outline_a[1] - outline_a[0]).angle()
	var side_b := (outline_b[1] - outline_b[0]).angle()
	return rad_to_deg(wrapf(side_b - side_a, -PI / 4.0, PI / 4.0))

func _assert_squares_fuse(radius_a: float, radius_b: float) -> void:
	var x := arena.inner_left() + Arena.INNER_WIDTH / 2.0
	var side_a := _side(radius_a)
	var side_b := _side(radius_b)
	# The collision outlines overlap by 2 px, as round blobs are spawned in test_merge.
	_square_on_floor(radius_a, x - side_a / 2.0 + 1.0)
	_square_on_floor(radius_b, x + side_b / 2.0 - 1.0)
	var label := "squares of radius %.0f and %.0f" % [radius_a, radius_b]
	var fired := await await_signal(game.merged, MERGE_TIMEOUT)
	assert_true(fired, label + " side by side should merge within %.2f s" % MERGE_TIMEOUT)
	await wait_frames(2)
	assert_eq(game.bodies().size(), 1, label + " make one body")
	if game.bodies().size() != 1:
		return
	var fused := game.bodies()[0]
	var parts := PI * (radius_a * radius_a + radius_b * radius_b)
	var extent := _extent(fused.shape.outline)
	print("    %s fused: %d-point outline, area %.0f px² (%.1f%% of the two squares'), %.1f x %.1f px, radius %.1f, %d beads of %.2f px"
		% [label, fused.shape.outline.size(), fused.shape.area(), 100.0 * fused.shape.area() / parts,
			extent.x, extent.y, fused.radius, fused.particle_count(), fused.bead_radius()])
	assert_eq(fused.shape.kind, GooShape.Kind.POLYGON, label + ": the fused body is a shape")
	assert_almost_eq(fused.shape.area() / parts, 1.0, 0.08, label + ": the fused shape holds both areas")
	assert_almost_eq(fused.radius, fused.shape.radius(), 0.001, label + ": its radius is the equivalent radius")
	assert_eq(merges.size(), 1)
	if merges.size() == 1:
		assert_almost_eq(merges[0], fused.radius, 0.001, "the signal reports the fused radius")
	assert_gt(extent.x, 1.3 * extent.y, label + ": the fused shape is wider than tall")
	assert_true(game.merge_locked(fused), "a fused body starts merge-locked")
	assert_true(fused.corner_flags().count(1) >= 4, label + ": the fused ring keeps corners")
	# Settled, the ring still is that wide shape.
	for frame: int in roundi(3.0 / STEP):
		await get_tree().physics_frame
		if not is_instance_valid(fused) or fused.settled:
			break
	assert_true(is_instance_valid(fused) and fused.is_inside_tree(), label + ": the fused body stays")
	if not is_instance_valid(fused) or not fused.is_inside_tree():
		return
	var ring := _extent(fused.bead_points())
	print("    %s fused body at rest: beads span %.1f x %.1f px, area %.1f%% of target" %
		[label, ring.x, ring.y, 100.0 * fused.area() / fused.target_area])
	assert_gt(ring.x, 1.3 * ring.y, label + ": the resting body is wider than tall")
	assert_eq(splits, 0, label + ": the fused body does not split")

func test_two_squares_side_by_side_fuse_into_one_wide_shape() -> void:
	timeout_sec = 15.0
	await _assert_squares_fuse(R, R)

func test_squares_of_different_sizes_fuse_too() -> void:
	timeout_sec = 15.0
	assert_false(GooTuning.can_merge(30.0, 44.0), "round blobs of these sizes would not merge")
	await _assert_squares_fuse(30.0, 44.0)

func test_a_fused_ring_built_on_a_stepped_pair_holds_its_area_and_stays_calm() -> void:
	# Two squares face to face, one half a side higher than the other (a step,
	# with a crease on either side of the junction), merged straight away in mid
	# air: the ring placed on their union, with the fused shape's rest loop,
	# must not jolt in its first frames (fused merges did, to 15000 px/s, in
	# tools/births.gd).
	await get_tree().physics_frame
	var side := _side(R)
	var x := arena.inner_left() + 600.0
	var a := game.spawn(R, Vector2(x, 400.0), GooShape.regular(4, R))
	var b := game.spawn(R, Vector2(x + side - 2.0, 400.0 - side / 2.0), GooShape.regular(4, R))
	var fused := GooWorld2D.fused_outline(a, b)
	assert_false(fused.is_empty(), "the stepped squares fuse")
	if fused.is_empty():
		return
	var merged := Goo2D.make_merged(0.0, game, [a, b] as Array[Goo2D], fused)
	for body: Goo2D in [a, b]:
		game.remove_child(body)
		body.queue_free()
	assert_not_null(merged)
	if merged == null:
		return
	var birth := merged.area()
	var low := 1.0
	var high := 1.0
	var fastest := 0.0
	for frame: int in 5:
		await get_tree().physics_frame
		low = minf(low, merged.area() / birth)
		high = maxf(high, merged.area() / birth)
		for velocity: Vector2 in merged.bead_velocities():
			fastest = maxf(fastest, velocity.length())
	print("    fused %d-point ring from stepped squares: area %.0f%% .. %.0f%% of its birth area over 5 frames, fastest bead %.0f px/s"
		% [merged.shape.outline.size(), 100.0 * low, 100.0 * high, fastest])
	assert_gt(low, 0.7, "the fused ring keeps its area")
	assert_lt(high, 1.3, "the fused ring does not blow up")
	assert_lt(fastest, 1500.0, "the fused ring's beads stay calm")

func test_a_square_and_a_round_blob_do_not_merge() -> void:
	var x := arena.inner_left() + Arena.INNER_WIDTH / 2.0
	var side := _side(R)
	var square := _square_on_floor(R, x - side / 2.0 + 1.0)
	var blob := game.spawn(R, Vector2(x + R - 1.0, arena.floor_y() - R))
	var touched: Array[bool] = [false]
	square.touched.connect(func(other: Goo2D) -> void:
		if other == blob:
			touched[0] = true)
	await wait_seconds(1.5)
	assert_true(touched[0], "the square and the round blob touch")
	assert_eq(game.bodies().size(), 2)
	assert_eq(merges.size(), 0, "a shape never merges with a round blob")
	assert_false(square.merging or blob.merging)

func test_a_square_landing_corner_first_does_not_merge() -> void:
	timeout_sec = 15.0
	var x := arena.inner_left() + Arena.INNER_WIDTH / 2.0
	var side := _side(R)
	var base := _square_on_floor(R, x)
	# The same square turned 45°: a diamond, dropped from 20 px above the
	# base's top face onto its bottom corner.
	var diamond_outline := PackedVector2Array()
	for point: Vector2 in GooShape.regular(4, R).outline:
		diamond_outline.append(point.rotated(PI / 4.0))
	var half_diagonal := side * sqrt(2.0) / 2.0
	var top := arena.floor_y() - side
	var diamond := game.spawn(R, Vector2(x, top - 20.0 - half_diagonal), GooShape.polygon(diamond_outline))
	var first_touch: Array[float] = [INF]
	diamond.touched.connect(func(other: Goo2D) -> void:
		if other == base and first_touch[0] == INF:
			first_touch[0] = _relative_turn(base, diamond))
	var touched_at := -1
	var merge_turn := INF
	for frame: int in roundi(2.0 / STEP):
		await get_tree().physics_frame
		if touched_at < 0 and first_touch[0] != INF:
			touched_at = frame
		if not is_instance_valid(diamond) or not diamond.is_inside_tree():
			break
		if diamond.merging:
			merge_turn = _relative_turn(base, diamond)
			break
	var started := "never" if merge_turn == INF else "turned %.1f°" % merge_turn
	print("    diamond on a square: first touch turned %.1f°, frame %d; merge started: %s"
		% [first_touch[0], touched_at, started])
	assert_true(touched_at >= 0, "the diamond lands on the square")
	assert_gt(absf(first_touch[0]), 40.0, "it lands corner first")
	if merge_turn != INF:
		# It may topple onto a face and stick then, never on its corner.
		assert_lt(absf(merge_turn), rad_to_deg(GooWorld2D.FLAT_CONTACT_ANGLE) + 5.0,
			"a merge only starts once the faces meet")

func test_a_fused_body_with_a_notch_does_not_split_at_rest() -> void:
	timeout_sec = 20.0
	var x := arena.inner_left() + Arena.INNER_WIDTH / 2.0 - 30.0
	var side := _side(R)
	var base := _square_on_floor(R, x)
	# A second square on the base's top face, half a side to the right: the
	# fused body is a step, notched under the overhang and above the base.
	game.spawn(R, Vector2(x + side / 2.0, arena.floor_y() - 1.5 * side + 2.0), GooShape.regular(4, R))
	assert_not_null(base)
	var fired := await await_signal(game.merged, MERGE_TIMEOUT)
	assert_true(fired, "the stacked squares fuse")
	await wait_frames(2)
	assert_eq(game.bodies().size(), 1)
	if game.bodies().size() != 1:
		return
	var fused := game.bodies()[0]
	var notch := 0.0
	for depth: float in Goo2D.hull_depths(fused.rest_shape):
		notch = maxf(notch, depth)
	var seconds := 4.0
	var settled_at := -1.0
	for frame: int in roundi(seconds / STEP):
		await get_tree().physics_frame
		if not is_instance_valid(fused) or not fused.is_inside_tree():
			break
		if settled_at < 0.0 and fused.settled:
			settled_at = frame * STEP
	var extent := _extent(fused.shape.outline) if is_instance_valid(fused) else Vector2.ZERO
	var area := fused.shape.area() / (2.0 * PI * R * R) if is_instance_valid(fused) else 0.0
	print("    stacked squares fused: %d-point outline %.1f x %.1f px, %.1f%% of the two squares' area, deepest notch %.1f px, settled after %.2f s, splits %d"
		% [fused.shape.outline.size() if is_instance_valid(fused) else 0, extent.x, extent.y, 100.0 * area,
			notch, settled_at, splits])
	assert_gt(notch, 0.15 * side, "the fused rest shape has a deep notch")
	assert_eq(splits, 0, "the fused body does not split itself at its notch")
	assert_eq(game.bodies().size(), 1)
	if not is_instance_valid(fused) or not fused.is_inside_tree():
		return
	# Read against its rest shape's depths alone (no rest-distance filter), the
	# resting body has no neck either. (Settled, this notch is too shallow to
	# be one even against the hull; test_pinch_reads_a_notch_against_the_rest_shape
	# has a step that is.)
	var points := fused.bead_points()
	var plain := Goo2D.find_pinch(points, fused.bead_radius(), Goo2D.PINCH_CONSTRICTION)
	var relative := Goo2D.find_pinch(points, fused.bead_radius(), Goo2D.PINCH_CONSTRICTION,
		PackedVector2Array(), 0.0, Goo2D.hull_depths(fused.rest_shape))
	print("    resting fused body: neck against the hull %.2f constriction, against the rest shape %.2f"
		% [plain["constriction"], relative["constriction"]])
	assert_eq(relative["a"], -1, "against its rest shape, the notch is no neck")
	assert_eq(fused.pinch()["a"], -1, "the body sees no neck")

func test_pinch_reads_a_notch_against_the_rest_shape() -> void:
	# A step: a square with another half a side up and to the right, as a
	# bead loop. At rest its two creases are deep inside its hull, close
	# together across the junction: a neck, unless the rest shape's own depths
	# are taken off.
	var square := GooShape.regular(4, 40.0)
	var side := sqrt(PI) * 40.0
	var a := square.outline.duplicate()
	var b := square.outline.duplicate()
	for i: int in b.size():
		b[i] += Vector2(side / 2.0, -side)
	var fused := GooShape.fused(a, b, 10.0)
	var loop := GooShape.polygon(fused).bead_loop(48, 4.0)
	assert_eq(loop.size(), 48)
	var plain := Goo2D.find_pinch(loop, 4.0, Goo2D.PINCH_CONSTRICTION)
	print("    step at rest: neck %d-%d, gap %.1f px, constriction %.2f without rest depths"
		% [plain["a"], plain["b"], plain["gap"], plain["constriction"]])
	assert_ne(plain["a"], -1, "the notch reads as a neck against the hull alone")
	var depths := Goo2D.hull_depths(loop)
	var at_rest := Goo2D.find_pinch(loop, 4.0, Goo2D.PINCH_CONSTRICTION,
		PackedVector2Array(), 0.0, depths)
	assert_eq(at_rest["a"], -1, "at rest the notch is no neck")
	# Squeezed across the junction, it is one again: pull the beads of the
	# junction's two sides 40% closer together.
	var squeezed := loop.duplicate()
	var middle := (loop[plain["a"]] + loop[plain["b"]]) / 2.0
	var across := loop[plain["a"]].direction_to(loop[plain["b"]])
	for i: int in squeezed.size():
		var offset := (squeezed[i] - middle).dot(across)
		if absf((squeezed[i] - middle).dot(across.orthogonal())) < side / 2.0:
			squeezed[i] -= across * offset * 0.4
	var pressed := Goo2D.find_pinch(squeezed, 4.0, Goo2D.PINCH_CONSTRICTION,
		PackedVector2Array(), 0.0, depths)
	assert_ne(pressed["a"], -1, "squeezed further than its rest shape, the notch is a neck")
