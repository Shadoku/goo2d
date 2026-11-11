extends TestCase
## Goo2D.find_pinch(), the neck scan a ring runs every few physics frames,
## against a plain reference: every pair of beads a quarter of the ring apart,
## in index order, as the scan was first written. The scan skips pairs that
## cannot be pressed in enough to count; on every loop here, round, squashed,
## dented, pinched into a waist or folded, with and without a rest shape and
## rest depths, it must return exactly what the reference returns. Likewise
## Goo2D.hull_depths(), which skips the hull's own corners, against measuring
## every point.

const CONSTRICTION: float = Goo2D.PINCH_CONSTRICTION

# The scan as first written: all pairs, no shortcut.
static func _reference(points: PackedVector2Array, bead_size: float, min_constriction: float,
		rest: PackedVector2Array = PackedVector2Array(), min_rest_distance: float = 0.0,
		rest_depths: PackedFloat32Array = PackedFloat32Array()) -> Dictionary:
	var count := points.size()
	var apart := maxi(count / 4, 2)
	var depths := _reference_depths(points)
	if rest_depths.size() == count:
		for i: int in count:
			depths[i] = maxf(depths[i] - rest_depths[i], 0.0)
	var best := { "a": -1, "b": -1, "gap": INF, "constriction": 0.0 }
	var best_distance := INF
	var check_rest := rest.size() == count
	for i: int in count:
		for j: int in range(i + apart, count):
			if count - (j - i) < apart:
				break
			if check_rest and rest[i].distance_to(rest[j]) < min_rest_distance:
				continue
			var distance := points[i].distance_to(points[j])
			if distance >= best_distance:
				continue
			var pressed := depths[i] + depths[j]
			var constriction := pressed / maxf(distance + pressed, 0.001)
			if constriction < min_constriction:
				continue
			if not Geometry2D.is_point_in_polygon((points[i] + points[j]) * 0.5, points):
				continue
			best_distance = distance
			best = { "a": i, "b": j, "gap": distance - 2.0 * bead_size, "constriction": constriction }
	return best

# hull_depths() as first written: every point measured against every edge.
static func _reference_depths(points: PackedVector2Array) -> PackedFloat32Array:
	var depths := PackedFloat32Array()
	depths.resize(points.size())
	var hull := Geometry2D.convex_hull(points)
	var corners := hull.size()
	if corners < 3:
		return depths
	for i: int in points.size():
		var nearest := INF
		for k: int in corners:
			var on_edge := Geometry2D.get_closest_point_to_segment(points[i], hull[k], hull[(k + 1) % corners])
			nearest = minf(nearest, points[i].distance_squared_to(on_edge))
		depths[i] = sqrt(nearest)
	return depths

# A ring of `count` beads of radius `radius` around `centre`, squashed to
# `squash` of its height, with `dents` (Vector3(angle, depth as a fraction of
# the radius, width in radians)) pushed in and `noise` px of jitter.
static func _ring(rng: RandomNumberGenerator, count: int, radius: float, squash: float,
		dents: Array[Vector3], noise: float) -> PackedVector2Array:
	var points := PackedVector2Array()
	for i: int in count:
		var angle := -TAU * i / count
		var r := radius
		for dent: Vector3 in dents:
			var off := absf(wrapf(angle - dent.x, -PI, PI))
			if off < dent.z:
				r -= radius * dent.y * (0.5 + 0.5 * cos(PI * off / dent.z))
		var point := Vector2(cos(angle) * r, sin(angle) * r * squash)
		points.append(Vector2(400.0, 600.0) + point + Vector2(rng.randf_range(-noise, noise), rng.randf_range(-noise, noise)))
	return points

func _assert_same(points: PackedVector2Array, bead_size: float, what: String,
		rest: PackedVector2Array = PackedVector2Array(), min_rest: float = 0.0,
		rest_depths: PackedFloat32Array = PackedFloat32Array()) -> bool:
	assert_eq(Goo2D.hull_depths(points), _reference_depths(points), what + ": hull depths")
	var got := Goo2D.find_pinch(points, bead_size, CONSTRICTION, rest, min_rest, rest_depths)
	var want := _reference(points, bead_size, CONSTRICTION, rest, min_rest, rest_depths)
	assert_eq(got, want, what)
	return int(want["a"]) >= 0

func test_matches_the_full_scan_on_many_loops() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261015
	var necks := 0
	var cases := 0
	for count: int in [12, 16, 23, 32, 40, 60]:
		for k: int in 40:
			var radius := rng.randf_range(20.0, 120.0)
			var dents: Array[Vector3] = []
			for _d: int in rng.randi_range(0, 3):
				dents.append(Vector3(rng.randf_range(-PI, PI), rng.randf_range(0.0, 1.6), rng.randf_range(0.2, 1.4)))
			if k % 4 == 0:
				# A waist: two opposite dents, deep enough to meet.
				var at := rng.randf_range(-PI, PI)
				var depth := rng.randf_range(0.5, 1.0)
				dents = [Vector3(at, depth, 1.0), Vector3(at + PI, depth, 1.0)] as Array[Vector3]
			var squash := rng.randf_range(0.3, 1.0)
			var noise := rng.randf_range(0.0, 3.0) if k % 3 != 0 else 0.0
			var points := _ring(rng, count, radius, squash, dents, noise)
			var bead := radius * rng.randf_range(0.05, 0.2)
			if _assert_same(points, bead, "%d beads, case %d" % [count, k]):
				necks += 1
			cases += 1
	print("    %d loops, %d with a neck" % [cases, necks])
	assert_gt(necks, 20, "the loops should include plenty of necks")
	assert_lt(necks, cases - 20, "and plenty without")

func test_matches_the_full_scan_with_a_rest_shape() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var square := GooShape.regular(4, 40.0)
	var ring_tuning := GooTuning.tuning_for(square)
	var rest := square.bead_loop(ring_tuning["bead_count"], ring_tuning["bead_radius"])
	var count := rest.size()
	var rest_depths := _reference_depths(rest)
	var min_rest := 2.0 * float(ring_tuning["ring_radius"]) * sin(PI * maxi(count / 4, 2) / count)
	for k: int in 60:
		var dents: Array[Vector3] = []
		var at := rng.randf_range(-PI, PI)
		dents.append(Vector3(at, rng.randf_range(0.0, 1.2), rng.randf_range(0.3, 1.2)))
		if k % 2 == 0:
			dents.append(Vector3(at + PI, rng.randf_range(0.0, 1.2), rng.randf_range(0.3, 1.2)))
		var points := _ring(rng, count, 40.0, rng.randf_range(0.4, 1.0), dents, rng.randf_range(0.0, 2.0))
		var bead: float = ring_tuning["bead_radius"]
		_assert_same(points, bead, "square, case %d" % k, rest, min_rest)
		_assert_same(points, bead, "square with rest depths, case %d" % k, PackedVector2Array(), 0.0, rest_depths)

func test_matches_the_full_scan_on_flat_and_degenerate_loops() -> void:
	var line := PackedVector2Array()
	for i: int in 16:
		line.append(Vector2(i * 3.0, 0.0))
	_assert_same(line, 2.0, "beads on a line")
	var same := PackedVector2Array()
	same.resize(16)
	same.fill(Vector2(5.0, 5.0))
	_assert_same(same, 2.0, "every bead in one place")
	var rng := RandomNumberGenerator.new()
	rng.seed = 3
	var flat := _ring(rng, 24, 50.0, 0.02, [] as Array[Vector3], 0.0)
	_assert_same(flat, 4.0, "a ring squashed flat")
	var folded := _ring(rng, 24, 50.0, 1.0, [] as Array[Vector3], 0.0)
	for i: int in [22, 23, 0, 1]:
		folded[i] = Vector2(400.0, 600.0) - (folded[i] - Vector2(400.0, 600.0)) * 1.3
	_assert_same(folded, 4.0, "a ring folded through itself")
