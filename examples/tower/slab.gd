@tool
class_name TowerSlab
extends StaticBody2D
## A solid block of scenery for the tower example (the platform, the floor): a
## StaticBody2D on the goo's wall layer whose first CollisionShape2D child is a
## RectangleShape2D, drawn as a filled rectangle with a lighter top edge, in the
## editor and in the game. Resize the rectangle or move the shape (or the body)
## in the editor and the drawing follows; GooStatics mirrors the same shape for
## the goo.

## Fill colour of the slab.
@export var color: Color = Color(0.32, 0.29, 0.38, 1.0):
	set(value):
		color = value
		queue_redraw()
## Colour of the slab's top edge.
@export var edge_color: Color = Color(0.55, 0.5, 0.64, 1.0):
	set(value):
		edge_color = value
		queue_redraw()
## Thickness, in px, of the top edge.
@export var edge_width: float = 4.0:
	set(value):
		edge_width = value
		queue_redraw()

# The rectangle drawn last, in the body's local space, to redraw when it changes.
var _drawn: Rect2 = Rect2()

func _ready() -> void:
	if not Engine.is_editor_hint():
		collision_layer = GooTuning.LAYER_WALLS
		collision_mask = 0
	queue_redraw()

# The shape's size and the shape node's position are not this node's
# properties, so nothing tells it they changed: in the editor it looks every
# frame (cheap) and redraws when the rectangle moved.
func _process(_delta: float) -> void:
	if Engine.is_editor_hint() and local_rect() != _drawn:
		queue_redraw()

## The first CollisionShape2D child holding a RectangleShape2D, or null.
func collision_shape() -> CollisionShape2D:
	for child: Node in get_children():
		var shape := child as CollisionShape2D
		if shape != null and shape.shape is RectangleShape2D:
			return shape
	return null

## The collision rectangle in this body's local space (the shape node's
## rotation ignored; keep it unrotated). An empty rect when there is none.
func local_rect() -> Rect2:
	var shape := collision_shape()
	if shape == null:
		return Rect2()
	var size := (shape.shape as RectangleShape2D).size * shape.scale.abs()
	return Rect2(shape.position - size * 0.5, size)

## The collision rectangle in global space (the body's own scale and position
## applied; keep it unrotated).
func global_rect() -> Rect2:
	var rect := local_rect()
	var corner := global_transform * rect.position
	var far := global_transform * rect.end
	return Rect2(corner, Vector2.ZERO).expand(far)

## Global y of the slab's top face.
func top_y() -> float:
	return global_rect().position.y

func _draw() -> void:
	_drawn = local_rect()
	if _drawn.size.x <= 0.0 or _drawn.size.y <= 0.0:
		return
	draw_rect(_drawn, color)
	var edge := minf(edge_width, _drawn.size.y)
	draw_rect(Rect2(_drawn.position, Vector2(_drawn.size.x, edge)), edge_color)
