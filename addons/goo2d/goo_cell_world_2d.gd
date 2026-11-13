class_name GooCellWorld2D
extends Node2D
## A world of creatures made of cells, one disc particle per cell (docs/cells.md): owns a
## GooCells (the native solver, native/src/cells.rs), mirrors the scene's walls into it
## through GooStatics (every StaticBody2D and TileMapLayer on GooTuning.LAYER_WALLS, as
## GooWorld2D does), steps it in _physics_process and draws every creature's skin as one
## triangle array. Creatures are not nodes: spawn() returns a GooCellCreature handle.
##
## The cell creatures and a GooWorld2D's ring bodies do not collide with each other.
##
## Every frame: walls synced, grabs held, the water fed (water_source), the step, its
## events as signals, a retopology when one was asked for, the skins drawn.

## A creature was spawned (or split off: creature_split first).
signal creature_spawned(creature: GooCellCreature)
## A creature was despawned or cleared.
signal creature_despawned(creature: GooCellCreature)
## A link broke (past the break force) or a removed cell's links went: the cells' uids.
signal cells_parted(creature: GooCellCreature, uid_a: int, uid_b: int)
## A link was made at a retopology: the cells' uids (in the creature they are in now).
signal cells_joined(creature: GooCellCreature, uid_a: int, uid_b: int)
## A creature fell apart: `child` is a new creature (creature_spawned follows).
signal creature_split(parent: GooCellCreature, child: GooCellCreature)
## A retopology joined `from` into `into`: `from` is gone.
signal creatures_merged(into: GooCellCreature, from: GooCellCreature)

## The world's own body mode for types left at GooCellType.Body.DEFAULT.
enum BodyMode { LINKS = 1, SHAPE = 2, NONE = 0 }
## Which of a creature's own cells collide with each other (unlinked ones always pass a
## linked neighbour).
enum SelfCollision {
	## None: a creature bent far folds through itself.
	NONE = 0,
	## Every unlinked pair.
	UNLINKED = 1,
	## Cells of self-colliding types (GooCellType.self_collides) against unlinked cells.
	TYPES = 2,
	## Unlinked pairs not sharing a neighbour (the default: cheap and sound).
	FAR = 3,
}

## Capture distance at a retopology: two cells this close to touching may join (px at
## GooTuning.unit 1).
const CAPTURE: float = 4.0
## The solver's margin and speed cap (px and px/s at unit 1).
const MARGIN: float = 6.0
const MAX_SPEED: float = 6000.0
## A grab takes the nearest cell within this of its disc (px at unit 1).
const GRAB_PICK: float = 16.0
## The grab's spring (1/s²) and damping (1/s); critically damped.
const GRAB_STIFFNESS: float = 400.0
const GRAB_DAMPING: float = 40.0
## Cells within this many radii of the grabbed one share the pull.
const GRAB_REACH: float = 3.0

## Threads the solver uses (creatures stepped in parallel; threaded == serial bit for bit).
## 0 (the default): chosen each step from the live cells (1 below 800, 2 below 1600, else
## 4; at most one per live creature and the machine's cores), measured: a thread pool costs
## more than it saves below about 800 cells (docs/cells.md, "Threads").
@export_range(0, 64) var threads: int = 0:
	set(value):
		threads = value
		_send_options()
## Substeps per physics frame (6: 4 lose a quarter of the swimming speed).
@export_range(1, 16) var substeps: int = 6:
	set(value):
		substeps = value
		_send_options()
## The links' stretch stiffness (Hz over a pair's reduced mass).
@export var stretch_hz: float = 60.0:
	set(value):
		stretch_hz = value
		_send_options()
## The bending stiffness of oriented links and joints (Hz).
@export var bend_hz: float = 40.0:
	set(value):
		bend_hz = value
		_send_options()
## How cells of types left at Body.DEFAULT hold their shape.
@export var body_mode: BodyMode = BodyMode.SHAPE:
	set(value):
		body_mode = value
		_send_options()
## Shape matching's pull per substep (0..1).
@export_range(0.0, 1.0, 0.01) var shape_stiffness: float = 0.3:
	set(value):
		shape_stiffness = value
		_send_options()
## Which of a creature's own cells collide.
@export var self_collision: SelfCollision = SelfCollision.FAR:
	set(value):
		self_collision = value
		_send_options()
## The kernel's gravity (GooTuning's) × this. 0 for a top-down world.
@export_range(0.0, 4.0, 0.01, "or_greater") var gravity_scale: float = 1.0:
	set(value):
		gravity_scale = value
		_send_options()
## Water drag on the creatures' outlines (the fluid game's law, docs/cells.md).
@export var drag_enabled: bool = true:
	set(value):
		drag_enabled = value
		_send_options()
## Drag across an outline edge: quadratic (per px/s) and linear (px/s) coefficients.
@export var drag_normal: float = 0.1:
	set(value):
		drag_normal = value
		_send_options()
@export var drag_linear_normal: float = 60.0:
	set(value):
		drag_linear_normal = value
		_send_options()
## Across over along: the drag along an edge is the drag across it ÷ this (both terms).
## 20: undulation swims 0.23 body lengths a cycle; the fluid game's own rings use 7.5-10
## (0.185). docs/cells.md, "Drag".
@export_range(1.0, 200.0, 0.1, "or_greater") var drag_ratio: float = 20.0:
	set(value):
		drag_ratio = value
		_send_options()
## The along-edge linear drag (px/s) on its own; below 0 (the default) it is
## drag_linear_normal / drag_ratio. A brake against the glide that leaves the quadratic
## terms (and so swimming at speed) much as they are.
@export var drag_linear_tangent: float = -1.0:
	set(value):
		drag_linear_tangent = value
		_send_options()
## The water's mass per px².
@export var drag_density: float = 1.0:
	set(value):
		drag_density = value
		_send_options()
## The water's velocity where no water_source or creature current says otherwise.
@export var current: Vector2 = Vector2.ZERO:
	set(value):
		current = value
		_send_options()
## A link breaks past this load (INF: never). With break_leaves_out_own_share, the load
## over the creature's own envelope (docs/cells.md, "Breaking").
@export var break_force: float = INF:
	set(value):
		break_force = value
		_send_options()
## The break test leaves out the creature's own share (muscles, thrust, drag): one break
## force tells a crash from swimming.
@export var break_leaves_out_own_share: bool = true:
	set(value):
		break_leaves_out_own_share = value
		_send_options()
## Draw the creatures' skins.
@export var draw_skins: bool = true
## The skins' material (null: a ShaderMaterial of addons/goo2d/goo_cells.gdshader). Its
## shader gets the types' colours as COLOR, UV.x 1 inside and 0 on the skin, UV.y type / 16.
@export var skin_material: Material = null:
	set(value):
		skin_material = value
		_apply_material()
## Lines between cells of different types.
@export var draw_borders: bool = true
@export var border_color: Color = Color(0.03, 0.06, 0.05, 0.85)
## px at unit 1.
@export var border_width: float = 2.0
## The type of cells whose design names none.
@export var default_type: GooCellType = null
## Called with every live creature's cell centres (one PackedVector2Array, slot order) each
## frame before the step; returns the water's velocity there (empty: none, one value for
## all, or one per point), e.g. a flow field's velocities_at. Invalid: not called.
var water_source: Callable = Callable()

var _cells: GooCells = null
var _statics: GooStatics = null
var _handles: Dictionary[int, GooCellCreature] = {}
var _slots: Array[GooCellType] = []
var _retopology: bool = false
var _retopology_capture: float = -1.0
var _retopology_same: bool = false
var _item: RID = RID()
var _material: Material = null
var _grabs: Dictionary[int, Dictionary] = {}
var _next_grab: int = 1
## The last frame's skin build (µs in the kernel, µs handing it to the RenderingServer).
var draw_stats: Dictionary = {"mesh_us": 0, "submit_us": 0, "vertices": 0, "triangles": 0}

## The world's GooCells (made on first use).
func cells() -> GooCells:
	if _cells == null:
		_cells = GooCells.new()
		_statics = GooStatics.new(_cells)
		if default_type == null:
			default_type = GooCellType.new()
		_slots = [default_type]
		_send_options()
		_send_type(0)
	return _cells

func _enter_tree() -> void:
	cells()
	_statics.attach(get_tree())

func _exit_tree() -> void:
	if _statics != null:
		_statics.detach()

func _ready() -> void:
	_item = RenderingServer.canvas_item_create()
	RenderingServer.canvas_item_set_parent(_item, get_canvas_item())
	_apply_material()

func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and _item.is_valid():
		RenderingServer.free_rid(_item)

## Mirrors the scene's walls again at the next step (after a change GooStatics cannot see).
func refresh_walls() -> void:
	cells()
	_statics.refresh()

## Walls in the solver now.
func wall_count() -> int:
	return cells().static_shape_count()

func _send_options() -> void:
	if _cells == null:
		return
	var gravity: Vector2 = GooTuning.solver_settings()["gravity"]
	var options := {
		"threads": threads, "substeps": substeps, "stretch_hz": stretch_hz, "bend_hz": bend_hz,
		"bend_mode": int(body_mode), "shape_k": shape_stiffness, "link_damp": 0.02, "bend_damp": 0.02,
		"self_mode": int(self_collision), "margin": MARGIN * GooTuning.unit, "max_speed": MAX_SPEED * GooTuning.unit,
		"gravity": gravity * gravity_scale, "drag": drag_enabled, "drag_normal": drag_normal,
		"drag_linear_normal": drag_linear_normal, "drag_ratio": drag_ratio, "drag_density": drag_density,
		"current": current, "break_force": break_force if break_force > 0.0 else INF,
		"break_excess": break_leaves_out_own_share,
	}
	if drag_linear_tangent >= 0.0:
		options["drag_linear_tangent"] = drag_linear_tangent
	_cells.set_options(options)

## The threads the last step ran on (threads 0 chooses them by size).
func threads_in_use() -> int:
	return cells().threads_in_use()

# --- Types -----------------------------------------------------------------------------

## The kernel slot of `type` (registered on first sight; null: the default type's, 0).
## The kernel has 16 slots: a 17th type is an error and gets slot 0.
func type_slot(type: GooCellType) -> int:
	cells()
	if type == null:
		return 0
	var k := _slots.find(type)
	if k >= 0:
		return k
	if _slots.size() >= 16:
		push_error("GooCellWorld2D: more than 16 cell types")
		return 0
	_slots.append(type)
	_send_type(_slots.size() - 1)
	return _slots.size() - 1

## The GooCellType of kernel slot `slot`.
func type_of_slot(slot: int) -> GooCellType:
	cells()
	return _slots[slot] if slot >= 0 and slot < _slots.size() else default_type

## Sends `type`'s parameters again (after editing it).
func update_type(type: GooCellType) -> void:
	var k := _slots.find(type)
	if k >= 0:
		_send_type(k)

## The region key of cells of `type` and `group` (GooCells.set_joint_angle()'s).
func region_key(type: GooCellType, group: int) -> int:
	return (type_slot(type) << 16) | (group & 0xffff)

func _send_type(slot: int) -> void:
	var t := _slots[slot]
	var p := t.kernel_params()
	_cells.set_type(slot, p)
	# Every slot's join mask from the layers: bit u when the two types join both ways.
	for a: int in _slots.size():
		var mask := 0
		for b: int in _slots.size():
			if _slots[a].joins(_slots[b]):
				mask |= 1 << b
		for b: int in range(_slots.size(), 16):
			mask |= 1 << b
		_cells.set_type(a, {"join_mask": mask})

# --- Creatures -------------------------------------------------------------------------

## A creature from `design` at `at` (global; its origin the design's origin). Spawning
## onto another creature tangles them for good (docs/cells.md, quirks): a warning names
## the overlap.
func spawn(design: GooCellDesign, at: Transform2D = Transform2D.IDENTITY) -> GooCellCreature:
	var c := cells()
	var n := design.cell_count()
	var centers := PackedVector2Array()
	var radii := PackedFloat32Array()
	var types := PackedInt32Array()
	var groups := PackedInt32Array()
	var masses := PackedFloat32Array()
	var angles := PackedFloat32Array()
	var thrust := PackedFloat32Array()
	var turn := at.get_rotation()
	for i: int in n:
		var t := design.type_of(i)
		centers.append(at * design.positions[i])
		radii.append(design.radius_of(i) * at.get_scale().x)
		types.append(type_slot(t))
		groups.append(design.group_of(i))
		masses.append(t.mass_factor if t != null else default_type.mass_factor)
		angles.append(design.angle_of(i) + turn)
		thrust.append(0.0)
	for i: int in n:
		var other := c.creature_at(centers[i])
		if other >= 0:
			push_warning("GooCellWorld2D.spawn: cell %d lands inside creature %d (it stays tangled)" % [i, other])
			break
	var slot := c.add_creature_ex(centers, radii, types, groups, masses)
	c.set_cell_thrust(slot, thrust, angles)
	var handle := GooCellCreature.new(self, slot, design, design.forward.rotated(turn))
	_handles[slot] = handle
	creature_spawned.emit(handle)
	return handle

## Removes `creature` (creature_despawned).
func despawn(creature: GooCellCreature) -> void:
	if creature == null or not _handles.has(creature.id):
		return
	_release_grabs_of(creature)
	cells().remove_creature(creature.id)
	_handles.erase(creature.id)
	creature_despawned.emit(creature)

## Removes every creature.
func clear() -> void:
	for slot: int in _handles.keys():
		despawn(_handles[slot])

## Every live creature, by slot.
func creatures() -> Array[GooCellCreature]:
	var out: Array[GooCellCreature] = []
	for slot: int in _handles:
		out.append(_handles[slot])
	return out

## The creature of kernel slot `slot` (null: none alive).
func creature(slot: int) -> GooCellCreature:
	return _handles.get(slot, null)

## The creature whose skin holds `point` (global), or null.
func creature_at(point: Vector2) -> GooCellCreature:
	return creature(cells().creature_at(point))

## Adds a cell to `creature` (GooCellCreature.add_cell()). Returns its uid.
func add_cell(creature: GooCellCreature, at: Vector2, radius: float, type: GooCellType = null, group: int = 0) -> int:
	var c := cells()
	var t := type if type != null else default_type
	var k := c.add_cell_ex(creature.id, at, radius * t.radius_factor, type_slot(t), group, t.mass_factor)
	return c.uids(creature.id)[k]

## Removes the cell of `uid` from `creature` (GooCellCreature.remove_cell()).
func remove_cell(creature: GooCellCreature, uid: int) -> void:
	var i := creature.cell_index(uid)
	if i < 0:
		return
	_release_grabs_of(creature)
	cells().remove_cell(creature.id, i)
	_dispatch_events()

# --- Joining ---------------------------------------------------------------------------

## Asks for a retopology after the next step: every two cells within `capture` px of
## touching (default CAPTURE × unit), of different creatures (and of one, sharing no
## neighbour, when `same`), whose types join and that may_join() allows, are linked.
func request_retopology(capture: float = -1.0, same: bool = false) -> void:
	_retopology = true
	_retopology_capture = capture
	_retopology_same = same

## A retopology now (see request_retopology()). Returns the links made.
func retopology(capture: float = -1.0, same: bool = false) -> int:
	var c := cells()
	if capture < 0.0:
		capture = CAPTURE * GooTuning.unit
	var found := c.find_captures(capture, same)
	var keep := PackedInt32Array()
	for k: int in range(0, found.size(), 4):
		var a := creature(found[k])
		var b := creature(found[k + 2])
		if a == null or b == null:
			continue
		if may_join(a, c.uids(a.id)[found[k + 1]], b, c.uids(b.id)[found[k + 3]]):
			keep.append_array([found[k], found[k + 1], found[k + 2], found[k + 3]])
	if keep.is_empty():
		return 0
	# Each creature by one of its cells' uids, to find where a merged one went.
	var marks: Dictionary[int, int] = {}
	for slot: int in _handles:
		var u := c.uids(slot)
		if not u.is_empty():
			marks[slot] = u[0]
	var made := c.join(keep)
	_dispatch_events()
	for slot: int in marks:
		if c.alive(slot):
			continue
		var from: GooCellCreature = _handles[slot]
		_handles.erase(slot)
		var into: GooCellCreature = null
		for other: int in _handles:
			if c.uids(other).has(marks[slot]):
				into = _handles[other]
				break
		_release_grabs_of(from)
		creatures_merged.emit(into, from)
	return made

## Override to veto a join between cell `uid_a` of `a` and cell `uid_b` of `b` (asked at
## a retopology after the types' join layers allowed it). Default: true.
func may_join(_a: GooCellCreature, _uid_a: int, _b: GooCellCreature, _uid_b: int) -> bool:
	return true

# --- Grabbing --------------------------------------------------------------------------

## Grabs `creature` at `point` (global): a spring pulls its cells near the point toward
## move_grab()'s target. Returns a handle (-1: no cell there).
func grab(creature: GooCellCreature, point: Vector2) -> int:
	var c := cells()
	var i := c.cell_at(creature.id, point, GRAB_PICK * GooTuning.unit)
	if i < 0:
		return -1
	var p := c.centers(creature.id)
	var r := c.radii(creature.id)
	var u := c.uids(creature.id)
	var held := PackedInt32Array()
	for k: int in p.size():
		if p[k].distance_to(p[i]) <= GRAB_REACH * r[i]:
			held.append(u[k])
	var handle := _next_grab
	_next_grab += 1
	_grabs[handle] = {"creature": creature, "uid": u[i], "held": held, "target": point, "offset": point - p[i]}
	return handle

func move_grab(handle: int, point: Vector2) -> void:
	if _grabs.has(handle):
		_grabs[handle]["target"] = point

## Lets go (its forces cleared).
func release_grab(handle: int) -> void:
	if not _grabs.has(handle):
		return
	var g: Dictionary = _grabs[handle]
	_grabs.erase(handle)
	var cr: GooCellCreature = g["creature"]
	if cr.is_alive():
		for uid: int in g["held"]:
			var k := cr.cell_index(uid)
			if k >= 0:
				cells().set_cell_force(cr.id, k, Vector2.ZERO)

func _release_grabs_of(creature: GooCellCreature) -> void:
	for handle: int in _grabs.keys():
		if _grabs[handle]["creature"] == creature:
			release_grab(handle)

func _hold_grabs() -> void:
	var c := _cells
	for handle: int in _grabs.keys():
		var g: Dictionary = _grabs[handle]
		var cr: GooCellCreature = g["creature"]
		if not cr.is_alive():
			_grabs.erase(handle)
			continue
		var u := c.uids(cr.id)
		var p := c.centers(cr.id)
		var v := c.velocities(cr.id)
		var i := -1
		var held: Array[int] = []
		for k: int in u.size():
			if u[k] == g["uid"]:
				i = k
			if (g["held"] as PackedInt32Array).has(u[k]):
				held.append(k)
		if i < 0 or held.is_empty():
			release_grab(handle)
			continue
		var at: Vector2 = p[i] + g["offset"]
		var f: Vector2 = (GRAB_STIFFNESS * (g["target"] - at) - GRAB_DAMPING * v[i]) * c.creature_mass(cr.id) / held.size()
		for k: int in held:
			c.set_cell_force(cr.id, k, f)

# --- Stepping --------------------------------------------------------------------------

func _physics_process(delta: float) -> void:
	step(delta)

## One frame (what _physics_process does): walls, grabs, water, the step, events, a
## requested retopology, the skins.
func step(delta: float) -> void:
	var c := cells()
	_statics.sync()
	if not _grabs.is_empty():
		_hold_grabs()
	if water_source.is_valid():
		var points: PackedVector2Array = c.centers_all()[0]
		c.set_water_all(water_source.call(points))
	c.step(delta)
	_dispatch_events()
	if _retopology:
		_retopology = false
		retopology(_retopology_capture, _retopology_same)
	if draw_skins and _item.is_valid():
		redraw()

func _dispatch_events() -> void:
	var e := _cells.take_events()
	for k: int in range(0, e.size(), 4):
		match e[k]:
			GooCells.EVENT_PARTED:
				cells_parted.emit(creature(e[k + 1]), e[k + 2], e[k + 3])
			GooCells.EVENT_JOINED:
				cells_joined.emit(creature(e[k + 1]), e[k + 2], e[k + 3])
			GooCells.EVENT_SPLIT:
				var parent := creature(e[k + 1])
				var child := GooCellCreature.new(self, e[k + 2], parent.design if parent != null else null, parent.axis if parent != null else Vector2.RIGHT)
				if parent != null:
					child.data = parent.data.duplicate()
				_handles[e[k + 2]] = child
				creature_split.emit(parent, child)
				creature_spawned.emit(child)

# --- Drawing ---------------------------------------------------------------------------

func _apply_material() -> void:
	if not _item.is_valid():
		return
	_material = skin_material
	if _material == null:
		var m := ShaderMaterial.new()
		m.shader = preload("res://addons/goo2d/goo_cells.gdshader")
		_material = m
	RenderingServer.canvas_item_set_material(_item, _material.get_rid())

## The material the skins draw with now.
func current_skin_material() -> Material:
	return _material

## Draws every creature's skin again (step() does after each step).
func redraw() -> void:
	var c := cells()
	RenderingServer.canvas_item_clear(_item)
	var m: Array = c.meshes_all(draw_borders)
	var t := Time.get_ticks_usec()
	var points: PackedVector2Array = m[0]
	RenderingServer.canvas_item_set_transform(_item, global_transform.affine_inverse())
	var indices: PackedInt32Array = m[5]
	if indices.size() >= 3:
		RenderingServer.canvas_item_add_triangle_array(_item, indices, points, m[1], m[2])
	var lines: PackedVector2Array = m[3]
	if draw_borders and lines.size() >= 2:
		RenderingServer.canvas_item_add_multiline(_item, lines, PackedColorArray([border_color]), border_width * GooTuning.unit)
	draw_stats = {"mesh_us": m[4], "submit_us": Time.get_ticks_usec() - t, "vertices": points.size(), "triangles": indices.size() / 3}
