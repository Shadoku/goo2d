extends TestCase
## Unit tests for GooShape: the rest outline of a body (a round blob's circle
## or a polygon), its area, equivalent radius, orientation and corners, and the
## bead loop a pressure ring of that shape is built on; and a polygon body's
## split made in rest space (cut(), cut_ring()). The parent's rest outline is
## moved rigidly onto its beads, cut along the chord between two fitted rest
## points (not the whole line through them: other arms of a concave outline
## stay whole), and each side becomes a polygon GooShape of its own area,
## the piece holding its own beads' rest points, unless it is a sliver too
## thin for its beads.

const R: float = 40.0

func test_round_keeps_its_radius_exactly() -> void:
	var shape := GooShape.round(R)
	assert_eq(shape.kind, GooShape.Kind.ROUND)
	assert_true(shape.is_round())
	assert_false(shape.has_flat_surface())
	assert_eq(shape.radius(), R, "a round shape's equivalent radius is the radius it was made with")
	assert_almost_eq(shape.area(), PI * R * R, 0.0001)
	assert_almost_eq(shape.perimeter(), TAU * R, 0.0001)
	assert_eq(shape.outline.size(), GooShape.ROUND_OUTLINE_POINTS)
	assert_true(GooLoop.is_ccw(shape.outline))
	assert_true(GooLoop.centroid(shape.outline).length() < 0.001)
	assert_eq(shape.corners(deg_to_rad(30.0)).size(), 0, "a circle has no corners")

func test_regular_polygons_have_the_area_of_their_equivalent_circle() -> void:
	for sides: int in [3, 4, 5, 6, 8]:
		var shape := GooShape.regular(sides, R)
		assert_eq(shape.kind, GooShape.Kind.POLYGON)
		assert_false(shape.is_round())
		assert_true(shape.has_flat_surface())
		assert_eq(shape.outline.size(), sides)
		assert_almost_eq(shape.area(), PI * R * R, 0.01, "%d-gon area" % sides)
		assert_almost_eq(shape.radius(), R, 0.0001, "%d-gon equivalent radius" % sides)
		assert_true(GooLoop.is_ccw(shape.outline), "%d-gon runs CCW on screen" % sides)
		assert_true(_area_centroid(shape.outline).length() < 0.001, "%d-gon centred on its centroid" % sides)

func test_square_side_and_perimeter() -> void:
	var square := GooShape.regular(4, R)
	var side := sqrt(PI) * R
	for i: int in 4:
		assert_almost_eq(square.outline[i].distance_to(square.outline[(i + 1) % 4]), side, 0.001)
	assert_almost_eq(square.perimeter(), 4.0 * side, 0.001)

func test_regular_polygons_sit_on_a_flat_bottom_edge() -> void:
	for sides: int in [3, 4, 5, 6, 7]:
		var outline := GooShape.regular(sides, R).outline
		var lowest := -INF
		for point: Vector2 in outline:
			lowest = maxf(lowest, point.y)
		# The two first vertices are the bottom edge (y down: largest y), left to right.
		assert_almost_eq(outline[0].y, lowest, 0.001, "%d-gon vertex 0 on the bottom" % sides)
		assert_almost_eq(outline[1].y, lowest, 0.001, "%d-gon vertex 1 on the bottom" % sides)
		assert_lt(outline[0].x, outline[1].x, "%d-gon bottom edge runs left to right" % sides)
		for i: int in range(2, sides):
			assert_lt(outline[i].y, lowest - 0.001, "%d-gon has only one bottom edge" % sides)

func test_polygon_recentres_and_makes_ccw() -> void:
	# A clockwise (on screen) 20 x 10 rectangle far from the origin.
	var clockwise := PackedVector2Array([Vector2(100.0, 50.0), Vector2(120.0, 50.0),
		Vector2(120.0, 60.0), Vector2(100.0, 60.0)])
	assert_false(GooLoop.is_ccw(clockwise))
	var shape := GooShape.polygon(clockwise)
	assert_eq(shape.kind, GooShape.Kind.POLYGON)
	assert_true(GooLoop.is_ccw(shape.outline))
	assert_true(_area_centroid(shape.outline).length() < 0.001)
	assert_almost_eq(shape.area(), 200.0, 0.001)
	assert_almost_eq(shape.perimeter(), 60.0, 0.001)
	assert_almost_eq(shape.radius(), sqrt(200.0 / PI), 0.0001)
	assert_false(GooLoop.is_ccw(clockwise), "the input is not modified")

func test_polygon_centres_on_the_area_centroid_not_the_vertex_mean() -> void:
	# A right triangle with extra points crowded on one leg: the vertex mean moves, the area centroid does not.
	var triangle := PackedVector2Array([Vector2(0.0, 0.0), Vector2(30.0, 0.0), Vector2(0.0, -30.0),
		Vector2(0.0, -20.0), Vector2(0.0, -10.0)])
	var shape := GooShape.polygon(triangle)
	assert_true(_area_centroid(shape.outline).length() < 0.001)
	assert_almost_eq(shape.area(), 450.0, 0.001)

func test_scaled_keeps_the_outline_and_changes_the_size() -> void:
	var triangle := GooShape.regular(3, R)
	var big := triangle.scaled(2.0 * R)
	assert_eq(big.kind, GooShape.Kind.POLYGON)
	assert_almost_eq(big.radius(), 2.0 * R, 0.0001)
	assert_almost_eq(big.area(), 4.0 * triangle.area(), 0.01)
	for i: int in 3:
		assert_almost_eq(big.outline[i].distance_to(2.0 * triangle.outline[i]), 0.0, 0.001)
	assert_almost_eq(triangle.radius(), R, 0.0001, "scaled() returns a new shape")
	var circle := GooShape.round(R).scaled(30.0)
	assert_true(circle.is_round())
	assert_eq(circle.radius(), 30.0)

func test_corners_of_regular_polygons() -> void:
	var limit := deg_to_rad(30.0)
	assert_eq(GooShape.regular(3, R).corners(limit), PackedInt32Array([0, 1, 2]))
	assert_eq(GooShape.regular(4, R).corners(limit), PackedInt32Array([0, 1, 2, 3]))
	assert_eq(GooShape.regular(6, R).corners(limit).size(), 6, "a hexagon turns 60° at every vertex")
	assert_eq(GooShape.regular(16, R).corners(limit).size(), 0, "a 16-gon turns only 22.5° at each vertex")

func test_corners_skip_straight_and_shallow_vertices() -> void:
	# A square with an extra point in the middle of its bottom edge and one bent outward by 10°.
	var outline := PackedVector2Array([Vector2(-10.0, 10.0), Vector2(0.0, 10.0), Vector2(10.0, 10.0),
		Vector2(10.0, -10.0), Vector2(0.0, -10.0 - 10.0 * tan(deg_to_rad(10.0))), Vector2(-10.0, -10.0)])
	var shape := GooShape.polygon(outline)
	# polygon() drops the point the outline runs straight through.
	assert_eq(shape.outline.size(), 5)
	assert_eq(shape.corners(deg_to_rad(30.0)), PackedInt32Array([0, 1, 2, 4]))
	assert_almost_eq(rad_to_deg(absf(GooShape.turn(shape.outline, 3))), 20.0, 0.001)

func test_bead_loop_is_the_inset_outline_with_a_bead_on_every_corner() -> void:
	var square := GooShape.regular(4, R)
	var inset := 6.0
	var loop := square.bead_loop(20, inset)
	assert_eq(loop.size(), 20)
	assert_true(GooLoop.is_ccw(loop))
	assert_false(GooLoop.self_intersects(loop))
	var half := sqrt(PI) * R / 2.0 - inset
	assert_almost_eq(GooLoop.area(loop), 4.0 * half * half, 0.1, "the bead loop encloses the inset square")
	for corner: Vector2 in [Vector2(-half, half), Vector2(half, half), Vector2(half, -half), Vector2(-half, -half)]:
		var nearest := INF
		for point: Vector2 in loop:
			nearest = minf(nearest, point.distance_to(corner))
		assert_lt(nearest, 0.01, "a bead sits on the inset corner %s" % corner)
	for point: Vector2 in loop:
		var on_edge := absf(absf(point.x) - half) < 0.01 or absf(absf(point.y) - half) < 0.01
		assert_true(on_edge, "bead %s lies on the inset square" % point)

func test_round_bead_loop_is_a_circle() -> void:
	var loop := GooShape.round(R).bead_loop(16, 5.0)
	assert_eq(loop.size(), 16)
	assert_true(GooLoop.is_ccw(loop))
	for point: Vector2 in loop:
		assert_almost_eq(point.length(), R - 5.0, 0.001)

# Area centroid of a simple polygon (not the vertex mean).
func _area_centroid(points: PackedVector2Array) -> Vector2:
	var total := Vector2.ZERO
	var twice_area := 0.0
	for i: int in points.size():
		var a := points[i]
		var b := points[(i + 1) % points.size()]
		var cross := a.cross(b)
		twice_area += cross
		total += (a + b) * cross
	return total / (3.0 * twice_area)

# The outline of `shape` moved by `offset`.
static func _moved(shape: GooShape, offset: Vector2) -> PackedVector2Array:
	var points := shape.outline.duplicate()
	for i: int in points.size():
		points[i] += offset
	return points

# Distance from `point` to the closed loop `loop`.
static func _distance_to_loop(point: Vector2, loop: PackedVector2Array) -> float:
	var nearest := INF
	for i: int in loop.size():
		var on_edge := Geometry2D.get_closest_point_to_segment(point, loop[i], loop[(i + 1) % loop.size()])
		nearest = minf(nearest, point.distance_to(on_edge))
	return nearest

func test_fused_squares_keep_their_outer_corners_and_fill_the_creases() -> void:
	var square := GooShape.regular(4, R)
	var side := sqrt(PI) * R
	var half := side / 2.0
	var reach := 10.0
	# B stands 1 px right of A and half a side higher (y down): A's top right
	# corner and B's bottom left corner are the two creases of the junction.
	var a := _moved(square, Vector2.ZERO)
	var b := _moved(square, Vector2(side + 1.0, -half))
	var fused := GooShape.fused(a, b, reach)
	assert_gt(fused.size(), 2, "one polygon")
	if fused.size() < 3:
		return
	assert_true(GooLoop.is_ccw(fused))
	assert_false(GooLoop.self_intersects(fused))
	var outer: Array[Vector2] = [Vector2(-half, -half), Vector2(-half, half), Vector2(half, half),
		Vector2(half + 1.0, -side), Vector2(side + half + 1.0, -side), Vector2(side + half + 1.0, 0.0)]
	for corner: Vector2 in outer:
		var at := -1
		for i: int in fused.size():
			if fused[i].distance_to(corner) < 0.05:
				at = i
		assert_ne(at, -1, "outer corner %s is kept" % corner)
		if at >= 0:
			assert_almost_eq(absf(rad_to_deg(GooShape.turn(fused, at))), 90.0, 2.0, "corner %s stays square" % corner)
	var sharp := 0
	for i: int in fused.size():
		if absf(GooShape.turn(fused, i)) > Goo2D.CORNER_ANGLE:
			sharp += 1
	assert_eq(sharp, 6, "only the 6 outer corners are sharp: the creases are rounded off")
	for crease: Vector2 in [Vector2(half + 1.0, -half), Vector2(half, 0.0)]:
		assert_true(Geometry2D.is_point_in_polygon(crease, fused), "crease %s is filled" % crease)
		# A disc of radius `reach` rolled into a right-angled crease stops
		# (√2 − 1) × reach from its corner.
		assert_almost_eq(_distance_to_loop(crease, fused), (sqrt(2.0) - 1.0) * reach, 0.5,
			"crease %s is filled up to the contact range" % crease)
	var bridge := 1.0 * half
	var fillets := 2.0 * reach * reach * (1.0 - PI / 4.0)
	var expected := 2.0 * square.area() + bridge + fillets
	print("    fused squares: %d points, area %.1f (squares %.1f + bridge %.1f + fillets %.1f)"
		% [fused.size(), GooLoop.area(fused), 2.0 * square.area(), bridge, fillets])
	assert_almost_eq(GooLoop.area(fused), expected, 0.01 * expected, "nothing but the creases changes")

func test_fused_aligned_squares_make_one_rectangle() -> void:
	var square := GooShape.regular(4, R)
	var side := sqrt(PI) * R
	var fused := GooShape.fused(_moved(square, Vector2.ZERO), _moved(square, Vector2(side - 0.5, 0.0)), 10.0)
	assert_eq(fused.size(), 4, "two squares overlapping by half a pixel fuse into a rectangle")
	assert_almost_eq(GooLoop.area(fused), (2.0 * side - 0.5) * side, 0.5)
	var shape := GooShape.polygon(fused)
	assert_eq(shape.corners(Goo2D.CORNER_ANGLE).size(), 4)

func test_fused_rejects_shapes_apart() -> void:
	var square := GooShape.regular(4, R)
	var side := sqrt(PI) * R
	var reach := 10.0
	var apart := GooShape.fused(_moved(square, Vector2.ZERO), _moved(square, Vector2(side + 2.0 * reach + 2.0, 0.0)), reach)
	assert_true(apart.is_empty(), "squares more than twice the contact range apart do not fuse")
	var near := GooShape.fused(_moved(square, Vector2.ZERO), _moved(square, Vector2(side + 3.0, 0.0)), reach)
	assert_false(near.is_empty(), "a gap under the contact range is bridged")

func test_scaled_to_area_keeps_the_centroid_and_sets_the_area() -> void:
	var square := GooShape.regular(4, R)
	var moved := _moved(square, Vector2(120.0, -40.0))
	var scaled := GooShape.scaled_to_area(moved, 2.0 * square.area())
	assert_eq(scaled.size(), 4)
	assert_almost_eq(GooLoop.area(scaled), 2.0 * square.area(), 0.01)
	var centre := GooShape.area_centroid(scaled)
	assert_almost_eq(centre.x, 120.0, 0.01)
	assert_almost_eq(centre.y, -40.0, 0.01)
	assert_almost_eq(moved[0].distance_to(moved[1]) * sqrt(2.0), scaled[0].distance_to(scaled[1]), 0.01,
		"a doubled area scales each side by root two")
	var same := GooShape.scaled_to_area(moved, 0.0)
	assert_eq(same, moved, "a non-positive area leaves the outline alone")

func test_fitted_outline_follows_the_ring() -> void:
	var square := GooShape.regular(4, R)
	var count := 20
	var bead := 5.0
	var loop := square.bead_loop(count, bead)
	var mean := GooLoop.centroid(loop)
	var rest := PackedVector2Array()
	for point: Vector2 in loop:
		rest.append(point - mean)
	var angle := deg_to_rad(20.0)
	var centre := Vector2(300.0, 400.0)
	var points := PackedVector2Array()
	for point: Vector2 in rest:
		points.append(centre + point.rotated(angle))
	var fitted := square.fitted_outline(rest, points, bead)
	assert_eq(fitted.size(), 4)
	for i: int in 4:
		var expected := centre + (square.outline[i] - mean).rotated(angle)
		assert_almost_eq(fitted[i].distance_to(expected), 0.0, 0.001, "corner %d" % i)

# ---- Cutting a polygon body in rest space ----
# A square of its own size, CUT_R (R above is another size).

const CUT_R: float = 48.0

# The square of equivalent radius CUT_R as a ring would hold it: its rest shape
# (bead loop about its centroid) and its beads in the pose `angle`, `centre`.
func _square_ring(angle: float, centre: Vector2) -> Dictionary:
	var shape := GooShape.regular(4, CUT_R)
	var tuning := GooTuning.tuning_for(shape)
	var loop := shape.bead_loop(tuning["bead_count"], tuning["bead_radius"])
	var mean := GooLoop.centroid(loop)
	var rest := PackedVector2Array()
	var points := PackedVector2Array()
	for point: Vector2 in loop:
		rest.append(point - mean)
		points.append(centre + (point - mean).rotated(angle))
	return { "shape": shape, "tuning": tuning, "rest": rest, "points": points, "mean": mean }

# Indices of the rest loop's corner beads, in loop order.
static func _corner_beads(rest: PackedVector2Array) -> PackedInt32Array:
	var corners := PackedInt32Array()
	var flags := Goo2D.find_corners(rest)
	for i: int in flags.size():
		if flags[i] == 1:
			corners.append(i)
	return corners

func test_fitted_outline_is_the_outline_moved_onto_the_beads() -> void:
	var angle := 0.4
	var centre := Vector2(300.0, 500.0)
	var ring := _square_ring(angle, centre)
	var shape: GooShape = ring["shape"]
	var fitted := shape.fitted_outline(ring["rest"], ring["points"], float(ring["tuning"]["bead_radius"]))
	assert_eq(fitted.size(), 4)
	assert_almost_eq(GooLoop.area(fitted), shape.area(), 0.01, "a rigid move keeps the area")
	# The bead loop's mean is not quite the outline's area centroid (a square's
	# edges get 5 and 6 beads): the outline goes where it sits around the beads.
	var mean: Vector2 = ring["mean"]
	for i: int in 4:
		var expected := centre + (shape.outline[i] - mean).rotated(angle)
		assert_almost_eq(fitted[i].distance_to(expected), 0.0, 0.01, "corner %d" % i)

func test_cut_by_a_line_gives_both_sides() -> void:
	var square := PackedVector2Array([Vector2(-10, -10), Vector2(-10, 10), Vector2(10, 10), Vector2(10, -10)])
	var sides := GooShape.cut(square, Vector2(0.0, -3.0), Vector2(0.0, 3.0))
	assert_eq(sides.size(), 2)
	for side: PackedVector2Array in sides:
		assert_true(GooLoop.is_ccw(side))
		assert_almost_eq(GooLoop.area(side), 200.0, 0.01, "the line cuts the square in half")
	var normal := Vector2(0.0, 6.0).orthogonal()
	assert_gt(GooLoop.centroid(sides[0]).dot(normal), 0.0, "side 0 is the one (to - from).orthogonal() points to")
	assert_lt(GooLoop.centroid(sides[1]).dot(normal), 0.0)
	var missed := GooShape.cut(square, Vector2(20.0, 0.0), Vector2(20.0, 5.0))
	assert_true(missed[0].is_empty() and missed[1].is_empty(), "a chord beside the polygon cuts nothing")

func test_cut_follows_the_chord_not_the_whole_line() -> void:
	# A U open at the top: the line y = 10 crosses both arms; the chord across
	# the left arm cuts only that arm's tip off.
	var u := PackedVector2Array(U_OUTLINE)
	var sides := GooShape.cut(u, Vector2(10.0, 100.0), Vector2(60.0, 100.0))
	assert_false(sides[0].is_empty() or sides[1].is_empty(), "the chord across the left arm cuts")
	if sides[0].is_empty() or sides[1].is_empty():
		return
	var areas: Array[float] = [GooLoop.area(sides[0]), GooLoop.area(sides[1])]
	assert_almost_eq(areas[0] + areas[1], GooLoop.area(u), 0.01, "the two parts share the area exactly")
	assert_almost_eq(minf(areas[0], areas[1]), 70.0 * 100.0, 0.01, "the tip of the left arm, above the chord")
	var tip := sides[0] if areas[0] < areas[1] else sides[1]
	assert_true(Geometry2D.is_point_in_polygon(Vector2(35.0, 50.0), tip))
	assert_false(Geometry2D.is_point_in_polygon(Vector2(245.0, 50.0), tip), "the right arm is not in the tip")
	var normal := Vector2(50.0, 0.0).orthogonal()
	assert_gt((GooShape.area_centroid(sides[0]) - Vector2(35.0, 100.0)).dot(normal), 0.0,
		"side 0 is the one (to - from).orthogonal() points to (up the screen here: the tip)")
	# A chord with an end on the outline still cuts; one across the gap between
	# the arms (outside the outline) or crossing it between its ends does not.
	var to_edge := GooShape.cut(u, Vector2(0.0, 100.0), Vector2(60.0, 100.0))
	assert_almost_eq(minf(GooLoop.area(to_edge[0]), GooLoop.area(to_edge[1])), 70.0 * 100.0, 0.01, "an end on the outline")
	var across_gap := GooShape.cut(u, Vector2(80.0, 100.0), Vector2(180.0, 100.0))
	assert_true(across_gap[0].is_empty() and across_gap[1].is_empty(), "a chord outside the outline")
	var through_gap := GooShape.cut(u, Vector2(30.0, 100.0), Vector2(250.0, 100.0))
	assert_true(through_gap[0].is_empty() and through_gap[1].is_empty(), "a chord that leaves and re-enters the outline")

func test_square_cut_on_its_diagonal_gives_two_triangles_of_half_the_area() -> void:
	var ring := _square_ring(0.3, Vector2(360.0, 400.0))
	var shape: GooShape = ring["shape"]
	var corners := _corner_beads(ring["rest"])
	assert_eq(corners.size(), 4)
	var pieces := shape.cut_ring(ring["rest"], ring["points"], corners[0], corners[2],
		float(ring["tuning"]["bead_radius"]), 0.0)
	assert_eq(pieces.size(), 2, "the diagonal cut is made")
	if pieces.size() != 2:
		return
	for piece: Dictionary in pieces:
		var piece_shape: GooShape = piece["shape"]
		assert_eq(piece_shape.kind, GooShape.Kind.POLYGON)
		assert_eq(piece_shape.outline.size(), 3, "a triangle")
		assert_almost_eq(piece_shape.area(), shape.area() / 2.0, 0.01 * shape.area(), "half the square")
		assert_almost_eq(piece_shape.radius(), CUT_R / sqrt(2.0), 0.1)
		assert_eq(piece_shape.corners(Goo2D.CORNER_ANGLE).size(), 3)

func test_pieces_come_in_bead_order_with_rest_loops_in_the_fitted_pose() -> void:
	var angle := -0.7
	var ring := _square_ring(angle, Vector2(200.0, 300.0))
	var points: PackedVector2Array = ring["points"]
	var count := points.size()
	var a := 1
	var b := count / 2 + 3
	var pieces := (ring["shape"] as GooShape).cut_ring(ring["rest"], points, a, b,
		float(ring["tuning"]["bead_radius"]), 0.0)
	assert_eq(pieces.size(), 2)
	if pieces.size() != 2:
		return
	# Piece 0 holds beads a+1 … b-1 (sub_loop(points, a, b)), piece 1 the others.
	var inside := [Goo2D.sub_loop(points, a, b), Goo2D.sub_loop(points, b, a)]
	for k: int in 2:
		var piece: Dictionary = pieces[k]
		var outline: PackedVector2Array = piece["outline"]
		var loop: PackedVector2Array = inside[k]
		var middle := loop[loop.size() / 2]
		assert_true(Geometry2D.is_point_in_polygon(middle, outline), "piece %d holds its own beads" % k)
		var tuning: Dictionary = piece["tuning"]
		var rest_loop: PackedVector2Array = piece["rest_loop"]
		var piece_shape: GooShape = piece["shape"]
		assert_eq(rest_loop.size(), int(tuning["bead_count"]), "one rest point per bead")
		assert_true(GooLoop.is_ccw(rest_loop))
		assert_eq(tuning, GooTuning.tuning_for(piece_shape))
		# The rest loop is the piece's bead loop inside its fitted outline, one bead radius in.
		for point: Vector2 in rest_loop:
			assert_true(Geometry2D.is_point_in_polygon(point, outline), "rest point inside the piece")
		assert_almost_eq(GooLoop.area(rest_loop),
			GooLoop.area(piece_shape.bead_loop(tuning["bead_count"], tuning["bead_radius"])), 0.01)
	var total := 0.0
	for piece: Dictionary in pieces:
		total += (piece["shape"] as GooShape).area()
	assert_almost_eq(total, (ring["shape"] as GooShape).area(), 0.01, "the pieces share the parent's area exactly")

func test_off_centre_cuts_give_a_triangle_and_a_trapezoid_or_a_pentagon() -> void:
	var s := 40.0
	var square := PackedVector2Array([Vector2(-s, -s), Vector2(-s, s), Vector2(s, s), Vector2(s, -s)])
	# Through a corner and the middle of a far side: a triangle and a trapezoid.
	var through_corner := GooShape.cut(square, Vector2(s, s), Vector2(-s, 0.0))
	var counts: Array[int] = []
	for side: PackedVector2Array in through_corner:
		counts.append(GooShape.polygon(side).outline.size())
	counts.sort()
	assert_eq(counts, [3, 4] as Array[int], "a corner to a side's middle: triangle and trapezoid")
	var areas: Array[float] = [GooLoop.area(through_corner[0]), GooLoop.area(through_corner[1])]
	areas.sort()
	assert_almost_eq(areas[0], s * s, 0.01)
	assert_almost_eq(areas[1], 3.0 * s * s, 0.01)
	# Across two adjacent sides: a triangle and a pentagon.
	var corner_clip := GooShape.cut(square, Vector2(0.0, s), Vector2(s, 0.0))
	counts.clear()
	for side: PackedVector2Array in corner_clip:
		counts.append(GooShape.polygon(side).outline.size())
	counts.sort()
	assert_eq(counts, [3, 5] as Array[int], "a corner clipped off: triangle and pentagon")
	# Across two opposite sides off the middle: two trapezoids.
	var slanted := GooShape.cut(square, Vector2(-10.0, -s), Vector2(10.0, s))
	counts.clear()
	for side: PackedVector2Array in slanted:
		counts.append(GooShape.polygon(side).outline.size())
	assert_eq(counts, [4, 4] as Array[int], "opposite sides: two trapezoids")

func test_inscribed_width() -> void:
	var strip := PackedVector2Array([Vector2(0, 0), Vector2(0, 20), Vector2(100, 20), Vector2(100, 0)])
	assert_true(GooShape.is_wider_than(strip, 19.0))
	assert_false(GooShape.is_wider_than(strip, 21.0))
	var triangle := GooShape.regular(3, CUT_R).outline
	# A triangle's inscribed circle: radius side / (2√3).
	var side := triangle[0].distance_to(triangle[1])
	var width := side / sqrt(3.0)
	assert_true(GooShape.is_wider_than(triangle, width - 0.5))
	assert_false(GooShape.is_wider_than(triangle, width + 0.5))

func test_sliver_is_rejected() -> void:
	var ring := _square_ring(0.0, Vector2(360.0, 400.0))
	var shape: GooShape = ring["shape"]
	var rest: PackedVector2Array = ring["rest"]
	var points: PackedVector2Array = ring["points"]
	var bead_size: float = ring["tuning"]["bead_radius"]
	# The beads on the left and right sides nearest a horizontal line a fifth of
	# the way down: a strip of a fifth of the square (17 px of a side of 85) is
	# big enough by area (equivalent radius 21 px), far too thin for its beads.
	var side := sqrt(PI) * CUT_R
	var sliver := _side_beads(rest, -side / 2.0 + side / 5.0, side)
	var pieces := shape.cut_ring(rest, points, sliver.x, sliver.y, bead_size, 0.0)
	assert_eq(pieces.size(), 0, "a sliver is not cut off")
	# The square cut the same way through its middle is fine.
	var middle := _side_beads(rest, 0.0, side)
	assert_eq(shape.cut_ring(rest, points, middle.x, middle.y, bead_size, 0.0).size(), 2,
		"halves of a launch-size square are wide enough")

# The beads of the left and right sides of the square rest loop `rest` (of
# side `side`) nearest the height `y`, as Vector2i(left, right).
static func _side_beads(rest: PackedVector2Array, y: float, side: float) -> Vector2i:
	var left := -1
	var right := -1
	for i: int in rest.size():
		if rest[i].x < -side / 4.0 and (left < 0 or absf(rest[i].y - y) < absf(rest[left].y - y)):
			left = i
		if rest[i].x > side / 4.0 and (right < 0 or absf(rest[i].y - y) < absf(rest[right].y - y)):
			right = i
	return Vector2i(left, right)

func test_trim_keeps_the_larger_side_at_the_whole_area() -> void:
	var ring := _square_ring(0.0, Vector2(360.0, 400.0))
	var shape: GooShape = ring["shape"]
	var rest: PackedVector2Array = ring["rest"]
	var points: PackedVector2Array = ring["points"]
	var bead_size: float = ring["tuning"]["bead_radius"]
	var side := sqrt(PI) * CUT_R
	# The sliver cut above: the strip on top is refused, so the trim keeps the
	# rest, the side of beads b … a, scaled back up to the square's area.
	var sliver := _side_beads(rest, -side / 2.0 + side / 5.0, side)
	var trimmed := shape.trim_ring(rest, points, sliver.x, sliver.y, bead_size)
	assert_false(trimmed.is_empty(), "a sliver cut trims")
	if trimmed.is_empty():
		return
	var kept: GooShape = trimmed["shape"]
	var cut := shape.cut_ring(rest, points, sliver.x, sliver.y, bead_size, 0.0)
	assert_eq(cut.size(), 0)
	var sides := GooShape.cut(shape.fitted_outline(rest, points, bead_size),
		GooLoop.goal_positions(rest, points)[sliver.x], GooLoop.goal_positions(rest, points)[sliver.y])
	var larger := maxf(GooLoop.area(sides[0]), GooLoop.area(sides[1]))
	print("    trim of a %.0f px square a fifth of the way down: kept side %d, %.0f px² of %.0f scaled to %.0f; %d-gon, %d-bead rest loop"
		% [CUT_R, trimmed["side"], larger, shape.area(), kept.area(), kept.outline.size(), (trimmed["rest_loop"] as PackedVector2Array).size()])
	assert_almost_eq(kept.area(), shape.area(), 0.001 * shape.area(), "the whole area")
	assert_almost_eq(kept.radius(), CUT_R, 0.01)
	assert_eq(kept.outline.size(), 4, "a square less a strip is a rectangle")
	assert_eq((trimmed["rest_loop"] as PackedVector2Array).size(), int(trimmed["tuning"]["bead_count"]))
	# Beads a+1 … b-1 run from the left side over the top to the right side (CCW
	# on screen runs left, down, right, up): the strip is side 0, the kept rest
	# side 1.
	var a_side := Goo2D.sub_loop(points, sliver.x, sliver.y)
	var kept_side := 0 if GooLoop.area(a_side) > GooLoop.area(Goo2D.sub_loop(points, sliver.y, sliver.x)) else 1
	assert_eq(trimmed["side"], kept_side, "the larger side is kept")
	var outline: PackedVector2Array = trimmed["outline"]
	var centre := GooShape.area_centroid(outline)
	assert_gt(centre.y, 400.0, "the kept outline sits below the cut, where the larger side is")

func test_trim_is_refused_like_a_cut_for_degenerate_requests() -> void:
	var ring := _square_ring(0.0, Vector2(360.0, 400.0))
	var bead_size: float = ring["tuning"]["bead_radius"]
	var count := (ring["points"] as PackedVector2Array).size()
	for pair: Vector2i in [Vector2i(0, 0), Vector2i(0, 1), Vector2i(-1, 3), Vector2i(0, count)]:
		assert_true((ring["shape"] as GooShape).trim_ring(ring["rest"], ring["points"], pair.x, pair.y, bead_size).is_empty(),
			"pair %s" % pair)
	assert_true(GooShape.round(CUT_R).trim_ring(ring["rest"], ring["points"], 0, count / 2, bead_size).is_empty(),
		"a round shape is not trimmed in rest space")

func test_piece_under_the_minimum_radius_is_rejected() -> void:
	var ring := _square_ring(0.0, Vector2(360.0, 400.0))
	var corners := _corner_beads(ring["rest"])
	var bead_size: float = ring["tuning"]["bead_radius"]
	var shape: GooShape = ring["shape"]
	var rest: PackedVector2Array = ring["rest"]
	var points: PackedVector2Array = ring["points"]
	assert_eq(shape.cut_ring(rest, points, corners[0], corners[2], bead_size, CUT_R / sqrt(2.0) - 1.0).size(), 2)
	assert_eq(shape.cut_ring(rest, points, corners[0], corners[2], bead_size, CUT_R / sqrt(2.0) + 1.0).size(), 0,
		"a piece under the minimum equivalent radius")

func test_degenerate_requests_are_rejected() -> void:
	var ring := _square_ring(0.0, Vector2(360.0, 400.0))
	var bead_size: float = ring["tuning"]["bead_radius"]
	var count := (ring["points"] as PackedVector2Array).size()
	for pair: Vector2i in [Vector2i(0, 0), Vector2i(0, 1), Vector2i(-1, 3), Vector2i(0, count)]:
		assert_eq((ring["shape"] as GooShape).cut_ring(ring["rest"], ring["points"], pair.x, pair.y, bead_size, 0.0).size(), 0,
			"pair %s" % pair)
	assert_eq(GooShape.round(CUT_R).cut_ring(ring["rest"], ring["points"], 0, count / 2, bead_size, 0.0).size(), 0,
		"a round shape is not cut in rest space")

# ---- Cutting a concave polygon body ----
# The line through a chord's ends crosses a concave outline more than twice: a
# U's left arm cut across at mid-height lies on a line that also crosses its
# right arm. The cut must follow the chord, not the whole line, and give each
# side of the beads the piece that holds them.

# A U, open at the top of the screen: arms 70 and 110 px wide and 200 long on a
# base 300 wide and 60 high (CCW on screen).
const U_OUTLINE: Array[Vector2] = [Vector2(0, 0), Vector2(0, 260), Vector2(300, 260), Vector2(300, 0),
	Vector2(190, 0), Vector2(190, 200), Vector2(70, 200), Vector2(70, 0)]
# A dumbbell: two 120 x 200 bulbs joined near the bottom by a bar 100 long
# and 60 high, so a line across the top of one bulb crosses the other bulb too.
const DUMBBELL_OUTLINE: Array[Vector2] = [Vector2(0, 0), Vector2(0, 200), Vector2(120, 200),
	Vector2(120, 180), Vector2(220, 180), Vector2(220, 200), Vector2(340, 200), Vector2(340, 0),
	Vector2(220, 0), Vector2(220, 120), Vector2(120, 120), Vector2(120, 0)]

# A ring of the polygon `outline` (given in its own frame) at rest, as a body of
# it holds it: its shape, tuning, rest shape (bead loop about its centroid) and
# beads, turned by `angle` about the outline's area centroid and moved there
# to `offset`; "place" maps a point of the outline's frame to that pose.
func _outline_ring(outline: Array[Vector2], angle: float, offset: Vector2) -> Dictionary:
	var source := PackedVector2Array(outline)
	var shape := GooShape.polygon(source)
	var tuning := GooTuning.tuning_for(shape)
	var loop := shape.bead_loop(tuning["bead_count"], tuning["bead_radius"])
	var mean := GooLoop.centroid(loop)
	var origin := GooShape.area_centroid(source)
	var rest := PackedVector2Array()
	var points := PackedVector2Array()
	for point: Vector2 in loop:
		rest.append(point - mean)
		points.append(offset + point.rotated(angle))
	var place := func(local: Vector2) -> Vector2: return offset + (local - origin).rotated(angle)
	return { "shape": shape, "tuning": tuning, "rest": rest, "points": points, "place": place }

# Index of the point of `points` nearest `target`.
static func _nearest_point(points: PackedVector2Array, target: Vector2) -> int:
	var best := 0
	for i: int in points.size():
		if points[i].distance_squared_to(target) < points[best].distance_squared_to(target):
			best = i
	return best

# Asserts that the cut of the ring `ring` along the chord from bead `a` to bead
# `b` is made, that each piece's outline holds the fitted rest points of its
# own beads (piece 0 those of beads a+1 … b-1, piece 1 the others), and that
# the pieces share the outline's area; returns the pieces.
func _assert_cut_by_beads(ring: Dictionary, a: int, b: int, label: String) -> Array[Dictionary]:
	var shape: GooShape = ring["shape"]
	var rest: PackedVector2Array = ring["rest"]
	var points: PackedVector2Array = ring["points"]
	var bead_size: float = ring["tuning"]["bead_radius"]
	var pieces := shape.cut_ring(rest, points, a, b, bead_size, GooTuning.MIN_RADIUS * GooWorld2D.MIN_PIECE_RATIO)
	assert_eq(pieces.size(), 2, label + ": the cut is made (%d beads of %.1f px)" % [points.size(), bead_size])
	if pieces.size() != 2:
		return pieces
	var goals := GooLoop.goal_positions(rest, points)
	var count := points.size()
	var total := 0.0
	for k: int in 2:
		var outline: PackedVector2Array = pieces[k]["outline"]
		total += GooLoop.area(outline)
		var i := (a + 1) % count if k == 0 else (b + 1) % count
		var end := b if k == 0 else a
		var outside := 0
		while i != end:
			if not Geometry2D.is_point_in_polygon(goals[i], outline):
				outside += 1
			i = (i + 1) % count
		assert_eq(outside, 0, label + ": piece %d holds the rest points of its own beads" % k)
		print("    %s: piece %d, %d-gon of %.0f px² centred on %s" % [label, k, outline.size(),
			GooLoop.area(outline), GooShape.area_centroid(outline)])
	assert_almost_eq(total, shape.area(), 0.001 * shape.area(), label + ": the pieces share the outline's area")
	return pieces

func test_a_u_cut_across_one_arm_leaves_the_other_arm_whole() -> void:
	for angle: float in [0.0, 0.6]:
		var ring := _outline_ring(U_OUTLINE, angle, Vector2(500.0, 400.0))
		var place: Callable = ring["place"]
		var points: PackedVector2Array = ring["points"]
		var a := _nearest_point(points, place.call(Vector2(0, 100)))
		var b := _nearest_point(points, place.call(Vector2(70, 100)))
		for pair: Vector2i in [Vector2i(a, b), Vector2i(b, a)]:
			var label := "U turned %.1f, chord %d-%d" % [angle, pair.x, pair.y]
			var pieces := _assert_cut_by_beads(ring, pair.x, pair.y, label)
			if pieces.size() != 2:
				continue
			# The tip of the left arm, above the chord, is the small piece; the
			# right arm (x 190 … 300) and the base are all in the other.
			var areas: Array[float] = [GooLoop.area(pieces[0]["outline"]), GooLoop.area(pieces[1]["outline"])]
			var tip: PackedVector2Array = pieces[0 if areas[0] < areas[1] else 1]["outline"]
			var rest_of_u: PackedVector2Array = pieces[1 if areas[0] < areas[1] else 0]["outline"]
			for local: Vector2 in [Vector2(35, 5), Vector2(195, 5), Vector2(295, 5), Vector2(245, 100), Vector2(150, 230)]:
				var spot: Vector2 = place.call(local)
				var on_tip := local.x < 70.0
				assert_eq(Geometry2D.is_point_in_polygon(spot, tip), on_tip,
					label + ": %s is in the tip only if it is on the left arm" % local)
				assert_eq(Geometry2D.is_point_in_polygon(spot, rest_of_u), not on_tip,
					label + ": %s is in the rest of the U unless it is on the left arm's tip" % local)
			assert_almost_eq(minf(areas[0], areas[1]), 70.0 * 100.0, 70.0 * 25.0,
				label + ": the tip is the left arm above the chord")

func test_a_dumbbell_cut_across_one_bulb_leaves_the_other_bulb_whole() -> void:
	var ring := _outline_ring(DUMBBELL_OUTLINE, -0.25, Vector2(300.0, 300.0))
	var place: Callable = ring["place"]
	var points: PackedVector2Array = ring["points"]
	var a := _nearest_point(points, place.call(Vector2(0, 60)))
	var b := _nearest_point(points, place.call(Vector2(120, 60)))
	var pieces := _assert_cut_by_beads(ring, a, b, "dumbbell, chord %d-%d" % [a, b])
	if pieces.size() != 2:
		return
	var areas: Array[float] = [GooLoop.area(pieces[0]["outline"]), GooLoop.area(pieces[1]["outline"])]
	var larger: PackedVector2Array = pieces[1 if areas[0] < areas[1] else 0]["outline"]
	for local: Vector2 in [Vector2(225, 5), Vector2(335, 5), Vector2(280, 100), Vector2(170, 150), Vector2(60, 190)]:
		assert_true(Geometry2D.is_point_in_polygon(place.call(local), larger), "%s is in the larger piece" % local)
	assert_almost_eq(minf(areas[0], areas[1]), 120.0 * 60.0, 120.0 * 20.0, "the cut-off piece is the left bulb's top")

func test_a_chord_that_leaves_the_outline_is_not_cut() -> void:
	# Beads on the two arms' inner faces: the chord between them runs across the
	# gap of the U, outside the outline.
	var ring := _outline_ring(U_OUTLINE, 0.0, Vector2(500.0, 400.0))
	var place: Callable = ring["place"]
	var points: PackedVector2Array = ring["points"]
	var a := _nearest_point(points, place.call(Vector2(70, 100)))
	var b := _nearest_point(points, place.call(Vector2(190, 100)))
	var shape: GooShape = ring["shape"]
	var bead_size: float = ring["tuning"]["bead_radius"]
	assert_eq(shape.cut_ring(ring["rest"], points, a, b, bead_size, 0.0).size(), 0, "a chord across the gap is refused")
	assert_true(shape.trim_ring(ring["rest"], points, a, b, bead_size).is_empty(), "and not trimmed either")

func test_trim_of_a_u_keeps_the_piece_the_cut_gives_that_side() -> void:
	var ring := _outline_ring(U_OUTLINE, 0.3, Vector2(500.0, 400.0))
	var place: Callable = ring["place"]
	var points: PackedVector2Array = ring["points"]
	var shape: GooShape = ring["shape"]
	var bead_size: float = ring["tuning"]["bead_radius"]
	var a := _nearest_point(points, place.call(Vector2(0, 100)))
	var b := _nearest_point(points, place.call(Vector2(70, 100)))
	for pair: Vector2i in [Vector2i(a, b), Vector2i(b, a)]:
		var pieces := shape.cut_ring(ring["rest"], points, pair.x, pair.y, bead_size, 0.0)
		var trimmed := shape.trim_ring(ring["rest"], points, pair.x, pair.y, bead_size)
		assert_eq(pieces.size(), 2, "the U is cut")
		assert_false(trimmed.is_empty(), "the U trims")
		if pieces.size() != 2 or trimmed.is_empty():
			continue
		var larger := 0 if GooLoop.area(pieces[0]["outline"]) >= GooLoop.area(pieces[1]["outline"]) else 1
		assert_eq(int(trimmed["side"]), larger, "the trim keeps the larger side, numbered as the cut numbers it")
		var kept: PackedVector2Array = trimmed["outline"]
		assert_almost_eq(GooShape.area_centroid(kept).distance_to(GooShape.area_centroid(pieces[larger]["outline"])), 0.0, 0.5,
			"the kept outline is that piece scaled about its centroid")
		assert_almost_eq(GooLoop.area(kept), shape.area(), 0.001 * shape.area(), "at the whole area")
		assert_true(Geometry2D.is_point_in_polygon(place.call(Vector2(245, 5)), kept), "with the right arm in it")
