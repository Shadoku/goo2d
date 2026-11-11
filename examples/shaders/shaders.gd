class_name ShadersExample
extends Node2D
## The `shaders` example: the same goo drawn by three skin shaders side by side.
## Three GooWorld2D columns (GooWorld, CelWorld, GemWorld), each with its own
## floor and walls and its own `skin_shader` (set in the scene: none, so the
## addon's goo; assets/goo/cel.gdshader; assets/goo/gem.gdshader). Every
## `drop_interval` seconds the same next body (size, shape and place in the
## column, from `rng`) drops into all three, so the columns show the same
## bodies in three looks (they drift apart as the goo settles a little
## differently in each); a column over
## MAX_BODIES bodies, or MAX_FILL full, loses its oldest, and a body pushed out
## of its column goes. A click drops the next body at the mouse, in the column
## under it; R clears every column.

## The canvas size this scene is laid out for: it gives the window's canvas
## this size while it is in the tree (the project's own, the game's, is
## 960 × 528).
const LAYOUT_SIZE := Vector2i(1920, 1080)

## Bodies a column keeps: a drop over this despawns the column's oldest body.
const MAX_BODIES: int = 8
## The share of a column's inside the bodies may cover: past it the oldest go
## too (merged bodies are big, and a full column pushes new drops out over
## its walls).
const MAX_FILL: float = 0.4
## The drops' radii (px), in the order they come.
const SIZES: PackedFloat32Array = [32.0, 54.0, 76.0, 98.0, 120.0]
## The drops' shapes, in the order they come, by their number of sides (0:
## round). Three shapes against five sizes: every size comes in every shape.
const SHAPES: PackedInt32Array = [0, 4, 6]
## The middle of each column, global x, left to right (the scene's walls are
## built around these).
const COLUMN_X: PackedFloat32Array = [330.0, 960.0, 1590.0]
## Half the inside width of a column, px (the walls' inner faces).
const HALF_WIDTH: float = 280.0
## The top of the floors, px.
const FLOOR_Y: float = 1000.0
## The top of the walls, px: drops start below it.
const WALL_TOP_Y: float = 140.0
## Gap, px, between a drop and the walls and the top of the walls.
const DROP_MARGIN: float = 8.0

## Seconds between two automatic drops.
@export var drop_interval: float = 1.0
## Whether the scene drops on its own every drop_interval (tests turn it off
## to drop by hand).
@export var auto_drop: bool = true
## The seed `rng` starts from, and starts from again on reset().
@export var drop_seed: int = 7

## Where in its column the next drop lands (its x offset). Seeded from
## drop_seed; replace it or reseed it for another sequence.
var rng: RandomNumberGenerator = RandomNumberGenerator.new()
## How many drops so far (one per drop_next() or drop_at()), since the last
## reset(). The next drop's size and shape follow from it.
var drops: int = 0

var _since_drop: float = 0.0
var _cap_scheduled: bool = false

@onready var _worlds: Array[GooWorld2D] = [$GooWorld, $CelWorld, $GemWorld]

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

func _ready() -> void:
	rng.seed = drop_seed
	# Compile each skin shader now: no hitch on the first body, and the render
	# stage of check.py sees both shaders' errors.
	GooSkin.warm_up(self)
	for world: GooWorld2D in _worlds:
		if world.skin_shader != null:
			GooSkin.warm_up(self, world.skin_shader)
		# A pinch can split a body in two between drops: the cap holds then too.
		world.count_changed.connect(_on_count_changed)

func _physics_process(delta: float) -> void:
	_despawn_escaped()
	if not auto_drop:
		return
	_since_drop += delta
	if _since_drop >= drop_interval:
		_since_drop -= drop_interval
		drop_next()

func _unhandled_input(event: InputEvent) -> void:
	var click := event as InputEventMouseButton
	if click != null and click.pressed and click.button_index == MOUSE_BUTTON_LEFT:
		drop_at(get_global_mouse_position())
		get_viewport().set_input_as_handled()
		return
	var key := event as InputEventKey
	if key != null and key.pressed and not key.echo and key.keycode == KEY_R:
		reset()
		get_viewport().set_input_as_handled()

## The three columns' worlds, left to right.
func worlds() -> Array[GooWorld2D]:
	return _worlds

## The world of `column` (0, 1, 2: left to right).
func world(column: int) -> GooWorld2D:
	return _worlds[column]

## The column whose walls hold the global x `x` (the nearest one in a gap).
func column_at(x: float) -> int:
	var best := 0
	for column: int in _worlds.size():
		if absf(x - column_center(column).x) < absf(x - column_center(best).x):
			best = column
	return best

## The middle of `column`'s floor, global space: x between its walls, y the
## top of its floor.
func column_center(column: int) -> Vector2:
	return Vector2(COLUMN_X[column], FLOOR_Y)

## The radius of the next drop, px.
func next_radius() -> float:
	return SIZES[drops % SIZES.size()]

## The number of sides of the next drop's shape (0: round).
func next_sides() -> int:
	return SHAPES[drops % SHAPES.size()]

## Drops the next body into every column at the same spot in each (a random x
## between its walls, just below their top) and returns the bodies, left to
## right.
func drop_next() -> Array[Goo2D]:
	var radius := next_radius()
	var room := HALF_WIDTH - radius - DROP_MARGIN
	var offset := Vector2(rng.randf_range(-room, room), WALL_TOP_Y + DROP_MARGIN + radius - FLOOR_Y)
	var dropped: Array[Goo2D] = []
	for column: int in _worlds.size():
		dropped.append(_drop(column, column_center(column) + offset))
	drops += 1
	return dropped

## Drops the next body at `global_pos` (kept clear of the walls and the floor)
## into the column under it only, and returns it.
func drop_at(global_pos: Vector2) -> Goo2D:
	var column := column_at(global_pos.x)
	var radius := next_radius()
	var room := HALF_WIDTH - radius - DROP_MARGIN
	var center := column_center(column)
	var at := Vector2(clampf(global_pos.x, center.x - room, center.x + room),
		clampf(global_pos.y, WALL_TOP_Y - radius, FLOOR_Y - radius - DROP_MARGIN))
	var body := _drop(column, at)
	drops += 1
	return body

## Removes every body from every column and starts the drop sequence over.
func reset() -> void:
	for world: GooWorld2D in _worlds:
		world.clear()
	drops = 0
	_since_drop = 0.0
	rng.seed = drop_seed

# Spawns the next drop's body in `column` at `at`, then despawns that column's
# oldest bodies while it holds more than MAX_BODIES.
func _drop(column: int, at: Vector2) -> Goo2D:
	var world := _worlds[column]
	var radius := next_radius()
	var sides := next_sides()
	var shape: GooShape = GooShape.regular(sides, radius) if sides > 0 else null
	var body := world.spawn(radius, at, shape)
	_cap(world)
	return body

# Despawns `world`'s oldest bodies while it holds more than MAX_BODIES or they
# cover more than MAX_FILL of its column (the newest one always stays).
func _cap(world: GooWorld2D) -> void:
	var bodies := world.bodies()
	var room := MAX_FILL * 2.0 * HALF_WIDTH * (FLOOR_Y - WALL_TOP_Y)
	var area := 0.0
	for body: Goo2D in bodies:
		area += PI * body.radius * body.radius
	while bodies.size() > 1 and (bodies.size() > MAX_BODIES or area > room):
		area -= PI * bodies[0].radius * bodies[0].radius
		world.despawn(bodies[0])
		bodies = world.bodies()

# Despawns any body that left its column (pushed out over a wall, or through
# it): its centre outside the column's walls, above the screen or below the
# floor.
func _despawn_escaped() -> void:
	for column: int in _worlds.size():
		var center := column_center(column)
		for body: Goo2D in _worlds[column].bodies():
			var at := body.center()
			if not at.is_finite() or absf(at.x - center.x) > HALF_WIDTH or at.y < 0.0 or at.y > FLOOR_Y:
				_worlds[column].despawn(body)

# A column's body count changed (a drop, a merge, a split): caps every column
# once the frame's physics is done (despawn() is not for the physics flush).
func _on_count_changed(count: int) -> void:
	if count > MAX_BODIES and not _cap_scheduled:
		_cap_scheduled = true
		_cap_all.call_deferred()

func _cap_all() -> void:
	_cap_scheduled = false
	for world: GooWorld2D in _worlds:
		_cap(world)
