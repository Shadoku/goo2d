class_name GooColonySim
extends RefCounted
## A thin layer over GooColony, the colony's own solver (creatures of many cells that
## stick where they touch: docs/colony-adhesion.md). It sets the colony's adhesion up at
## GooTuning.unit, steps it, answers the colony's asks with may_adhere() (when
## `asks_script` is on), and turns its joined and parted events into signals, after each
## step, in the colony's order (creature after creature, a step's in cell-pair order).
## Everything else is GooColony's own API, through `colony`.

## Cells `a` and `b` of creature `creature` stuck to each other (a < b).
signal cells_joined(creature: int, a: int, b: int)
## Cells `a` and `b` of creature `creature` no longer have a stick between them (a < b).
signal cells_parted(creature: int, a: int, b: int)

## The capture gap at unit 1 (px): a free bead this close to another cell's skin sticks.
## 5 (2.5 px at unit 0.5) makes a wall between two touching round cells about three
## beads wide; at 3 it is one bead wide and weak; at 8 the walls are pulled flatter and
## their sticks carry standing loads of most of the break force.
const CAPTURE: float = 5.0
## How far join_cells() reaches at unit 1 (px).
const JOIN_REACH: float = 8.0
## The break force at unit 1 (a 14 px cell at unit 0.5 weighs 2.6; masses do not scale
## with the unit, accelerations do, so forces scale with it).
const BREAK_FORCE: float = 24000.0

## Milestone 2's parts on (docs/colony-exposure.md): exposure (the particles of cells
## with no exposed bead take no part in contacts with other creatures met slower than
## SKIP_SPEED), rings wholly enclosed becoming cores and exposed cores rings again, cores'
## contacts with their own creature compliant (1 × the cell's skin stiffness: an impact
## squashes the outer cells less), beads anchored on cores' rims. Pass it (merged with your
## own) to new(). The water drag is separate: DRAG_OPTIONS.
const EXPOSURE_OPTIONS: Dictionary = { "exposure": true, "auto_cores": true, "core_contact": 1.0, "core_anchors": true }
## Creatures meeting faster than this (mean velocities, px/s at unit 1) collide whole: at
## 1200 px/s an outer layer is crushed enough to let the other's beads through to the
## skipped cells behind it; at 600 it is not.
const SKIP_SPEED: float = 1600.0
## The water drag on exposed edges, with the fluid game's numbers (its GameSettings:
## WATER_DENSITY 1, DRAG_NORMAL 0.1, DRAG_TANGENT 0.01, DRAG_LINEAR_NORMAL 60,
## DRAG_LINEAR_TANGENT 8, DRAG_MAX_STEP_FRACTION 0.5, tuned at unit 0.5). Cells meant to
## swim in it want no damping of their own: cell_floats()'s `linear_damp` 0.
const DRAG_OPTIONS: Dictionary = { "drag": true, "drag_density": 1.0, "drag_normal": 0.1, "drag_tangent": 0.01,
	"drag_linear_normal": 60.0, "drag_linear_tangent": 8.0, "drag_max_step": 0.5 }

## Milestone 3's surface tension (docs/colony-tension.md): the force each edge of a
## creature's surface pulls with, at unit 1 (tension_options() scales it by
## GooTuning.unit, as forces scale). At 1500 two touching cells of the smallest size zip
## their wall from 3 sticks to 4, their centres from 0.92 to 0.80 of a diameter apart,
## squeezed to about 0.91 of their area; see the doc for what it costs a designed shape.
const TENSION: float = 1500.0

## The surface tension on, `strength` at unit 1 (the option is a force at the current
## unit); pockets keep their size (`tension_pockets` 0). It runs the exposure pass, whose
## surface it pulls along. Merge it with EXPOSURE_OPTIONS (or use everything_options()).
static func tension_options(strength: float = TENSION) -> Dictionary:
	return { "tension": strength * GooTuning.unit, "tension_pockets": 0.0 }

## Everything the fluid game's creatures use (docs/colony-tension.md): adhesion (always on
## in GooColonySim), EXPOSURE_OPTIONS, DRAG_OPTIONS, the surface tension at `strength` (at
## unit 1) and the creature's own contact candidates kept across frames (reuse_pairs, with
## pair_skin 8 px at unit 1: 4 px at the fluid game's 0.5, as docs/colony-exposure.md measured),
## and the exposure pass only on its regular frames and after a switch or a parting, not on
## the 6 frames after (exposure_hot 0: half the passes, the settle pass 0.2 ms less at 30 × 150;
## a core whose neighbour drifts off slowly comes back as a ring up to 0.5 s later).
static func everything_options(strength: float = TENSION) -> Dictionary:
	var options := EXPOSURE_OPTIONS.duplicate()
	options.merge(DRAG_OPTIONS)
	options.merge(tension_options(strength))
	options.merge({ "reuse_pairs": true, "pair_skin": 8.0 * GooTuning.unit, "exposure_hot": 0 })
	return options

var colony: GooColony

## Ask may_adhere() once about each pair of cells that touch for the first time (until
## they part and come apart): the colony holds such a pair back until it is answered,
## which happens right after the step that found it, so it joins a frame later.
var asks_script: bool = false:
	set(value):
		asks_script = value
		colony.set_options({ "ask": value })

## A filter used by may_adhere() when it is not overridden: (creature, a, b) -> bool.
var adhere_filter: Callable

## `options` go to GooColony.set_options() after the defaults (adhesion on, the capture,
## join reach, break force and speed cap at GooTuning.unit).
func _init(options: Dictionary = {}) -> void:
	colony = GooColony.new()
	var unit := GooTuning.unit
	colony.set_options({ "adhesion": true, "capture": CAPTURE * unit, "join_reach": JOIN_REACH * unit,
		"break_force": BREAK_FORCE * unit, "max_speed": GooTuning.MAX_BEAD_SPEED * unit, "skip_speed": SKIP_SPEED * unit })
	if not options.is_empty():
		colony.set_options(options)

## May cells `a` and `b` of creature `creature` stick (asked once per first touch while
## `asks_script` is on, never from a worker thread). Override, or set `adhere_filter`.
func may_adhere(creature: int, a: int, b: int) -> bool:
	if adhere_filter.is_valid():
		return adhere_filter.call(creature, a, b)
	return true

## Steps the colony, answers its asks, emits its events.
func step(delta: float) -> void:
	colony.step(delta)
	answer_asks()
	flush_events()

func answer_asks() -> void:
	var asks := colony.take_asks()
	for i: int in range(0, asks.size(), 3):
		colony.answer(asks[i], asks[i + 1], asks[i + 2], may_adhere(asks[i], asks[i + 1], asks[i + 2]))

## Emits every event the colony has queued (a step's, or a join or part by hand).
func flush_events() -> void:
	var events := colony.take_events()
	for i: int in range(0, events.size(), 4):
		if events[i] == GooColony.EVENT_JOINED:
			cells_joined.emit(events[i + 1], events[i + 2], events[i + 3])
		else:
			cells_parted.emit(events[i + 1], events[i + 2], events[i + 3])

## Joins two cells by hand (GooColony.join_cells()) and emits the event at once.
func join_cells(creature: int, a: int, b: int) -> int:
	var made := colony.join_cells(creature, a, b)
	flush_events()
	return made

## Parts two cells by hand (GooColony.part_cells()) and emits the event at once.
func part_cells(creature: int, a: int, b: int) -> int:
	var removed := colony.part_cells(creature, a, b)
	flush_events()
	return removed

## Adds a creature of `cells`, each a Dictionary {position: Vector2, radius: float,
## type: int (0), core: bool (false), color: Color}; its index.
func add_creature(cells: Array) -> int:
	var floats := PackedFloat32Array()
	for cell: Dictionary in cells:
		floats.append_array(cell_floats(cell["position"], cell["radius"], cell.get("core", false), cell.get("color", Color.WHITE)))
	var k := colony.add_creature(floats)
	for i: int in cells.size():
		var type_id: int = cells[i].get("type", 0)
		if type_id != 0:
			colony.set_cell_type(k, i, type_id)
	return k

## The GooColony.CELL_STRIDE floats of a cell of `radius` at `at`: GooTuning.tuning()
## for its size at the current unit (`linear_damp` < 0: the tuning's).
static func cell_floats(at: Vector2, radius: float, core: bool = false, color: Color = Color.WHITE,
		linear_damp: float = -1.0) -> PackedFloat32Array:
	var t := GooTuning.tuning(radius)
	return PackedFloat32Array([at.x, at.y, radius, 1.0 if core else 0.0, t["bead_count"], t["ring_radius"],
		t["bead_radius"], t["bead_mass"], t["pressure_k"], t["shape_match_k"], t["skin_stiffness"],
		t["skin_damping"], t["bending_stiffness"], t["bending_damping"], t["internal_damp"],
		t["linear_damp"] if linear_damp < 0.0 else linear_damp, t["target_area"], color.r, color.g, color.b])
