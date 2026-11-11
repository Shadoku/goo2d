extends TestCase
## Unit tests for GooStatics reading TileMapLayers (docs/loose-ends-plan.md's
## D1), on a 4 × 4 layer of 16 px tiles built here with a two-cell wall: the
## kernel holds one convex polygon of the wall's outline, at the layer's place,
## with its TileSet physics layer's friction and bounce, gripping; the layer's
## own material (GooStatics.MATERIAL_META) and NO_GRIP_GROUP win; a physics
## layer without the wall bit, or a layer with collision_enabled off, gives
## nothing; the mirror follows the layer as it moves (the same shape moved, no
## rebuild), as its cells change (the outline grows, then goes), as its
## collision is turned on, and as it leaves the tree; GooStatics.CLIP_META
## leaves out the cells wholly outside it; a layer that does not change is not
## rebuilt frame after frame. And the merge itself (bake_cells() and its
## parts, once the game's TileCollisionBaker), on squares and small layers: a
## block of touching squares merges into one rectangle; a ring of squares
## around an empty cell is one outline with its hole filled (a warning); an L
## splits into two convex pieces; a layer's cell polygons sit at the cells'
## centres, flipped as the cell says; a clip leaves out the cells wholly
## outside it and keeps the ones crossing it whole.

const TILE: float = 16.0
## Where the layer stands, so its space is not the global one.
const AT := Vector2(100.0, 50.0)

var kernel: GooKernel
var statics: GooStatics

func before_each() -> void:
	GooTuning.unit = 1.0
	kernel = GooTuning.make_kernel()
	statics = GooStatics.new(kernel)

func after_each() -> void:
	statics.detach()

# A 4 × 4 layer of 16 px tiles at AT, in the tree, whose one tile is a full
# square on a physics layer of collision layer `bits` and material
# `material`, its cells (1, 1) and (2, 1) set: a wall two cells wide.
func _layer(bits: int = GooTuning.LAYER_WALLS, material: PhysicsMaterial = null) -> TileMapLayer:
	var tile_set := TileSet.new()
	tile_set.tile_size = Vector2i(16, 16)
	tile_set.add_physics_layer()
	tile_set.set_physics_layer_collision_layer(0, bits)
	tile_set.set_physics_layer_physics_material(0, material)
	var source := TileSetAtlasSource.new()
	source.texture = ImageTexture.create_from_image(Image.create(16, 16, false, Image.FORMAT_RGBA8))
	source.texture_region_size = Vector2i(16, 16)
	source.create_tile(Vector2i.ZERO)
	tile_set.add_source(source, 0)
	var data := source.get_tile_data(Vector2i.ZERO, 0)
	data.add_collision_polygon(0)
	data.set_collision_polygon_points(0, 0, PackedVector2Array([Vector2(-8, -8), Vector2(8, -8), Vector2(8, 8), Vector2(-8, 8)]))
	var layer := TileMapLayer.new()
	layer.tile_set = tile_set
	layer.position = AT
	layer.set_cell(Vector2i(1, 1), 0, Vector2i.ZERO)
	layer.set_cell(Vector2i(2, 1), 0, Vector2i.ZERO)
	add_child(layer)
	return layer

func _material(friction: float, bounce: float) -> PhysicsMaterial:
	var material := PhysicsMaterial.new()
	material.friction = friction
	material.bounce = bounce
	return material

# The kernel's static shapes once the mirror is brought up to date, in the
# order added: GooKernel.static_shape_info() plus "id".
func _shapes() -> Array[Dictionary]:
	statics.attach(get_tree())
	statics.sync()
	var result: Array[Dictionary] = []
	for id: int in kernel.static_shape_ids():
		var info: Dictionary = kernel.static_shape_info(id)
		info["id"] = id
		result.append(info)
	return result

func _box(points: PackedVector2Array) -> Rect2:
	var box := Rect2(points[0], Vector2.ZERO)
	for point: Vector2 in points:
		box = box.expand(point)
	return box

func test_a_two_cell_wall_is_one_convex_polygon() -> void:
	_layer(GooTuning.LAYER_WALLS, _material(0.2, 0.4))
	var shapes := _shapes()
	assert_eq(shapes.size(), 1, "one shape for the two cells")
	if shapes.size() != 1:
		return
	var points: PackedVector2Array = shapes[0]["points"]
	print("    the wall's polygon %s" % [points])
	assert_eq(points.size(), 4, "a rectangle")
	assert_true(GooStatics.is_convex(points), "convex")
	assert_eq(_box(points), Rect2(AT + Vector2(TILE, TILE), Vector2(2.0 * TILE, TILE)),
		"the two cells' outline, at the layer's place")
	assert_almost_eq(absf(GooStatics.signed_area(points)), 2.0 * TILE * TILE, 0.01, "of two cells' area")
	assert_almost_eq(shapes[0]["friction"], 0.2, 0.0001, "the physics layer's friction")
	assert_almost_eq(shapes[0]["bounce"], 0.4, 0.0001, "and bounce")
	assert_true(shapes[0]["grip"], "gripping, as a body outside NO_GRIP_GROUP")

func test_godot_defaults_without_a_material() -> void:
	_layer()
	var shapes := _shapes()
	assert_eq(shapes.size(), 1, "one shape")
	if shapes.size() == 1:
		assert_almost_eq(shapes[0]["friction"], 1.0, 0.0001, "Godot's friction")
		assert_almost_eq(shapes[0]["bounce"], 0.0, 0.0001, "and bounce")

func test_the_layer_material_and_group_win() -> void:
	var layer := _layer(GooTuning.LAYER_WALLS, _material(0.2, 0.4))
	layer.set_meta(GooStatics.MATERIAL_META, _material(0.1, 0.3))
	layer.add_to_group(GooTuning.NO_GRIP_GROUP)
	var shapes := _shapes()
	assert_eq(shapes.size(), 1, "one shape")
	if shapes.size() == 1:
		assert_almost_eq(shapes[0]["friction"], 0.1, 0.0001, "the layer's friction")
		assert_almost_eq(shapes[0]["bounce"], 0.3, 0.0001, "and bounce")
		assert_false(shapes[0]["grip"], "in NO_GRIP_GROUP: no grip")

func test_no_wall_bit_mirrors_nothing() -> void:
	_layer(2)
	assert_eq(_shapes().size(), 0, "a physics layer off the goo's wall layer is not the goo's")

func test_collision_off_mirrors_nothing_until_turned_on() -> void:
	var layer := _layer()
	layer.collision_enabled = false
	assert_eq(_shapes().size(), 0, "collision_enabled off: nothing")
	layer.collision_enabled = true
	await get_tree().process_frame
	assert_eq(_shapes().size(), 1, "turned on: the wall, without a refresh()")

func test_follows_the_layer_moving() -> void:
	var layer := _layer()
	var before := _shapes()
	layer.position += Vector2(30.0, -10.0)
	var after := _shapes()
	assert_eq(after.size(), 1, "one shape")
	if before.size() != 1 or after.size() != 1:
		return
	assert_eq(after[0]["id"], before[0]["id"], "the same shape, moved (no rebuild)")
	assert_eq(_box(after[0]["points"]), Rect2(AT + Vector2(30.0, -10.0) + Vector2(TILE, TILE), Vector2(2.0 * TILE, TILE)),
		"where the layer went")

func test_follows_the_cells() -> void:
	var layer := _layer()
	assert_eq(_shapes().size(), 1, "the wall")
	layer.set_cell(Vector2i(3, 1), 0, Vector2i.ZERO)
	await get_tree().process_frame
	var grown := _shapes()
	assert_eq(grown.size(), 1, "still one shape")
	if grown.size() == 1:
		assert_eq(_box(grown[0]["points"]), Rect2(AT + Vector2(TILE, TILE), Vector2(3.0 * TILE, TILE)),
			"three cells wide: the layer's `changed` followed")
	layer.clear()
	await get_tree().process_frame
	assert_eq(_shapes().size(), 0, "no cell: no wall")

func test_follows_the_layer_leaving() -> void:
	var layer := _layer()
	assert_eq(_shapes().size(), 1, "the wall")
	remove_child(layer)
	autofree(layer)
	assert_eq(_shapes().size(), 0, "out of the tree: gone")
	add_child(layer)
	assert_eq(_shapes().size(), 1, "back")

func test_the_clip_leaves_out_cells_outside_it() -> void:
	var layer := _layer()
	# In the layer's space: crossing cell (1, 1) (x 16..32), short of (2, 1).
	layer.set_meta(GooStatics.CLIP_META, Rect2(0.0, 0.0, 24.0, 64.0))
	var shapes := _shapes()
	assert_eq(shapes.size(), 1, "one shape")
	if shapes.size() == 1:
		assert_eq(_box(shapes[0]["points"]), Rect2(AT + Vector2(TILE, TILE), Vector2(TILE, TILE)),
			"only the cell the clip crosses, whole")
	layer.set_meta(GooStatics.CLIP_META, Rect2(200.0, 0.0, 10.0, 10.0))
	statics.refresh()
	assert_eq(_shapes().size(), 0, "a clip around nothing: no wall (after refresh())")

func test_a_layer_left_alone_is_not_rebuilt() -> void:
	_layer()
	# The layer's first update after entering the tree emits `changed` once.
	await get_tree().process_frame
	var first := _shapes()
	for frame: int in 5:
		await get_tree().process_frame
		await get_tree().physics_frame
	var later := _shapes()
	assert_eq(later.size(), first.size(), "the same shapes")
	if later.size() == 1 and first.size() == 1:
		assert_eq(later[0]["id"], first[0]["id"], "kept, not rebuilt every frame")

func test_bodies_and_layers_together() -> void:
	_layer()
	var body := StaticBody2D.new()
	body.collision_layer = GooTuning.LAYER_WALLS
	var shape := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = Vector2(10.0, 10.0)
	shape.shape = rect
	body.add_child(shape)
	add_child(body)
	assert_eq(_shapes().size(), 2, "the layer's wall and the body's rectangle")
	body.free()
	assert_eq(_shapes().size(), 1, "the body gone, the wall kept")

# The square of cell (x, y), clockwise on screen as the map's tiles are.
func _square(x: int, y: int) -> PackedVector2Array:
	var at := Vector2(x, y) * TILE
	return PackedVector2Array([at, at + Vector2(0.0, TILE), at + Vector2(TILE, TILE), at + Vector2(TILE, 0.0)])

func _area(pieces: Array[PackedVector2Array]) -> float:
	var total := 0.0
	for piece: PackedVector2Array in pieces:
		total += absf(GooStatics.signed_area(piece))
	return total

# A layer of 16 px tiles, not in the tree, whose one tile has `points` as its
# collision polygon.
func _bare_layer(points: PackedVector2Array) -> TileMapLayer:
	var tile_set := TileSet.new()
	tile_set.tile_size = Vector2i(16, 16)
	tile_set.add_physics_layer()
	var source := TileSetAtlasSource.new()
	source.texture = ImageTexture.create_from_image(Image.create(16, 16, false, Image.FORMAT_RGBA8))
	source.texture_region_size = Vector2i(16, 16)
	source.create_tile(Vector2i.ZERO)
	tile_set.add_source(source, 0)
	var data := source.get_tile_data(Vector2i.ZERO, 0)
	data.add_collision_polygon(0)
	data.set_collision_polygon_points(0, 0, points)
	var layer := TileMapLayer.new()
	layer.tile_set = tile_set
	return autofree(layer) as TileMapLayer

func test_a_block_of_squares_is_one_rectangle() -> void:
	var squares: Array[PackedVector2Array] = []
	for y: int in 30:
		for x: int in 2:
			squares.append(_square(x, y))
	var pieces := GooStatics.convex_pieces(squares)
	assert_eq(pieces.size(), 1, "one piece")
	if pieces.size() == 1:
		assert_eq(pieces[0].size(), 4, "a rectangle")
		assert_almost_eq(_area(pieces), 2.0 * 30.0 * TILE * TILE, 0.01, "of the squares' area")

func test_a_ring_is_filled_with_a_warning() -> void:
	allow_errors = true
	var squares: Array[PackedVector2Array] = []
	for y: int in 3:
		for x: int in 3:
			if x != 1 or y != 1:
				squares.append(_square(x, y))
	var outlines := GooStatics.merge(squares, "ring")
	assert_eq(outlines.size(), 1, "one outline")
	for outline: PackedVector2Array in outlines:
		assert_false(Geometry2D.is_polygon_clockwise(outline), "counter-clockwise")
	assert_almost_eq(_area(GooStatics.convex_pieces(squares, "ring")), 9.0 * TILE * TILE, 0.01,
		"the hole filled in")

func test_an_l_splits_into_two_convex_pieces() -> void:
	var squares: Array[PackedVector2Array] = [_square(0, 0), _square(0, 1), _square(0, 2), _square(1, 2), _square(2, 2)]
	var pieces := GooStatics.convex_pieces(squares)
	assert_eq(pieces.size(), 2, "two pieces")
	for piece: PackedVector2Array in pieces:
		assert_true(GooStatics.is_convex(piece), "convex: %s" % [piece])
	assert_almost_eq(_area(pieces), 5.0 * TILE * TILE, 0.01, "of the squares' area")

func test_apart_squares_stay_apart() -> void:
	var squares: Array[PackedVector2Array] = [_square(0, 0), _square(2, 0), _square(0, 2)]
	assert_eq(GooStatics.merge(squares).size(), 3, "three outlines")

func test_cell_polygons_at_the_cells_flipped() -> void:
	# The left half of the tile, around its centre.
	var layer := _bare_layer(PackedVector2Array([Vector2(-8, -8), Vector2(0, -8), Vector2(0, 8), Vector2(-8, 8)]))
	layer.set_cell(Vector2i(2, 1), 0, Vector2i.ZERO, 0)
	layer.set_cell(Vector2i(4, 1), 0, Vector2i.ZERO, TileSetAtlasSource.TRANSFORM_FLIP_H)
	var polygons := GooStatics.cell_polygons(layer)
	assert_eq(polygons.size(), 2, "one polygon per cell")
	var boxes: Array[Rect2] = []
	for polygon: PackedVector2Array in polygons:
		boxes.append(_box(polygon))
	boxes.sort_custom(func(a: Rect2, b: Rect2) -> bool: return a.position.x < b.position.x)
	print("    cell polygons' boxes %s" % [boxes])
	assert_eq(boxes[0], Rect2(32.0, 16.0, 8.0, 16.0), "the plain cell's left half")
	assert_eq(boxes[1], Rect2(72.0, 16.0, 8.0, 16.0), "the flipped cell's right half")

func test_bake_cells_of_a_row_and_none() -> void:
	var layer := _bare_layer(PackedVector2Array([Vector2(-8, -8), Vector2(8, -8), Vector2(8, 8), Vector2(-8, 8)]))
	assert_eq(GooStatics.bake_cells(layer).size(), 0, "nothing without cells")
	for x: int in 5:
		layer.set_cell(Vector2i(x, 3), 0, Vector2i.ZERO)
	var pieces := GooStatics.bake_cells(layer)
	assert_eq(pieces.size(), 1, "five tiles in a row: one piece")
	if pieces.size() == 1:
		assert_eq(_box(pieces[0]), Rect2(0.0, 48.0, 80.0, 16.0), "the row's outline")
	assert_eq(GooStatics.bake_cells(layer, Rect2(), 1).size(), 0, "nothing on a physics layer it lacks")

func test_bake_cells_clips_to_a_rect() -> void:
	# Five tiles in a row, x 0..80 at y 48..64; the clip from x 20 to 50 (the
	# second cell crossing its left edge, the fourth its right): the first and
	# the last cells, wholly outside, are left out, the crossing ones kept
	# whole; a clip that only touches a cell's edge leaves it out.
	var layer := _bare_layer(PackedVector2Array([Vector2(-8, -8), Vector2(8, -8), Vector2(8, 8), Vector2(-8, 8)]))
	for x: int in 5:
		layer.set_cell(Vector2i(x, 3), 0, Vector2i.ZERO)
	var clip := Rect2(20.0, 0.0, 30.0, 100.0)
	assert_eq(GooStatics.cell_polygons(layer).size(), 5, "every cell without a clip")
	assert_eq(GooStatics.cell_polygons(layer, clip).size(), 3, "the cells the clip overlaps")
	assert_eq(GooStatics.cell_polygons(layer, Rect2(80.0, 0.0, 10.0, 100.0)).size(), 0,
		"none for a clip touching the last cell's edge from outside")
	var pieces := GooStatics.bake_cells(layer, clip)
	assert_eq(pieces.size(), 1, "one piece")
	if pieces.size() == 1:
		assert_eq(_box(pieces[0]), Rect2(16.0, 48.0, 48.0, 16.0), "the crossing cells whole: x 16..64")
	assert_eq(GooStatics.bake_cells(layer, Rect2(200.0, 0.0, 10.0, 10.0)).size(), 0, "nothing inside the clip: no piece")
