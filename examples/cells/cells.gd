class_name CellsExample
extends Node2D
## The cells example's scene: a top-down tank (a GooCellWorld2D with gravity_scale 0 inside
## walls, a concave rock in the middle) of creatures made of cells, one disc particle each
## (docs/cells.md): a worm 24 × 5 driven by its swim drive (its spine row pushing hardest)
## with a gentle pose wave as its visible stroke, steered toward points round the tank by
## the wave's curvature bias alone (WORM), a blob pushed by a ring of thruster cells at its back and turned
## by the solver's spin servo (BLOB), a mixed-size creature from a saved design (mixed.tres) drifting, and
## a crawler of three shape-matched segments whose two joints swing (CRAWLER). The water
## turns slowly round the tank's middle (the world's water_source, per cell). Drag a
## creature with the mouse; R builds the tank again.

## The canvas size this scene is laid out for.
const LAYOUT_SIZE := Vector2i(1920, 1080)
## The cells' radius in the built designs.
const RADIUS: float = 14.0
## Where each creature starts and which way it faces.
const WORM_AT := Vector2(620.0, 260.0)
const BLOB_AT := Vector2(1380.0, 820.0)
const MIXED_AT := Vector2(1480.0, 300.0)
const CRAWLER_AT := Vector2(560.0, 840.0)
## The worm's stroke: slope, frequency (Hz), and how hard it steers (curvature per rad).
## A toned-down stroke: the swim drive does most of the work, the wave shows it.
const WORM_SLOPE: float = 0.3
const WORM_HZ: float = 0.8
const WORM_STEER: float = 0.0025
## The worm's swim drive (px/s²), its ripple with the stroke, and its spine row's share.
const WORM_SWIM: float = 55.0
const WORM_PULSE: float = 0.3
const SPINE_SWIM: float = 2.0
## The blob's thrusters (force per cell, × its mass) and its spin servo: the fastest spin
## (rad/s), the servo's angular acceleration (rad/s²; it brakes at 0.8 of it), its rim's
## top speed (px/s) and how far it yields to what it touches (docs/cells.md, "Turning by the
## spin servo": a tame setting).
const THRUST: float = 600.0
const BLOB_SPIN: float = 3.0
const BLOB_TURN: float = 12.0
const BLOB_TIP: float = 500.0
const BLOB_YIELD: float = 0.3
## The crawler's joints' swing (rad) and frequency (Hz).
const SWING: float = 0.45
const SWING_HZ: float = 0.6
## The swirl's speed (px/s at the tank's edge) and centre.
const SWIRL_SPEED: float = 40.0
const SWIRL_CENTER := Vector2(960.0, 580.0)
## Waypoints the swimmers head for in turn.
const WAYPOINTS: Array[Vector2] = [Vector2(460, 300), Vector2(1460, 300), Vector2(1460, 860), Vector2(460, 860)]

const MIXED := preload("res://examples/cells/mixed.tres")

@onready var _world: GooCellWorld2D = $World
@onready var _label: Label = $UI/Label

var worm: GooCellCreature
var blob: GooCellCreature
var mixed: GooCellCreature
var crawler: GooCellCreature
## The types the built designs use.
var body_type: GooCellType
var spine_type: GooCellType
var thruster_type: GooCellType
var segment_type: GooCellType
## Seconds since the tank was built.
var time: float = 0.0

var _goal: Dictionary = {}
var _thrusters: Array[int] = []
var _grab: int = -1
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
	body_type = _type(&"body", Color(0.36, 0.78, 0.5))
	spine_type = _type(&"spine", Color(0.35, 0.6, 0.95))
	spine_type.swim_weight = SPINE_SWIM
	thruster_type = _type(&"thruster", Color(0.98, 0.55, 0.25))
	thruster_type.behaviours = {"thrust": THRUST}
	segment_type = _type(&"segment", Color(0.75, 0.55, 0.95))
	segment_type.body = GooCellType.Body.SHAPE
	_world.water_source = swirl
	build()

## The world the creatures live in.
func world() -> GooCellWorld2D:
	return _world

static func _type(type_name: StringName, colour: Color) -> GooCellType:
	var t := GooCellType.new()
	t.name = type_name
	t.color = colour
	return t

## The water's velocity at `points`: a slow swirl round SWIRL_CENTER (clockwise).
func swirl(points: PackedVector2Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	out.resize(points.size())
	for i: int in points.size():
		var d := points[i] - SWIRL_CENTER
		out[i] = d.orthogonal() * (-SWIRL_SPEED / 500.0) if d.length() < 500.0 else d.orthogonal().normalized() * -SWIRL_SPEED
	return out

## The worm: a hex worm 24 × 5 of body cells with a spine row.
func worm_design() -> GooCellDesign:
	var d := GooCellDesign.hex_worm(24, 5, RADIUS)
	d.types = [body_type, spine_type]
	for i: int in d.cell_count():
		if absf(d.positions[i].y) < 1.0:
			d.cell_types[i] = 1
	return d

## The blob: a hex blob of four rings, its back rim of thrusters pointing forward.
func blob_design() -> GooCellDesign:
	var d := GooCellDesign.hex_blob(4, RADIUS)
	d.types = [body_type, thruster_type]
	var reach := 0.0
	for p: Vector2 in d.positions:
		reach = maxf(reach, p.length())
	for i: int in d.cell_count():
		var p := d.positions[i]
		if p.length() > 0.85 * reach and p.x < -RADIUS:
			d.cell_types[i] = 1
	return d

## The crawler: a worm 12 × 3 of three shape-matched segments (groups 0, 1, 2).
func crawler_design() -> GooCellDesign:
	var d := GooCellDesign.new()
	d.types = [segment_type]
	for row: int in 3:
		var y := (row - 1) * 2.0 * RADIUS * 0.8660254
		var shift := RADIUS if row % 2 == 1 else 0.0
		for k: int in 12:
			d.add_cell(Vector2((k - 5.5) * 2.0 * RADIUS + shift, y), RADIUS, 0, k / 4)
	return d

## Empties the tank and spawns the four creatures.
func build() -> void:
	_world.clear()
	_grab = -1
	time = 0.0
	worm = _world.spawn(worm_design(), Transform2D(0.0, WORM_AT))
	blob = _world.spawn(blob_design(), Transform2D(0.0, BLOB_AT))
	mixed = _world.spawn(MIXED, Transform2D(0.0, MIXED_AT))
	crawler = _world.spawn(crawler_design(), Transform2D(0.0, CRAWLER_AT))
	_goal = {worm: 1, blob: 3}
	_thrusters.clear()
	for i: int in blob.cell_count():
		if blob.cell_type(i) == thruster_type:
			_thrusters.append(i)
	worm.set_pose_wave(WORM_SLOPE, worm.design.length(), WORM_HZ)
	worm.set_swim(WORM_SWIM, WORM_PULSE)
	blob.set_spin_servo(0.0, BLOB_TURN, BLOB_TIP, BLOB_YIELD)
	_update_label()

## The waypoint a swimmer heads for now.
func goal_of(creature: GooCellCreature) -> Vector2:
	return WAYPOINTS[_goal.get(creature, 0)]

func _steer(creature: GooCellCreature) -> float:
	var to := goal_of(creature) - creature.center()
	if to.length() < 180.0:
		_goal[creature] = (_goal.get(creature, 0) + 1) % WAYPOINTS.size()
	return wrapf(to.angle() - creature.heading().angle(), -PI, PI)

func _physics_process(delta: float) -> void:
	time += delta
	if worm != null and worm.is_alive():
		var err := _steer(worm)
		worm.set_pose_wave(WORM_SLOPE, worm.design.length(), WORM_HZ, clampf(err, -1.0, 1.0) * WORM_STEER)
	if blob != null and blob.is_alive():
		var err := _steer(blob)
		# The servo's target each frame: the fastest spin that stops on the heading.
		blob.set_spin_target(GooCellCreature.spin_toward(err, BLOB_SPIN, 0.8 * BLOB_TURN, delta))
		# Thrust only while it roughly faces its goal: it turns on the spot first.
		var throttle := maxf(0.0, cos(err))
		for i: int in _thrusters:
			blob.set_cell_thrust(i, throttle * THRUST * PI * RADIUS * RADIUS)
	if crawler != null and crawler.is_alive():
		var phase := TAU * SWING_HZ * time
		crawler.set_joint_angle(segment_type, 0, segment_type, 1, SWING * sin(phase))
		crawler.set_joint_angle(segment_type, 1, segment_type, 2, SWING * sin(phase - PI / 2.0))

func _unhandled_input(event: InputEvent) -> void:
	var mouse := event as InputEventMouseButton
	var motion := event as InputEventMouseMotion
	var key := event as InputEventKey
	if mouse != null and mouse.button_index == MOUSE_BUTTON_LEFT:
		var at := (make_input_local(mouse) as InputEventMouseButton).position
		if mouse.pressed:
			var creature := _world.creature_at(at)
			if creature != null:
				_grab = _world.grab(creature, at)
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
	var cells := 0
	for c: GooCellCreature in _world.creatures():
		cells += c.cell_count()
	_label.text = "Cells: creatures of one disc particle per cell (GooCellWorld2D)    Creatures: %d    Cells: %d\n" % [_world.creatures().size(), cells] \
		+ "Worm: swim drive, a gentle pose wave    Blob: thrusters    Mixed sizes: mixed.tres    Crawler: three jointed segments    The water swirls    Drag a creature    R: rebuild"
