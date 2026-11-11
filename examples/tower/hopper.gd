@tool
class_name TowerHopper
extends Node2D
## The tower example's hopper: blocks drop from this node's y, anywhere across
## `width` px centred on it. Draws its range (a rail with end stops) and the
## next block's square outline where it would drop, in the editor (at the
## centre, in the first palette colour) and in the game (at `aim_x`, in
## `next_color`, set by the game). `block_radius` is the size of every block
## the game drops, so a designer sees it here.

## Width, in px, of the range blocks drop from, centred on the node.
@export var width: float = 600.0:
	set(value):
		width = maxf(value, 0.0)
		queue_redraw()
## Equivalent radius, in px, of every block (GooShape.regular(4, block_radius):
## a square of side √π × block_radius, about 78 px for 44).
@export_range(28.0, 90.0, 0.5) var block_radius: float = 44.0:
	set(value):
		block_radius = value
		queue_redraw()
## Colour of the rail and its stops.
@export var rail_color: Color = Color(0.75, 0.75, 0.85, 0.7):
	set(value):
		rail_color = value
		queue_redraw()

## Gap, in px, between the rail and the top of the next block's outline.
const RAIL_GAP: float = 10.0
## Height of the rail's end stops, in px.
const STOP_HEIGHT: float = 22.0
## Fill alpha of the next block's outline.
const PREVIEW_ALPHA: float = 0.28

## Colour of the next block (set by the game).
var next_color: Color = Color(0.95, 0.36, 0.36, 1.0):
	set(value):
		next_color = value
		queue_redraw()
## Global x the next block would drop at (set by the game; NAN for the centre).
var aim_x: float = NAN:
	set(value):
		aim_x = value
		queue_redraw()
## Whether the hopper is ready to drop (drawn faint while it reloads).
var ready_to_drop: bool = true:
	set(value):
		if value != ready_to_drop:
			ready_to_drop = value
			queue_redraw()

## The square's outline for a block of block_radius, centred on the origin,
## resting on a side.
func block_outline() -> PackedVector2Array:
	return GooShape.regular(4, block_radius).outline

## Half the side of a block, in px.
func half_side() -> float:
	return sqrt(PI) * block_radius * 0.5

## Global x range blocks may drop at: the centres that keep the whole block
## within the hopper's width.
func drop_range() -> Vector2:
	var reach := maxf(width * 0.5 - half_side(), 0.0)
	return Vector2(global_position.x - reach, global_position.x + reach)

## `x` (global) clamped into drop_range().
func clamp_x(x: float) -> float:
	var span := drop_range()
	return clampf(x, span.x, span.y)

## Where the next block's centre is, global: at `x` clamped into range, on this
## node's y.
func drop_point(x: float) -> Vector2:
	return Vector2(clamp_x(x), global_position.y)

func _draw() -> void:
	var half := width * 0.5
	var rail_y := -half_side() - RAIL_GAP
	draw_line(Vector2(-half, rail_y), Vector2(half, rail_y), rail_color, 3.0, true)
	for end: float in [-half, half]:
		draw_line(Vector2(end, rail_y - STOP_HEIGHT * 0.5), Vector2(end, rail_y + STOP_HEIGHT * 0.5), rail_color, 3.0, true)
	var x := 0.0 if is_nan(aim_x) else clamp_x(aim_x) - global_position.x
	var outline := block_outline()
	for i: int in outline.size():
		outline[i] += Vector2(x, 0.0)
	var fill := next_color
	fill.a = PREVIEW_ALPHA if ready_to_drop else PREVIEW_ALPHA * 0.35
	draw_colored_polygon(outline, fill)
	var edge := next_color
	edge.a = 0.9 if ready_to_drop else 0.35
	var loop := outline.duplicate()
	loop.append(outline[0])
	draw_polyline(loop, edge, 2.0, true)
	# The carriage holding it on the rail.
	draw_line(Vector2(x, rail_y), Vector2(x, -half_side()), edge, 3.0, true)
