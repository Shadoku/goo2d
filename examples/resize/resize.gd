class_name ResizeExample
extends Node2D
## The resize example's scene: a box (the Walls static body in resize.tscn) and
## a ResizeWorld of four bodies. Three breathe between two sizes
## (Goo2D.resize(), one ease per half breath: BREATHERS), a round one, a square
## and a triangle, each rebuilding its ring where its bead count must change;
## the fourth squashes rhythmically along its rest pose's horizontal
## (Goo2D.set_rest_deform() every physics frame: SQUASHER), already squashed
## at frame 0 for check.py's render stage. The mouse wheel (or + and -) grows
## and shrinks the body under the pointer by WHEEL_STEP (a breathing one stops
## breathing); R puts the four back.

## The canvas size this scene is laid out for: it gives the window's canvas
## this size while it is in the tree.
const LAYOUT_SIZE := Vector2i(1920, 1080)
## Y of the floor's top face (the Walls in resize.tscn).
const FLOOR_Y: float = 1000.0
## The breathing bodies: [sides (0 round), smallest radius, largest radius,
## seconds per breath, centre x, colour] each.
const BREATHERS: Array[Array] = [
	[0, 40.0, 110.0, 4.0, 520.0, Color(0.95, 0.35, 0.3)],
	[4, 45.0, 85.0, 3.0, 900.0, Color(0.95, 0.75, 0.25)],
	[3, 50.0, 90.0, 5.0, 1240.0, Color(0.35, 0.8, 0.45)],
]
## The squashing body: its radius, centre x, colour, squash amplitude (the
## squash runs 1 ± this) and frequency, Hz.
const SQUASHER_RADIUS: float = 70.0
const SQUASHER_X: float = 1540.0
const SQUASHER_COLOR := Color(0.35, 0.55, 0.95)
const SQUASH_AMPLITUDE: float = 0.35
const SQUASH_FREQUENCY: float = 1.5
## How much one wheel notch (or + / -) changes the radius of the body under the
## pointer: × (1 + this), or ÷ it.
const WHEEL_STEP: float = 0.12

var _breathing: Dictionary[Goo2D, Array] = {}
var _squasher: Goo2D = null
var _time: float = 0.0

@onready var _world: ResizeWorld = $World
@onready var _label: Label = $UI/Label

var _previous_size: Vector2i
var _previous_stretch: Window.ContentScaleStretch

# Lays the window's canvas out at LAYOUT_SIZE, fitted to the window, while the
# scene is in the tree; the window's settings come back when it leaves.
func _enter_tree() -> void:
	var window := get_window()
	_previous_size = window.content_scale_size
	_previous_stretch = window.content_scale_stretch
	window.content_scale_size = LAYOUT_SIZE
	window.content_scale_stretch = Window.CONTENT_SCALE_STRETCH_FRACTIONAL

func _exit_tree() -> void:
	var window := get_window()
	window.content_scale_size = _previous_size
	window.content_scale_stretch = _previous_stretch

func _ready() -> void:
	GooSkin.warm_up(self)
	reset()

## The world the bodies live in.
func world() -> ResizeWorld:
	return _world

## The squashing body (null after it was removed).
func squasher() -> Goo2D:
	return _squasher if is_instance_valid(_squasher) else null

## True while `body` breathes (the wheel stops it).
func is_breathing(body: Goo2D) -> bool:
	return _breathing.has(body)

## Puts the four bodies back as they start: the breathers at their smallest
## size, the squasher already squashed.
func reset() -> void:
	_world.clear()
	_breathing.clear()
	_time = 0.0
	for entry: Array in BREATHERS:
		var sides := int(entry[0])
		var smallest := float(entry[1])
		var shape := GooShape.regular(sides, smallest) if sides > 0 else null
		var body := _world.spawn(smallest, Vector2(float(entry[4]), FLOOR_Y - smallest - 2.0), shape)
		body.color = entry[5]
		# [smallest, largest, seconds per breath, growing next]
		_breathing[body] = [smallest, float(entry[2]), float(entry[3]), true]
		_breathe(body)
	_squasher = _world.spawn(SQUASHER_RADIUS, Vector2(SQUASHER_X, FLOOR_Y - SQUASHER_RADIUS - 2.0))
	_squasher.color = SQUASHER_COLOR
	_squash()
	_update_label()

func _physics_process(delta: float) -> void:
	_time += delta
	for body: Goo2D in _breathing.keys():
		if not is_instance_valid(body):
			_breathing.erase(body)
		elif not body.is_resizing():
			_breathe(body)
	_squash()
	_update_label()

# Starts the next half breath of `body`: to its largest or smallest size over
# half its breath.
func _breathe(body: Goo2D) -> void:
	var breath: Array = _breathing[body]
	var growing: bool = breath[3]
	body.resize(float(breath[1]) if growing else float(breath[0]), float(breath[2]) * 0.5)
	breath[3] = not growing

# The squasher's rest outline this frame: squashed along its rest horizontal,
# 1 ± SQUASH_AMPLITUDE at SQUASH_FREQUENCY.
func _squash() -> void:
	if squasher() != null:
		_squasher.set_rest_deform(1.0 - SQUASH_AMPLITUDE * cos(TAU * SQUASH_FREQUENCY * _time), Vector2.RIGHT)

func _unhandled_input(event: InputEvent) -> void:
	var mouse := event as InputEventMouseButton
	var key := event as InputEventKey
	var at := get_global_mouse_position()
	if mouse != null and mouse.pressed and mouse.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
		at = (make_input_local(mouse) as InputEventMouseButton).position
		step_size_at(at, 1 if mouse.button_index == MOUSE_BUTTON_WHEEL_UP else -1)
	elif key != null and key.pressed and key.keycode in [KEY_PLUS, KEY_EQUAL, KEY_KP_ADD]:
		step_size_at(at, 1)
	elif key != null and key.pressed and key.keycode in [KEY_MINUS, KEY_KP_SUBTRACT]:
		step_size_at(at, -1)
	elif key != null and key.pressed and not key.echo and key.keycode == KEY_R:
		reset()
	else:
		return
	get_viewport().set_input_as_handled()

## Grows (`steps` above 0) or shrinks the body under the global point `at` by
## WHEEL_STEP per step, within the goo's size range, and stops its breathing.
## Returns the body, or null where there is none.
func step_size_at(at: Vector2, steps: int) -> Goo2D:
	var body := _world.body_at(at)
	if body == null:
		return null
	_breathing.erase(body)
	var wanted := body.radius * pow(1.0 + WHEEL_STEP, steps)
	body.resize(clampf(wanted, GooTuning.min_radius(), GooTuning.max_radius()), 0.25)
	return body

func _update_label() -> void:
	if _label == null:
		return
	var sizes := PackedStringArray()
	for body: Goo2D in _world.bodies():
		sizes.append("%.0f" % body.eased_radius())
	_label.text = "Resizing goo: bodies that breathe (Goo2D.resize()) and squash (Goo2D.set_rest_deform())" \
		+ "      Radii: %s px\n" % ", ".join(sizes) \
		+ "Mouse wheel or + / -: grow or shrink the body under the pointer      R: reset"
