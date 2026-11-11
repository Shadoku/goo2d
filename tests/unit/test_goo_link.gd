extends TestCase
## GooLink's pure geometry: the tied patch (patch()), the anchors facing each
## other and the bridge skin's polygon (bridge_polygon()), which must always be
## a simple polygon Polygon2D can draw, spanning the neck between the two
## outlines, wider for a stronger link.

const RADIUS: float = 40.0

func before_each() -> void:
	GooTuning.unit = 1.0

func after_each() -> void:
	GooTuning.unit = 1.0

# The rest loop of a round body of `radius`.
static func _rest(radius: float) -> PackedVector2Array:
	var tuning := GooTuning.tuning(radius)
	return GooLoop.circle_points(Vector2.ZERO, tuning["ring_radius"], int(tuning["bead_count"]))

# The rest loop of `body`, moved to `at`.
static func _placed(rest: PackedVector2Array, at: Vector2) -> PackedVector2Array:
	var points := PackedVector2Array()
	for point: Vector2 in rest:
		points.append(point + at)
	return points

func test_patch_width_follows_strength() -> void:
	var rest := _rest(RADIUS)
	var ring := rest[0].length()
	var thread := GooLink.patch(rest, Vector2(ring, 0.0), rest, Vector2(-ring, 0.0), 0.1, RADIUS, RADIUS)
	var full := GooLink.patch(rest, Vector2(ring, 0.0), rest, Vector2(-ring, 0.0), 1.0, RADIUS, RADIUS)
	var half := GooLink.patch(rest, Vector2(ring, 0.0), rest, Vector2(-ring, 0.0), 0.5, RADIUS, RADIUS)
	var pairs_thread: PackedInt32Array = thread["pairs"]
	var pairs_half: PackedInt32Array = half["pairs"]
	var pairs_full: PackedInt32Array = full["pairs"]
	print("    pairs at strength 0.1, 0.5, 1: %d, %d, %d" % [pairs_thread.size() / 2, pairs_half.size() / 2,
		pairs_full.size() / 2])
	assert_eq(pairs_thread.size(), 2, "a thread is one pair")
	assert_gt(pairs_full.size(), pairs_half.size())
	assert_gt(pairs_half.size(), pairs_thread.size())
	# The middle pair is the anchors' beads; the pairs face each other.
	var mid := pairs_full.size() / 4
	assert_eq(rest[pairs_full[2 * mid]], rest[0], "a's middle bead is the one at its anchor")
	for k: int in pairs_full.size() / 2:
		var on_a := rest[pairs_full[2 * k]]
		var on_b := rest[pairs_full[2 * k + 1]] + Vector2(3.0 * ring, 0.0)
		assert_almost_eq(on_a.y, on_b.y, 1.0, "pair %d faces across the neck" % k)
	var through: PackedInt32Array = full["through_a"]
	assert_eq(through.size(), pairs_full.size() / 2 + 2 * GooTuning.LINK_THROUGH_BEADS,
		"the tied beads and LINK_THROUGH_BEADS either side pass through")

func test_patch_of_a_square_and_a_round_body() -> void:
	var square := GooShape.regular(4, RADIUS)
	var tuning := GooTuning.tuning_for(square)
	var rest_square := square.bead_loop(int(tuning["bead_count"]), float(tuning["bead_radius"]))
	rest_square = _placed(rest_square, -GooLoop.centroid(rest_square))
	var rest_round := _rest(30.0)
	var patch := GooLink.patch(rest_square, Vector2(RADIUS, 0.0), rest_round, Vector2(-30.0, 0.0), 1.0, RADIUS, 30.0)
	var pairs: PackedInt32Array = patch["pairs"]
	assert_gt(pairs.size(), 2)
	for k: int in range(0, pairs.size(), 2):
		assert_true(pairs[k] < rest_square.size() and pairs[k + 1] < rest_round.size(), "beads in range")

# The bridge between two round bodies of RADIUS `apart` px between centres
# (along x), linked at `strength`; [polygon, points_a, points_b, bead radius].
static func _bridge(strength: float, apart: float, radius_b: float = RADIUS) -> Array:
	var rest_a := _rest(RADIUS)
	var rest_b := _rest(radius_b)
	var bead_a := GooTuning.bead_radius(RADIUS)
	var bead_b := GooTuning.bead_radius(radius_b)
	var patch := GooLink.patch(rest_a, Vector2(100.0, 0.0), rest_b, Vector2(-100.0, 0.0), strength, RADIUS, radius_b)
	var pairs: PackedInt32Array = patch["pairs"]
	var beads_a := PackedInt32Array()
	var beads_b := PackedInt32Array()
	for k: int in range(0, pairs.size(), 2):
		beads_a.append(pairs[k])
		beads_b.append(pairs[k + 1])
	var points_a := _placed(rest_a, Vector2(300.0, 300.0))
	var points_b := _placed(rest_b, Vector2(300.0 + apart, 300.0))
	return [GooLink.bridge_polygon(points_a, beads_a, bead_a, points_b, beads_b, bead_b), points_a, points_b,
		bead_a, bead_b]

# Px of the bridge across the neck's middle, x = `x`: the length of the
# vertical line there inside it.
static func _width_at(polygon: PackedVector2Array, x: float) -> float:
	var inside := 0
	for k: int in 400:
		if Geometry2D.is_point_in_polygon(Vector2(x, 300.0 - 100.0 + k * 0.5), polygon):
			inside += 1
	return inside * 0.5

# The least distance from any point of `polygon` to the collision outline of
# beads `points` of `bead` px.
static func _gap_to_outline(polygon: PackedVector2Array, points: PackedVector2Array, bead: float) -> float:
	var best := INF
	for p: Vector2 in polygon:
		for q: Vector2 in points:
			best = minf(best, absf(p.distance_to(q) - bead))
	return best

func _assert_drawable(polygon: PackedVector2Array, what: String) -> void:
	assert_gt(polygon.size(), 2, "%s: a polygon" % what)
	assert_false(GooLoop.self_intersects(polygon), "%s: simple" % what)
	assert_false(Geometry2D.triangulate_polygon(polygon).is_empty(), "%s: Polygon2D can draw it" % what)
	assert_gt(GooLoop.area(polygon), 1.0, "%s: an area" % what)

func test_the_bridge_spans_the_neck_and_widens_with_strength() -> void:
	var widths: Array[float] = []
	for strength: float in [0.2, 0.6, 1.0]:
		for apart: float in [80.0, 95.0, 120.0]:
			var made := _bridge(strength, apart)
			var polygon: PackedVector2Array = made[0]
			var what := "strength %.1f, %d px apart" % [strength, apart]
			_assert_drawable(polygon, what)
			assert_lt(_gap_to_outline(polygon, made[1], made[3]), 0.5, "%s: touches a's outline" % what)
			assert_lt(_gap_to_outline(polygon, made[2], made[4]), 0.5, "%s: touches b's outline" % what)
			if apart == 95.0:
				var width := _width_at(polygon, 300.0 + apart * 0.5)
				widths.append(width)
	print("    neck width at strength 0.2, 0.6, 1: %s px" % [widths])
	assert_gt(widths[0], 0.0)
	assert_gt(widths[1], widths[0], "wider at 0.6 than at 0.2")
	assert_gt(widths[2], widths[1], "wider at 1 than at 0.6")

func test_the_bridge_has_a_waist() -> void:
	var made := _bridge(1.0, 100.0)
	var polygon: PackedVector2Array = made[0]
	var middle := _width_at(polygon, 350.0)
	# Its ends on the outlines are further apart across than the waist.
	var top := INF
	var bottom := -INF
	for p: Vector2 in polygon:
		top = minf(top, p.y)
		bottom = maxf(bottom, p.y)
	print("    waist %.1f px, bridge %.1f px tall" % [middle, bottom - top])
	assert_lt(middle, bottom - top, "narrower in the middle than at its ends")

func test_the_bridge_is_drawable_between_unequal_and_overlapping_bodies() -> void:
	for apart: float in [40.0, 60.0, 70.0, 150.0]:
		var made := _bridge(0.8, apart, 28.0)
		_assert_drawable(made[0], "%d px apart, 40 and 28 px" % apart)
	# Squashed and turned bodies.
	var rest := _rest(RADIUS)
	var squashed := PackedVector2Array()
	for point: Vector2 in rest:
		squashed.append(Vector2(point.x * 0.6, point.y * 1.3).rotated(0.7) + Vector2(300.0, 300.0))
	var other := _placed(rest, Vector2(370.0, 330.0))
	var patch := GooLink.patch(rest, Vector2(100.0, 0.0), rest, Vector2(-100.0, 0.0), 1.0, RADIUS, RADIUS)
	var pairs: PackedInt32Array = patch["pairs"]
	var beads_a := PackedInt32Array()
	var beads_b := PackedInt32Array()
	for k: int in range(0, pairs.size(), 2):
		beads_a.append(pairs[k])
		beads_b.append(pairs[k + 1])
	_assert_drawable(GooLink.bridge_polygon(squashed, beads_a, 9.0, other, beads_b, 9.0), "squashed and turned")

func test_facing_anchors_and_kernel_params() -> void:
	var params := GooLink.kernel_params(6.0, 4.0, 0.5, 0.25)
	assert_almost_eq(float(params["gap"]), GooTuning.LINK_GAP * 10.0, 0.0001)
	assert_almost_eq(float(params["bend_stiffness"]), GooTuning.LINK_BEND_STIFFNESS * 0.5, 0.0001)
	assert_almost_eq(float(params["rest_angle"]), 0.25, 0.0001)
	assert_almost_eq(float(params["min_rest"]), GooTuning.LINK_MIN_REST * 10.0, 0.0001)
