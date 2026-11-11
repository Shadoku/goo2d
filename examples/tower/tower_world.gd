class_name TowerWorld
extends GooWorld2D
## The tower example's world: stiff square blocks that do not merge, a platform
## to stack them on and a goal line to stack them past.
##
## - tuning_for(): every block is `stiffness` times stiffer than GooTuning makes
##   goo of its size (skin, bending, pressure; the springs' damping by its
##   square root, so their damping ratio stays), holds its square `shape_hold`
##   times harder again (shape matching), falls through `air_drag`, grips
##   with `friction` and does not bounce, so a stack of them stands instead of
##   leaning over, and a dropped block lands on it gently and stays put.
## - may_merge(): never, unless `allow_merging` (then by the default rule, flat
##   face to flat face, up to GooTuning.max_radius()).
## - Every physics frame: a block that left the platform (its centre outside the
##   platform's x range and DESPAWN_DEPTH below its top) or the screen is
##   despawned; the stack (the blocks resting on the platform or on a block of
##   the stack) is measured, and once its top has stood above the goal line for
##   WIN_HOLD seconds, or with every block settled, `won` fires (once, until
##   reset()).
##
## The platform and the goal line are nodes placed in the scene (TowerSlab,
## TowerGoalLine), found through the exported NodePaths `platform_path` and
## `goal_line_path`: a designer moves or resizes them in the editor and the
## rules follow.

## Emitted once when the stack first stands above the goal line (again only
## after reset()).
signal won
## Emitted when the measured stack height changes by a pixel or more, or the
## stack comes or goes (tower_height() 0 when there is none).
signal height_changed(height: float)

## Seconds the stack's top must stay above the goal line, resting, to win
## while some body is still not settled (a block falling past the line, a
## wobble below it). With every body settled the win counts at once.
const WIN_HOLD: float = 1.0
## Speed, in px/s (the body's average bead velocity), under which a block
## counts as resting on the stack though the kernel has not settled it yet.
const REST_SPEED: float = 40.0
## Gap, in px, by which two bodies' collision outlines (bead bounds grown by a
## bead radius), or a body's and the platform, may miss each other and still
## count as one resting on the other.
const SUPPORT_SLOP: float = 6.0
## How far, in px, below the platform's top a block's centre must be (with the
## centre outside the platform's x range) before it is despawned: it is seen
## falling past the edge first.
const DESPAWN_DEPTH: float = 60.0
## Y below which any block is despawned, whatever its x: off the screen.
const OUT_Y: float = 1250.0
## Largest multiplier on the pressure: it is an explicit force over the step,
## not a constraint, and at 7-8 times GooTuning's a resting block blew apart
## within a second (measured; the skin, bending and shape matching are
## compliant constraints, stable at any stiffness).
const MAX_PRESSURE_SCALE: float = 5.0

## Multiplier on the blocks' skin and bending spring stiffness, shape matching
## and pressure over GooTuning's (the springs' damping by its square root, so
## their damping ratio stays; the pressure by at most MAX_PRESSURE_SCALE). 1 is
## the addon's soft goo: a block squashes and wobbles like any blob. See the
## README for what stands at each value.
@export_range(1.0, 12.0, 0.25) var stiffness: float = 4.0
## Further multiplier on the blocks' shape matching, on top of `stiffness`: how
## hard a block pulls back to a square when it is sheared into a rhombus. What
## lets a stack stand: a soft square shears under the blocks above it, the
## stack leans, and the lean grows until it topples (the README's measurements).
## Shape matching is a compliant pull in the kernel, stable at any value.
@export_range(1.0, 50.0, 0.5) var shape_hold: float = 4.0
## Linear damping (per second) of every bead of a block, GooTuning's is about
## 0.4 for this size: air drag that holds a falling block to about
## gravity / air_drag px/s (490 at 2), so a block dropped from the hopper lands
## on the stack instead of knocking it off, and slows a sway. 0 keeps
## GooTuning's.
@export_range(0.0, 8.0, 0.1) var air_drag: float = 2.0
## Coulomb friction of a block (GooTuning's goo has 0.2; a contact uses the
## lower of the two, the platform's is 1). Slick blocks slide off each other
## as they land, and a stack whose blocks slid apart soon falls.
@export_range(0.0, 1.0, 0.05) var friction: float = 1.0
## Restitution of a block's beads (GooTuning's is about 0.36 for this size; a
## contact adds the wall's). A bouncing block lands off where it was dropped.
@export_range(0.0, 1.0, 0.05) var bounce: float = 0.0
## Lets blocks merge by the addon's default rule (squares fuse flat face to flat
## face). Off for the game: a fused stack is one body and no longer a tower.
@export var allow_merging: bool = false
## The platform the tower stands on: a TowerSlab (StaticBody2D with a
## rectangle CollisionShape2D).
@export var platform_path: NodePath
## The line the tower must stand above: a TowerGoalLine.
@export var goal_line_path: NodePath

## True once the stack has stood above the goal line (won emitted), until reset().
var has_won: bool = false

var _hold: float = 0.0
var _height: float = 0.0
var _top_y: float = INF
var _stack: Array[Goo2D] = []

@onready var _platform: TowerSlab = get_node_or_null(platform_path) as TowerSlab
@onready var _goal: TowerGoalLine = get_node_or_null(goal_line_path) as TowerGoalLine

func _ready() -> void:
	super()
	if _platform == null:
		push_warning("TowerWorld: platform_path does not point at a TowerSlab")
	if _goal == null:
		push_warning("TowerWorld: goal_line_path does not point at a TowerGoalLine")

## GooTuning's tuning of `shape`, stiffened: skin and bending stiffness times
## `stiffness`, their damping times its square root (a spring's damping ratio
## is c / (2 √(k m)), so it stays as GooTuning measured it), shape matching
## times `stiffness` × `shape_hold`, pressure times `stiffness` (at most
## MAX_PRESSURE_SCALE), linear damping `air_drag` (when not 0), `friction`
## and `bounce`. The ring's
## geometry (bead_count, bead_radius, spacing, target_area) is GooTuning's, as
## cuts and merges need.
func tuning_for(shape: GooShape, tags: Array = []) -> Dictionary:
	var values := super(shape, tags)
	for key: String in ["skin_stiffness", "bending_stiffness"]:
		values[key] = float(values[key]) * stiffness
	var damping_scale := sqrt(stiffness)
	for key: String in ["skin_damping", "bending_damping"]:
		values[key] = float(values[key]) * damping_scale
	values["shape_match_k"] = float(values["shape_match_k"]) * stiffness * shape_hold
	values["pressure_k"] = float(values["pressure_k"]) * minf(stiffness, MAX_PRESSURE_SCALE)
	if air_drag > 0.0:
		values["linear_damp"] = air_drag
	values["friction"] = friction
	values["bounce"] = bounce
	return values

## Blocks stay separate unless `allow_merging`, then the default rule decides,
## up to a merged body of GooTuning.max_radius().
func may_merge(a: Goo2D, b: Goo2D) -> bool:
	if not allow_merging:
		return false
	return GooTuning.merged_radius(a.radius, b.radius) <= GooTuning.max_radius() and can_merge(a, b)

## The merged block keeps the colour of the first of the pair (only with
## allow_merging).
func merged_color(a: Goo2D, _b: Goo2D) -> Color:
	return a.color

func _physics_process(delta: float) -> void:
	super(delta)
	_despawn_fallen()
	_measure(delta)

## Empties the world and clears the win, the hold and the height.
func reset() -> void:
	clear()
	_stack.clear()
	has_won = false
	_hold = 0.0
	_top_y = INF
	_set_height(0.0)

## The platform node (null when platform_path is not set).
func platform() -> TowerSlab:
	return _platform

## The goal line node (null when goal_line_path is not set).
func goal_line() -> TowerGoalLine:
	return _goal

## Global y of the platform's top face.
func platform_top() -> float:
	return _platform.top_y() if _platform != null else INF

## Global y of the goal line.
func goal_y() -> float:
	return _goal.global_position.y if _goal != null else -INF

## Height, in px, of the goal line above the platform's top.
func goal_height() -> float:
	return platform_top() - goal_y()

## Height, in px, of the stack's top above the platform's top (0 for no stack),
## as last measured (every physics frame).
func tower_height() -> float:
	return _height

## Global y of the stack's top (the topmost bead's collision edge), INF when
## nothing rests on the platform; as last measured.
func tower_top() -> float:
	return _top_y

## The blocks that make up the stack: resting (settled, or slower than
## REST_SPEED) on the platform, or on another block of the stack; as last
## measured (every physics frame), bottom up as they were found.
func stack() -> Array[Goo2D]:
	var result: Array[Goo2D] = []
	for item: Variant in _stack:
		# A block despawned or freed since the measure is left out.
		if is_instance_valid(item) and not (item as Goo2D).is_queued_for_deletion():
			result.append(item as Goo2D)
	return result

## The stack measured from where the blocks are now (stack() is the last
## physics frame's).
func find_stack() -> Array[Goo2D]:
	var result: Array[Goo2D] = []
	if _platform == null:
		return result
	var candidates: Array[Goo2D] = []
	var boxes: Array[Rect2] = []
	for body: Goo2D in bodies():
		if body.particle_count() == 0 or not _resting(body):
			continue
		candidates.append(body)
		boxes.append(body.bead_bounds().grow(body.bead_radius() + SUPPORT_SLOP))
	var in_stack: Array[bool] = []
	in_stack.resize(candidates.size())
	in_stack.fill(false)
	var platform_rect := _platform.global_rect()
	var frontier: Array[int] = []
	for i: int in candidates.size():
		if boxes[i].intersects(platform_rect):
			in_stack[i] = true
			frontier.append(i)
	while not frontier.is_empty():
		var i: int = frontier.pop_front()
		result.append(candidates[i])
		for j: int in candidates.size():
			if not in_stack[j] and boxes[j].intersects(boxes[i]):
				in_stack[j] = true
				frontier.append(j)
	return result

# A body counts as resting when the kernel settled it or it barely moves.
static func _resting(body: Goo2D) -> bool:
	return body.settled or body.average_velocity().length() < REST_SPEED

# Despawns the blocks that fell off the platform or off the screen.
func _despawn_fallen() -> void:
	if _platform == null:
		return
	var rect := _platform.global_rect()
	for body: Goo2D in bodies():
		if body.particle_count() == 0:
			continue
		var centre := body.center()
		var beside := centre.x < rect.position.x or centre.x > rect.end.x
		if centre.y > OUT_Y or (beside and centre.y > rect.position.y + DESPAWN_DEPTH):
			despawn(body)

# Measures the stack, holds the win timer and emits won.
func _measure(delta: float) -> void:
	_stack = find_stack()
	var top := INF
	for body: Goo2D in _stack:
		top = minf(top, body.bead_bounds().position.y - body.bead_radius())
	_top_y = top
	_set_height(maxf(platform_top() - top, 0.0) if top < INF else 0.0)
	if has_won:
		return
	if top < goal_y():
		_hold += delta
		if _hold >= WIN_HOLD or _all_settled():
			has_won = true
			won.emit()
	else:
		_hold = 0.0

func _all_settled() -> bool:
	for body: Goo2D in bodies():
		if not body.settled:
			return false
	return true

func _set_height(height: float) -> void:
	if absf(height - _height) >= 1.0 or (height == 0.0) != (_height == 0.0):
		_height = height
		height_changed.emit(height)
