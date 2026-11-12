class_name GooCellsSim
extends RefCounted
## The thin GDScript layer over GooCells, the one-particle-per-cell prototype
## (addons/goo2d/native/src/cells.rs, docs/explore-cells.md): the recommended options, the
## events as signals, and retopologies: joining by capture distance at moments the game
## asks for, filtered by the type table (GooCells.set_type()'s join_mask) and then by
## may_join() (override it, or set join_filter).
##
## Creature ids are slots: a creature merged into another keeps its slot, dead
## (cells.alive(c) false); a split's parts get new slots. Cells are named by uid in events
## (cells.uids(c) maps a creature's cell indices to them).

## A link between two cells was made at a retopology: (creature, uid a, uid b).
signal cells_joined(creature: int, a: int, b: int)
## A link broke past its force, or a removed cell's links went: (creature, uid a, uid b).
signal cells_parted(creature: int, a: int, b: int)
## A creature fell apart: `child` holds `count` of its cells now.
signal creature_split(parent: int, child: int, count: int)

## The capture distance at a retopology (px at unit 1; × GooTuning.unit).
const CAPTURE := 4.0

var cells: GooCells = GooCells.new()
## Asked for each candidate pair at a retopology when set: (a, cell a, b, cell b) -> bool.
var join_filter: Callable = Callable()

## The settings docs/explore-cells.md recommends: 6 substeps, stiff links and bending
## (60 / 40 Hz), the creature's own cells colliding unless linked or two links apart, the
## fluid game's drag with a tangential share of a twentieth (anguilliform swimming needs it).
static func recommended_options() -> Dictionary:
	return {
		"substeps": 6, "stretch_hz": 60.0, "bend_hz": 40.0, "bend_mode": GooCells.BEND_LINK,
		"link_damp": 0.02, "bend_damp": 0.02, "self_mode": GooCells.SELF_FAR,
		"drag": true, "drag_normal": 0.1, "drag_tangent": 0.005, "drag_linear_normal": 60.0, "drag_linear_tangent": 3.0,
	}

func _init(options: Dictionary = {}) -> void:
	cells.set_options(recommended_options())
	cells.set_options(options)

## Override to veto a join; the default asks join_filter, else allows it.
func may_join(a: int, cell_a: int, b: int, cell_b: int) -> bool:
	return join_filter.call(a, cell_a, b, cell_b) if join_filter.is_valid() else true

## A creature from cells as Vector3 (x, y, radius) and their types.
func add_creature(design: Array[Vector3], types: PackedInt32Array = PackedInt32Array()) -> int:
	var centers := PackedVector2Array()
	var radii := PackedFloat32Array()
	for c: Vector3 in design:
		centers.append(Vector2(c.x, c.y))
		radii.append(c.z)
	if types.is_empty():
		types.resize(design.size())
	return cells.add_creature(centers, radii, types)

func step(delta: float) -> void:
	cells.step(delta)
	_emit()

## Joins every pair of cells within `capture` px of touching (default CAPTURE × unit) that
## the type table and may_join() allow; `same`: within a creature too. Returns links made.
func retopology(capture: float = -1.0, same: bool = false) -> int:
	if capture < 0.0:
		capture = CAPTURE * GooTuning.unit
	var found := cells.find_captures(capture, same)
	var keep := PackedInt32Array()
	for k: int in range(0, found.size(), 4):
		if may_join(found[k], found[k + 1], found[k + 2], found[k + 3]):
			keep.append_array([found[k], found[k + 1], found[k + 2], found[k + 3]])
	var made := cells.join(keep)
	_emit()
	return made

func add_cell(creature: int, at: Vector2, radius: float, type: int = 0) -> int:
	return cells.add_cell(creature, at, radius, type)

func remove_cell(creature: int, index: int) -> void:
	cells.remove_cell(creature, index)
	_emit()

func _emit() -> void:
	var e := cells.take_events()
	for k: int in range(0, e.size(), 4):
		match e[k]:
			GooCells.EVENT_JOINED:
				cells_joined.emit(e[k + 1], e[k + 2], e[k + 3])
			GooCells.EVENT_PARTED:
				cells_parted.emit(e[k + 1], e[k + 2], e[k + 3])
			GooCells.EVENT_SPLIT:
				creature_split.emit(e[k + 1], e[k + 2], e[k + 3])
