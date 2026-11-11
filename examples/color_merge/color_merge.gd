class_name ColorMerge
extends Node2D
## The color_merge example's scene: a box (a floor and two walls, the Walls
## static body in color_merge.tscn) that a hopper fills with blobs of random
## sizes and palette colours, and a ColorMergeWorld in which blobs merge only
## with blobs of their own colour, whatever their sizes. A click drops a blob
## where the mouse is, in the colour picked with keys 1-4; R empties the box.
## The label counts merges.
##
## The hopper waits while the box is FILL_LIMIT full, so the pile never spills
## over the walls; a blob that leaves the screen anyway is despawned.

## Emitted for every blob the hopper or a click drops (drop()).
signal dropped(body: Goo2D)

## The canvas size this scene is laid out for: it gives the window's canvas
## this size while it is in the tree (the project's own, the game's, is
## 960 × 528).
const LAYOUT_SIZE := Vector2i(1920, 1080)

## X of the left wall's inner face (the Walls in color_merge.tscn).
const INNER_LEFT: float = 260.0
## X of the right wall's inner face.
const INNER_RIGHT: float = 1660.0
## Y of the floor's top face.
const FLOOR_Y: float = 1000.0
## Y of the top of the walls.
const WALL_TOP_Y: float = 260.0
## Y of the centre of a blob the hopper drops.
const HOPPER_Y: float = 180.0
## Seconds between two hopper drops.
const HOPPER_INTERVAL: float = 1.2
## Smallest radius, in px, of a dropped blob.
const DROP_MIN_RADIUS: float = GooTuning.MIN_RADIUS
## Largest radius, in px, of a dropped blob.
const DROP_MAX_RADIUS: float = 90.0
## Gap, in px, kept between a dropped blob and the walls or the floor.
const DROP_MARGIN: float = 4.0
## Share of the box (between the walls, below their tops) the blobs' rest area
## may fill before the hopper waits.
const FILL_LIMIT: float = 0.45
## Y below which a blob is despawned: off the bottom of the screen.
const OUT_Y: float = 1300.0
## Alpha of the next drop's preview at the mouse.
const PREVIEW_ALPHA: float = 0.35
## Font size of the colour legend, in px.
const LEGEND_FONT_SIZE: int = 22
## Top left of the colour legend, left of the box.
const LEGEND_ORIGIN := Vector2(36.0, 330.0)
## Distance between two rows of the legend.
const LEGEND_ROW: float = 52.0

## Whether the hopper drops blobs (tests turn it off to place their own).
@export var hopper_enabled: bool = true

## Draws every random number: the hopper's sizes, colours and x, the click
## drop's size. Seed it before the scene enters the tree to replay a game.
var rng := RandomNumberGenerator.new()
## Merges since the start or the last reset().
var merges: int = 0
## Colour of the next blob a click drops (keys 1-4 pick it).
var next_color: Color = ColorMergeWorld.PALETTE[0]
## Radius, in px, of the next blob a click drops.
var next_radius: float = DROP_MIN_RADIUS

var _hopper_time: float = 0.0
var _hopper_radius: float = DROP_MIN_RADIUS
var _hopper_color: Color = ColorMergeWorld.PALETTE[0]
var _hopper_x: float = 0.0
var _mouse_seen: bool = false
var _full: bool = false

@onready var _world: ColorMergeWorld = $World
@onready var _label: Label = $UI/Label

var _previous_size: Vector2i
var _previous_stretch: Window.ContentScaleStretch

# Lays the window's canvas out at LAYOUT_SIZE, fitted to the window (not by
# whole numbers: 1080 does not go into the default 1056 px window), while the
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
	next_radius = _random_radius()
	_roll_hopper()
	_update_label()
	GooSkin.warm_up(self)

## The world the blobs live in.
func world() -> ColorMergeWorld:
	return _world

func _physics_process(delta: float) -> void:
	for body: Goo2D in _world.bodies():
		if body.center().y > OUT_Y:
			_world.despawn(body)
	var full := filled() >= FILL_LIMIT
	if full != _full:
		_full = full
		_update_label()
	if not hopper_enabled or full:
		return
	_hopper_time += delta
	if _hopper_time >= HOPPER_INTERVAL:
		_hopper_time -= HOPPER_INTERVAL
		drop(_hopper_radius, Vector2(_hopper_x, HOPPER_Y), _hopper_color)
		_roll_hopper()

func _process(_delta: float) -> void:
	queue_redraw()

func _unhandled_input(event: InputEvent) -> void:
	var motion := event as InputEventMouseMotion
	var mouse := event as InputEventMouseButton
	var key := event as InputEventKey
	if motion != null:
		_mouse_seen = true
		return
	if mouse != null and mouse.pressed and mouse.button_index == MOUSE_BUTTON_LEFT:
		_mouse_seen = true
		drop_at((make_input_local(mouse) as InputEventMouseButton).position)
	elif key != null and key.pressed and not key.echo and key.keycode >= KEY_1 \
			and key.keycode < KEY_1 + ColorMergeWorld.PALETTE.size():
		next_color = ColorMergeWorld.PALETTE[key.keycode - KEY_1]
	elif key != null and key.pressed and not key.echo and key.keycode == KEY_R:
		reset()
	else:
		return
	get_viewport().set_input_as_handled()

## Drops a blob of next_radius in next_color centred on `point` (global), moved
## inside the box if it is not, and draws the next click's radius. Returns it.
func drop_at(point: Vector2) -> Goo2D:
	var body := drop(next_radius, _inside(point, next_radius), next_color)
	next_radius = _random_radius()
	return body

## Spawns a round blob of `radius` (px) centred on `at` (global) in `colour`,
## emits dropped and returns it.
func drop(radius: float, at: Vector2, colour: Color) -> Goo2D:
	var body := _world.spawn_colored(radius, at, colour)
	dropped.emit(body)
	return body

## Empties the box, starts the merge count and the hopper's wait over.
func reset() -> void:
	_world.clear()
	merges = 0
	_hopper_time = 0.0
	_update_label()

## Share of the box the blobs' rest areas fill (0 empty; can pass 1 when the
## pile rises above the walls).
func filled() -> float:
	var area := 0.0
	for body: Goo2D in _world.bodies():
		area += PI * body.radius * body.radius
	return area / ((INNER_RIGHT - INNER_LEFT) * (FLOOR_Y - WALL_TOP_Y))

func _random_radius() -> float:
	return rng.randf_range(DROP_MIN_RADIUS, DROP_MAX_RADIUS)

# Draws the hopper's next drop: its size, colour and x.
func _roll_hopper() -> void:
	_hopper_radius = _random_radius()
	_hopper_color = ColorMergeWorld.random_color(rng)
	_hopper_x = rng.randf_range(INNER_LEFT + _hopper_radius + DROP_MARGIN, INNER_RIGHT - _hopper_radius - DROP_MARGIN)

# `point` moved so a blob of `radius` there is between the walls, above the
# floor and on screen.
func _inside(point: Vector2, radius: float) -> Vector2:
	return Vector2(
		clampf(point.x, INNER_LEFT + radius + DROP_MARGIN, INNER_RIGHT - radius - DROP_MARGIN),
		clampf(point.y, radius + DROP_MARGIN, FLOOR_Y - radius - DROP_MARGIN))

func _on_merged(_radius: float, _position: Vector2) -> void:
	merges += 1
	_update_label()

func _on_count_changed(_count: int) -> void:
	_update_label()

func _update_label() -> void:
	if _label == null:
		return
	_label.text = "Color merge: a blob merges only with blobs of its own colour, whatever their sizes" \
		+ "      Merges: %d      Blobs: %d\n" % [merges, _world.bodies().size()] \
		+ "Click: drop a blob there      1-4: pick its colour      R: reset" \
		+ ("      (the box is full: the hopper waits)" if _full and hopper_enabled else "")

func _draw() -> void:
	# The hopper's next blob fades in where it will drop.
	if hopper_enabled:
		var ghost := _hopper_color
		var ready := clampf(_hopper_time / HOPPER_INTERVAL, 0.0, 1.0)
		ghost.a = 0.1 + 0.2 * ready
		draw_circle(Vector2(_hopper_x, HOPPER_Y), _hopper_radius, ghost)
		ghost.a = 0.35 + 0.5 * ready
		draw_arc(Vector2(_hopper_x, HOPPER_Y), _hopper_radius, 0.0, TAU, 48, ghost, 3.0, true)
	# The next click's blob at the mouse, where drop_at() would put it.
	if _mouse_seen:
		var preview := next_color
		preview.a = PREVIEW_ALPHA
		draw_circle(_inside(get_global_mouse_position(), next_radius), next_radius, preview)
	# The legend: the four colours and their keys, the picked one ringed.
	var font := ThemeDB.fallback_font
	draw_string(font, LEGEND_ORIGIN, "Next click", HORIZONTAL_ALIGNMENT_LEFT, -1.0, LEGEND_FONT_SIZE, Color(0.85, 0.85, 0.92))
	for i: int in ColorMergeWorld.PALETTE.size():
		var colour := ColorMergeWorld.PALETTE[i]
		var centre := LEGEND_ORIGIN + Vector2(18.0, LEGEND_ROW * (i + 1) - 8.0)
		var picked := colour == next_color
		draw_circle(centre, 15.0, colour)
		if picked:
			draw_arc(centre, 21.0, 0.0, TAU, 32, Color.WHITE, 3.0, true)
		var text := "%d  %s" % [i + 1, ColorMergeWorld.PALETTE_NAMES[i]]
		var shade := Color.WHITE if picked else Color(0.7, 0.7, 0.78)
		draw_string(font, centre + Vector2(34.0, 8.0), text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, LEGEND_FONT_SIZE, shade)
