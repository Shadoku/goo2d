class_name Dropper
extends Node2D
## Player input: aims from the arena's launch point towards the mouse, previews
## the next blob (its shape's outline) with an aim line and its ballistic path,
## cycles the next shape with Tab, and asks Game to launch or reset.

## Alpha of the next-blob preview.
const PREVIEW_ALPHA: float = 0.6
## Length of the aim line per px/s of launch speed, in seconds.
const AIM_LINE_SCALE: float = 0.25
## Longest aim line, in px, so it stays on screen.
const AIM_LINE_MAX: float = 240.0
## Width of the aim line, in px.
const AIM_LINE_WIDTH: float = 3.0
## Number of dots in the trajectory preview.
const TRAJECTORY_DOTS: int = 12
## Time between trajectory dots, in seconds; the first dot is at this time too.
const TRAJECTORY_STEP: float = 0.05
## Radius of the first trajectory dot, in px; later dots shrink towards a third of it.
const TRAJECTORY_DOT_RADIUS: float = 6.0

## Game that launches and resets blobs.
@export var game: Game
## Arena whose launch point blobs leave from.
@export var arena: Arena

## Aim offset, in px: the aimed point minus the launch point.
var aim: Vector2 = Vector2.ZERO
## Velocity, in px/s, the next blob would be launched at.
var launch_velocity: Vector2 = Vector2.ZERO

func _process(_delta: float) -> void:
	aim_at(get_global_mouse_position())
	queue_redraw()

func _unhandled_input(event: InputEvent) -> void:
	if game == null:
		return
	var mouse := event as InputEventMouseButton
	var key := event as InputEventKey
	if mouse != null and mouse.pressed and mouse.button_index == MOUSE_BUTTON_LEFT:
		aim_at(get_global_mouse_position())
		game.launch(launch_velocity)
	elif key != null and key.pressed and not key.echo and key.keycode == KEY_SPACE:
		game.launch(launch_velocity)
	elif key != null and key.pressed and not key.echo and key.keycode == KEY_R:
		game.reset()
	elif key != null and key.pressed and not key.echo and key.keycode == KEY_TAB:
		game.controller.cycle_shape()
	else:
		return
	get_viewport().set_input_as_handled()

## Aims at the global `point`: updates `aim` and `launch_velocity`.
func aim_at(point: Vector2) -> void:
	aim = point - launch_point()
	launch_velocity = game.controller.launch_velocity(aim) if game != null else Vector2.ZERO

## Global point blobs are launched from.
func launch_point() -> Vector2:
	return arena.launch_point() if arena != null else Arena.LAUNCH_POINT

## Global position of a launched blob's centre `t` seconds after launch,
## ignoring collisions and damping.
func trajectory_point(t: float) -> Vector2:
	return launch_point() + launch_velocity * t + 0.5 * _gravity() * t * t

func _draw() -> void:
	if game == null or arena == null:
		return
	var radius := game.next_radius()
	var colour := GooTuning.color(radius)
	colour.a = PREVIEW_ALPHA
	var origin := to_local(launch_point())
	var shape := game.next_shape()
	if shape == null or shape.is_round():
		draw_circle(origin, radius, colour)
	else:
		var outline := shape.outline.duplicate()
		for i: int in outline.size():
			outline[i] += origin
		draw_colored_polygon(outline, colour)
	var line := (launch_velocity * AIM_LINE_SCALE).limit_length(AIM_LINE_MAX)
	if line != Vector2.ZERO:
		draw_line(origin, origin + line, colour, AIM_LINE_WIDTH, true)
	for i: int in TRAJECTORY_DOTS:
		var t := TRAJECTORY_STEP * (i + 1)
		var shrink := 1.0 - (2.0 / 3.0) * float(i) / float(TRAJECTORY_DOTS - 1)
		draw_circle(to_local(trajectory_point(t)), TRAJECTORY_DOT_RADIUS * shrink, colour)

func _gravity() -> Vector2:
	var strength: float = ProjectSettings.get_setting("physics/2d/default_gravity", 980.0)
	var direction: Vector2 = ProjectSettings.get_setting("physics/2d/default_gravity_vector", Vector2.DOWN)
	return direction * strength
