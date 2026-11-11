class_name LinksExample
extends Node2D
## The links example's scene: a top-down tank (a LinksWorld with gravity_scale
## 0 inside four walls) of bodies joined by GooWorld2D.link(): a chain of five
## round bodies (CHAIN), a round body linked to a square and a triangle
## (CLUSTER), three pairs at strengths 0.2, 0.6 and 1 (PAIRS), and a chain of
## three whose first link's rest angle swings back and forth (WAVER: SWING
## radians at SWING_HZ), so that joint visibly bends. Each linked pair is drawn as one blob with a
## neck (the bridge skin). Drag a body with the mouse to pull a group about;
## R builds the tank again.

## The canvas size this scene is laid out for: it gives the window's canvas
## this size while it is in the tree.
const LAYOUT_SIZE := Vector2i(1920, 1080)
## The chain: its bodies' radius, the first one's centre, the step between
## centres along x, its links' strength and colour.
const CHAIN_RADIUS: float = 44.0
const CHAIN_START := Vector2(420.0, 260.0)
const CHAIN_STRENGTH: float = 0.7
const CHAIN_COLOR := Color(0.35, 0.75, 0.95)
## The cluster: the round body in the middle, the square left of it and the
## triangle right of it ([radius, sides, colour] of each, its centre x offset
## from the middle).
const CLUSTER_CENTER := Vector2(620.0, 560.0)
const CLUSTER_RADIUS: float = 56.0
const CLUSTER: Array[Array] = [[56.0, 0, Color(0.95, 0.55, 0.3)], [48.0, 4, Color(0.95, 0.8, 0.3)],
	[50.0, 3, Color(0.9, 0.4, 0.5)]]
## The three pairs: their strengths, centres (the middle of each pair) and
## radius.
const PAIR_STRENGTHS: Array[float] = [0.2, 0.6, 1.0]
const PAIR_CENTERS: Array[Vector2] = [Vector2(460.0, 860.0), Vector2(860.0, 860.0), Vector2(1260.0, 860.0)]
const PAIR_RADIUS: float = 50.0
const PAIR_COLOR := Color(0.55, 0.9, 0.45)
## The waving chain of three: its middle body's centre, the radius, colour,
## and its first link's swing.
const WAVER_CENTER := Vector2(1340.0, 540.0)
const WAVER_RADIUS: float = 50.0
const WAVER_COLOR := Color(0.75, 0.55, 0.95)
const SWING: float = 0.6
const SWING_HZ: float = 0.5

@onready var _world: LinksWorld = $World
@onready var _label: Label = $UI/Label

## The waving chain's swinging link's handle.
var waver: int = -1
## Seconds since the tank was built (the swing's clock).
var time: float = 0.0

var _grab: int = -1
var _previous_size: Vector2i
var _previous_stretch: Window.ContentScaleStretch

# Lays the window's canvas out at LAYOUT_SIZE while the scene is in the tree.
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
	build()

## The world the bodies live in.
func world() -> LinksWorld:
	return _world

## Empties the tank and builds the chain, the cluster, the pairs and the
## waving chain again, linked.
func build() -> void:
	_world.clear()
	_grab = -1
	time = 0.0
	var gap := 2.0
	var chain: Array[Goo2D] = []
	for k: int in 5:
		chain.append(_spawn(CHAIN_RADIUS, 0, CHAIN_START + Vector2(k * (2.0 * CHAIN_RADIUS + gap), 0.0), CHAIN_COLOR))
	for k: int in 4:
		_world.link(chain[k], chain[k + 1], CHAIN_STRENGTH)
	var middle := _spawn(CLUSTER[0][0], CLUSTER[0][1], CLUSTER_CENTER, CLUSTER[0][2])
	var square := _spawn(CLUSTER[1][0], CLUSTER[1][1],
		CLUSTER_CENTER - Vector2(CLUSTER_RADIUS + float(CLUSTER[1][0]) + gap, 0.0), CLUSTER[1][2])
	var triangle := _spawn(CLUSTER[2][0], CLUSTER[2][1],
		CLUSTER_CENTER + Vector2(CLUSTER_RADIUS + float(CLUSTER[2][0]) + gap, 0.0), CLUSTER[2][2])
	_world.link(middle, square, 0.8)
	_world.link(middle, triangle, 0.8)
	for k: int in PAIR_STRENGTHS.size():
		var a := _spawn(PAIR_RADIUS, 0, PAIR_CENTERS[k] - Vector2(PAIR_RADIUS + gap * 0.5, 0.0), PAIR_COLOR)
		var b := _spawn(PAIR_RADIUS, 0, PAIR_CENTERS[k] + Vector2(PAIR_RADIUS + gap * 0.5, 0.0), PAIR_COLOR)
		_world.link(a, b, PAIR_STRENGTHS[k])
	var step := Vector2(2.0 * WAVER_RADIUS + gap, 0.0)
	var left := _spawn(WAVER_RADIUS, 0, WAVER_CENTER - step, WAVER_COLOR)
	var centre := _spawn(WAVER_RADIUS, 0, WAVER_CENTER, WAVER_COLOR)
	var right := _spawn(WAVER_RADIUS, 0, WAVER_CENTER + step, WAVER_COLOR)
	waver = _world.link(left, centre, 1.0)
	_world.link(centre, right, 1.0)
	_update_label()

func _spawn(radius: float, sides: int, at: Vector2, colour: Color) -> Goo2D:
	var body := _world.spawn(radius, at, GooShape.regular(sides, radius) if sides >= 3 else null)
	body.color = colour
	return body

func _physics_process(delta: float) -> void:
	time += delta
	if waver >= 0:
		_world.set_link_rest_angle(waver, SWING * sin(TAU * SWING_HZ * time))

func _unhandled_input(event: InputEvent) -> void:
	var mouse := event as InputEventMouseButton
	var motion := event as InputEventMouseMotion
	var key := event as InputEventKey
	if mouse != null and mouse.button_index == MOUSE_BUTTON_LEFT:
		var at := (make_input_local(mouse) as InputEventMouseButton).position
		if mouse.pressed:
			var body := _world.body_at(at)
			if body != null:
				_grab = _world.grab(body, at)
		elif _grab >= 0:
			_world.release_grab(_grab)
			_grab = -1
	elif motion != null and _grab >= 0:
		_world.move_grab(_grab, (make_input_local(motion) as InputEventMouseMotion).position)
	elif key != null and key.pressed and not key.echo and key.keycode == KEY_R:
		build()
	else:
		return
	get_viewport().set_input_as_handled()

func _update_label() -> void:
	if _label == null:
		return
	_label.text = "Links: bodies joined by GooWorld2D.link(), each joint drawn as one blob with a neck" \
		+ "      Bodies: %d      Links: %d\n" % [_world.bodies().size(), _world.links().size()] \
		+ "A chain of five      A round body, a square and a triangle      Strengths 0.2, 0.6, 1      " \
		+ "A joint bent back and forth      Drag a body to pull      R: rebuild"
