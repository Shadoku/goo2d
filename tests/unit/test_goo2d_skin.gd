extends TestCase
## Unit tests for the skin polygons Goo2D builds from its beads
## (Goo2D.skin_pieces(), Goo2D.skin_offset()): at rest one polygon, the bead
## loop pushed out one bead radius and smoothed, unchanged by the kink clamp; a
## ring sharply notched or crushed still gets a polygon Polygon2D can draw
## (Geometry2D.triangulate_polygon() accepts it, where a self-intersecting one
## draws nothing at all); a ring folded through itself gets one polygon per
## loop of the fold, so every bead is drawn (the inverted lobe too); a
## degenerate loop never gets a polygon Polygon2D would drop (empty instead:
## the body keeps its previous skin). And the corner flags: a round ring of 12
## beads, which turns exactly CORNER_ANGLE at each, has none.

const CENTRE: Vector2 = Vector2(300.0, 300.0)

## A ring crushed in a pile on the wedge (stability.gd impale_pile, a 15 px
## piece at 104% of its target area): beads 0 and 1 are the floor of a slot two
## beads deep and 1.5 bead radii wide. Its unclamped skin did not triangulate.
const CRUSHED_BEAD_RADIUS: float = 3.60509729687567
const CRUSHED: PackedVector2Array = [
	Vector2(681.96606, 848.4465), Vector2(676.6991, 849.83704), Vector2(674.9478, 844.3505),
	Vector2(670.1119, 846.3146), Vector2(670.3651, 851.29315), Vector2(670.6065, 856.22003),
	Vector2(675.4398, 858.0508), Vector2(679.3799, 854.9852), Vector2(683.8622, 856.4266),
	Vector2(688.4101, 857.8498), Vector2(692.4426, 853.9098), Vector2(691.0869, 848.38855),
	Vector2(688.10474, 843.97296), Vector2(685.85205, 839.25586), Vector2(680.3205, 839.09924),
	Vector2(680.6642, 843.6374),
]

# The rest bead loop of a round body of `radius` around CENTRE.
static func _ring(radius: float) -> PackedVector2Array:
	return GooLoop.circle_points(CENTRE, GooTuning.ring_radius(radius), GooTuning.bead_count(radius))

func _assert_drawable(pieces: Array[PackedVector2Array], what: String) -> void:
	assert_false(pieces.is_empty(), "%s: the skin should have a polygon" % what)
	for k: int in pieces.size():
		var skin := pieces[k]
		assert_true(skin.size() >= 3, "%s: polygon %d should have points, got %d" % [what, k, skin.size()])
		assert_false(Geometry2D.triangulate_polygon(skin).is_empty(),
			"%s: polygon %d should triangulate (Polygon2D draws nothing otherwise)" % [what, k])
		assert_true(GooLoop.is_ccw(skin), "%s: polygon %d should run CCW like the beads" % [what, k])

# How far the farthest of `points` outside every one of `pieces` lies from the
# nearest of them (0 if each is inside one).
static func outside(points: PackedVector2Array, pieces: Array[PackedVector2Array]) -> float:
	var worst := 0.0
	for point: Vector2 in points:
		var nearest := INF
		for piece: PackedVector2Array in pieces:
			if Geometry2D.is_point_in_polygon(point, piece):
				nearest = 0.0
				break
			for i: int in piece.size():
				var q := Geometry2D.get_closest_point_to_segment(point, piece[i], piece[(i + 1) % piece.size()])
				nearest = minf(nearest, point.distance_to(q))
		worst = maxf(worst, nearest)
	return worst

# Every bead of `loop` is drawn: inside one of the skin's polygons, or within
# half a bead radius of one (the kink clamp pulls the skin in over a bead).
func _assert_covers(pieces: Array[PackedVector2Array], loop: PackedVector2Array, bead: float, what: String) -> void:
	var worst := outside(loop, pieces)
	assert_lt(worst, 0.5 * bead, "%s: every bead should be drawn (one is %.1f px outside the skin)" % [what, worst])

func test_rest_ring_skin_is_the_full_offset_smoothed() -> void:
	var radius := GooTuning.radius_at(0.3)
	var bead := GooTuning.bead_radius(radius)
	var ring := _ring(radius)
	var raw := Goo2D.skin_offset(ring, bead)
	assert_eq(raw.size(), ring.size())
	for i: int in ring.size():
		assert_almost_eq(raw[i].distance_to(ring[i]), bead, 0.0001, "bead %d is pushed out one bead radius" % i)
		assert_gt((raw[i] - ring[i]).dot(ring[i] - CENTRE), 0.0, "bead %d is pushed outward" % i)
	var skin := Goo2D.skin_pieces(ring, bead, PackedByteArray())
	assert_eq(skin.size(), 1, "a calm ring's skin is one polygon")
	assert_eq(skin[0], GooLoop.chaikin(raw, Goo2D.SKIN_SMOOTHING), "a calm ring's skin is the smoothed offset")
	_assert_drawable(skin, "a ring at rest")

func test_rest_square_skin_keeps_the_full_offset_at_its_corners() -> void:
	var shape := GooShape.regular(4, GooTuning.radius_at(0.3))
	var tuning := GooTuning.tuning_for(shape)
	var bead: float = tuning["bead_radius"]
	var rest := shape.bead_loop(tuning["bead_count"], bead)
	var flags := Goo2D.find_corners(rest)
	assert_eq(flags.count(1), 4, "the square's four corners are flagged")
	var raw := Goo2D.skin_offset(rest, bead)
	for i: int in rest.size():
		assert_almost_eq(raw[i].distance_to(rest[i]), bead, 0.0001, "bead %d is pushed out one bead radius" % i)
	var skin := Goo2D.skin_pieces(rest, bead, flags)
	assert_eq(skin.size(), 1, "a square's skin is one polygon")
	assert_eq(skin[0], GooLoop.chaikin_keeping(raw, Goo2D.SKIN_SMOOTHING, flags), "the corners stay sharp")
	_assert_drawable(skin, "a square at rest")

func test_folded_ring_is_drawn_as_one_polygon_per_loop() -> void:
	var radius := GooTuning.radius_at(0.3)
	var bead := GooTuning.bead_radius(radius)
	var ring := _ring(radius)
	var rest_area := GooLoop.area(Goo2D.skin_pieces(ring, bead, PackedByteArray())[0])
	var count := ring.size()
	# Three consecutive beads pushed through the ring, past its opposite side.
	var folded := ring.duplicate()
	for i: int in [count - 1, 0, 1]:
		folded[i] = CENTRE - (ring[i] - CENTRE) * 1.3
	assert_true(GooLoop.self_intersects(folded), "precondition: the bead loop crosses itself")
	var skin := Goo2D.skin_pieces(folded, bead, PackedByteArray())
	_assert_drawable(skin, "a ring folded through itself")
	assert_gt(skin.size(), 1, "the fold's loops are drawn as polygons of their own")
	_assert_covers(skin, folded, bead, "a ring folded through itself")
	var covered := 0.0
	for piece: PackedVector2Array in skin:
		covered += GooLoop.area(piece)
	assert_gt(covered, 0.5 * rest_area, "the skin still covers most of the body")

## A 12-bead ring of 30 px crushed in a packed column (stability.gd skin, at
## 82% and 62% of its area): folded through itself for four seconds, drawn with
## 8 of its 12 beads outside the skin while the repair kept only the largest
## simple boundary of the fold.
const COLUMN_BEAD_RADIUS: float = 9.42477796076938
const COLUMN_FOLDS: Array[PackedVector2Array] = [
	[Vector2(990.4226, 149.7467), Vector2(1004.126, 150.7272), Vector2(1016.003, 154.6305),
		Vector2(1019.575, 165.3259), Vector2(1013.269, 175.0497), Vector2(1000.399, 176.9948),
		Vector2(996.3597, 170.1896), Vector2(970.8737, 163.4728), Vector2(968.6765, 157.3594),
		Vector2(964.194, 169.2788), Vector2(974.8774, 179.1436), Vector2(988.0374, 155.6808)],
	[Vector2(985.8869, 142.6079), Vector2(989.5919, 129.4645), Vector2(982.0833, 136.9383),
		Vector2(990.9307, 147.9387), Vector2(994.6713, 160.741), Vector2(982.4225, 165.2845),
		Vector2(972.9172, 155.4574), Vector2(959.5723, 151.0867), Vector2(951.8459, 162.3403),
		Vector2(963.0326, 163.6382), Vector2(972.3816, 158.5521), Vector2(979.9824, 150.4324)],
]

func test_ring_folded_in_a_column_is_drawn_whole() -> void:
	for k: int in COLUMN_FOLDS.size():
		var loop := COLUMN_FOLDS[k]
		var what := "column fold %d" % k
		assert_true(GooLoop.self_intersects(loop), what + ": precondition: the bead loop crosses itself")
		var skin := Goo2D.skin_pieces(loop, COLUMN_BEAD_RADIUS, PackedByteArray())
		_assert_drawable(skin, what)
		assert_gt(skin.size(), 1, what + ": the fold's loops are drawn as polygons of their own")
		_assert_covers(skin, loop, COLUMN_BEAD_RADIUS, what)

func test_sharp_notch_skin_triangulates_without_crossing() -> void:
	var radius := GooTuning.MIN_RADIUS
	var bead := GooTuning.bead_radius(radius)
	var ring := _ring(radius)
	var count := ring.size()
	# A slot into the ring's right side (bead 0 is its rightmost), 1.6 bead
	# radii wide and two beads deep: rim, wall, floor, floor, wall, rim.
	var half := 0.8 * bead
	var step := 1.2 * bead
	var rim_x := sqrt(ring[0].distance_squared_to(CENTRE) - half * half)
	var notched := ring.duplicate()
	notched[count - 2] = CENTRE + Vector2(rim_x, half)
	notched[count - 1] = CENTRE + Vector2(rim_x - step, half)
	notched[0] = CENTRE + Vector2(rim_x - 2.0 * step, half)
	notched[1] = CENTRE + Vector2(rim_x - 2.0 * step, -half)
	notched[2] = CENTRE + Vector2(rim_x - step, -half)
	notched[3] = CENTRE + Vector2(rim_x, -half)
	assert_false(GooLoop.self_intersects(notched), "precondition: the bead loop itself is simple")
	var raw := Goo2D.skin_offset(notched, bead)
	assert_false(GooLoop.self_intersects(raw), "the offsets in the slot must not cross")
	var far := count / 2
	assert_almost_eq(raw[far].distance_to(notched[far]), bead, 0.0001, "away from the notch the offset is full")
	var skin := Goo2D.skin_pieces(notched, bead, PackedByteArray())
	assert_eq(skin.size(), 1, "a notched ring's skin is one polygon")
	_assert_drawable(skin, "a sharply notched ring")

func test_ring_crushed_in_a_pile_skin_triangulates() -> void:
	assert_false(GooLoop.self_intersects(CRUSHED), "precondition: the bead loop itself is simple")
	var raw := Goo2D.skin_offset(CRUSHED, CRUSHED_BEAD_RADIUS)
	assert_false(GooLoop.self_intersects(raw), "the offsets in the slot must not cross")
	var flags := PackedByteArray()
	flags.resize(CRUSHED.size())
	var skin := Goo2D.skin_pieces(CRUSHED, CRUSHED_BEAD_RADIUS, flags)
	assert_eq(skin.size(), 1, "a crushed ring's skin is one polygon")
	_assert_drawable(skin, "a ring crushed in a pile")

func test_degenerate_loops_never_get_an_undrawable_skin() -> void:
	var collapsed := PackedVector2Array()
	collapsed.resize(16)
	collapsed.fill(CENTRE)
	var flattened := PackedVector2Array()
	for i: int in 8:
		flattened.append(CENTRE + Vector2(5.0 * i, 0.0))
	for i: int in 8:
		flattened.append(CENTRE + Vector2(5.0 * (7 - i), 0.0))
	for loop: PackedVector2Array in [collapsed, flattened]:
		var skin := Goo2D.skin_pieces(loop, 4.0, PackedByteArray())
		# Empty means nothing to draw: the body keeps its previous skin.
		for piece: PackedVector2Array in skin:
			assert_false(Geometry2D.triangulate_polygon(piece).is_empty(),
				"a degenerate loop's skin is drawable or empty, never one Polygon2D drops")

func test_round_rings_have_no_corners_but_a_square_has_four() -> void:
	for radius: float in [18.0, GooTuning.MIN_RADIUS, 30.0, 36.0, GooTuning.MAX_RADIUS]:
		var ring := _ring(radius)
		var flags := Goo2D.find_corners(ring)
		assert_eq(flags.count(1), 0, "a round ring of %d beads (radius %.0f) has no corner" % [ring.size(), radius])
	var square := GooShape.regular(4, GooTuning.radius_at(0.3))
	var tuning := GooTuning.tuning_for(square)
	assert_eq(Goo2D.find_corners(square.bead_loop(tuning["bead_count"], tuning["bead_radius"])).count(1), 4)
