extends TestCase
## Unit tests for GooLoop: area and orientation of bead rings, outward edge
## normals, smoothing, resampling, outline unions, best-fit rotation for shape
## matching and self-intersection checks, beads spread over polygons and
## smoothing that keeps corners; where a loop crosses itself and the loops it
## falls into cut there; and cuts along a line: whether a blade's tip is
## inside a bead loop, and the chord (two bead indices) along the blade's axis
## that the loop is cut on.

const CENTRE: Vector2 = Vector2(100.0, 50.0)

func test_circle_area_matches_pi_r_squared() -> void:
	var ring := GooLoop.circle_points(CENTRE, 10.0, 64)
	assert_eq(ring.size(), 64)
	assert_almost_eq(GooLoop.area(ring), PI * 100.0, PI * 100.0 * 0.01)
	assert_almost_eq(absf(GooLoop.signed_area(ring)), PI * 100.0, PI * 100.0 * 0.01)

func test_circle_points_are_ccw_and_reverse_is_not() -> void:
	var ring := GooLoop.circle_points(CENTRE, 10.0, 16)
	assert_true(GooLoop.is_ccw(ring), "circle_points should be CCW")
	assert_lt(GooLoop.signed_area(ring), 0.0, "CCW is negative in y-down space")
	var reversed := ring.duplicate()
	reversed.reverse()
	assert_false(GooLoop.is_ccw(reversed), "reversed ring should not be CCW")
	assert_gt(GooLoop.signed_area(reversed), 0.0)

func test_circle_points_lie_on_the_circle_starting_on_the_right() -> void:
	var ring := GooLoop.circle_points(CENTRE, 10.0, 8)
	assert_almost_eq(ring[0].x, CENTRE.x + 10.0, 0.0001)
	assert_almost_eq(ring[0].y, CENTRE.y, 0.0001)
	# The second point is above the first on screen (y down): counter-clockwise.
	assert_lt(ring[1].y, ring[0].y)
	for point: Vector2 in ring:
		assert_almost_eq(point.distance_to(CENTRE), 10.0, 0.0001)

func test_edge_normals_point_outward_with_edge_length() -> void:
	var ring := GooLoop.circle_points(CENTRE, 20.0, 12)
	var normals := GooLoop.edge_normals(ring)
	assert_eq(normals.size(), ring.size())
	for i: int in ring.size():
		var a := ring[i]
		var b := ring[(i + 1) % ring.size()]
		var midpoint := (a + b) * 0.5
		assert_gt(normals[i].dot(a - CENTRE), 0.0, "normal %d points inward" % i)
		assert_gt(normals[i].dot(midpoint - CENTRE), 0.0, "normal %d points inward" % i)
		assert_almost_eq(normals[i].length(), a.distance_to(b), 0.0001, "normal %d length" % i)
		assert_almost_eq(normals[i].dot(b - a), 0.0, 0.0001, "normal %d not perpendicular" % i)

func test_edge_normals_sum_to_zero_on_a_closed_ring() -> void:
	var ring := GooLoop.circle_points(CENTRE, 20.0, 17)
	var total := Vector2.ZERO
	for normal: Vector2 in GooLoop.edge_normals(ring):
		total += normal
	assert_almost_eq(total.length(), 0.0, 0.001)

func test_chaikin_doubles_count_and_keeps_area() -> void:
	var ring := GooLoop.circle_points(CENTRE, 30.0, 16)
	var area := GooLoop.area(ring)
	assert_eq(GooLoop.chaikin(ring, 1).size(), 32)
	var twice := GooLoop.chaikin(ring, 2)
	assert_eq(twice.size(), 64)
	assert_almost_eq(GooLoop.area(twice), area, area * 0.05)
	assert_true(GooLoop.is_ccw(twice), "chaikin keeps orientation")
	assert_eq(GooLoop.chaikin(ring, 0), ring)

func test_resample_spaces_points_evenly() -> void:
	# A smooth loop with very uneven point spacing: 7 corners cut 3 times.
	var dense := GooLoop.chaikin(GooLoop.circle_points(CENTRE, 40.0, 7), 3)
	var even := GooLoop.resample(dense, 24)
	assert_eq(even.size(), 24)
	assert_eq(even[0], dense[0])
	var gaps: Array[float] = []
	var mean := 0.0
	for i: int in even.size():
		var gap := even[i].distance_to(even[(i + 1) % even.size()])
		gaps.append(gap)
		mean += gap / even.size()
	for i: int in gaps.size():
		assert_almost_eq(gaps[i], mean, mean * 0.05, "gap %d" % i)

func test_resample_steps_by_arc_length() -> void:
	# A lopsided loop: one long straight edge then many short ones.
	var loop := PackedVector2Array([Vector2(0, 0), Vector2(100, 0), Vector2(100, 5),
		Vector2(98, 6), Vector2(96, 7), Vector2(94, 8), Vector2(0, 60)])
	var perimeter := 0.0
	for i: int in loop.size():
		perimeter += loop[i].distance_to(loop[(i + 1) % loop.size()])
	var resampled := GooLoop.resample(loop, 20)
	assert_eq(resampled.size(), 20)
	assert_eq(resampled[0], loop[0])
	# Points along the long first edge are exactly one step apart.
	assert_almost_eq(resampled[1].x, perimeter / 20.0, 0.001)
	assert_almost_eq(resampled[2].x, 2.0 * perimeter / 20.0, 0.001)
	assert_almost_eq(resampled[1].y, 0.0, 0.001)

func test_union_of_overlapping_circles_is_one_loop() -> void:
	var a := GooLoop.circle_points(Vector2(0, 0), 20.0, 32)
	var b := GooLoop.circle_points(Vector2(25, 0), 15.0, 32)
	var union := GooLoop.union_outline(a, b)
	assert_gt(union.size(), 3)
	assert_true(GooLoop.is_ccw(union), "union should be CCW")
	var area := GooLoop.area(union)
	assert_gt(area, maxf(GooLoop.area(a), GooLoop.area(b)))
	assert_lt(area, GooLoop.area(a) + GooLoop.area(b))

func test_union_of_far_circles_falls_back_to_hull() -> void:
	var a := GooLoop.circle_points(Vector2(0, 0), 10.0, 16)
	var b := GooLoop.circle_points(Vector2(100, 0), 10.0, 16)
	var union := GooLoop.union_outline(a, b)
	assert_true(GooLoop.is_ccw(union), "hull should be CCW")
	assert_ne(union[0], union[union.size() - 1], "hull's closing point should be dropped")
	assert_gt(GooLoop.area(union), GooLoop.area(a) + GooLoop.area(b))
	for point: Vector2 in a + b:
		var on_edge := false
		for i: int in union.size():
			var closest := Geometry2D.get_closest_point_to_segment(point, union[i], union[(i + 1) % union.size()])
			if closest.distance_to(point) < 0.001:
				on_edge = true
		assert_true(GooLoop.point_in_loop(point, union) or on_edge, "%s outside the hull" % point)

func test_centroid_of_circle_is_its_centre() -> void:
	var centroid := GooLoop.centroid(GooLoop.circle_points(CENTRE, 10.0, 12))
	assert_almost_eq(centroid.x, CENTRE.x, 0.0001)
	assert_almost_eq(centroid.y, CENTRE.y, 0.0001)

func test_best_fit_rotation_recovers_rotation() -> void:
	# A non-symmetric shape so the rotation is unambiguous.
	var rest := PackedVector2Array([Vector2(0, 0), Vector2(30, 0), Vector2(30, 10), Vector2(5, 20)])
	var rest_centroid := GooLoop.centroid(rest)
	var current := PackedVector2Array()
	for point: Vector2 in rest:
		current.append((point - rest_centroid).rotated(0.3) + Vector2(200, -40))
	assert_almost_eq(GooLoop.best_fit_rotation(rest, current), 0.3, 0.0001)
	var goals := GooLoop.goal_positions(rest, current)
	assert_eq(goals.size(), rest.size())
	for i: int in goals.size():
		assert_almost_eq(goals[i].distance_to(current[i]), 0.0, 0.001, "goal %d" % i)

func test_best_fit_rotation_ignores_translation() -> void:
	var rest := GooLoop.circle_points(Vector2.ZERO, 10.0, 16)
	var current := PackedVector2Array()
	for point: Vector2 in rest:
		current.append(point + Vector2(37, 12))
	assert_almost_eq(GooLoop.best_fit_rotation(rest, current), 0.0, 0.0001)

func test_goal_positions_undo_a_squash() -> void:
	var rest := GooLoop.circle_points(Vector2.ZERO, 10.0, 16)
	var current := PackedVector2Array()
	for point: Vector2 in rest:
		current.append(Vector2(point.x * 1.5, point.y * 0.5) + Vector2(50, 0))
	var goals := GooLoop.goal_positions(rest, current)
	for i: int in goals.size():
		assert_almost_eq(goals[i].distance_to(Vector2(50, 0)), 10.0, 0.001, "goal %d" % i)

func test_self_intersects() -> void:
	assert_false(GooLoop.self_intersects(GooLoop.circle_points(CENTRE, 10.0, 16)))
	var bow_tie := PackedVector2Array([Vector2(0, 0), Vector2(10, 10), Vector2(10, 0), Vector2(0, 10)])
	assert_true(GooLoop.self_intersects(bow_tie))
	var square := PackedVector2Array([Vector2(0, 0), Vector2(10, 0), Vector2(10, 10), Vector2(0, 10)])
	assert_false(GooLoop.self_intersects(square))

func test_point_in_loop() -> void:
	var ring := GooLoop.circle_points(CENTRE, 10.0, 16)
	assert_true(GooLoop.point_in_loop(CENTRE, ring))
	assert_false(GooLoop.point_in_loop(CENTRE + Vector2(20, 0), ring))

var SQUARE := PackedVector2Array([Vector2(0, 10), Vector2(10, 10), Vector2(10, 0), Vector2(0, 0)])

func test_polygon_beads_put_a_bead_on_every_vertex_in_order() -> void:
	var beads := GooLoop.polygon_beads(SQUARE, 8)
	assert_eq(beads.size(), 8)
	assert_true(GooLoop.is_ccw(beads), "the square is CCW on screen and so are its beads")
	assert_eq(beads[0], SQUARE[0], "starts at vertex 0")
	# Four equal edges, eight beads: a vertex and a midpoint per edge.
	var expected := PackedVector2Array([Vector2(0, 10), Vector2(5, 10), Vector2(10, 10), Vector2(10, 5),
		Vector2(10, 0), Vector2(5, 0), Vector2(0, 0), Vector2(0, 5)])
	for i: int in 8:
		assert_almost_eq(beads[i].distance_to(expected[i]), 0.0, 0.0001, "bead %d" % i)

func test_polygon_beads_spread_by_edge_length() -> void:
	# A 30 x 10 rectangle: 80 px around, so 8 beads 10 px apart, three segments on each long edge.
	var rectangle := PackedVector2Array([Vector2(0, 10), Vector2(30, 10), Vector2(30, 0), Vector2(0, 0)])
	var beads := GooLoop.polygon_beads(rectangle, 8)
	assert_eq(beads.size(), 8)
	for i: int in 8:
		assert_almost_eq(beads[i].distance_to(beads[(i + 1) % 8]), 10.0, 0.0001, "spacing after bead %d" % i)
	for vertex: Vector2 in rectangle:
		assert_true(beads.has(vertex), "bead on vertex %s" % vertex)

func test_polygon_beads_keep_the_area_and_take_uneven_counts() -> void:
	var triangle := PackedVector2Array([Vector2(0, 0), Vector2(40, 0), Vector2(20, -34.64)])
	if not GooLoop.is_ccw(triangle):
		triangle.reverse()
	for count: int in [3, 7, 16, 23]:
		var beads := GooLoop.polygon_beads(triangle, count)
		assert_eq(beads.size(), count)
		assert_almost_eq(GooLoop.area(beads), GooLoop.area(triangle), 0.001, "%d beads" % count)
		assert_true(GooLoop.is_ccw(beads))
		assert_false(GooLoop.self_intersects(beads))
		var gaps := PackedFloat32Array()
		for i: int in count:
			gaps.append(beads[i].distance_to(beads[(i + 1) % count]))
		if count >= 16:
			assert_lt(_max(gaps) / _min(gaps), 1.5, "%d beads spread evenly" % count)

func test_polygon_beads_with_fewer_beads_than_vertices_resamples() -> void:
	var beads := GooLoop.polygon_beads(SQUARE, 3)
	assert_eq(beads.size(), 3)
	assert_eq(GooLoop.polygon_beads(SQUARE, 0).size(), 0)

func test_chaikin_keeping_nothing_is_chaikin() -> void:
	var ring := GooLoop.circle_points(CENTRE, 30.0, 16)
	var keep := PackedByteArray()
	keep.resize(16)
	assert_eq(GooLoop.chaikin_keeping(ring, 2, keep), GooLoop.chaikin(ring, 2))
	assert_eq(GooLoop.chaikin_keeping(ring, 2, PackedByteArray()), GooLoop.chaikin(ring, 2),
		"no flags keeps nothing")

func test_chaikin_keeping_corners_leaves_them_sharp() -> void:
	var keep := PackedByteArray([1, 1, 1, 1])
	var once := GooLoop.chaikin_keeping(SQUARE, 1, keep)
	assert_eq(once.size(), 4 * 2 + 4, "each pass adds two points per edge plus the kept vertices")
	var smooth := GooLoop.chaikin_keeping(SQUARE, 3, keep)
	assert_almost_eq(GooLoop.area(smooth), 100.0, 0.0001, "nothing is cut off a square whose corners are kept")
	assert_true(GooLoop.is_ccw(smooth))
	for corner: Vector2 in SQUARE:
		assert_true(smooth.has(corner), "corner %s kept" % corner)
	assert_lt(GooLoop.area(GooLoop.chaikin(SQUARE, 3)), 90.0, "plain chaikin rounds the corners off")

func test_chaikin_keeping_some_corners_rounds_the_others() -> void:
	var keep := PackedByteArray([1, 0, 1, 0])
	var smooth := GooLoop.chaikin_keeping(SQUARE, 2, keep)
	assert_true(smooth.has(SQUARE[0]))
	assert_true(smooth.has(SQUARE[2]))
	assert_false(smooth.has(SQUARE[1]))
	assert_false(smooth.has(SQUARE[3]))
	var area := GooLoop.area(smooth)
	assert_gt(area, GooLoop.area(GooLoop.chaikin(SQUARE, 2)))
	assert_lt(area, 100.0)

func _max(values: PackedFloat32Array) -> float:
	var best := -INF
	for value: float in values:
		best = maxf(best, value)
	return best

func _min(values: PackedFloat32Array) -> float:
	var best := INF
	for value: float in values:
		best = minf(best, value)
	return best

func test_perimeter() -> void:
	assert_almost_eq(GooLoop.perimeter(SQUARE), 40.0, 0.0001)
	assert_almost_eq(GooLoop.perimeter(GooLoop.circle_points(CENTRE, 10.0, 256)), TAU * 10.0, 0.01)
	assert_eq(GooLoop.perimeter(PackedVector2Array()), 0.0)

# ---- Cuts along a line ----
# A loop of their own, away from CENTRE above.

const CUT_CENTRE: Vector2 = Vector2(400.0, 300.0)
const CUT_RADIUS: float = 100.0

func _circle() -> PackedVector2Array:
	return GooLoop.circle_points(CUT_CENTRE, CUT_RADIUS, 24)

# A peanut r(θ) = R (1 + 0.6 cos 2θ) around CUT_CENTRE, CCW on screen: two lobes
# along x, a waist 0.4 R high on either side of the centre.
func _peanut() -> PackedVector2Array:
	var points := PackedVector2Array()
	for i: int in 64:
		var angle := -TAU * i / 64.0
		var r := CUT_RADIUS * (1.0 + 0.6 * cos(2.0 * angle))
		points.append(CUT_CENTRE + Vector2(cos(angle), sin(angle)) * r)
	return points

func _sorted(ends: Vector2i) -> Array[int]:
	var result: Array[int] = [ends.x, ends.y]
	result.sort()
	return result

func test_pierces_only_with_the_tip_inside() -> void:
	var loop := _circle()
	assert_true(GooLoop.pierces(loop, CUT_CENTRE))
	assert_true(GooLoop.pierces(loop, CUT_CENTRE + Vector2(0.0, CUT_RADIUS * 0.9)))
	assert_false(GooLoop.pierces(loop, CUT_CENTRE + Vector2(CUT_RADIUS * 1.5, 0.0)))
	assert_false(GooLoop.pierces(loop, CUT_CENTRE + Vector2(0.0, CUT_RADIUS * 1.1)))

func test_pierces_within_reach_of_the_loop() -> void:
	# A Blade cannot get into the bead loop itself, only touch the beads' circles
	# around it: the tip counts as inside within `reach` of the loop.
	var loop := _circle()
	var below := CUT_CENTRE + Vector2(0.0, CUT_RADIUS + 5.0)
	assert_false(GooLoop.pierces(loop, below), "5 px outside, no reach")
	assert_true(GooLoop.pierces(loop, below, 6.0), "5 px outside, 6 px reach")
	assert_false(GooLoop.pierces(loop, below, 4.0), "5 px outside, 4 px reach")
	assert_true(GooLoop.pierces(loop, CUT_CENTRE, 4.0), "inside, whatever the reach")

func test_axis_through_the_centre_cuts_top_to_bottom() -> void:
	# circle_points starts on the right and runs CCW on screen: bead 6 is the
	# top, bead 18 the bottom.
	var ends := GooLoop.chord(_circle(), CUT_CENTRE, Vector2.UP)
	assert_eq(_sorted(ends), [6, 18] as Array[int])

func test_offset_axis_cuts_a_shorter_chord_on_its_side() -> void:
	var loop := _circle()
	var tip := CUT_CENTRE + Vector2(60.0, 0.0)
	var ends := GooLoop.chord(loop, tip, Vector2.UP)
	assert_ne(ends, GooLoop.NO_CHORD)
	if ends == GooLoop.NO_CHORD:
		return
	var spacing := loop[0].distance_to(loop[1])
	for index: int in [ends.x, ends.y]:
		assert_lt(absf(loop[index].x - tip.x), spacing / 2.0, "bead %d is next to the line" % index)
	assert_lt(loop[ends.x].distance_to(loop[ends.y]), 2.0 * CUT_RADIUS * 0.9, "a chord shorter than the diameter")
	assert_lt(minf(loop[ends.x].y, loop[ends.y].y), tip.y, "one end ahead of the tip")
	assert_gt(maxf(loop[ends.x].y, loop[ends.y].y), tip.y, "one end behind the tip")

func test_tilted_axis_cuts_along_it() -> void:
	var loop := _circle()
	var axis := Vector2(1.0, -1.0).normalized()
	var ends := GooLoop.chord(loop, CUT_CENTRE, axis)
	assert_ne(ends, GooLoop.NO_CHORD)
	if ends == GooLoop.NO_CHORD:
		return
	var spacing := loop[0].distance_to(loop[1])
	for index: int in [ends.x, ends.y]:
		var off_line := absf((loop[index] - CUT_CENTRE).cross(axis))
		assert_lt(off_line, spacing / 2.0, "bead %d is next to the line" % index)

func test_concave_loop_cuts_the_crossings_around_the_tip() -> void:
	var loop := _peanut()
	# The line y = CUT_CENTRE.y + 50 passes beside the waist (0.4 R high): it
	# enters and leaves each lobe, four crossings in all. The tip is inside the
	# right lobe.
	var tip := CUT_CENTRE + Vector2(100.0, 50.0)
	assert_true(GooLoop.pierces(loop, tip))
	var ends := GooLoop.chord(loop, tip, Vector2.RIGHT)
	assert_ne(ends, GooLoop.NO_CHORD)
	if ends == GooLoop.NO_CHORD:
		return
	var a := loop[ends.x]
	var b := loop[ends.y]
	assert_gt(a.x, CUT_CENTRE.x, "end %s is in the right lobe" % a)
	assert_gt(b.x, CUT_CENTRE.x, "end %s is in the right lobe" % b)
	assert_lt(minf(a.x, b.x), tip.x, "one end behind the tip")
	assert_gt(maxf(a.x, b.x), tip.x, "one end ahead of the tip")
	for point: Vector2 in [a, b]:
		assert_lt(absf(point.y - tip.y), 20.0, "%s is next to the line" % point)

func test_axis_along_an_edge_never_returns_one_bead() -> void:
	# A square with a bead at each corner and edge middle.
	var square := PackedVector2Array([
		Vector2(100, 0), Vector2(100, -50), Vector2(100, -100), Vector2(50, -100),
		Vector2(0, -100), Vector2(0, -50), Vector2(0, 0), Vector2(50, 0),
	])
	for tip: Vector2 in [Vector2(50, 0), Vector2(50, -100), Vector2(0, -50), Vector2(100, -50)]:
		for axis: Vector2 in [Vector2.RIGHT, Vector2.LEFT, Vector2.UP, Vector2.DOWN]:
			var ends := GooLoop.chord(square, tip, axis)
			assert_true(ends == GooLoop.NO_CHORD or ends.x != ends.y,
				"tip %s axis %s gave %s" % [tip, axis, ends])
	# A diamond touched at its top corner only: both crossings are that bead.
	var diamond := PackedVector2Array([Vector2(50, 0), Vector2(0, -50), Vector2(-50, 0), Vector2(0, 50)])
	assert_eq(GooLoop.chord(diamond, Vector2(0, -50), Vector2.RIGHT), GooLoop.NO_CHORD)

func test_a_bead_hooked_over_the_tip_is_cut_off_between_its_neighbours() -> void:
	# A 20-bead loop hanging left of a blade whose tip (the origin, axis up)
	# pokes into it: bead 17 has slipped over to the blade's right, below the
	# tip, so the line along the axis crosses only bead 17's two edges around
	# the tip (from the stability repro's impale_pile, on the floor blade).
	var loop := PackedVector2Array([
		Vector2(-7.1, -9.3), Vector2(-14.2, -2.4), Vector2(-20.1, 5.4), Vector2(-27.7, 11.6),
		Vector2(-35.8, 17.3), Vector2(-43.1, 23.9), Vector2(-37.5, 30.0), Vector2(-34.3, 37.9),
		Vector2(-34.5, 46.4), Vector2(-28.9, 53.4), Vector2(-20.2, 50.2), Vector2(-22.2, 41.7),
		Vector2(-13.3, 45.4), Vector2(-6.3, 38.0), Vector2(-7.1, 28.3), Vector2(-6.3, 18.8),
		Vector2(-5.1, 9.3), Vector2(4.4, 3.0), Vector2(-2.4, -5.2), Vector2(-3.3, -4.9)])
	var tip := Vector2.ZERO
	assert_true(GooLoop.point_in_loop(tip, loop), "the tip is inside the loop")
	assert_eq(_sorted(GooLoop.chord(loop, tip, Vector2.UP)), [16, 18] as Array[int],
		"the cut takes bead 17 off, not a chord between neighbours")
	# With the tip just outside the hooked bead, the same line names its edge's
	# beads as before.
	var ends := GooLoop.chord(loop, Vector2(0.0, 10.0), Vector2.UP)
	assert_true(ends == GooLoop.NO_CHORD or ends.x != ends.y)

func test_fewer_than_two_crossings_give_no_chord() -> void:
	var loop := _circle()
	assert_eq(GooLoop.chord(loop, CUT_CENTRE + Vector2(CUT_RADIUS * 2.0, 0.0), Vector2.UP), GooLoop.NO_CHORD,
		"a line beside the loop")
	assert_eq(GooLoop.chord(loop, CUT_CENTRE, Vector2.ZERO), GooLoop.NO_CHORD, "no axis")
	assert_eq(GooLoop.chord(PackedVector2Array([CUT_CENTRE, CUT_CENTRE + Vector2.RIGHT]), CUT_CENTRE, Vector2.UP), GooLoop.NO_CHORD,
		"too few beads")

func test_tip_just_outside_cuts_the_span_ahead() -> void:
	# A blade pressing into the loop's underside, its tip not inside yet: the
	# line runs into the loop ahead of the tip, and that span is the cut.
	var ends := GooLoop.chord(_circle(), CUT_CENTRE + Vector2(0.0, CUT_RADIUS + 5.0), Vector2.UP)
	assert_eq(_sorted(ends), [6, 18] as Array[int])

# ---- Crossings ----

const BOW_TIE: PackedVector2Array = [Vector2(0.0, 0.0), Vector2(10.0, 10.0), Vector2(10.0, 0.0), Vector2(0.0, 10.0)]

func test_first_crossing_of_a_bow_tie_is_its_middle() -> void:
	var crossing := GooLoop.first_crossing(BOW_TIE)
	assert_false(crossing.is_empty(), "a bow tie crosses itself")
	if crossing.is_empty():
		return
	assert_eq(crossing["i"], 0, "edge 0 (0,0)-(10,10)")
	assert_eq(crossing["j"], 2, "crosses edge 2 (10,0)-(0,10)")
	assert_eq(crossing["point"], Vector2(5.0, 5.0))
	assert_true(GooLoop.first_crossing(GooLoop.circle_points(CENTRE, 10.0, 16)).is_empty(), "a circle has none")
	# Edges that share a vertex or only touch do not count.
	var touching := PackedVector2Array([Vector2(0.0, 0.0), Vector2(10.0, 0.0), Vector2(10.0, 10.0), Vector2(5.0, 0.0), Vector2(0.0, 10.0)])
	assert_true(GooLoop.first_crossing(touching).is_empty(), "a vertex on another edge is not a crossing")

func test_split_at_crossings_cuts_a_bow_tie_into_its_two_triangles() -> void:
	var loops := GooLoop.split_at_crossings(BOW_TIE, 8)
	assert_eq(loops.size(), 2)
	if loops.size() != 2:
		return
	assert_eq(loops[0], PackedVector2Array([Vector2(0.0, 0.0), Vector2(5.0, 5.0), Vector2(0.0, 10.0)]))
	assert_eq(loops[1], PackedVector2Array([Vector2(5.0, 5.0), Vector2(10.0, 10.0), Vector2(10.0, 0.0)]))
	for lp: PackedVector2Array in loops:
		assert_false(GooLoop.self_intersects(lp), "each loop is simple")
		assert_almost_eq(GooLoop.area(lp), 25.0, 1e-4, "each lobe of the bow tie")
	assert_ne(GooLoop.is_ccw(loops[0]), GooLoop.is_ccw(loops[1]), "the two lobes of a bow tie are wound opposite ways")
	var flags := GooLoop.split_flags(BOW_TIE, PackedByteArray([1, 2, 3, 4]), 8)
	assert_eq(flags.size(), 2)
	if flags.size() == 2:
		assert_eq(flags[0], PackedByteArray([1, 0, 4]), "the first loop's flags, 0 at the crossing")
		assert_eq(flags[1], PackedByteArray([0, 2, 3]), "the second loop's flags, 0 at the crossing")
	var untouched := GooLoop.split_at_crossings(BOW_TIE, 0)
	assert_eq(untouched.size(), 1, "no budget: the loop as it is")
	assert_eq(untouched[0], BOW_TIE)
	var circle := GooLoop.circle_points(CENTRE, 10.0, 16)
	var simple := GooLoop.split_at_crossings(circle, 8)
	assert_eq(simple.size(), 1, "a simple loop as it is")
	assert_eq(simple[0], circle)

func test_split_at_crossings_of_a_folded_ring_gives_simple_loops_covering_the_fold() -> void:
	var ring := GooLoop.circle_points(CENTRE, 40.0, 16)
	var folded := ring.duplicate()
	for i: int in [15, 0, 1]:
		folded[i] = CENTRE - (ring[i] - CENTRE) * 1.3
	assert_true(GooLoop.self_intersects(folded))
	var loops := GooLoop.split_at_crossings(folded, 8)
	assert_gt(loops.size(), 1, "the fold is cut into loops")
	var total_signed := 0.0
	for lp: PackedVector2Array in loops:
		assert_false(GooLoop.self_intersects(lp), "each loop is simple")
		total_signed += GooLoop.signed_area(lp)
	assert_almost_eq(total_signed, GooLoop.signed_area(folded), 1e-2, "the loops' signed areas add up to the fold's")
	for i: int in [15, 0, 1]:
		var covered := false
		for lp: PackedVector2Array in loops:
			if Geometry2D.is_point_in_polygon(folded[i], lp) or lp.has(folded[i]):
				covered = true
		assert_true(covered, "folded bead %d is in a loop" % i)

# ---- Resizing ----

func test_scaled_keeps_centroid_turns_and_scales_area() -> void:
	var loop := GooShape.regular(4, 40.0).bead_loop(16, 6.0)
	for i: int in loop.size():
		loop[i] += CENTRE
	var big := GooLoop.scaled(loop, 1.7)
	assert_lt(GooLoop.centroid(big).distance_to(GooLoop.centroid(loop)), 0.001, "the centroid stays")
	assert_almost_eq(GooLoop.area(big) / GooLoop.area(loop), 1.7 * 1.7, 0.0001, "the area is factor² times")
	for i: int in loop.size():
		assert_almost_eq(GooShape.turn(big, i), GooShape.turn(loop, i), 0.0001, "turn %d kept" % i)
	assert_eq(Goo2D.find_corners(big), Goo2D.find_corners(loop), "the corners stay corners")

func test_squashed_keeps_area_and_stretches_across() -> void:
	var loop := GooLoop.circle_points(CENTRE, 50.0, 64)
	var flat := GooLoop.squashed(loop, 0.6, Vector2.RIGHT)
	assert_almost_eq(GooLoop.area(flat) / GooLoop.area(loop), 1.0, 0.0001, "a squash keeps the area")
	assert_lt(GooLoop.centroid(flat).distance_to(CENTRE), 0.001, "about the centroid")
	var box := Rect2(flat[0], Vector2.ZERO)
	for point: Vector2 in flat:
		box = box.expand(point)
	assert_almost_eq(box.size.x, 100.0 * 0.6, 0.5, "0.6 times as wide along the axis")
	assert_almost_eq(box.size.y, 100.0 / 0.6, 0.5, "1 / 0.6 times as tall across it")
	var turned := GooLoop.squashed(loop, 0.6, Vector2.DOWN, 1.2)
	box = Rect2(turned[0], Vector2.ZERO)
	for point: Vector2 in turned:
		box = box.expand(point)
	assert_almost_eq(box.size.y, 100.0 * 0.6 * 1.2, 0.5, "along another axis, scaled as a whole too")
	assert_almost_eq(GooLoop.area(turned) / GooLoop.area(loop), 1.44, 0.001)

func test_place_like_resamples_a_loop_keeping_area_corners_and_values() -> void:
	var square := GooShape.regular(4, 40.0)
	var loop := square.bead_loop(16, 6.0)
	var rest := square.bead_loop(24, 4.5)
	var shift := Vector2(300.0, 200.0)
	for i: int in loop.size():
		loop[i] += shift
	for i: int in rest.size():
		rest[i] += shift
	# Velocities equal to the positions: interpolated along the loop, each
	# placed point's value is the point itself.
	var placed := GooLoop.place_like(loop, loop, rest)
	var points: PackedVector2Array = placed[0]
	var values: PackedVector2Array = placed[1]
	assert_eq(points.size(), 24)
	assert_almost_eq(GooLoop.area(points) / GooLoop.area(loop), 1.0, 0.03, "the outline's area within 3%")
	for i: int in 24:
		assert_lt(values[i].distance_to(points[i]), 0.01, "value %d interpolated like its point" % i)
	var loop_corners := Goo2D.find_corners(loop)
	var rest_corners := Goo2D.find_corners(rest)
	for i: int in 24:
		if rest_corners[i] == 0:
			continue
		var nearest := INF
		for j: int in 16:
			if loop_corners[j] == 1:
				nearest = minf(nearest, loop[j].distance_to(points[i]))
		assert_lt(nearest, 1.0, "rest corner %d lands on a corner of the loop" % i)
	# Fewer points, and a loop turned and moved: still its outline.
	var circle := GooLoop.circle_points(Vector2(50.0, 60.0), 40.0, 22)
	var fewer := GooLoop.place_like(circle, PackedVector2Array(), GooLoop.circle_points(Vector2(50.0, 60.0), 30.0, 12))
	assert_eq((fewer[0] as PackedVector2Array).size(), 12)
	assert_almost_eq(GooLoop.area(fewer[0]) / GooLoop.area(circle), 1.0, 0.05)
	# A rest loop turned half a step of the loop's: its point 0 faces the middle
	# of the loop's edge 0, where placing starts (not at a vertex).
	var turned := PackedVector2Array()
	for point: Vector2 in GooLoop.circle_points(Vector2.ZERO, 40.0, 12):
		turned.append(Vector2(50.0, 60.0) + point.rotated(-PI / 22.0))
	var start: Vector2 = (GooLoop.place_like(circle, PackedVector2Array(), turned)[0] as PackedVector2Array)[0]
	assert_lt(start.distance_to((circle[0] + circle[1]) * 0.5), 0.01,
		"starting at the point of the loop nearest rest point 0, not at a vertex")
