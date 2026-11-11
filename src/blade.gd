@tool
class_name Blade
extends StaticBody2D
## A blade: a thin, sharp steel triangle standing on its base at the node's
## origin, its tip `length` px away at Vector2(0, -length) in local space, so
## it points up; rotate the node to point it elsewhere. It is solid like the
## walls, and Game cuts any blob whose bead loop its tip gets into along its
## axis (see Game._check_blades(), GooLoop). It is in GooTuning.NO_GRIP_GROUP:
## the goo slides off it rather than gripping it like a wall.
##
## _ready() builds its collision triangle and its drawing unless the scene
## already gives it a CollisionShape2D or a Polygon2D. In the editor (a tool
## script) it builds nothing: _draw() previews the triangle (steel fill and
## edge) instead, following `length` and `base_width`, unless the node has a
## Polygon2D of its own.

## Fill colour of the blade.
const STEEL := Color(0.78, 0.8, 0.86, 1.0)
## Colour of the bright strip along one face that reads as a sharpened edge.
const EDGE := Color(0.95, 0.97, 1.0, 1.0)

## Distance, in px, from the middle of the base to the tip.
@export var length: float = 150.0:
	set(value):
		length = value
		queue_redraw()
## Width, in px, of the base the blade stands on.
@export var base_width: float = 10.0:
	set(value):
		base_width = value
		queue_redraw()

func _ready() -> void:
	if Engine.is_editor_hint():
		queue_redraw()
		return
	add_to_group(GooTuning.NO_GRIP_GROUP)
	collision_layer = GooTuning.LAYER_WALLS
	collision_mask = 0
	if physics_material_override == null:
		var surface := PhysicsMaterial.new()
		surface.friction = Arena.WALL_FRICTION
		surface.bounce = Arena.WALL_BOUNCE
		physics_material_override = surface
	if _child_of_type("CollisionShape2D") == null:
		var shape := CollisionShape2D.new()
		shape.name = "Shape"
		var polygon := ConvexPolygonShape2D.new()
		polygon.points = outline()
		shape.shape = polygon
		add_child(shape)
	if _child_of_type("Polygon2D") == null:
		var body := Polygon2D.new()
		body.name = "Visual"
		body.color = STEEL
		body.polygon = outline()
		add_child(body)
		var edge := Polygon2D.new()
		edge.name = "Edge"
		edge.color = EDGE
		edge.polygon = edge_outline()
		add_child(edge)

## The blade's triangle in local space: base left, base right, tip.
func outline() -> PackedVector2Array:
	var half := base_width / 2.0
	return PackedVector2Array([Vector2(-half, 0.0), Vector2(half, 0.0), Vector2(0.0, -length)])

## The bright edge strip along the blade's left face, in local space.
func edge_outline() -> PackedVector2Array:
	var half := base_width / 2.0
	return PackedVector2Array([Vector2(-half, 0.0), Vector2(-half * 0.45, 0.0), Vector2(0.0, -length)])

## Global position of the tip.
func tip() -> Vector2:
	return to_global(Vector2(0.0, -length))

## Unit vector, in global space, from the middle of the base to the tip.
func axis() -> Vector2:
	return global_position.direction_to(tip())

# In the editor only, and only for a blade without a drawing of its own: the
# triangle and its edge, as the game will draw them.
func _draw() -> void:
	if not Engine.is_editor_hint() or _child_of_type("Polygon2D") != null:
		return
	draw_colored_polygon(outline(), STEEL)
	draw_colored_polygon(edge_outline(), EDGE)

func _child_of_type(type: String) -> Node:
	for child: Node in get_children():
		if child.is_class(type):
			return child
	return null
