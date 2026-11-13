class_name RingsAndCellsExample
extends Node2D
## The rings-and-cells example's scene: a top-down tank holding both kinds of goo, ring
## bodies (Rings, a GooWorld2D) and creatures made of cells (Cells, a GooCellWorld2D whose
## ring_world is Rings), coupled so they collide (docs/cells.md, "Rings and cells"): seven
## rings of several sizes and shapes (RINGS) drift in the middle; a worm swims round the
## tank by its pose wave through them (WORM), a blob is pushed toward a ring
## (BLOB), a different one every BLOB_SWITCH seconds, and shoves it about, and a small blob
## drifts. Drag a ring or a creature with the
## mouse; R builds the tank again.

## The canvas size this scene is laid out for.
const LAYOUT_SIZE := Vector2i(1920, 1080)
## The cells' radius in the built designs.
const RADIUS: float = 14.0
## The rings: [centre, radius, sides (0 round), colour].
const RINGS: Array[Array] = [
	[Vector2(820, 470), 46.0, 0, Color(0.95, 0.55, 0.3)],
	[Vector2(960, 590), 36.0, 0, Color(0.95, 0.8, 0.3)],
	[Vector2(1100, 470), 56.0, 4, Color(0.9, 0.4, 0.5)],
	[Vector2(900, 720), 30.0, 0, Color(0.55, 0.85, 0.95)],
	[Vector2(1060, 740), 40.0, 3, Color(0.75, 0.55, 0.95)],
	[Vector2(1240, 640), 32.0, 0, Color(0.6, 0.9, 0.45)],
	[Vector2(700, 640), 38.0, 0, Color(0.95, 0.65, 0.75)],
]
## The worm: where it starts, its stroke (slope, frequency) and steering (curvature per rad).
const WORM_AT := Vector2(560.0, 260.0)
const WORM_HZ: float = 0.8
const WORM_STEER: float = 0.0025
## The blob: where it starts, its push toward the ring it shoves (px/s²) and how long it
## shoves each ring (s).
const BLOB_AT := Vector2(1450.0, 860.0)
const BLOB_PUSH: float = 260.0
const BLOB_SWITCH: float = 3.0
const SMALL_AT := Vector2(500.0, 860.0)
## Waypoints the worm heads for in turn, round the rings.
const WAYPOINTS: Array[Vector2] = [Vector2(460, 300), Vector2(1460, 300), Vector2(1460, 860), Vector2(460, 860)]

@onready var _rings: RingsAndCellsWorld = $Rings
@onready var _cells: GooCellWorld2D = $Cells
@onready var _label: Label = $UI/Label

var worm: GooCellCreature
var blob: GooCellCreature
var small: GooCellCreature
var body_type: GooCellType
var spine_type: GooCellType

var _goal: int = 1
var _time: float = 0.0
var _grab: int = -1
var _grab_ring: int = -1
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
	body_type = GooCellType.new()
	body_type.color = Color(0.36, 0.78, 0.5)
	spine_type = GooCellType.new()
	spine_type.color = Color(0.35, 0.6, 0.95)
	build()

## The ring world and the cell world.
func rings() -> RingsAndCellsWorld:
	return _rings

func cells() -> GooCellWorld2D:
	return _cells

## Empties the tank and spawns the rings and the creatures.
func build() -> void:
	_rings.clear()
	_cells.clear()
	_grab = -1
	_grab_ring = -1
	_goal = 1
	_time = 0.0
	for r: Array in RINGS:
		var body := _rings.spawn(r[1], r[0], GooShape.regular(r[2], r[1]) if r[2] >= 3 else null)
		body.color = r[3]
	var d := GooCellDesign.hex_worm(18, 4, RADIUS)
	d.types = [body_type, spine_type]
	for i: int in d.cell_count():
		if absf(d.positions[i].y) < RADIUS:
			d.cell_types[i] = 1
	worm = _cells.spawn(d, Transform2D(0.0, WORM_AT))
	worm.set_pose_wave(1.0, worm.design.length(), WORM_HZ)
	blob = _cells.spawn(GooCellDesign.hex_blob(3, RADIUS), Transform2D(0.0, BLOB_AT))
	small = _cells.spawn(GooCellDesign.hex_blob(1, RADIUS), Transform2D(0.0, SMALL_AT))
	_update_label()

## The ring the blob shoves now: the rings in turn, BLOB_SWITCH seconds each (null: none).
func blob_target() -> Goo2D:
	var all := _rings.bodies()
	if all.is_empty():
		return null
	return all[int(_time / BLOB_SWITCH) % all.size()]

func _physics_process(delta: float) -> void:
	_time += delta
	if worm != null and worm.is_alive():
		var to := WAYPOINTS[_goal] - worm.center()
		if to.length() < 180.0:
			_goal = (_goal + 1) % WAYPOINTS.size()
		var err := wrapf(to.angle() - worm.heading().angle(), -PI, PI)
		worm.set_pose_wave(1.0, worm.design.length(), WORM_HZ, clampf(err, -1.0, 1.0) * WORM_STEER)
	if blob != null and blob.is_alive():
		var ring := blob_target()
		if ring != null:
			blob.push((ring.center() - blob.center()).normalized() * BLOB_PUSH)

func _unhandled_input(event: InputEvent) -> void:
	var mouse := event as InputEventMouseButton
	var motion := event as InputEventMouseMotion
	var key := event as InputEventKey
	if mouse != null and mouse.button_index == MOUSE_BUTTON_LEFT:
		var at := (make_input_local(mouse) as InputEventMouseButton).position
		if mouse.pressed:
			var body := _rings.body_at(at)
			if body != null:
				_grab_ring = _rings.grab(body, at)
			else:
				var creature := _cells.creature_at(at)
				if creature != null:
					_grab = _cells.grab(creature, at)
		else:
			if _grab >= 0:
				_cells.release_grab(_grab)
			if _grab_ring >= 0:
				_rings.release_grab(_grab_ring)
			_grab = -1
			_grab_ring = -1
	elif motion != null and (_grab >= 0 or _grab_ring >= 0):
		var at := (make_input_local(motion) as InputEventMouseMotion).position
		if _grab >= 0:
			_cells.move_grab(_grab, at)
		if _grab_ring >= 0:
			_rings.move_grab(_grab_ring, at)
	elif key != null and key.pressed and not key.echo and key.keycode == KEY_R:
		build()
	else:
		return
	get_viewport().set_input_as_handled()

func _update_label() -> void:
	if _label == null:
		return
	_label.text = "Rings and cells: ring bodies (GooWorld2D) and creatures of cells (GooCellWorld2D) coupled so they collide    Rings: %d    Creatures: %d\n" % [_rings.bodies().size(), _cells.creatures().size()] \
		+ "Worm: swims round the tank    Blob: shoves the rings in turn    Drag a ring or a creature    R: rebuild"
