extends TestCase
## GooProxies' plain parts: the grown hull a Shape.HULL proxy is made of, either way round.

func test_grown_hull_covers_the_circles() -> void:
	var square := PackedVector2Array([Vector2(0, 0), Vector2(10, 0), Vector2(10, 10), Vector2(0, 10)])
	for hull: PackedVector2Array in [square, _reversed(square)]:
		var grown := GooProxies.grown_hull(hull, 2.0)
		assert_eq(grown.size(), 8)
		assert_true(Geometry2D.is_point_in_polygon(Vector2(-1.9, 5), grown), "the side grown by 2")
		assert_false(Geometry2D.is_point_in_polygon(Vector2(-2.1, 5), grown))
		assert_true(Geometry2D.is_point_in_polygon(Vector2(11.5, 10.4), grown))
		assert_true(Geometry2D.is_point_in_polygon(Vector2(5, 5), grown))
		# The corner is cut: within by × (1 − cos 45°) of the round join.
		var corner := Vector2(10, 10) + Vector2(1, 1).normalized() * 2.0 * cos(PI / 4) * 0.99
		assert_true(Geometry2D.is_point_in_polygon(corner, grown))

func _reversed(points: PackedVector2Array) -> PackedVector2Array:
	var out := points.duplicate()
	out.reverse()
	return out
