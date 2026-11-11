@tool
class_name TowerGoalLine
extends Node2D
## The tower example's goal: a dashed horizontal line `width` px long centred on
## this node, with its `label` text above its left end, drawn in the editor and
## in the game. The TowerWorld reads its global y: the tower wins once its top
## stands above it. Move it up or down in the editor to make the game harder or
## easier. `reached` (set by the game) draws it lit.

## Length of the line, in px, centred on the node.
@export var width: float = 900.0:
	set(value):
		width = maxf(value, 0.0)
		queue_redraw()
## Text drawn above the line's left end.
@export var label: String = "GOAL":
	set(value):
		label = value
		queue_redraw()
## Colour of the line and its text.
@export var color: Color = Color(1.0, 0.84, 0.3, 0.9):
	set(value):
		color = value
		queue_redraw()
## Font size of the label, in px.
@export var font_size: int = 26:
	set(value):
		font_size = value
		queue_redraw()

## Length of one dash and of the gap after it, in px.
const DASH: float = 18.0
## Thickness of the line, in px.
const THICKNESS: float = 3.0
## Colour the line is drawn in once reached.
const REACHED_COLOR := Color(0.45, 1.0, 0.55, 1.0)

## Whether the tower has reached the line (drawn lit, solid); set by the game.
var reached: bool = false:
	set(value):
		if value != reached:
			reached = value
			queue_redraw()

func _draw() -> void:
	var colour := REACHED_COLOR if reached else color
	var left := Vector2(-width * 0.5, 0.0)
	var right := Vector2(width * 0.5, 0.0)
	if reached:
		draw_line(left, right, colour, THICKNESS, true)
	else:
		draw_dashed_line(left, right, colour, THICKNESS, DASH, true, true)
	var font := ThemeDB.fallback_font
	if font != null and not label.is_empty():
		draw_string_outline(font, left + Vector2(0.0, -10.0), label, HORIZONTAL_ALIGNMENT_LEFT, -1.0,
			font_size, 6, Color(0.03, 0.03, 0.06, 0.9))
		draw_string(font, left + Vector2(0.0, -10.0), label, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size, colour)
