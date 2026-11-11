class_name TwoTone
extends Node2D
## The two_tone example's scene: a box (a floor and two walls, the Walls static
## body in two_tone.tscn) and a TwoToneWorld, whose blobs merge whatever their
## colours with GooWorld2D.two_tone_merges on: a merge of two colours makes a
## blob drawn in both. At start (the opening) six blobs in the colour merge
## example's palette fall in three pairs that meet in the first second, and one
## blob already two-tone (ROLLER) rolls along the floor from the first frame,
## its division turning with it (what check.py's render stage draws). Space or
## a click drops another blob of a random palette colour; R empties the box.

## Emitted for every blob the opening, a key or a click drops (drop()).
signal dropped(body: Goo2D)

## The canvas size this scene is laid out for: it gives the window's canvas
## this size while it is in the tree (the project's own, the game's, is
## 960 × 528).
const LAYOUT_SIZE := Vector2i(1920, 1080)

## X of the left wall's inner face (the Walls in two_tone.tscn).
const INNER_LEFT: float = 260.0
## X of the right wall's inner face.
const INNER_RIGHT: float = 1660.0
## Y of the floor's top face.
const FLOOR_Y: float = 1000.0
## Y of the centre of a blob Space drops.
const DROP_Y: float = 180.0
## Smallest and largest radius, in px, of a blob Space or a click drops.
const DROP_MIN_RADIUS: float = 36.0
const DROP_MAX_RADIUS: float = 64.0
## Gap, in px, kept between a dropped blob and the walls or the floor.
const DROP_MARGIN: float = 4.0
## The opening's six blobs, three pairs one above the other: [radius, x, y,
## palette index] each.
const OPENING: Array[Array] = [
	[56.0, 520.0, 860.0, 0], [44.0, 530.0, 690.0, 3],
	[50.0, 900.0, 760.0, 1], [50.0, 890.0, 580.0, 2],
	[60.0, 1280.0, 840.0, 3], [40.0, 1270.0, 680.0, 0],
]
## The blob already two-tone at the first frame: its radius, centre x (on the
## floor), palette indices of its colours (red over blue: the division across
## its rest pose's vertical, `color` on top) and the speed, px/s along x, it is
## sent rolling at.
const ROLLER_RADIUS: float = 70.0
const ROLLER_X: float = 1540.0
const ROLLER_COLORS: Array[int] = [0, 3]
const ROLLER_SPEED: float = -240.0
## Y below which a blob is despawned: off the bottom of the screen.
const OUT_Y: float = 1300.0

## Whether the opening is played at start (tests turn it off to place their own).
@export var opening: bool = true

## Draws every random number: the colours, sizes and x of the blobs Space and a
## click drop. Seed it before the scene enters the tree to replay a game.
var rng := RandomNumberGenerator.new()
## Merges since the start or the last reset().
var merges: int = 0

@onready var _world: TwoToneWorld = $World
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

func _init() -> void:
	rng.randomize()

func _ready() -> void:
	_world.merged.connect(_on_merged)
	_world.count_changed.connect(_on_count_changed)
	GooSkin.warm_up(self)
	if opening:
		play_opening()
	_update_label()

## The world the blobs live in.
func world() -> TwoToneWorld:
	return _world

## Drops the opening's six blobs (OPENING) and the two-tone ROLLER, rolling.
func play_opening() -> void:
	for entry: Array in OPENING:
		drop(float(entry[0]), Vector2(float(entry[1]), float(entry[2])), ColorMergeWorld.PALETTE[int(entry[3])])
	var roller := drop(ROLLER_RADIUS, Vector2(ROLLER_X, FLOOR_Y - ROLLER_RADIUS),
		ColorMergeWorld.PALETTE[ROLLER_COLORS[0]])
	# The division across the rest pose's vertical: `color` above, the second below.
	roller.set_two_tone(ColorMergeWorld.PALETTE[ROLLER_COLORS[0]], ColorMergeWorld.PALETTE[ROLLER_COLORS[1]],
		Vector2.DOWN, 0.0)
	roller.set_velocity(Vector2(ROLLER_SPEED, 0.0))

func _physics_process(_delta: float) -> void:
	for body: Goo2D in _world.bodies():
		if body.center().y > OUT_Y:
			_world.despawn(body)

func _unhandled_input(event: InputEvent) -> void:
	var mouse := event as InputEventMouseButton
	var key := event as InputEventKey
	if mouse != null and mouse.pressed and mouse.button_index == MOUSE_BUTTON_LEFT:
		var at := (make_input_local(mouse) as InputEventMouseButton).position
		drop_random(at.x, at.y)
	elif key != null and key.pressed and not key.echo and key.keycode == KEY_SPACE:
		drop_random(rng.randf_range(INNER_LEFT, INNER_RIGHT), DROP_Y)
	elif key != null and key.pressed and not key.echo and key.keycode == KEY_R:
		reset()
	else:
		return
	get_viewport().set_input_as_handled()

## Drops a blob of a random size and palette colour centred on (`x`, `y`),
## moved inside the box if it is not. Returns it.
func drop_random(x: float, y: float) -> Goo2D:
	var radius := rng.randf_range(DROP_MIN_RADIUS, DROP_MAX_RADIUS)
	var colour := ColorMergeWorld.random_color(rng)
	var at := Vector2(
		clampf(x, INNER_LEFT + radius + DROP_MARGIN, INNER_RIGHT - radius - DROP_MARGIN),
		clampf(y, radius + DROP_MARGIN, FLOOR_Y - radius - DROP_MARGIN))
	return drop(radius, at, colour)

## Spawns a round blob of `radius` (px) centred on `at` (global) in `colour`,
## emits dropped and returns it.
func drop(radius: float, at: Vector2, colour: Color) -> Goo2D:
	var body := _world.spawn(radius, at)
	body.color = colour
	dropped.emit(body)
	return body

## Empties the box and starts the merge count over.
func reset() -> void:
	_world.clear()
	merges = 0
	_update_label()

func _on_merged(_radius: float, _position: Vector2) -> void:
	merges += 1
	_update_label()

func _on_count_changed(_count: int) -> void:
	_update_label()

func _update_label() -> void:
	if _label == null:
		return
	var two_tone := 0
	for body: Goo2D in _world.bodies():
		if body.is_two_tone():
			two_tone += 1
	_label.text = "Two-tone goo: a blob merged from two colours shows both, the division turning with it" \
		+ "      Merges: %d      Blobs: %d (two-tone: %d)\n" % [merges, _world.bodies().size(), two_tone] \
		+ "Space: drop a blob      Click: drop one there      R: reset"
