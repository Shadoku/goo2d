class_name GodotPhysicsExample
extends Node2D
## The godot_physics example's scene (docs/godot-physics.md): goo meeting Godot's own
## physics nodes. Both kinds of goo have physics_proxies and push_bodies on: a ring world
## (a round blob, a square blob with a rigid crate resting on it, a small blob a paddle
## pushes in and out of a sensor) and a cell world (a creature of cells a character walks
## into and back from). The sensor, an Area2D, lights up while goo is inside it
## (body_entered / body_exited); the crate, a RigidBody2D on the wall layer, presses on
## the square and takes the goo's reaction; the paddle, an AnimatableBody2D, sweeps the
## small blob along; the character, a CharacterBody2D whose mask has the proxies' layer,
## is stopped by the creature and turns round. Drag a ring body with the mouse; R builds
## the scene again.

## The canvas size this scene is laid out for: it gives the window's canvas this size
## while it is in the tree.
const LAYOUT_SIZE := Vector2i(1920, 1080)
## The floor's top and the walls' inner faces.
const FLOOR_Y: float = 980.0
const LEFT_X: float = 80.0
const RIGHT_X: float = 1840.0
## The ring bodies: a round blob, a square, and the small blob the paddle pushes.
const ROUND_AT := Vector2(300.0, FLOOR_Y - 70.0)
const ROUND_RADIUS: float = 70.0
const SQUARE_AT := Vector2(560.0, FLOOR_Y - 64.0)
const SQUARE_RADIUS: float = 64.0
const SMALL_AT := Vector2(820.0, FLOOR_Y - 40.0)
const SMALL_RADIUS: float = 40.0
## The crate on the square: its size and mass over the square's.
const CRATE_SIZE := Vector2(96.0, 96.0)
const CRATE_MASS_RATIO: float = 0.5
## The sensor: its rectangle (global).
const SENSOR := Rect2(980.0, FLOOR_Y - 160.0, 160.0, 160.0)
## The paddle, a cup of two bars PADDLE_GAP apart with the small blob between them: a
## bar's size, the middle of its sweep and how far and how often it swings (from
## SMALL_AT.x to SMALL_AT.x + PADDLE_SWING and back), carrying the blob in and out of the
## sensor.
const PADDLE_SIZE := Vector2(24.0, 110.0)
const PADDLE_GAP: float = 200.0
const PADDLE_Y: float = FLOOR_Y - 60.0
const PADDLE_SWING: float = 480.0
const PADDLE_HZ: float = 0.2
## The creature: its centre, rings of cells and cell radius.
const CREATURE_AT := Vector2(1580.0, FLOOR_Y - 62.0)
const CREATURE_RINGS: int = 3
const CELL_RADIUS: float = 10.0
## The character: its size, where it starts and how fast it walks.
const CHARACTER_SIZE := Vector2(36.0, 72.0)
const CHARACTER_AT := Vector2(1790.0, FLOOR_Y - 37.0)
const CHARACTER_SPEED: float = 160.0

const SENSOR_OFF := Color(0.3, 0.9, 0.6, 0.12)
const SENSOR_ON := Color(0.3, 0.9, 0.6, 0.45)

@onready var _world: GodotPhysicsWorld = $World
@onready var _cells: GooCellWorld2D = $Cells
@onready var _label: Label = $UI/Label

## The nodes build() makes.
var sensor: Area2D
var crate: RigidBody2D
var paddle: AnimatableBody2D
var character: CharacterBody2D
## The goo inside the sensor now, and how often it lit up.
var inside: Array[Node2D] = []
var lit_count: int = 0
## Seconds since build() (the paddle's clock).
var time: float = 0.0

var _sensor_look: Polygon2D
var _walk: float = -1.0
var _grab: int = -1
var _built: Array[Node] = []
var _previous_size: Vector2i
var _previous_stretch: Window.ContentScaleStretch

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

## The ring world and the cell world.
func world() -> GodotPhysicsWorld:
	return _world

func cell_world() -> GooCellWorld2D:
	return _cells

## Builds the bodies, the crate, the sensor, the paddle and the character again.
func build() -> void:
	_world.clear()
	_cells.clear()
	for node: Node in _built:
		if is_instance_valid(node):
			node.queue_free()
	_built.clear()
	inside.clear()
	lit_count = 0
	time = 0.0
	_grab = -1
	_walk = -1.0
	var round := _world.spawn(ROUND_RADIUS, ROUND_AT)
	round.color = Color(0.35, 0.75, 0.95)
	var square := _world.spawn(SQUARE_RADIUS, SQUARE_AT, GooShape.regular(4, SQUARE_RADIUS))
	square.color = Color(0.95, 0.75, 0.3)
	var small := _world.spawn(SMALL_RADIUS, SMALL_AT)
	small.color = Color(0.95, 0.45, 0.5)
	var creature := _cells.spawn(GooCellDesign.hex_blob(CREATURE_RINGS, CELL_RADIUS), Transform2D(0.0, CREATURE_AT))
	creature.data["name"] = "creature"
	sensor = Area2D.new()
	sensor.name = "Sensor"
	sensor.collision_layer = 0
	sensor.collision_mask = GooTuning.LAYER_PROXIES
	sensor.position = SENSOR.get_center()
	sensor.add_child(_box(SENSOR.size))
	_sensor_look = _polygon(SENSOR.size, SENSOR_OFF)
	sensor.add_child(_sensor_look)
	sensor.body_entered.connect(_on_entered)
	sensor.body_exited.connect(_on_exited)
	_add(sensor)
	crate = RigidBody2D.new()
	crate.name = "Crate"
	crate.collision_layer = GooTuning.LAYER_WALLS
	crate.collision_mask = GooTuning.LAYER_WALLS
	crate.mass = CRATE_MASS_RATIO * square.body_mass()
	crate.position = Vector2(SQUARE_AT.x, square.bead_bounds().position.y - CRATE_SIZE.y / 2.0 - 2.0)
	crate.add_child(_box(CRATE_SIZE))
	crate.add_child(_polygon(CRATE_SIZE, Color(0.55, 0.38, 0.22)))
	_add(crate)
	paddle = AnimatableBody2D.new()
	paddle.name = "Paddle"
	paddle.sync_to_physics = false
	paddle.collision_layer = GooTuning.LAYER_WALLS
	paddle.collision_mask = 0
	paddle.position = Vector2(SMALL_AT.x, PADDLE_Y)
	for side: float in [-1.0, 1.0]:
		var bar := _box(PADDLE_SIZE)
		bar.position.x = side * PADDLE_GAP / 2.0
		paddle.add_child(bar)
		var look := _polygon(PADDLE_SIZE, Color(0.7, 0.72, 0.78))
		look.position.x = bar.position.x
		paddle.add_child(look)
	_add(paddle)
	character = CharacterBody2D.new()
	character.name = "Character"
	character.collision_layer = 0
	character.collision_mask = GooTuning.LAYER_WALLS | GooTuning.LAYER_PROXIES
	character.position = CHARACTER_AT
	character.add_child(_box(CHARACTER_SIZE))
	character.add_child(_polygon(CHARACTER_SIZE, Color(0.85, 0.85, 0.95)))
	_add(character)
	_update_label()

func _add(node: Node) -> void:
	add_child(node)
	_built.append(node)

static func _box(size: Vector2) -> CollisionShape2D:
	var shape := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = size
	shape.shape = rect
	return shape

static func _polygon(size: Vector2, colour: Color) -> Polygon2D:
	var look := Polygon2D.new()
	var h := size / 2.0
	look.polygon = PackedVector2Array([Vector2(-h.x, -h.y), Vector2(h.x, -h.y), Vector2(h.x, h.y), Vector2(-h.x, h.y)])
	look.color = colour
	return look

func _on_entered(body: Node2D) -> void:
	if not inside.has(body):
		inside.append(body)
	if inside.size() == 1:
		lit_count += 1
	_sensor_look.color = SENSOR_ON

func _on_exited(body: Node2D) -> void:
	inside.erase(body)
	if inside.is_empty():
		_sensor_look.color = SENSOR_OFF

func _physics_process(delta: float) -> void:
	time += delta
	if is_instance_valid(paddle):
		paddle.position.x = SMALL_AT.x + PADDLE_SWING * 0.5 * (1.0 - cos(TAU * PADDLE_HZ * time))
	if is_instance_valid(character):
		character.velocity.x = CHARACTER_SPEED * _walk
		character.velocity.y += GooTuning.gravity() * delta
		character.move_and_slide()
		if character.is_on_wall():
			_walk = -_walk

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
	_label.text = "Godot physics: a sensor (Area2D) lit by goo, a crate (RigidBody2D) on a square blob, a paddle (AnimatableBody2D)" \
		+ "\ncarrying a blob, a character (CharacterBody2D) stopped by a creature  ·  drag a blob  ·  R: build again"
