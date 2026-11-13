class_name GooStatics
extends RefCounted
## The static geometry a GooKernel's beads collide with, mirrored from the
## scene: every StaticBody2D (AnimatableBody2D included) on
## GooTuning.LAYER_WALLS anywhere in the SceneTree, each of its enabled
## CollisionShape2D and CollisionPolygon2D children as convex polygons in the
## kernel (GooKernel.add_static_shape()): a RectangleShape2D as its four
## corners, a ConvexPolygonShape2D as its points, a CircleShape2D or
## CapsuleShape2D as an inscribed polygon of CIRCLE_SIDES sides per full turn,
## a CollisionPolygon2D decomposed into convex parts. Other shapes (segments,
## concave polygons, world boundaries) are skipped with a warning. Each shape
## takes its body's material (physics_material_override: friction and bounce,
## Godot's defaults without one) and grips unless its body is in
## GooTuning.NO_GRIP_GROUP.
##
## And every TileMapLayer with collision_enabled: the collision polygons of its
## used cells on each physics layer of its TileSet whose collision_layer has
## GooTuning.LAYER_WALLS, merged into a few convex pieces per physics layer
## (bake_cells(): a wall of sixty tiles is one rectangle, not sixty squares).
## They take that physics layer's material (the TileSet's
## get_physics_layer_physics_material(); Godot's defaults without one), or the
## layer's own when its metadata MATERIAL_META holds a PhysicsMaterial (a
## TileSet is often shared by several layers and maps), and grip unless the
## layer is in GooTuning.NO_GRIP_GROUP, as a body. A Rect2 in the layer's
## metadata CLIP_META (in the layer's space) leaves out the cell polygons
## wholly outside it (where no goo goes). The layer's own physics bodies are not
## read: the goo takes the TileSet's polygons, so of the layer's physics only
## collision_enabled matters (off: the goo passes, as Godot's bodies would).
##
## A GooWorld2D keeps one for its kernel, and the kernel of lone Goo2D bodies
## another; a GooCellWorld2D one for its GooCells (any object with GooKernel's
## add_static_shape(), set_static_transform() and clear_static_shapes() will do). attach() follows the tree: a static body, shape or tile layer added
## or removed anywhere marks the mirror stale, as does a tile layer's `changed`
## (its TileSet swapped, its collision_enabled) or its cells changing (Godot
## emits no signal for set_cell(): sync() compares the layer's tile_map_data
## with the one it last merged, a copy of a few kB, every frame), and the next
## sync() (every physics frame, before the kernel's step) rebuilds it; sync()
## also moves the kernel's shapes with nodes that moved (an AnimatableBody2D
## pushing the goo, a tile layer moved). A layer's merged pieces are kept while
## its TileSet, cells and clip stay, so a rebuild for a body coming or going
## does not merge its cells again. A change it cannot see (a shape's resource
## or a TileSet edited, a body's or a layer's layer bits, group or metadata
## changed) needs refresh().

## Sides of the polygon a circle (or a capsule's two ends together) becomes.
const CIRCLE_SIDES: int = 24
## A TileMapLayer's metadata under this name, a PhysicsMaterial, is its walls'
## friction and bounce, in place of its TileSet physics layers' materials.
const MATERIAL_META: StringName = &"goo_physics_material"
## A TileMapLayer's metadata under this name, a Rect2 in the layer's space,
## clips its walls: a cell polygon wholly outside it is not mirrored, one
## crossing it is kept whole (bake_cells()'s `clip`).
const CLIP_META: StringName = &"goo_clip"
# Turns smaller than this (px²) count as straight (bake_cells()).
const STRAIGHT: float = 0.001
# Area (px²) a convex split may lose or gain before it counts as failed.
const AREA_SLACK: float = 0.5

var _kernel: Object
var _tree: SceneTree = null
var _stale: bool = true
# One entry per kernel shape: { "node": the CollisionShape2D,
# CollisionPolygon2D or TileMapLayer, "id": its kernel id, "transform": the
# node's global transform when it was last given to the kernel }.
var _entries: Array[Dictionary] = []
var _next_id: int = 1
# The tile layers the last rebuild saw, by instance id: { "layer", "tile_set",
# "cells" (its tile_map_data) and "clip" its pieces were merged with, "pieces"
# (physics layer -> its convex pieces in the layer's space; emptied when one of
# those three changes) }.
var _layers: Dictionary[int, Dictionary] = {}
static var _warned: Dictionary[String, bool] = {}

func _init(kernel: Object) -> void:
	_kernel = kernel

## Follows `tree`: static bodies, shapes and tile layers added to or removed
## from it mark the mirror stale.
func attach(tree: SceneTree) -> void:
	if _tree == tree:
		return
	detach()
	_tree = tree
	tree.node_added.connect(_on_node_changed)
	tree.node_removed.connect(_on_node_changed)
	_stale = true

## Stops following the tree.
func detach() -> void:
	if _tree != null:
		if _tree.node_added.is_connected(_on_node_changed):
			_tree.node_added.disconnect(_on_node_changed)
		if _tree.node_removed.is_connected(_on_node_changed):
			_tree.node_removed.disconnect(_on_node_changed)
	_tree = null
	for watched: Dictionary in _layers.values():
		_unwatch(watched)
	_layers.clear()

## Rebuilds the mirror at the next sync(), the tile layers' pieces merged again.
func refresh() -> void:
	_stale = true
	for watched: Dictionary in _layers.values():
		watched["pieces"] = {}

## Number of shapes in the kernel.
func shape_count() -> int:
	return _entries.size()

## Brings the kernel's shapes up to date: rebuilt if stale, else moved with
## nodes that moved.
func sync() -> void:
	if _tree == null:
		return
	if _stale or _cells_changed():
		_rebuild()
		return
	for entry: Dictionary in _entries:
		var node: Node2D = entry["node"]
		if not is_instance_valid(node) or not node.is_inside_tree():
			_rebuild()
			return
		var transform := node.global_transform
		if transform != entry["transform"]:
			entry["transform"] = transform
			_kernel.set_static_transform(entry["id"], transform)

func _on_node_changed(node: Node) -> void:
	if node is CollisionShape2D or node is CollisionPolygon2D or node is StaticBody2D or node is TileMapLayer:
		_stale = true

# A followed tile layer changed (its TileSet, collision_enabled...).
func _on_layer_changed() -> void:
	_stale = true

# Whether a followed layer the goo collides with has other cells than when it
# was last merged (or is gone).
func _cells_changed() -> bool:
	for watched: Dictionary in _layers.values():
		if not watched["pieces"].is_empty():
			var layer := watched["layer"] as Object
			if not is_instance_valid(layer) or (layer as TileMapLayer).tile_map_data != watched["cells"]:
				return true
	return false

func _rebuild() -> void:
	_stale = false
	_kernel.clear_static_shapes()
	_entries.clear()
	var seen: Dictionary[int, Dictionary] = {}
	for found: Node in _tree.root.find_children("*", "TileMapLayer", true, false):
		var layer := found as TileMapLayer
		if layer == null or not layer.is_inside_tree():
			continue
		var watched := _watch(layer)
		seen[layer.get_instance_id()] = watched
		if not layer.collision_enabled or layer.tile_set == null:
			watched["pieces"] = {}
			continue
		var cells := layer.tile_map_data
		var clip := tile_clip(layer)
		if watched["tile_set"] != layer.tile_set or watched["cells"] != cells or watched["clip"] != clip:
			watched["tile_set"] = layer.tile_set
			watched["cells"] = cells
			watched["clip"] = clip
			watched["pieces"] = {}
		var grip := not layer.is_in_group(GooTuning.NO_GRIP_GROUP)
		for physics: int in layer.tile_set.get_physics_layers_count():
			if (layer.tile_set.get_physics_layer_collision_layer(physics) & GooTuning.LAYER_WALLS) == 0:
				continue
			var material := tile_material(layer, physics)
			var friction := material.friction if material != null else 1.0
			var bounce := material.bounce if material != null else 0.0
			var pieces: Dictionary = watched["pieces"]
			if not pieces.has(physics):
				pieces[physics] = bake_cells(layer, clip, physics)
			for piece: PackedVector2Array in pieces[physics]:
				for part: PackedVector2Array in _convex_parts(piece):
					_add(layer, part, friction, bounce, grip)
	for id: int in _layers:
		if not seen.has(id):
			_unwatch(_layers[id])
	_layers = seen
	for found: Node in _tree.root.find_children("*", "StaticBody2D", true, false):
		var body := found as StaticBody2D
		if body == null or not body.is_inside_tree() or (body.collision_layer & GooTuning.LAYER_WALLS) == 0:
			continue
		var material := body.physics_material_override
		var friction := material.friction if material != null else 1.0
		var bounce := material.bounce if material != null else 0.0
		var grip := not body.is_in_group(GooTuning.NO_GRIP_GROUP)
		for child: Node in body.get_children():
			for part: PackedVector2Array in _parts(child):
				_add(child as Node2D, part, friction, bounce, grip)

# Gives the kernel `part` (convex, in `node`'s space) as a new shape that
# follows `node`.
func _add(node: Node2D, part: PackedVector2Array, friction: float, bounce: float, grip: bool) -> void:
	var id := _next_id
	_next_id += 1
	_kernel.add_static_shape(id, node.global_transform, part, friction, bounce, grip)
	_entries.append({ "node": node, "id": id, "transform": node.global_transform })

# The entry of `layer` in _layers, made (its `changed` followed) on first sight.
func _watch(layer: TileMapLayer) -> Dictionary:
	var id := layer.get_instance_id()
	if _layers.has(id):
		return _layers[id]
	layer.changed.connect(_on_layer_changed)
	var watched := { "layer": layer, "tile_set": null, "cells": PackedByteArray(), "clip": Rect2(), "pieces": {} }
	_layers[id] = watched
	return watched

# Stops following a layer's `changed` (nothing for a freed one: the Variant is
# tested before any cast, which errors on a freed object).
func _unwatch(watched: Dictionary) -> void:
	var layer: Variant = watched["layer"]
	if not is_instance_valid(layer):
		return
	var tiles := layer as TileMapLayer
	if tiles.changed.is_connected(_on_layer_changed):
		tiles.changed.disconnect(_on_layer_changed)

## The material of `layer`'s walls on its TileSet's physics layer `physics`:
## the layer's MATERIAL_META when that holds a PhysicsMaterial, else the
## physics layer's own; null for neither (Godot's defaults then: friction 1,
## bounce 0).
static func tile_material(layer: TileMapLayer, physics: int) -> PhysicsMaterial:
	if layer.has_meta(MATERIAL_META):
		var own := layer.get_meta(MATERIAL_META) as PhysicsMaterial
		if own != null:
			return own
	if layer.tile_set == null or physics < 0 or physics >= layer.tile_set.get_physics_layers_count():
		return null
	return layer.tile_set.get_physics_layer_physics_material(physics)

## The clip of `layer`'s walls, in its space: its CLIP_META when that holds a
## Rect2, else an empty Rect2 (no clip).
static func tile_clip(layer: TileMapLayer) -> Rect2:
	var clip: Variant = layer.get_meta(CLIP_META, Rect2())
	return clip if clip is Rect2 else Rect2()

## Every convex piece of wall `layer`'s tiles give the goo, as the mirror
## takes them (bake_cells() of each physics layer of its TileSet with
## GooTuning.LAYER_WALLS, clipped by its CLIP_META), in the layer's space;
## none while its collision_enabled is off. Merged afresh at each call.
static func layer_pieces(layer: TileMapLayer) -> Array[PackedVector2Array]:
	var result: Array[PackedVector2Array] = []
	if not layer.collision_enabled or layer.tile_set == null:
		return result
	for physics: int in layer.tile_set.get_physics_layers_count():
		if (layer.tile_set.get_physics_layer_collision_layer(physics) & GooTuning.LAYER_WALLS) != 0:
			result.append_array(bake_cells(layer, tile_clip(layer), physics))
	return result

## The walls `layer`'s tiles make on its TileSet's physics layer `physics`
## (-1: every physics layer, together), in the layer's space: few convex
## pieces covering exactly its used cells' collision polygons
## (cell_polygons()), merged and split by convex_pieces(). With a `clip` of
## some area, a cell polygon wholly outside it is left out before the merge,
## one crossing it kept whole. Empty when no cell carries collision.
static func bake_cells(layer: TileMapLayer, clip: Rect2 = Rect2(), physics: int = -1) -> Array[PackedVector2Array]:
	return convex_pieces(cell_polygons(layer, clip, physics), String(layer.name))

## Every collision polygon of `layer`'s used cells on its TileSet's physics
## layer `physics` (-1: every one), in the layer's space: at the cell's centre
## (map_to_local()), flipped and transposed as the cell's alternative says;
## with a `clip` of some area, only those whose bounding box overlaps it (one
## that only touches its edge from outside is left out).
static func cell_polygons(layer: TileMapLayer, clip: Rect2 = Rect2(), physics: int = -1) -> Array[PackedVector2Array]:
	var result: Array[PackedVector2Array] = []
	if layer.tile_set == null:
		return result
	var physics_layers: Array[int] = []
	for index: int in layer.tile_set.get_physics_layers_count():
		if physics < 0 or index == physics:
			physics_layers.append(index)
	for cell: Vector2i in layer.get_used_cells():
		var data := layer.get_cell_tile_data(cell)
		if data == null:
			continue
		var alternative := layer.get_cell_alternative_tile(cell)
		var transpose := alternative & TileSetAtlasSource.TRANSFORM_TRANSPOSE != 0
		var flip_h := alternative & TileSetAtlasSource.TRANSFORM_FLIP_H != 0
		var flip_v := alternative & TileSetAtlasSource.TRANSFORM_FLIP_V != 0
		var centre := layer.map_to_local(cell)
		for index: int in physics_layers:
			for i: int in data.get_collision_polygons_count(index):
				var placed := PackedVector2Array()
				for point: Vector2 in data.get_collision_polygon_points(index, i):
					var p := Vector2(point.y, point.x) if transpose else point
					if flip_h:
						p.x = -p.x
					if flip_v:
						p.y = -p.y
					placed.append(centre + p)
				if placed.size() >= 3 and (not clip.has_area() or _box(placed).intersects(clip)):
					result.append(placed)
	return result

## Convex pieces covering the union of `polygons`: merged into outlines, each
## split into convex pieces (Geometry2D.decompose_polygon_in_convex(), which
## fans long walls into slivers at every notch) and the pieces joined again
## where their union is convex; or, should an outline not split into pieces of
## its own area, one convex piece set per polygon, with a warning (more shapes
## for the kernel, the same walls). `label` names the polygons' origin in
## warnings.
static func convex_pieces(polygons: Array[PackedVector2Array], label: String = "") -> Array[PackedVector2Array]:
	var pieces: Array[PackedVector2Array] = []
	for outline: PackedVector2Array in merge(polygons, label):
		var parts: Array[PackedVector2Array] = []
		for part: PackedVector2Array in Geometry2D.decompose_polygon_in_convex(outline):
			parts.append(part)
		parts = join_convex(parts)
		var area := 0.0
		for part: PackedVector2Array in parts:
			area += absf(signed_area(part))
		if parts.is_empty() or absf(area - absf(signed_area(outline))) > AREA_SLACK:
			push_warning("GooStatics: %s: an outline of %d points did not split into convex pieces; one piece per cell instead"
				% [label, outline.size()])
			return per_cell(polygons)
		pieces.append_array(parts)
	return pieces

## Merges `polygons` into the outlines of their union, iteratively (each one
## into every outline it touches); holes (a ring of tiles around an empty cell)
## are filled, with a warning. Every outline is counter-clockwise
## (Geometry2D.is_polygon_clockwise() false).
static func merge(polygons: Array[PackedVector2Array], label: String = "") -> Array[PackedVector2Array]:
	var outlines: Array[PackedVector2Array] = []
	var boxes: Array[Rect2] = []
	var holes := 0
	for polygon: PackedVector2Array in polygons:
		var current := polygon
		if Geometry2D.is_polygon_clockwise(current):
			current.reverse()
		var box := _box(current)
		var merged := true
		while merged:
			merged = false
			for j: int in outlines.size():
				if not boxes[j].grow(STRAIGHT).intersects(box):
					continue
				var outers: Array[PackedVector2Array] = []
				var inners := 0
				for result: PackedVector2Array in Geometry2D.merge_polygons(outlines[j], current):
					if Geometry2D.is_polygon_clockwise(result):
						inners += 1
					else:
						outers.append(result)
				if outers.size() != 1:
					continue
				holes += inners
				current = outers[0]
				box = _box(current)
				outlines.remove_at(j)
				boxes.remove_at(j)
				merged = true
				break
		outlines.append(current)
		boxes.append(box)
	if holes > 0:
		push_warning("GooStatics: %s: %d hole(s) in the merged tiles' collision filled in" % [label, holes])
	return outlines

## Joins convex `parts` pairwise while the union of two is one convex polygon
## (collinear points dropped), until no pair joins.
static func join_convex(parts: Array[PackedVector2Array]) -> Array[PackedVector2Array]:
	var result := parts.duplicate()
	var joined := true
	while joined:
		joined = false
		for i: int in result.size():
			for j: int in range(i + 1, result.size()):
				if not _box(result[i]).grow(STRAIGHT).intersects(_box(result[j])):
					continue
				var union := Geometry2D.merge_polygons(result[i], result[j])
				if union.size() != 1:
					continue
				var hull := _straightened(union[0])
				if not is_convex(hull):
					continue
				result[i] = hull
				result.remove_at(j)
				joined = true
				break
			if joined:
				break
	return result

## The fallback: every polygon split into convex pieces on its own.
static func per_cell(polygons: Array[PackedVector2Array]) -> Array[PackedVector2Array]:
	var pieces: Array[PackedVector2Array] = []
	for polygon: PackedVector2Array in polygons:
		for part: PackedVector2Array in Geometry2D.decompose_polygon_in_convex(polygon):
			pieces.append(part)
	return pieces

## Whether `points` is a convex polygon (collinear points allowed), either way round.
static func is_convex(points: PackedVector2Array) -> bool:
	if points.size() < 3:
		return false
	var turn := 0.0
	for i: int in points.size():
		var a := points[i]
		var b := points[(i + 1) % points.size()]
		var c := points[(i + 2) % points.size()]
		var cross := (b - a).cross(c - b)
		if absf(cross) < STRAIGHT:
			continue
		if turn == 0.0:
			turn = signf(cross)
		elif signf(cross) != turn:
			return false
	return turn != 0.0

## The signed area of `points` (shoelace), in px².
static func signed_area(points: PackedVector2Array) -> float:
	var twice := 0.0
	for i: int in points.size():
		twice += points[i].cross(points[(i + 1) % points.size()])
	return twice / 2.0

# `points` without the points where it goes straight on.
static func _straightened(points: PackedVector2Array) -> PackedVector2Array:
	var result := PackedVector2Array()
	for i: int in points.size():
		var a := points[(i - 1 + points.size()) % points.size()]
		var b := points[i]
		var c := points[(i + 1) % points.size()]
		if absf((b - a).cross(c - b)) >= STRAIGHT:
			result.append(b)
	return result

static func _box(points: PackedVector2Array) -> Rect2:
	var box := Rect2(points[0], Vector2.ZERO)
	for point: Vector2 in points:
		box = box.expand(point)
	return box

# The convex polygons, in `node`'s own space, of a collision node (none for
# anything else, or a disabled one).
static func _parts(node: Node) -> Array[PackedVector2Array]:
	var parts: Array[PackedVector2Array] = []
	var collision := node as CollisionShape2D
	if collision != null:
		if collision.disabled or collision.shape == null:
			return parts
		var points := shape_points(collision.shape)
		if points.size() >= 3:
			parts.append(points)
		else:
			_warn_once(collision.shape.get_class())
		return parts
	var polygon := node as CollisionPolygon2D
	if polygon != null and not polygon.disabled and polygon.polygon.size() >= 3:
		if polygon.build_mode == CollisionPolygon2D.BUILD_SOLIDS:
			parts = _convex_parts(polygon.polygon)
		else:
			_warn_once("CollisionPolygon2D (segments)")
	return parts

# `polygon` decomposed into the convex parts the kernel takes (a convex one
# comes back whole), as a CollisionPolygon2D's solids are.
static func _convex_parts(polygon: PackedVector2Array) -> Array[PackedVector2Array]:
	var parts: Array[PackedVector2Array] = []
	for piece: PackedVector2Array in Geometry2D.decompose_polygon_in_convex(polygon):
		if piece.size() >= 3:
			parts.append(piece)
	return parts

## The convex polygon the kernel collides with for `shape`, in its own space;
## empty for a shape it does not support.
static func shape_points(shape: Shape2D) -> PackedVector2Array:
	var rect := shape as RectangleShape2D
	if rect != null:
		var half := rect.size / 2.0
		return PackedVector2Array([Vector2(-half.x, -half.y), Vector2(half.x, -half.y),
			Vector2(half.x, half.y), Vector2(-half.x, half.y)])
	var convex := shape as ConvexPolygonShape2D
	if convex != null:
		return convex.points
	var circle := shape as CircleShape2D
	if circle != null:
		return GooLoop.circle_points(Vector2.ZERO, circle.radius, CIRCLE_SIDES)
	var capsule := shape as CapsuleShape2D
	if capsule != null:
		var points := PackedVector2Array()
		var half := maxf(capsule.height / 2.0 - capsule.radius, 0.0)
		var steps := CIRCLE_SIDES / 2
		for k: int in steps + 1:
			points.append(Vector2(0.0, -half) + Vector2.from_angle(PI + PI * k / steps) * capsule.radius)
		for k: int in steps + 1:
			points.append(Vector2(0.0, half) + Vector2.from_angle(PI * k / steps) * capsule.radius)
		return points
	return PackedVector2Array()

static func _warn_once(kind: String) -> void:
	if _warned.has(kind):
		return
	_warned[kind] = true
	push_warning("GooStatics: %s is not supported as goo collision geometry; skipped" % kind)
