extends TestCase
## The arena scene's collision shapes line up with the constants Game and
## Dropper read from Arena, and its wedge is the triangle Arena describes.

func test_shapes_match_constants() -> void:
	var arena := (load("res://scenes/arena.tscn") as PackedScene).instantiate() as Arena
	add_child(arena)
	assert_eq(arena.collision_layer, 1)
	assert_eq(arena.collision_mask, 0)
	assert_eq(arena.inner_right() - arena.inner_left(), Arena.INNER_WIDTH)
	var floor_top := INF
	var left_face := -INF
	var right_face := INF
	for node: Node in arena.get_children():
		var shape := node as CollisionShape2D
		if shape == null or shape.name == "Wedge":
			continue
		var rect := (shape.shape as RectangleShape2D).get_rect()
		var box := Rect2(shape.position + rect.position, rect.size)
		if box.size.x > box.size.y:
			floor_top = box.position.y
		elif box.get_center().x < arena.inner_left() + Arena.INNER_WIDTH / 2.0:
			left_face = box.end.x
		else:
			right_face = box.position.x
	assert_almost_eq(floor_top, arena.floor_y(), 0.01, "floor top")
	assert_almost_eq(left_face, arena.inner_left(), 0.01, "left wall face")
	assert_almost_eq(right_face, arena.inner_right(), 0.01, "right wall face")
	assert_lt(Arena.LAUNCH_POINT.y, Arena.FLOOR_Y)

func test_wedge_matches_constants() -> void:
	var arena := (load("res://scenes/arena.tscn") as PackedScene).instantiate() as Arena
	add_child(arena)
	arena.position = Vector2(10.0, 20.0)
	var wedge := arena.get_node_or_null("Wedge") as CollisionShape2D
	assert_not_null(wedge, "the arena has a Wedge collision shape")
	if wedge == null:
		return
	var polygon := wedge.shape as ConvexPolygonShape2D
	assert_not_null(polygon, "the wedge is a ConvexPolygonShape2D")
	if polygon == null:
		return
	assert_eq(polygon.points.size(), 3, "the wedge is a triangle")
	var expected: Array[Vector2] = [
		Vector2(Arena.WEDGE_X - Arena.WEDGE_HALF_WIDTH, Arena.FLOOR_Y),
		Vector2(Arena.WEDGE_X + Arena.WEDGE_HALF_WIDTH, Arena.FLOOR_Y),
		Vector2(Arena.WEDGE_X, Arena.FLOOR_Y - Arena.WEDGE_HEIGHT),
	]
	for corner: Vector2 in expected:
		var found := false
		for point: Vector2 in polygon.points:
			if (wedge.position + point).distance_to(corner) < 0.01:
				found = true
		assert_true(found, "wedge corner %s" % corner)
	assert_almost_eq(arena.wedge_apex().x, arena.global_position.x + Arena.WEDGE_X, 0.01, "apex x")
	assert_almost_eq(arena.wedge_apex().y, arena.global_position.y + Arena.FLOOR_Y - Arena.WEDGE_HEIGHT, 0.01, "apex y")
	assert_gt(Arena.WEDGE_X - Arena.WEDGE_HALF_WIDTH, (Arena.INNER_LEFT + Arena.INNER_RIGHT) / 2.0 + 100.0,
		"the wedge stays clear of the arena centre")
	assert_lt(Arena.WEDGE_X + Arena.WEDGE_HALF_WIDTH, Arena.INNER_RIGHT, "the wedge stands inside the walls")
	var visual := arena.get_node_or_null("WedgeVisual") as Polygon2D
	assert_not_null(visual, "the wedge is drawn")
	if visual != null:
		assert_eq(visual.polygon.size(), 3)
		assert_eq(visual.color, Color(0.32, 0.29, 0.38, 1.0))

func test_launch_point_is_upper_right_and_clear() -> void:
	var middle := (Arena.INNER_LEFT + Arena.INNER_RIGHT) / 2.0
	assert_gt(Arena.LAUNCH_POINT.x, middle, "blobs launch from the right half")
	assert_lt(Arena.LAUNCH_POINT.x + DropController.DROP_MAX_RADIUS, Arena.INNER_RIGHT,
		"the largest drop starts clear of the right wall")
	assert_almost_eq(Arena.LAUNCH_POINT.x, Arena.INNER_RIGHT - Arena.LAUNCH_INSET, 0.01)
	assert_almost_eq(Arena.LAUNCH_POINT.y, Arena.DROP_Y, 0.01)
	assert_lt(Arena.WEDGE_X + Arena.WEDGE_HALF_WIDTH, Arena.LAUNCH_POINT.x - DropController.DROP_MAX_RADIUS,
		"a straight drop from the launch point misses the wedge")

func test_arena_fits_a_16_by_9_viewport() -> void:
	# The demo's canvas: the main scene's own (the project's is the game's).
	var layout: Vector2i = (load("res://src/main.gd") as Script).get_script_constant_map()["LAYOUT_SIZE"]
	var width := layout.x
	var height := layout.y
	assert_eq(width, 1920)
	assert_eq(height, 1080)
	var arena := (load("res://scenes/arena.tscn") as PackedScene).instantiate() as Arena
	add_child(arena)
	var bounds := Rect2()
	var first := true
	for node: Node in arena.get_children():
		var visual := node as Polygon2D
		if visual == null:
			continue
		for point: Vector2 in visual.polygon:
			if first:
				bounds = Rect2(point, Vector2.ZERO)
				first = false
			else:
				bounds = bounds.expand(point)
	assert_false(first, "the arena is drawn")
	assert_true(Rect2(0.0, 0.0, width, height).encloses(bounds), "the drawn arena %s fits the viewport" % bounds)

func test_blades_stand_inside_and_clear_of_the_launch_and_the_wedge() -> void:
	var arena := (load("res://scenes/arena.tscn") as PackedScene).instantiate() as Arena
	add_child(arena)
	var blades := arena.blades()
	assert_eq(blades.size(), 2, "the arena has two blades")
	for blade: Blade in blades:
		var tip := blade.tip()
		assert_gt(tip.x, arena.inner_left(), "%s's tip is right of the left wall" % blade.name)
		assert_lt(tip.x, arena.inner_right(), "%s's tip is left of the right wall" % blade.name)
		assert_lt(tip.y, arena.floor_y(), "%s's tip is above the floor" % blade.name)
		assert_gt(tip.y, arena.global_position.y + Arena.WALL_TOP_Y, "%s's tip is below the walls' top" % blade.name)
		assert_almost_eq(blade.axis().length(), 1.0, 0.0001, "%s's axis is a unit vector" % blade.name)
		assert_eq(blade.collision_layer, 1)
		assert_eq(blade.collision_mask, 0)
	var floor_blade := arena.get_node_or_null("FloorBlade") as Blade
	assert_not_null(floor_blade, "the arena has a FloorBlade")
	if floor_blade != null:
		assert_almost_eq(floor_blade.global_position.y, arena.floor_y(), 0.01, "the floor blade stands on the floor")
		assert_almost_eq(floor_blade.axis().y, -1.0, 0.0001, "the floor blade points up")
		var half := floor_blade.base_width / 2.0
		assert_lt(floor_blade.position.x + half, Arena.LAUNCH_POINT.x - DropController.DROP_MAX_RADIUS,
			"a straight drop from the launch point misses the floor blade")
		assert_lt(floor_blade.position.x + half, Arena.WEDGE_X - Arena.WEDGE_HALF_WIDTH,
			"the floor blade stands clear of the wedge")
	var wall_blade := arena.get_node_or_null("WallBlade") as Blade
	assert_not_null(wall_blade, "the arena has a WallBlade")
	if wall_blade != null:
		assert_almost_eq(wall_blade.global_position.x, arena.inner_left(), 0.01, "the wall blade stands on the left wall")
		assert_almost_eq(wall_blade.axis().x, 1.0, 0.0001, "the wall blade points right")
