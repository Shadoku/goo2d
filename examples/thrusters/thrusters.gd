class_name ThrustersExample
extends Node2D
## Thrusters and spike tips (docs/cells.md, "Thrusters", "Spike tips"), top-down: a blob whose
## rim is thruster cells, each facing inward, flies round four waypoints by setting every
## thruster's level in one call a frame (set_thrust_levels(): a thruster facing the way fires
## by how squarely it does, the simplest allocator); a block whose front column is spikes is
## pushed at the right wall again and again and its tips stop it short. Thrusters' plumes and
## spikes are drawn here (the skin draws neither): thrusters() and tips() once a frame. R
## rebuilds.

## Cell radius (px).
const RADIUS: float = 14.0
## The thrusters' maximum (px/s² of a cell's own mass).
const MAX_THRUST: float = 2400.0
## The spikes' tips: their distance out along the cell's facing and their radius (× the cell's).
const TIP_LENGTH: float = 2.0
const TIP_RADIUS: float = 0.3
const BLOB_AT := Vector2(400.0, 300.0)
const BLOCK_AT := Vector2(1500.0, 800.0)
const WAYPOINTS: Array[Vector2] = [Vector2(400, 300), Vector2(1500, 300), Vector2(1500, 560), Vector2(400, 560)]
## The block's push toward the wall (px/s²) and how long each run lasts (s).
const BLOCK_PUSH: float = 300.0
const BLOCK_RUN: float = 3.0
const PLUME_COLOR := Color(1.0, 0.7, 0.3, 0.8)
const SPIKE_COLOR := Color(0.95, 0.92, 0.82)

@onready var _world: GooCellWorld2D = $World
@onready var _ornaments: Node2D = $Ornaments

var body_type: GooCellType
var thruster_type: GooCellType
var spike_type: GooCellType
var blob: GooCellCreature = null
var block: GooCellCreature = null
## The blob's goal: an index into WAYPOINTS.
var goal: int = 1
var time: float = 0.0

func _ready() -> void:
	body_type = GooCellType.new()
	body_type.name = &"body"
	thruster_type = GooCellType.new()
	thruster_type.name = &"thruster"
	thruster_type.color = Color(0.98, 0.55, 0.25)
	thruster_type.max_thrust = MAX_THRUST
	spike_type = GooCellType.new()
	spike_type.name = &"spike"
	spike_type.color = Color(0.85, 0.82, 0.7)
	spike_type.tip_length = TIP_LENGTH
	spike_type.tip_radius = TIP_RADIUS
	_ornaments.draw.connect(_draw_ornaments)
	build()

## The world the creatures live in.
func world() -> GooCellWorld2D:
	return _world

## A hex blob of three rings whose rim cells are thrusters facing inward (so the back of the
## rim pushes forward, whichever way forward is).
func blob_design() -> GooCellDesign:
	var d := GooCellDesign.hex_blob(3, RADIUS)
	d.types = [body_type, thruster_type]
	var reach := 0.0
	for p: Vector2 in d.positions:
		reach = maxf(reach, p.length())
	for i: int in d.cell_count():
		var p := d.positions[i]
		if p.length() > 0.8 * reach:
			d.cell_types[i] = 1
			d.angles[i] = (-p).angle()
	return d

## A block 6 × 7 whose front column (+x) is spikes facing forward.
func block_design() -> GooCellDesign:
	var d := GooCellDesign.hex_worm(6, 7, RADIUS)
	d.types = [body_type, spike_type]
	var front := -INF
	for p: Vector2 in d.positions:
		front = maxf(front, p.x)
	for i: int in d.cell_count():
		if d.positions[i].x > front - RADIUS * 1.2:
			d.cell_types[i] = 1
	return d

func build() -> void:
	_world.clear()
	blob = _world.spawn(blob_design(), Transform2D(0.0, BLOB_AT))
	block = _world.spawn(block_design(), Transform2D(0.0, BLOCK_AT))
	# Its heading held (a creature pushed onto a wall by spikes ahead of its centre would
	# turn off them otherwise).
	block.set_spin_servo(0.0, 30.0)
	block.set_contact_tracking(true)
	goal = 1
	time = 0.0

func _physics_process(delta: float) -> void:
	time += delta
	if blob != null and blob.is_alive():
		var to := WAYPOINTS[goal] - blob.center()
		if to.length() < 60.0:
			goal = (goal + 1) % WAYPOINTS.size()
		# Toward the goal, braking as it gets near: the way less the velocity it already has.
		var way := (to.limit_length(200.0) * 1.5 - blob.velocity()).normalized()
		blob.set_thrust_levels(levels_toward(blob, way))
	if block != null and block.is_alive():
		var run := fmod(time, 2.0 * BLOCK_RUN)
		# Toward the wall for a run, then back for one.
		block.push(Vector2(BLOCK_PUSH if run < BLOCK_RUN else -0.6 * BLOCK_PUSH, 0.0))
	_ornaments.queue_redraw()

## Each thruster's level for a push along `way` (unit): max(0, its facing · way), by index.
static func levels_toward(creature: GooCellCreature, way: Vector2) -> PackedFloat32Array:
	var t := creature.thrusters()
	var levels := PackedFloat32Array()
	levels.resize(creature.cell_count())
	var idx: PackedInt32Array = t["indices"]
	var facings: PackedVector2Array = t["facings"]
	for k: int in idx.size():
		levels[idx[k]] = maxf(0.0, facings[k].dot(way))
	return levels

func _draw_ornaments() -> void:
	if blob != null and blob.is_alive():
		var t := blob.thrusters()
		var p := blob.positions()
		var idx: PackedInt32Array = t["indices"]
		for k: int in idx.size():
			var level: float = t["levels"][k]
			if level > 0.05:
				var at := p[idx[k]]
				var f: Vector2 = t["facings"][k]
				_ornaments.draw_line(at - f * RADIUS * 0.6, at - f * RADIUS * (0.8 + 1.6 * level), PLUME_COLOR, 4.0)
	if block != null and block.is_alive():
		var tips := block.tips()
		var p := block.positions()
		var idx: PackedInt32Array = tips["indices"]
		for k: int in idx.size():
			var at: Vector2 = tips["positions"][k]
			var base := p[idx[k]]
			var side := (at - base).orthogonal().normalized() * RADIUS * 0.35
			_ornaments.draw_colored_polygon(PackedVector2Array([base + side, at + (at - base).normalized() * tips["radii"][k], base - side]), SPIKE_COLOR)

func _unhandled_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key != null and key.pressed and key.keycode == KEY_R:
		build()
