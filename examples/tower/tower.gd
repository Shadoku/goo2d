class_name TowerExample
extends Node2D
## The tower example's scene: a tower-building minigame. Square goo blocks
## (GooShape.regular(4, Hopper.block_radius), each the next colour of PALETTE)
## drop from the Hopper onto a narrow Platform standing on a wide Floor; a block
## that falls off the platform is despawned (TowerWorld). The game is won once
## the stack stands above the GoalLine; R starts over.
##
## Controls: click drops a block at the mouse's x (within the hopper's range),
## Space drops one at the hopper's centre, R resets. A new block can drop
## DROP_INTERVAL seconds after the last.
##
## With `demo` on, the scene drops `demo_blocks` seeded blocks near the centre
## on its own at the start, each once the last rests on the stack, until the
## first click or key: a screenshot (or a player who just watches) sees a tower.
##
## Everything a designer moves is a node in tower.tscn: the Platform and the
## Floor (TowerSlab: resize their collision rectangles), the GoalLine
## (TowerGoalLine: move it up or down), the Hopper (TowerHopper: its width and
## the block size); the World (TowerWorld) holds the stiffness knobs and finds
## the platform and the goal line through its NodePaths.

## Emitted for every block dropped (drop()).
signal dropped(body: Goo2D)

## The canvas size this scene is laid out for: it gives the window's canvas
## this size while it is in the tree (the project's own, the game's, is
## 960 × 528).
const LAYOUT_SIZE := Vector2i(1920, 1080)

## The colours the blocks cycle through, one per block.
const PALETTE: Array[Color] = [
	Color(0.95, 0.36, 0.36),
	Color(1.0, 0.72, 0.25),
	Color(0.36, 0.84, 0.48),
	Color(0.3, 0.62, 1.0),
	Color(0.74, 0.46, 0.98),
]
## Seconds after a drop before the player may drop again.
const DROP_INTERVAL: float = 0.8
## Largest distance, in px, a demo block lands off the hopper's centre (drawn
## from rng): a demo tower is not perfectly straight either.
const DEMO_JITTER: float = 3.0
## Seconds the last demo block must rest on the stack before the next drops.
const DEMO_REST: float = 0.25
## Seconds after which the demo drops the next block anyway (the last one fell
## off, or never comes to rest).
const DEMO_MAX_WAIT: float = 3.5

## Drop demo_blocks blocks on its own at the start, until the first click or key.
@export var demo: bool = true
## How many blocks the demo drops (one fewer than the goal needs, so the
## player places the winning block).
@export_range(0, 12) var demo_blocks: int = 4

## Draws every random number (the demo's jitter). Seed it before the scene
## enters the tree to replay a demo.
var rng := RandomNumberGenerator.new()
## Blocks dropped since the start or the last reset() (the next one's colour
## is PALETTE[drops % PALETTE.size()]).
var drops: int = 0

var _cooldown: float = 0.0
var _demo_dropped: int = 0
var _demo_wait: float = 0.0
var _demo_rest: float = 0.0
var _last_drop: Goo2D = null

@onready var _world: TowerWorld = $World
@onready var _hopper: TowerHopper = $Hopper
@onready var _goal: TowerGoalLine = $GoalLine
@onready var _label: Label = $UI/Label
@onready var _banner: Label = $UI/Banner

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
	_world.won.connect(_on_won)
	_hopper.next_color = next_color()
	_update_label()
	GooSkin.warm_up(self)

## The world the blocks live in.
func world() -> TowerWorld:
	return _world

## The hopper the blocks drop from.
func hopper() -> TowerHopper:
	return _hopper

## The goal line.
func goal_line() -> TowerGoalLine:
	return _goal

## Equivalent radius, in px, of every block (the hopper's block_radius).
func block_radius() -> float:
	return _hopper.block_radius

## Colour of the next block.
func next_color() -> Color:
	return PALETTE[drops % PALETTE.size()]

## Drops the next block from the hopper at global `x` (clamped into the
## hopper's range): a square of block_radius() in next_color(), at rest.
## Emits dropped and returns it. Ignores the drop interval and the win (input
## respects both).
func drop(x: float) -> Goo2D:
	var radius := block_radius()
	var body := _world.spawn(radius, _hopper.drop_point(x), GooShape.regular(4, radius))
	body.color = next_color()
	drops += 1
	_cooldown = DROP_INTERVAL
	_last_drop = body
	_hopper.next_color = next_color()
	dropped.emit(body)
	return body

## Empties the world, clears the win and starts the colours over (the demo
## does not start again).
func reset() -> void:
	_world.reset()
	drops = 0
	_cooldown = 0.0
	_last_drop = null
	_hopper.next_color = next_color()
	_update_label()

func _physics_process(delta: float) -> void:
	_cooldown = maxf(_cooldown - delta, 0.0)
	if demo and _demo_dropped < demo_blocks:
		_run_demo(delta)

func _process(_delta: float) -> void:
	_hopper.ready_to_drop = _cooldown <= 0.0 and not _world.has_won
	_goal.reached = _world.has_won
	_banner.visible = _world.has_won
	_update_label()

# Drops the next demo block once the last one rests on the stack (or after
# DEMO_MAX_WAIT).
func _run_demo(delta: float) -> void:
	_demo_wait += delta
	var last_rests := _last_drop == null or not is_instance_valid(_last_drop) \
		or _world.stack().has(_last_drop)
	_demo_rest = _demo_rest + delta if last_rests else 0.0
	if _demo_rest < DEMO_REST and _demo_wait < DEMO_MAX_WAIT:
		return
	drop(_hopper.global_position.x + rng.randf_range(-DEMO_JITTER, DEMO_JITTER))
	_demo_dropped += 1
	_demo_wait = 0.0
	_demo_rest = 0.0

func _unhandled_input(event: InputEvent) -> void:
	var motion := event as InputEventMouseMotion
	var mouse := event as InputEventMouseButton
	var key := event as InputEventKey
	if motion != null:
		_hopper.aim_x = (make_input_local(motion) as InputEventMouseMotion).position.x
		return
	if mouse != null and mouse.pressed and mouse.button_index == MOUSE_BUTTON_LEFT:
		demo = false
		var x := (make_input_local(mouse) as InputEventMouseButton).position.x
		_hopper.aim_x = x
		_try_drop(x)
	elif key != null and key.pressed and not key.echo and key.keycode == KEY_SPACE:
		demo = false
		_try_drop(_hopper.global_position.x)
	elif key != null and key.pressed and not key.echo and key.keycode == KEY_R:
		demo = false
		reset()
	else:
		return
	get_viewport().set_input_as_handled()

# A player's drop: only once the drop interval has passed and before the win.
func _try_drop(x: float) -> void:
	if _cooldown <= 0.0 and not _world.has_won:
		drop(x)

func _on_won() -> void:
	_goal.reached = true
	_update_label()

func _update_label() -> void:
	if _label == null:
		return
	var goal := _world.goal_height()
	var height := _world.tower_height()
	var text := "Tower: %d px of %d px      Blocks standing: %d      Dropped: %d" \
		% [roundi(height), roundi(goal), _world.stack().size(), drops]
	if _world.has_won:
		text += "\nThe tower stands above the goal line: you win!      R: play again"
	else:
		text += "\nStack the blocks above the goal line.      Click: drop at the mouse      Space: drop at the centre      R: reset"
	if _label.text != text:
		_label.text = text
