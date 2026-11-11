@tool
@icon("res://addons/goo2d/icon_goo2d.svg")
class_name Goo2D
extends Node2D
## A soft, wet, jiggly body of goo: a hollow ring of beads (small circles,
## particles of the native kernel's solver) held together by skin constraints
## (to each neighbour) and bending constraints (to the bead after next),
## inflated by a pressure constraint toward `target_area`, pulled toward its
## rest shape (shape matching: the rest outline moved rigidly onto the beads,
## best-fit rotation) and damped internally (each bead's motion relative to the
## ring's mean). Its Skin child is a Polygon2D drawn around the smoothed ring,
## shaded as wet goo by GooSkin (res://addons/goo2d/goo.gdshader).
##
## Building: the static builders make(), make_merged() and make_from_loop()
## create a body at runtime from GooTuning.tuning() of its radius, or
## GooTuning.tuning_for() of its `shape`, unless given a tuning of their own
## (a GooWorld2D passes its tuning_for()'s). A Goo2D placed in a scene builds
## itself in _ready() from its exports `radius`, `sides` and `outline`, tuned
## by its parent GooWorld2D's tuning_for() (GooTuning's outside any world).
##
## In the editor: the script is a tool script only so that a placed body shows
## its rest outline (_draw(), see preview_outline()). There it builds nothing,
## runs no physics and adds nothing to the scene but its unowned Skin child,
## which the editor never saves.
##
## The beads live in the native kernel (GooKernel, a Rust GDExtension:
## addons/goo2d/native/), not in the scene tree: once the ring is built and in
## the tree it is a ring of its parent GooWorld2D's kernel, or, outside any
## world, of the kernel lone bodies share. There are no RigidBody2D, joint or
## collision nodes and no physics server bodies: the kernel's position-based
## solver moves the beads (gravity, the ring's constraints, contacts with other
## beads and with the static shapes registered from the scene, see GooStatics)
## once per physics frame (in the world's _physics_process, or at
## SceneTree.physics_frame for lone bodies), then detects calm and settles,
## scans for pinches and rebuilds the skin outline. bead_points(), center(),
## bead_bounds(), area() read where the last step left the beads. This node
## turns the kernel's events into signals and node state (dispatch_events()):
## it emits `touched` once for each other body its beads touch
## (report_contact()) and `pinched` when it should be split. It also carries the
## state a GooWorld2D keeps on it (`id`, `merging`, `merge_lock_until`); the
## world decides what its contacts and pinches mean. Out of the tree a built
## body keeps its beads' last positions and velocities and takes them back into
## a kernel when it returns.
##
## Layout: the Skin child has no transform of its own and the beads are in
## global space. The node itself stays where it was built: at its parent's
## origin for a body a builder made, where it was put for one placed in a
## scene. center() is the centroid of the beads: use it for where the body is,
## never position.
##
## The bead centres sit on a circle of tuning["ring_radius"], about one bead
## radius inside the body's radius, so the beads' collision outline is the
## body's circle and encloses exactly target_area at rest. Every area here
## (area(), target_area) is the area inside that outline: the bead loop's area
## plus a band one bead radius wide around it.
##
## Other shapes: setup(), rebuild_from() and build_from_loop() take an
## optional rest loop (a GooShape's bead loop, see make() and
## GooTuning.tuning_for()); the ring is then built on it and rest_shape is
## it, so the constraints' rest lengths and the shape matching hold that outline
## instead of a circle. Without one, every path is the round ring's. Beads
## where the rest loop turns by more than CORNER_ANGLE are corners: the skin
## keeps them sharp instead of smoothing them away.
##
## Self-collision: beads 1 and 2 apart along the ring never collide; every other
## pair of beads does, which keeps a squeezed ring from folding through itself.
##
## Settling: once no bead has moved more than settle_speed × settle_time over
## any settle_time window for settle_time (three samples of a history window,
## in the kernel), and the same holds for every ring it touches (directly or
## through others), the group settles: its beads stop where they are and the
## solver leaves them alone. A contact that presses into a settled ring (or
## closes on it fast) wakes it, as do apply_impulse() and set_velocity().
## A settled body's skin is drawn until its smoothed velocity has died away
## and then left alone (skin_at_rest()) until it wakes.
##
## Splitting: the body watches its own shape and emits `pinched` when it should
## be cut in two, in either of two ways. A pinch: two beads far apart along the
## ring come within tuning["split_neck"] of each other across the ring's inside
## (see pinch()) for GooTuning.SPLIT_HOLD seconds, whatever squeezed it (a
## wedge, a wall corner, a post, another body). An impact: the ring is crushed
## under tuning["splat_area_ratio"] of its target area for
## GooTuning.SPLAT_HOLD_FRAMES frames, its pressure overcome; it is then cut
## across its long axis. Neither fires while the ring is settled, nor for
## GooTuning.SPLIT_LOCK seconds after it was built or after it fired. A
## GooWorld2D does the cutting (two bodies built with make_from_loop()).

# ---- State and exports ----

## Emitted while one of this body's beads touches a bead of `other`: once per
## physics frame and other body, every frame the contact lasts (from the
## kernel's step, outside the physics flush: handlers may add or free physics
## nodes). Not emitted while the body is settled, nor while either body is
## merging or being freed.
signal touched(other: Goo2D)
## Emitted, outside the physics flush, when the ring should split along the
## chord from bead `a` to bead `b` (indices into bead_points()); GooWorld2D cuts it.
## Fires once, then not again for GooTuning.SPLIT_LOCK seconds.
signal pinched(a: int, b: int)

## Largest pressure, as a multiple of pressure_k: the force a ring squeezed to
## a fifth of its area gets. Keeps a crushed ring from exploding.
const MAX_PRESSURE_RATIO: float = 4.0
## Smallest area, as a fraction of the target, the pressure is computed from.
const MIN_AREA_RATIO: float = 0.01
## Chaikin passes that smooth the skin.
const SKIN_SMOOTHING: int = 2
## Concave turn of the bead loop, in radians, above which a bead is a kink the
## skin offset is clamped around (skin_offset()). A gentler bend cannot fold
## the offset: its curvature radius is several bead radii.
const SKIN_KINK_TURN: float = 0.2
## Beads either side of a kink, along the loop, whose skin offsets are clamped
## against each other: enough to span a slot whose floor is two or three beads.
const SKIN_KINK_REACH: int = 4
## Largest fraction of the gap between two beads near a kink that their skin
## offsets may close; past it the offsets are shortened (a mitre limit), so the
## points stay in order instead of crossing.
const SKIN_KINK_CLEARANCE: float = 0.75
## Most times a skin outline that crosses itself is cut at a crossing into two
## loops (GooLoop.split_at_crossings()) before what is left is drawn as it is:
## a ring folded through itself crosses its outline two to four times; a loop
## tangled past this budget is not worth more polygons.
const SKIN_MAX_SPLITS: int = 8
## Pixels a skin polygon that still cannot be drawn after that (its edges touch
## or overlap without crossing) is grown by to repair it: enough for
## Geometry2D.offset_polygon() to resolve it into simple boundaries (it
## returns the polygon untouched for a zero offset), too little to see.
const SKIN_REPAIR_GROW: float = 0.01
## Turn of the rest shape, in radians, above which a bead is a corner the skin
## keeps sharp (see corner_flags()). 30° marks every corner of a square (90°) or
## a triangle (120°) and no bead of a round ring: the smallest ring's 12 beads
## turn exactly 30° (CORNER_TOLERANCE keeps rounding from making corners of them).
const CORNER_ANGLE: float = PI / 6.0
## Radians over CORNER_ANGLE a turn must reach to count as a corner: a round
## ring of 12 beads turns PI / 6 to within rounding (a few millionths of a
## degree), which must not make every bead a corner (unsmoothed skin, the
## pinch scan's rest check meant for shapes).
const CORNER_TOLERANCE: float = 0.001
## Pixels, at GooTuning.unit 1, the old rings' collision outlines are grown by
## before a merge unites them (merge_grow() scales it by the unit), so rings
## pressed together overlap and merge into one outline. Small, so the new ring
## never reaches into a neighbour (the union of two rings' outlines holds no
## other ring).
const MERGE_GROW: float = 2.0
## How far, in bead radii of the merged ring, merge_placement() fills the
## creases of a merged outline before placing beads on it (grows it by this
## much, then shrinks it back): the waist of two rings that only just touch
## would otherwise put beads on either side of it within a bead diameter of
## each other, and the self-collision would throw them apart in one step.
const MERGE_CLOSE_BEADS: float = 2.0
## Passes spread_apart() makes at most.
const SPREAD_PASSES: int = 8
## Times _inset() halves its distance looking for an inset of a merged outline
## that is still one piece.
const INSET_TRIES: int = 4
## Seconds a calm ring waits before asking its contact group again after the
## group was not calm (in the kernel).
const GROUP_CHECK_INTERVAL: float = 0.25
## Speed, px/s, under which a settled ring's skin velocity (GooSkin's
## smoothing of average_velocity(), zero while settled) counts as stopped: the
## skin is then drawn one last time with it at exactly zero and left alone
## until the ring wakes (skin_at_rest()). A hundredth of a pixel per second
## moves nothing on screen.
const SKIN_REST_SPEED: float = 0.01
## Longest a skin edge (between neighbouring beads) may get, as a multiple of
## its rest length: a hard constraint of the kernel's solver, every substep.
## The skin constraints are soft, 400× softer on the largest ring than on the
## smallest (GooTuning.SKIN_FREQUENCY_RATIO), so without a limit a 2500 px/s
## impact stretched one edge of a 140 px ring by 70% and opened a 12-16 px hole
## between its beads, wide enough for a launch-size body's bead to slip into
## the ring. At 1.3 the beads (BEAD_RADIUS_RATIO 0.6 of the spacing) part by at
## most a tenth of the rest spacing, about 3 px on the largest ring.
const MAX_STRETCH: float = 1.3
## The kinds of GooKernel event records (take_events(): four integers each,
## [kind, ring key, x, y]; a ring key is a Goo2D's instance id), see
## dispatch_events().
const EVENT_TOUCHED: int = 0
const EVENT_PINCHED: int = 1
const EVENT_SETTLED: int = 2
const EVENT_WOKE: int = 3
## The pinch scan (O(beads²) at worst, a handful of pairs for a ring that is not
## pressed in) runs every this many physics frames. It was 4; with the
## kernel's solver a launch-size blob thrown onto the wedge's apex wraps it for
## 5 to 7 frames and springs off, so a scan every 4 frames saw the neck once or
## twice depending on the phase (a 48 px blob at 1200 px/s held it 7 frames and
## did not split); every 2 frames sees it 3 times.
const PINCH_SCAN_FRAMES: int = 2
## How far a ring must be pressed in at a pair of beads for the chord between
## them to count as a neck (see pinch()): the fraction of the ring's convex
## hull thickness across the chord that lies outside the ring. 0.2 let short
## chords near one end of a ring on the wedge count as necks, so launch-size
## blobs asked to be cut into a crumb (13 + 38 px of a 40 px blob, refused) and
## then stayed locked instead of splitting in two.
const PINCH_CONSTRICTION: float = 0.3
## Opacity of the rest outline's fill in the editor preview (_draw()); its edge
## is drawn opaque, PREVIEW_EDGE_WIDTH px wide.
const PREVIEW_ALPHA: float = 0.35
const PREVIEW_EDGE_WIDTH: float = 1.0
## The `color` that means "by size": the body is drawn in GooTuning.color() of
## its radius (base_color()). Transparent black, which no goo is drawn in.
const COLOR_BY_SIZE := Color(0, 0, 0, 0)

## Nominal radius in px; sizes are continuous (see GooTuning), and the
## colour follows from it unless `color` is set. For a shape other than round,
## its equivalent radius (GooShape.radius()), so every size rule reads it alike.
## The inspector's slider spans the sizes at GooTuning.unit 1 and takes any
## other (14 … 88 px at unit 0.5); the default stays MIN_RADIUS, the unit-1
## size, so a scene saved with it keeps its size whatever the unit.
@export_range(28.0, 176.0, 0.5, "or_less", "or_greater") var radius: float = GooTuning.MIN_RADIUS:
	set(value):
		radius = value
		_preview_changed()
## 0: a round blob. 3 or more: a regular polygon of that many sides resting on one.
## Read only by a body placed in a scene, when it builds itself in _ready().
@export_range(0, 12) var sides: int = 0:
	set(value):
		sides = value
		_preview_changed()
## A custom rest outline in px, any orientation (overrides `sides` when it has 3+ points),
## scaled to the equivalent radius `radius`. Read only by a body placed in a scene.
@export var outline: PackedVector2Array = PackedVector2Array():
	set(value):
		outline = value
		_preview_changed()
## The colour the goo is drawn in (base_color()). COLOR_BY_SIZE (the default)
## draws it in GooTuning.color() of its radius. Setting it on a built body
## retints it at once; on a two-tone body it is the primary colour and the
## second colour is kept. A piece of a split or trim keeps its parent's colour
## (inherit_look()); a merged body takes the one its world decides
## (GooWorld2D.merged_color(), or with two-tone merges the first of
## GooWorld2D.merged_colors()). set_tint() still sets the colour drawn for the
## moment (a merge's tint and flash), which goes back to this one after.
@export var color: Color = COLOR_BY_SIZE:
	set(value):
		color = value
		if _count > 0:
			reset_tint()
		_preview_changed()
## A two-tone body's second colour (is_two_tone()): drawn on the far side of
## its division (division_axis, division_offset), `color` on this side, the
## two faded into each other over the shader's `division_fade`. COLOR_BY_SIZE
## (the default) means none: the body is drawn in `color` alone. Setting it on
## a built body retints it at once; set_two_tone() sets it with the division,
## clear_two_tone() takes it away. A world sets it on a merged body when its
## GooWorld2D.two_tone_merges is on; the pieces of a split or trim keep it,
## half and half (inherit_look()).
@export var second_color: Color = COLOR_BY_SIZE:
	set(value):
		second_color = value
		if _count > 0:
			reset_tint()
## The shader the skin is drawn with; null for the addon's goo shader
## (goo.gdshader). Any canvas_item shader works: GooSkin pushes it the uniforms
## of the contract at the top of goo.gdshader (it may declare any subset), and
## COLOR is the body's tint. A world's GooWorld2D.skin_shader fills in a null
## one; split pieces and merged bodies keep their parent's (inherit_look()).
## Takes effect at once, built or not.
@export var skin_shader: Shader = null:
	set(value):
		skin_shader = value
		if _goo != null:
			_goo.set_shader(value)

## How much the skin's patterns (the bubbles, a two-tone division, a facet
## cut: everything the `rotation` uniform turns) roll with the body's sideways
## motion on top of the ring's own rotation (GooSkin.motion_roll): 1 turns them
## as a wheel of the body's radius would at its horizontal speed, so a body
## sliding over slick ground reads as rolling; 0, the default, the ring's
## rotation alone. Split pieces and merged bodies keep their parent's, and the
## roll so far (inherit_look()).
@export var skin_roll: float = 0.0:
	set(value):
		skin_roll = value
		if _goo != null:
			_goo.motion_roll = value

## A two-tone body's division (see second_color): a unit vector in the body's
## rest space (the frame of rest_shape, turned into the world by
## ring_rotation() about center()), pointing toward second_color's side.
## Vector2.RIGHT for a body of one colour. Set it with set_two_tone().
var division_axis: Vector2 = Vector2.RIGHT
## How far along division_axis, in px from the rest centroid, a two-tone
## body's division crosses it: 0 half and half, above 0 shifted toward the
## second colour's side (so `color` owns the larger share: dominant_color()),
## below 0 the other way. Set it with set_two_tone().
var division_offset: float = 0.0

## The body's rest outline: GooShape.round(radius) for a round body, the
## polygon it was built from otherwise (see make()). Never null once the body
## is built.
var shape: GooShape = null
## Identifier assigned by GooWorld2D, unique within one world; -1 until a
## world registers the body. Small enough for the 32-bit pairs of
## GooWorld2D.MergeQueue, unlike the instance id.
var id: int = -1
## What the body is to the game: its kinds, in order, each entry whatever the
## game puts there (a StringName, a kind resource); empty by default. The first
## is the one that counts for now (tag()): what a world's
## GooWorld2D.tuning_for() and may_merge() read. The addon never reads them
## beyond carrying them: GooWorld2D.spawn() sets them (a copy of the caller's
## list) and tuning_for() sees them when the ring is built; the pieces of a
## split and a trimmed body get a copy of their parent's list (never the same
## array object twice); a merged body gets GooWorld2D.merged_tags() of the pair
## (by default their union in order, without duplicates), which is what the
## list is there for: merging bodies of different kinds into new ones. A plain
## var, not an export: a game sets it in code. A body placed in a scene has
## none unless they are set before it enters the tree.
var tags: Array = []
## True while GooWorld2D pulls this body into a merge; its contacts are then ignored.
var merging: bool = false
## Physics time (s since the engine started, counted in physics frames) until
## which GooWorld2D will not merge this body (see GooWorld2D.merge_locked()):
## set for bodies made by a merge or a split (GooWorld2D.MERGE_LOCK), 0 for
## spawned and placed ones.
var merge_lock_until: float = 0.0

## What the ring was built from: GooTuning.tuning_for() of its shape (for a
## round body, GooTuning.tuning() of its radius), or what its world's
## GooWorld2D.tuning_for() made of that.
var tuning: Dictionary = {}
## Area, in px², the pressure inflates the ring's collision outline toward.
## After a merge, tweened from the old rings' area to the new radius's.
var target_area: float = 0.0:
	set(value):
		target_area = value
		if _kernel != null:
			_kernel.set_ring_param(_key, &"target_area", value)
## How far the rest lengths of the skin and bending constraints are from those
## of the loop the ring was built on (0) to those of its rest shape (1). 1 for
## every ring but a merged one or a piece of a split or trim: rebuild_from()
## places a merged ring on the union of its pair, which is longer around than
## its rest shape (or, for a fused shape, shaped otherwise), and
## build_from_loop() places a piece on the loop cut from its parent's beads,
## which is smaller than its rest shape (a small tip's starts at about half its
## area) or shaped otherwise; both tween this from 0 to 1 over inflate_time with
## target_area, so the skin eases into its rest lengths instead of snapping to
## them in one step. The kernel's ring parameter "rest_blend"; a ring that
## leaves the tree and comes back takes its beads then as the loop it was built
## on.
var rest_blend: float = 1.0:
	set(value):
		rest_blend = value
		if _kernel != null:
			_kernel.set_ring_param(_key, &"rest_blend", value)
## True while the ring is calm and its beads rest where they are; the solver
## leaves them alone then. The kernel's state (read only).
var settled: bool:
	get:
		return _kernel != null and _kernel.is_settled(_key)
## The rest ring the shape matching pulls toward, relative to its centroid.
var rest_shape: PackedVector2Array = PackedVector2Array()

# Number of beads (0 until built).
var _count: int = 0
# The beads' positions and velocities while the ring is in no kernel (unbuilt,
# or out of the tree): taken from the kernel when the body leaves the tree and
# given back when it returns.
var _points: PackedVector2Array = PackedVector2Array()
var _velocities: PackedVector2Array = PackedVector2Array()
var _skin: Polygon2D
var _goo: GooSkin
# The second colour the skin is drawn in now (get_second_tint()).
var _second_tint: Color = COLOR_BY_SIZE
# How far toward white the merge flash draws the body now (0: not at all).
var _flash: float = 0.0
var _bead_mass: float = 0.0
# The beads' total mass (body_mass()), summed when the ring is built.
var _body_mass: float = 0.0
var _bead_radius: float = 0.0
var _frictionless_on: bool = false
# One byte per bead, 1 where rest_shape turns by more than CORNER_ANGLE; set at
# each build. _has_corners is true if any is set.
var _corner_flags: PackedByteArray = PackedByteArray()
var _has_corners: bool = false
# Shortest rest-shape distance, px, between two beads that may count as a neck
# on a ring with corners: what a round ring of tuning["ring_radius"] has
# between beads a quarter of the ring apart. Set at each build.
var _min_neck_rest: float = 0.0
# How far each bead of rest_shape lies inside its convex hull (hull_depths()),
# so pinch() reads a notch the rest shape has (a fused body's) as no neck. Set
# at each build from a rest loop; empty for a round ring, which has none.
var _rest_depths: PackedFloat32Array = PackedFloat32Array()
# Rest length of each skin edge i → i+1 (from rest_shape), for the skin
# constraints and the stretch limit (MAX_STRETCH). Set at each build.
var _rest_edges: PackedFloat32Array = PackedFloat32Array()
# The kernel this ring is a ring of (its world's, or _lone_kernel), and its key
# there (this node's instance id); null while the ring is unbuilt or out of the
# tree (_register_ring(), _unregister_ring()).
var _kernel: GooKernel = null
var _key: int = 0
# The kernel's skin_version() when _update_skin() last took the skin, and the
# shader outline it took with it.
var _skin_version: int = -1
var _shader_points: PackedVector2Array = PackedVector2Array()
# True once _update_skin() drew the settled ring with its skin velocity
# stopped, at target area _skin_rest_area (see skin_at_rest()).
var _skin_resting: bool = false
var _skin_rest_area: float = 0.0

# The kernel of every built Goo2D outside a GooWorld2D, stepped by
# _step_lone() at SceneTree.physics_frame, and the static shapes it collides
# with; null while there is none.
static var _lone_kernel: GooKernel = null
static var _lone_statics: GooStatics = null

# Creates the Skin child, empty until the body is built. It gets no owner, so a
# scene holding the body (saved by the editor, or packed with
# PackedScene.pack()) never stores it. Runs in the editor too (a tool script):
# it must not touch physics or the tree beyond this child.
func _init() -> void:
	name = "Goo2D"
	_skin = Polygon2D.new()
	_skin.name = "Skin"
	_skin.antialiased = true
	add_child(_skin)
	_goo = GooSkin.new()
	_goo.motion_roll = skin_roll
	_goo.attach(_skin)

# A body placed in a scene builds itself: round of `radius`, a regular
# polygon of `sides`, or `outline`, centred where it was placed. A body made by
# a builder (or Goo2D.new()) is added to the tree first and built after, so it
# does not build here.
func _ready() -> void:
	if _count == 0 and not Engine.is_editor_hint() and _placed_in_scene():
		shape = GooShape.round(radius)
		var placed := _placed_shape()
		var world := get_parent() as GooWorld2D
		var ring_tuning := world.tuning_for(sized_shape(radius, placed), tags) if world != null else {}
		_setup_shape(radius, global_position, placed, ring_tuning)

## The body's first tag, the one that counts for now (see `tags`); null
## without one.
func tag() -> Variant:
	return null if tags.is_empty() else tags[0]

# The ring leaves its kernel when the body leaves the tree, keeping its beads'
# positions and velocities, and joins its parent's kernel again with them if it
# comes back built.
func _notification(what: int) -> void:
	match what:
		NOTIFICATION_POST_ENTER_TREE:
			if _kernel == null and _count > 0:
				_register_ring(_points)
		NOTIFICATION_EXIT_TREE, NOTIFICATION_PREDELETE:
			_unregister_ring()

# Makes the built ring, whose beads are at the global `points` moving at
# _velocities, a ring of the kernel of its parent GooWorld2D, or of
# _lone_kernel outside any world.
func _register_ring(points: PackedVector2Array) -> void:
	if Engine.is_editor_hint() or _count == 0 or not is_inside_tree():
		return
	_unregister_ring()
	var world := get_parent() as GooWorld2D
	_kernel = world.kernel() if world != null else _lone(get_tree())
	_key = get_instance_id()
	var params := {
		"radius": radius,
		"bead_mass": _bead_mass,
		"bead_radius": _bead_radius,
		"pressure_k": tuning["pressure_k"],
		"shape_match_k": tuning["shape_match_k"],
		"internal_damp": tuning["internal_damp"],
		"settle_speed": tuning["settle_speed"],
		"settle_time": tuning["settle_time"],
		"split_neck": tuning["split_neck"],
		"splat_area_ratio": tuning["splat_area_ratio"],
		"min_neck_rest": _min_neck_rest,
		"target_area": target_area,
		"split_lock": GooTuning.SPLIT_LOCK,
		"skin_stiffness": tuning["skin_stiffness"],
		"skin_damping": tuning["skin_damping"],
		"bending_stiffness": tuning["bending_stiffness"],
		"bending_damping": tuning["bending_damping"],
		"linear_damp": tuning["linear_damp"],
		"bounce": tuning["bounce"],
		"friction": tuning["friction"],
	}
	_kernel.add_ring(_key, points, rest_shape, _rest_edges, _rest_depths, _corner_flags, params)
	if rest_blend < 1.0:
		_kernel.set_ring_param(_key, &"rest_blend", rest_blend)
	if _velocities.size() == _count:
		_kernel.set_velocities(_key, _velocities)
	if _frictionless_on:
		_kernel.set_frictionless(_key, true)
	_skin_version = -1

# Takes the ring out of its kernel, if it is in one, keeping where its beads
# were and how they moved.
func _unregister_ring() -> void:
	if _kernel == null:
		return
	_points = _kernel.points(_key)
	_velocities = _kernel.velocities(_key)
	_kernel.remove_ring(_key)
	if _kernel == _lone_kernel and _lone_kernel.ring_count() == 0:
		_release_lone()
	_kernel = null

# The kernel lone bodies share, made (and hooked to `tree`'s physics frames)
# on first use.
static func _lone(tree: SceneTree) -> GooKernel:
	if _lone_kernel == null:
		_lone_kernel = GooTuning.make_kernel()
		_lone_statics = GooStatics.new(_lone_kernel)
		_lone_statics.attach(tree)
	if not tree.physics_frame.is_connected(_step_lone):
		tree.physics_frame.connect(_step_lone)
	return _lone_kernel

# Drops the lone kernel once its last ring left (and stops stepping it).
static func _release_lone() -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree != null and tree.physics_frame.is_connected(_step_lone):
		tree.physics_frame.disconnect(_step_lone)
	if _lone_statics != null:
		_lone_statics.detach()
	_lone_statics = null
	_lone_kernel = null

# One physics frame of every lone body: the static shapes brought up to date,
# then the kernel's step and its events.
static func _step_lone() -> void:
	if _lone_kernel == null:
		return
	_lone_statics.sync()
	_lone_kernel.step(Engine.time_scale / Engine.physics_ticks_per_second)
	dispatch_events(_lone_kernel.take_events())

## Turns the events of a GooKernel step (GooKernel.take_events(), see the
## EVENT_* constants) into signals and node state: `touched` (report_contact()),
## `pinched`, the skin's rest state when a ring woke. Called by whoever stepped
## the kernel, outside the physics flush. Events of a body freed since are
## dropped.
static func dispatch_events(events: PackedInt64Array, world: GooWorld2D = null) -> void:
	var size := events.size()
	var i := 0
	while i + 3 < size:
		var body := instance_from_id(events[i + 1]) as Goo2D
		if body != null:
			match events[i]:
				EVENT_TOUCHED:
					var other := instance_from_id(events[i + 2]) as Goo2D
					if body.can_report(other):
						if world != null and body.id >= 0 and other.id >= 0 and body.get_parent() == world:
							world.judge_contact(other, body)
						body.touched.emit(other)
				EVENT_PINCHED:
					body.pinched.emit(events[i + 2], events[i + 3])
				EVENT_WOKE:
					body._on_woke()
		i += 4

# The ring woke: its skin is drawn again.
func _on_woke() -> void:
	_skin_resting = false

# The rest outline the exports describe, before _setup_shape() scales a polygon
# to `radius`: `outline` if it has 3+ points, else round (`sides` 0) or the
# regular polygon of `sides`.
func _placed_shape() -> GooShape:
	return GooShape.polygon(outline) if outline.size() >= 3 \
		else GooShape.round(radius) if sides == 0 else GooShape.regular(sides, radius)

# True for a body instanced from a scene (placed in the editor): it has an
# owner, or is the root of its own scene. A builder's body has neither.
func _placed_in_scene() -> bool:
	return owner != null or not scene_file_path.is_empty()

# ---- Building ----

## Builds the ring of `radius` centred on `global_pos` from `ring_tuning`
## (GooTuning.tuning(radius)). With a `rest_loop` (global bead centres,
## CCW, exactly tuning["bead_count"] of them, e.g. a GooShape's bead loop
## moved to `global_pos`, with `ring_tuning` its GooTuning.tuning_for()),
## the beads are built on it and rest_shape is it about its centroid, and
## `global_pos` is not used; without, on the circle of tuning["ring_radius"]
## around `global_pos`. Call once, with the body inside the tree and outside
## the physics flush.
func setup(radius: float, global_pos: Vector2, ring_tuning: Dictionary,
		rest_loop: PackedVector2Array = PackedVector2Array()) -> void:
	_configure(ring_tuning)
	var count: int = tuning["bead_count"]
	if rest_loop.is_empty():
		var ring_radius: float = tuning["ring_radius"]
		_build(radius, GooLoop.circle_points(global_pos, ring_radius, count))
	else:
		if rest_loop.size() != count:
			push_error("setup() takes a rest loop of %d beads, got %d" % [count, rest_loop.size()])
		_build(radius, rest_loop, rest_loop)
	target_area = tuning["target_area"]
	_update_skin()

## Builds this body as the merge of `bodies` (the rings about to be removed):
## one ring of `radius` around the union of their collision outlines, its
## creases filled (merge_placement()), every bead moving like the nearest old
## bead, its target area tweened from that loop's to ring_tuning["target_area"]
## over inflate_time (the area of a circle of `radius`, or for a shape what its
## rest ring encloses, see GooTuning.tuning_for()), and its skin and bending
## rest lengths tweened with it from those of the loop it is placed on to its
## rest shape's (rest_blend from 0 to 1). If the rings no longer
## touch, the new ring is built around the lowest of them alone and inflates
## from there: the
## convex hull of rings apart would swallow whatever lies between them.
## With a `rest_loop` (global, CCW, the merged body's rest bead loop in the pose
## it should take), rest_shape is it about its centroid instead of a circle,
## and the beads go on the same outline at the same fractions of its perimeter
## as the rest loop's points (see _place_like()), starting at the outline's
## point nearest rest_loop[0], so bead i corresponds to rest point i. Call
## with this body inside the tree, before the old bodies leave it, outside the
## physics flush.
func rebuild_from(bodies: Array[Goo2D], radius: float, ring_tuning: Dictionary,
		rest_loop: PackedVector2Array = PackedVector2Array()) -> void:
	_configure(ring_tuning)
	var count: int = tuning["bead_count"]
	var old_points := PackedVector2Array()
	var old_velocities := PackedVector2Array()
	for body: Goo2D in bodies:
		old_points.append_array(body._frame_points())
		old_velocities.append_array(body.bead_velocities())
	var points := merge_placement(bodies, _bead_radius, count, rest_loop)
	if rest_loop.is_empty():
		_build(radius, points)
	else:
		_build(radius, points, _rest_of_count(rest_loop, count))
	var velocities := PackedVector2Array()
	for i: int in _count:
		velocities.append(old_velocities[_nearest(old_points, points[i])])
	_set_bead_velocities(velocities)
	target_area = area()
	rest_blend = 0.0
	var tween := create_tween()
	tween.set_process_mode(Tween.TWEEN_PROCESS_PHYSICS)
	tween.set_parallel()
	tween.tween_property(self, "target_area", float(tuning["target_area"]), float(tuning["inflate_time"]))
	tween.tween_property(self, "rest_blend", 1.0, float(tuning["inflate_time"]))
	_update_skin()

## Builds this body as one piece of a split ring: beads evenly spaced around the
## bead-centre loop `points` (either orientation), any two more than two apart
## along it that are closer than a bead diameter spread apart (spread_apart():
## a thin piece's beads across it would otherwise be thrown apart by the
## self-collision in its first step), each moving like the nearest
## point of `points` (`velocities` holds one velocity per point), its target
## area tweened from what the loop's collision outline encloses now to the area
## of a circle of `radius` over inflate_time, and its skin and bending rest
## lengths tweened with it from those of the loop it is placed on to its rest
## shape's (rest_blend from 0 to 1), so a piece cut smaller than its rest shape
## grows into it instead of snapping out to it. It cannot split for
## GooTuning.SPLIT_LOCK seconds.
## With a `rest_loop` (global, CCW, the piece's rest bead loop in the pose it
## should take), rest_shape is it about its centroid instead of a circle (a
## loop of another length is first resampled to tuning["bead_count"]), and the
## beads go on `points` at the rest loop's fractions of its perimeter (see
## _place_like()), starting at the point of `points` nearest rest_loop[0], so
## bead i corresponds to rest point i. Call with this body inside the tree,
## outside the physics flush.
func build_from_loop(points: PackedVector2Array, velocities: PackedVector2Array, radius: float,
		ring_tuning: Dictionary, rest_loop: PackedVector2Array = PackedVector2Array()) -> void:
	_configure(ring_tuning)
	var count: int = tuning["bead_count"]
	var loop := points.duplicate()
	var loop_velocities := velocities.duplicate()
	if not GooLoop.is_ccw(loop):
		loop.reverse()
		loop_velocities.reverse()
	var rest := PackedVector2Array() if rest_loop.is_empty() else _rest_of_count(rest_loop, count)
	var resampled := GooLoop.resample(loop, count) if rest.is_empty() else _place_like(loop, rest)
	resampled = spread_apart(resampled, 2.0 * _bead_radius)
	_build(radius, resampled, rest)
	var bead_velocities := PackedVector2Array()
	for i: int in _count:
		var nearest := _nearest(loop, resampled[i])
		bead_velocities.append(loop_velocities[nearest] if nearest < loop_velocities.size() else Vector2.ZERO)
	_set_bead_velocities(bead_velocities)
	target_area = area()
	rest_blend = 0.0
	var tween := create_tween()
	tween.set_process_mode(Tween.TWEEN_PROCESS_PHYSICS)
	tween.set_parallel()
	tween.tween_property(self, "target_area", float(tuning["target_area"]), float(tuning["inflate_time"]))
	tween.tween_property(self, "rest_blend", 1.0, float(tuning["inflate_time"]))
	_update_skin()

## `points` (a closed bead loop) with every two beads more than two apart
## along it that are closer than `distance` (two bead radii: the kernel's
## self-collision) pushed apart to it, each half the shortfall, in up to
## SPREAD_PASSES passes. A piece cut thin (a cap of a round ring, a corner)
## has beads across it within a bead diameter of each other; placed so, the
## self-collision throws them apart in the ring's first step.
static func spread_apart(points: PackedVector2Array, distance: float) -> PackedVector2Array:
	var result := points.duplicate()
	var count := result.size()
	var limit := distance * distance
	for pass_index: int in SPREAD_PASSES:
		var moved := false
		for i: int in count:
			for j: int in range(i + 3, count):
				if j - i > count - 3:
					continue
				var gap := result[j] - result[i]
				var length_sq := gap.length_squared()
				if length_sq >= limit:
					continue
				var length := sqrt(length_sq)
				var direction := gap / length if length > 0.000001 else Vector2.RIGHT
				var push := direction * (0.5 * (distance - length))
				result[i] -= push
				result[j] += push
				moved = true
		if not moved:
			break
	return result

# Sets bead i's velocity to velocities[i] (one per bead, or one for all),
# capped at GooTuning.MAX_BEAD_SPEED (the kernel caps them; out of a kernel,
# here, as it would).
func _set_bead_velocities(velocities: PackedVector2Array) -> void:
	if _kernel != null:
		_kernel.set_velocities(_key, velocities)
		return
	if velocities.size() == 1:
		_velocities.fill(_capped(velocities[0]))
	elif velocities.size() == _count:
		_velocities = velocities.duplicate()
		for i: int in _count:
			_velocities[i] = _capped(_velocities[i])

# `velocity` no longer than GooTuning.MAX_BEAD_SPEED (the kernel's cap).
static func _capped(velocity: Vector2) -> Vector2:
	return velocity.limit_length(GooTuning.MAX_BEAD_SPEED) if GooTuning.MAX_BEAD_SPEED > 0.0 else velocity

func _configure(ring_tuning: Dictionary) -> void:
	tuning = ring_tuning
	_bead_mass = tuning["bead_mass"]
	_bead_radius = tuning["bead_radius"]

# Builds the ring with its beads at the global `points`, at rest; the
# constraints' rest lengths and the rest shape come from `rest_loop` (one point
# per bead, any position: it is centred), or without one from the rest ring of
# `radius`. Then makes the ring a ring of its kernel (_register_ring()).
func _build(radius: float, points: PackedVector2Array,
		rest_loop: PackedVector2Array = PackedVector2Array()) -> void:
	var count := points.size()
	var ring_radius: float = tuning["ring_radius"]
	if rest_loop.is_empty():
		rest_shape = GooLoop.circle_points(Vector2.ZERO, ring_radius, count)
		_rest_depths = PackedFloat32Array()
	else:
		var centre := GooLoop.centroid(rest_loop)
		rest_shape = PackedVector2Array()
		for point: Vector2 in rest_loop:
			rest_shape.append(point - centre)
		_rest_depths = hull_depths(rest_shape)
	_rest_edges.resize(count)
	for i: int in count:
		_rest_edges[i] = rest_shape[i].distance_to(rest_shape[(i + 1) % count])
	_corner_flags = find_corners(rest_shape)
	_has_corners = _corner_flags.has(1)
	_min_neck_rest = 2.0 * ring_radius * sin(PI * maxi(count / 4, 2) / count)
	# By `radius` being built, which a setup() on a bare Goo2D.new() may not
	# have stored in the export. A two-tone body's second colour and division
	# are pushed with it.
	var primary := GooTuning.color(radius) if color == COLOR_BY_SIZE else color
	if is_two_tone():
		set_tint(primary, second_color)
	else:
		set_tint(primary)
	_count = count
	_points = points.duplicate()
	_velocities = PackedVector2Array()
	_velocities.resize(count)
	_body_mass = _bead_mass * count
	_register_ring(points)

# ---- Settling ----
#
# The kernel's solver applies, every substep of every awake ring: the skin and
# bending constraints (XPBD, compliance 1 / tuning["skin_stiffness"] and
# tuning["bending_stiffness"], their damping), the pressure (an area constraint
# toward target_area pushing like pressure_k × (target_area / area − 1) along
# the outline's normals; none while the ring is inside out: shape matching alone
# turns it back), shape matching toward the best-fit rest ring, the stretch
# limit (MAX_STRETCH), contacts, and internal damping of each bead's velocity
# relative to the ring's mean.

# The other rings this ring's beads touched when the kernel last read its
# contacts (this physics frame, or the last one before it settled), as long as
# they are still in play.
func _touching_rings() -> Array[Goo2D]:
	var rings: Array[Goo2D] = []
	if _kernel == null:
		return rings
	for key: int in _kernel.touching(_key):
		var other := instance_from_id(key) as Goo2D
		if other != null and not other.is_queued_for_deletion():
			rings.append(other)
	return rings

# Puts the ring to sleep now, as the kernel does when its contact group is calm.
func _settle() -> void:
	if _kernel == null:
		return
	_kernel.settle(_key)

# ---- Split detection ----

## The narrowest neck of the ring: the pair of beads `a`, `b` at least a quarter
## of the ring apart along it (both ways round) whose collision circles are
## closest, among the pairs that are a neck: the chord between them runs across
## the ring's inside (its middle inside the bead loop: the two sides of a dent
## wrapped around a corner are not a neck), and the ring is pressed in there,
## the two beads' depths inside the loop's convex hull adding up to at least
## PINCH_CONSTRICTION of the hull's thickness across the chord (centre distance
## plus both depths). A flattened ring's top and bottom sit on its hull, so a
## pancake, however thin, has no neck. Returned as { "a": int, "b": int,
## "gap": float, "constriction": float }, gap the distance between the two
## circles in px (centre distance − 2 × bead_radius()); gap is INF, a and b -1,
## when there is no neck.
##
## On a ring with corners, a pair must also be at least as far apart in the
## rest shape as two beads a quarter of a round ring of tuning["ring_radius"]
## apart. Index distance stands for distance across a circle, not across a
## corner: the closest beads a quarter of a triangle apart straddle a 60°
## corner, nearer each other at rest than a round ring's, and a triangle
## landing flat squashes its corners (its base rebounds first) enough for them
## to read as a neck. Measured on triangles of radius 28 … 48 dropped from the
## launch point and thrown down at up to 900 px/s: without this, every size
## asked to have a corner cut off on landing and 3 of 20 landings did (the
## other cuts left a piece under GooWorld2D.MIN_PIECE_RATIO); with it, none of 40
## landings at up to 1200 px/s split. A round ring's beads a quarter ring apart
## are exactly that far apart, and round rings do not check it at all.
##
## A ring built on a rest loop is pressed in only as far as it is deeper inside
## its hull than its rest shape is (each bead's depth less its rest depth, never
## under zero): the notch of two shapes fused at a step (GooShape.fused()) is
## part of the body's shape, not a neck, and only squeezing it further counts.
## A convex rest shape's depths are all zero, and a round ring has none.
func pinch() -> Dictionary:
	return find_pinch(_frame_points(), _bead_radius, PINCH_CONSTRICTION, _neck_rest(), _min_neck_rest,
		_rest_depths)

## pinch() of the bead loop `points` with beads of `bead_size` radius, counting
## pairs pressed in by at least `min_constriction`. With a `rest` loop of as
## many points (the ring's rest shape), pairs closer than `min_rest_distance`
## px in it are not counted. With `rest_depths` (one per point, hull_depths()
## of the rest shape), each point counts as pressed in only by how much deeper
## than that it lies inside the loop's hull.
static func find_pinch(points: PackedVector2Array, bead_size: float, min_constriction: float,
		rest: PackedVector2Array = PackedVector2Array(), min_rest_distance: float = 0.0,
		rest_depths: PackedFloat32Array = PackedFloat32Array()) -> Dictionary:
	var count := points.size()
	var apart := maxi(count / 4, 2)
	var depths := hull_depths(points)
	if rest_depths.size() == count:
		for i: int in count:
			depths[i] = maxf(depths[i] - rest_depths[i], 0.0)
	var best := { "a": -1, "b": -1, "gap": INF, "constriction": 0.0 }
	var best_distance := INF
	var check_rest := rest.size() == count
	for pair: int in _pinch_candidates(points, depths, apart, min_constriction):
		var i := pair / count
		var j := pair % count
		if check_rest and rest[i].distance_to(rest[j]) < min_rest_distance:
			continue
		var distance := points[i].distance_to(points[j])
		if distance >= best_distance:
			continue
		var pressed := depths[i] + depths[j]
		var constriction := pressed / maxf(distance + pressed, 0.001)
		if constriction < min_constriction:
			continue
		if not Geometry2D.is_point_in_polygon((points[i] + points[j]) * 0.5, points):
			continue
		best_distance = distance
		best = { "a": i, "b": j, "gap": distance - 2.0 * bead_size, "constriction": constriction }
	return best

# The pairs find_pinch() must look at, as i × count + j (i < j, at least
# `apart` apart both ways round), ascending: index order, so the first of
# equally narrow necks still wins. A pair's constriction p / (d + p), p the two
# beads' `depths` added, d their distance, reaches `min_constriction` (c) only
# if d ≤ p (1 − c) / c, and p is at most twice the deepest depth: pairs further
# apart than that (with slack for rounding) cannot count and are left out,
# found by a sweep along x instead of trying every pair. A resting or merely
# squashed ring is barely pressed in anywhere, so this is a handful of pairs,
# or none. Every pair for c ≤ 0.
static func _pinch_candidates(points: PackedVector2Array, depths: PackedFloat32Array, apart: int,
		min_constriction: float) -> PackedInt32Array:
	var count := points.size()
	var pairs := PackedInt32Array()
	if min_constriction <= 0.0:
		for i: int in count:
			for j: int in range(i + apart, count):
				if count - (j - i) < apart:
					break
				pairs.append(i * count + j)
		return pairs
	var deepest := 0.0
	for depth: float in depths:
		deepest = maxf(depth, deepest)
	if deepest <= 0.0:
		return pairs
	var reach := 2.0 * deepest * maxf(1.0 - min_constriction, 0.0) / min_constriction
	reach = reach * 1.001 + 0.001
	var order: Array[Vector3] = []
	order.resize(count)
	for i: int in count:
		order[i] = Vector3(points[i].x, points[i].y, i)
	order.sort()
	for a: int in count:
		var from := order[a]
		for b: int in range(a + 1, count):
			var to := order[b]
			if to.x - from.x > reach:
				break
			if absf(to.y - from.y) > reach:
				continue
			var i := mini(int(from.z), int(to.z))
			var j := maxi(int(from.z), int(to.z))
			if j - i < apart or count - (j - i) < apart:
				continue
			pairs.append(i * count + j)
	pairs.sort()
	return pairs

## How far, in px, each point of the loop `points` lies inside the loop's
## convex hull (0 for the points on it).
static func hull_depths(points: PackedVector2Array) -> PackedFloat32Array:
	var depths := PackedFloat32Array()
	depths.resize(points.size())
	var hull := Geometry2D.convex_hull(points)
	var corners := hull.size()
	if corners < 3:
		return depths
	# A corner of the hull is at distance 0 from the edge it starts (the
	# closest point of a segment to its own end is that end), so its depth
	# is 0 without measuring: on a ring that is most of its beads.
	var on_hull: Dictionary[Vector2, bool] = {}
	for corner: Vector2 in hull:
		on_hull[corner] = true
	for i: int in points.size():
		if on_hull.has(points[i]):
			continue
		var nearest := INF
		for k: int in corners:
			var on_edge := Geometry2D.get_closest_point_to_segment(points[i], hull[k], hull[(k + 1) % corners])
			nearest = minf(nearest, points[i].distance_squared_to(on_edge))
		depths[i] = sqrt(nearest)
	return depths

## The two beads nearest the ends of the short principal axis of the loop
## `points` (the minor eigenvector of their covariance, through their
## centroid), as Vector2i(a, b): a chord between them runs across the long axis
## and cuts the loop into two similar halves. The chord a crushed ring asks to
## be cut along (`pinched`, from the kernel's splat check, which follows this).
static func short_axis_beads(points: PackedVector2Array) -> Vector2i:
	var centre := GooLoop.centroid(points)
	var sxx := 0.0
	var sxy := 0.0
	var syy := 0.0
	for point: Vector2 in points:
		var d := point - centre
		sxx += d.x * d.x
		sxy += d.x * d.y
		syy += d.y * d.y
	# The major axis is at 0.5 atan2(2 sxy, sxx − syy); the minor one across it.
	var minor := Vector2.from_angle(0.5 * atan2(2.0 * sxy, sxx - syy) + PI / 2.0)
	var low := INF
	var high := -INF
	for point: Vector2 in points:
		var along := (point - centre).dot(minor)
		low = minf(low, along)
		high = maxf(high, along)
	return Vector2i(_nearest(points, centre + minor * high), _nearest(points, centre + minor * low))

## The bead-centre loop of one piece of the loop `points` cut along the chord
## from point `a` to point `b`: points a, a+1, …, b (wrapping), counter-clockwise.
static func sub_loop(points: PackedVector2Array, a: int, b: int) -> PackedVector2Array:
	var count := points.size()
	var loop := PackedVector2Array()
	if count == 0:
		return loop
	var i := a
	loop.append(points[i])
	while i != b:
		i = (i + 1) % count
		loop.append(points[i])
	if not GooLoop.is_ccw(loop):
		loop.reverse()
	return loop

## sub_loop(points, a, b) with everything closer than `clearance` px to the cut
## (the chord a–b, run on past both ends by `clearance` plus `overhang`)
## clipped off, so a piece built on it and the piece on the other side of the
## chord stay `clearance` px each from the cut; CCW, the largest part if the
## clip leaves several, empty if nothing is left.
static func cut_piece(points: PackedVector2Array, a: int, b: int, clearance: float,
		overhang: float) -> PackedVector2Array:
	var loop := sub_loop(points, a, b)
	var from := points[a]
	var to := points[b]
	var along := from.direction_to(to)
	if along == Vector2.ZERO:
		along = Vector2.RIGHT
	var across := along.orthogonal() * clearance
	var reach := along * (clearance + overhang)
	var strip := PackedVector2Array([from - reach - across, to + reach - across,
		to + reach + across, from - reach + across])
	var best := PackedVector2Array()
	for piece: PackedVector2Array in Geometry2D.clip_polygons(loop, strip):
		if Geometry2D.is_polygon_clockwise(piece):
			continue
		if GooLoop.area(piece) > GooLoop.area(best):
			best = piece
	if best.size() >= 3 and not GooLoop.is_ccw(best):
		best.reverse()
	return best if best.size() >= 3 else PackedVector2Array()

## Seconds left before the ring may split again (the kernel's split lock).
func split_lock() -> float:
	return _kernel.split_lock(_key) if _kernel != null else 0.0

## One byte per bead, 1 where the rest shape turns by more than CORNER_ANGLE
## (a corner the skin keeps sharp), 0 elsewhere. All 0 for a round ring.
func corner_flags() -> PackedByteArray:
	return _corner_flags.duplicate()

## corner_flags() of the rest loop `rest`: 1 where it turns by more than
## CORNER_ANGLE either way.
static func find_corners(rest: PackedVector2Array) -> PackedByteArray:
	var flags := PackedByteArray()
	flags.resize(rest.size())
	for i: int in rest.size():
		if absf(GooShape.turn(rest, i)) > CORNER_ANGLE + CORNER_TOLERANCE:
			flags[i] = 1
	return flags

# The rest shape pinch() checks pairs against: only on a ring with corners.
func _neck_rest() -> PackedVector2Array:
	return rest_shape if _has_corners else PackedVector2Array()

# ---- Queries and actions ----

## Global positions of the bead centres, in ring order (counter-clockwise on
## screen while the ring is not inside out), where the kernel's last step left
## them (or where set_bead_position() put one since). A copy: write into it
## freely.
func bead_points() -> PackedVector2Array:
	return _frame_points()

## Global position of bead `i` (bead_points()[i]).
func bead_position(i: int) -> Vector2:
	if _kernel != null:
		return _kernel.bead_position(_key, i)
	return _points[i] if i >= 0 and i < _points.size() else Vector2.ZERO

## Moves bead `i` to the global `point` (keeping its velocity) and redraws the
## skin from the new loop.
func set_bead_position(i: int, point: Vector2) -> void:
	if i < 0 or i >= _count:
		return
	if _kernel != null:
		_kernel.set_bead_position(_key, i, point)
	else:
		_points[i] = point

## Velocity of bead `i`, px/s.
func bead_velocity(i: int) -> Vector2:
	if _kernel != null:
		return _kernel.bead_velocity(_key, i)
	return _velocities[i] if i >= 0 and i < _velocities.size() else Vector2.ZERO

## Sets the velocity of bead `i`, px/s, capped at GooTuning.MAX_BEAD_SPEED.
func set_bead_velocity(i: int, velocity: Vector2) -> void:
	if i < 0 or i >= _count:
		return
	if _kernel != null:
		_kernel.set_bead_velocity(_key, i, velocity)
	elif i < _velocities.size():
		_velocities[i] = _capped(velocity)

## True while bead `i` touched a static shape the goo grips (a wall or the
## floor, not a blade: GooTuning.NO_GRIP_GROUP) during the last physics frame;
## such a bead gets GooTuning.WALL_GRIP_DAMP of extra linear damping.
func bead_gripping(i: int) -> bool:
	return _kernel != null and _kernel.bead_gripping(_key, i)

## The bounding box of the bead centres (not grown by the bead radius).
func bead_bounds() -> Rect2:
	if _kernel != null:
		return _kernel.bounds(_key)
	var points := _frame_points()
	if points.is_empty():
		return Rect2()
	var bounds := Rect2(points[0], Vector2.ZERO)
	for point: Vector2 in points:
		bounds = bounds.expand(point)
	return bounds

## True if the global `point` lies inside the body's collision outline: inside
## its bead loop or within bead_radius() of a bead (what GooWorld2D.body_at()
## asks). False for an unbuilt body.
func has_point(point: Vector2) -> bool:
	if _count == 0 or not bead_bounds().grow(_bead_radius).has_point(point):
		return false
	var points := _frame_points()
	if Geometry2D.is_point_in_polygon(point, points):
		return true
	var reach := _bead_radius * _bead_radius
	for bead: Vector2 in points:
		if bead.distance_squared_to(point) <= reach:
			return true
	return false

# The bead centres (a fresh array): the kernel's, or, for a ring in no kernel
# (unbuilt, or out of the tree), the last ones it had.
func _frame_points() -> PackedVector2Array:
	if _kernel != null:
		return _kernel.points(_key)
	return _points.duplicate()

## How far the ring has turned from its rest pose, in radians: the rotation
## that best maps the rest shape onto the beads (GooLoop.best_fit_rotation(),
## the one shape matching pulls toward; 0 for an unbuilt body). A round ring
## turns as it rolls, a shape as it tips over. The skin pushes it to the shader
## as the `rotation` uniform (GooSkin.set_rotation()).
func ring_rotation() -> float:
	if _count == 0:
		return 0.0
	return GooLoop.best_fit_rotation(rest_shape, _frame_points())

## Velocities of the beads, px/s, in ring order.
func bead_velocities() -> PackedVector2Array:
	if _kernel != null:
		return _kernel.velocities(_key)
	return _velocities.duplicate()

## Area, in px², inside the beads' collision outline: the bead loop's area plus
## a band one bead radius wide around it (GooTuning.outline_area()).
func area() -> float:
	if _kernel != null:
		return _kernel.area(_key)
	return GooTuning.outline_area(_frame_points(), _bead_radius)

## Collision radius of each bead.
func bead_radius() -> float:
	return _bead_radius

## Number of beads.
func particle_count() -> int:
	return _count

## Global position of the body: the centroid of its beads, from the snapshot
## (see bead_points()).
func center() -> Vector2:
	if _kernel != null:
		return _kernel.center(_key)
	return GooLoop.centroid(_frame_points())

## Mean velocity of the beads: zero while settled.
func average_velocity() -> Vector2:
	if _kernel != null:
		return _kernel.average_velocity(_key)
	return GooLoop.centroid(bead_velocities())

## Total mass of the beads (tuning["bead_mass"] × particle_count()).
func body_mass() -> float:
	return _body_mass

## Applies `impulse` to every bead, waking the ring; no bead ends up faster
## than GooTuning.MAX_BEAD_SPEED.
func apply_impulse(impulse: Vector2) -> void:
	if _kernel == null:
		if _bead_mass > 0.0:
			for i: int in _velocities.size():
				_velocities[i] = _capped(_velocities[i] + impulse / _bead_mass)
		return
	var was_settled := settled
	_kernel.apply_impulse(_key, impulse)
	if was_settled:
		_on_woke()

## Applies `total` for the next physics step, total / particle_count() to each
## bead, waking the ring if it is settled. Unlike apply_impulse(), it does not
## restart the ring's calm timer: a ring held still under a steady push can
## still settle.
func apply_force(total: Vector2) -> void:
	if _count == 0 or _kernel == null:
		return
	if settled:
		wake()
	var forces := PackedVector2Array()
	forces.resize(_count)
	forces.fill(total / _count)
	_kernel.apply_bead_forces(_key, forces)

## Applies `forces[i]` to bead i for the next physics step (one force per bead,
## in ring order; anything else is ignored), waking the ring if it is settled.
## Like apply_force(), it does not restart an awake ring's calm timer.
func apply_bead_forces(forces: PackedVector2Array) -> void:
	if forces.size() != _count or _count == 0 or _kernel == null:
		return
	if settled:
		wake()
	_kernel.apply_bead_forces(_key, forces)

## Sets the linear velocity of every bead, waking the ring. It is capped at
## GooTuning.MAX_BEAD_SPEED, as every bead's velocity is.
func set_velocity(velocity: Vector2) -> void:
	wake()
	_set_bead_velocities(PackedVector2Array([velocity]))

## With `on`, the beads have no friction and no bounce of their own (a wall's
## bounce still adds to it); without, the tuning of the body's radius again.
func set_frictionless(on: bool) -> void:
	if on == _frictionless_on:
		return
	_frictionless_on = on
	if _kernel != null:
		_kernel.set_frictionless(_key, on)

## True while set_frictionless() is on.
func is_frictionless() -> bool:
	return _frictionless_on

## With `on`, no bead of this ring collides with a bead of `other`; without,
## they collide again (an exclusion in their kernel; both must be rings of the
## same one). The kernel does the same for rings threaded through each other
## (GooWorld2D.Untangler).
func set_pass_through(other: Goo2D, on: bool) -> void:
	if other == null or other == self or _kernel == null or _kernel != other._kernel:
		return
	_kernel.set_pass_through(_key, other._key, on)

## True while every bead of this ring and of `other` pass through each other
## (set_pass_through(), or the Untangler).
func passes_through(other: Goo2D) -> bool:
	return other != null and _kernel != null and _kernel == other._kernel \
		and _kernel.passes_through(_key, other._key)

## With `on`, this ring's bead `index` does not collide with the beads of
## `other`; without, it does again. The kernel does the same to let a bead
## that got inside another ring's bead loop back out through its skin, while
## the rest of both rings still collide (GooWorld2D's overlap push).
func set_bead_pass_through(index: int, other: Goo2D, on: bool) -> void:
	if other == null or other == self or index < 0 or index >= _count \
			or _kernel == null or _kernel != other._kernel:
		return
	_kernel.set_bead_pass_through(_key, index, other._key, on)

## Number of this ring's bead centres inside `other`'s bead loop grown by
## `margin` px (0: the loop itself). Rings that only touch, however squashed,
## have none inside each other at margin 0. Rings whose boxes (bead_bounds(),
## the other's grown by `margin`) are apart are not looked at further.
func beads_inside(other: Goo2D, margin: float) -> int:
	if _count == 0 or other._count == 0:
		return 0
	if _kernel != null and _kernel == other._kernel:
		return _kernel.beads_inside(_key, other._key, margin)
	return GooKernel.count_inside(_frame_points(), other._frame_points(), margin)

## Clears `settled`: the solver moves the beads again.
func wake() -> void:
	if _kernel != null:
		_kernel.wake(_key)
	_on_woke()

## Called once per physics frame for each other body this body's beads touch
## (the kernel's contacts, through dispatch_events()), and by GooWorld2D when a
## merge lock runs out: emits `touched` unless either body is gone, being freed
## or merging. Returns true if it did. (A GooWorld2D judges its own bodies'
## contacts as it dispatches them, without a connection to the signal.)
func report_contact(other: Goo2D) -> bool:
	if not can_report(other):
		return false
	touched.emit(other)
	return true

## True if a contact with `other` is reported (report_contact()): neither body
## is gone, being freed or merging.
func can_report(other: Goo2D) -> bool:
	if other == null or other == self or not is_instance_valid(other):
		return false
	if is_queued_for_deletion() or other.is_queued_for_deletion():
		return false
	return not merging and not other.merging

## The Goo2D that `node` belongs to: the nearest Goo2D above `node` in the
## tree (its Skin's body), or null.
static func find(node: Node) -> Goo2D:
	var current := node.get_parent() if node != null else null
	while current != null:
		var body := current as Goo2D
		if body != null:
			return body
		current = current.get_parent()
	return null

# ---- Skin ----

func _process(delta: float) -> void:
	if Engine.is_editor_hint() or _kernel == null or skin_at_rest():
		return
	_update_skin(delta)

## True while the skin needs no redrawing: the ring is settled (its beads
## asleep, so nothing moves), its skin was drawn since with the smoothed
## velocity stopped (SKIN_REST_SPEED) and its target area has not changed.
## _process() then skips _update_skin(); waking ends it.
func skin_at_rest() -> bool:
	return _skin_resting and settled and target_area == _skin_rest_area

## Sets the colours the skin is drawn in for now (a merge's tint, a flash):
## `tint` on this side of a two-tone body's division (the Skin's colour, COLOR
## in the shader) and `second` on the far side; without a `second`
## (COLOR_BY_SIZE) the body is drawn in `tint` alone for the moment, whatever
## its own colours. `color` and second_color are the body's own (base_color(),
## second_base_color()), which reset_tint() goes back to.
func set_tint(tint: Color, second: Color = COLOR_BY_SIZE) -> void:
	_skin.color = tint
	if second == COLOR_BY_SIZE:
		_second_tint = tint
		_goo.clear_two_tone()
	else:
		_second_tint = second
		_goo.set_two_tone(second, division_axis, division_offset)

## The colour the skin is drawn in (on this side of a two-tone body's division).
func get_tint() -> Color:
	return _skin.color

## The colour the skin is drawn in on the far side of the division: the second
## colour set_tint() was last given, or its `tint` when it was given one alone.
func get_second_tint() -> Color:
	return _second_tint

## Draws the body in its own colours again (base_color(), and for a two-tone
## body second_base_color() beyond its division), as after a set_tint() for
## the moment; while the merge flash runs, blended toward white as it is.
func reset_tint() -> void:
	var primary := base_color().lerp(Color.WHITE, _flash)
	if is_two_tone():
		set_tint(primary, second_color.lerp(Color.WHITE, _flash))
	else:
		set_tint(primary)

## The body's own colour: `color`, or for COLOR_BY_SIZE GooTuning.color() of
## its radius. What it is drawn in when no merge tints it (on this side of a
## two-tone body's division).
func base_color() -> Color:
	return GooTuning.color(radius) if color == COLOR_BY_SIZE else color

## The body's own colour beyond its division: second_color for a two-tone
## body, base_color() for a body of one colour.
func second_base_color() -> Color:
	return second_color if is_two_tone() else base_color()

## True when the body is drawn in two colours: its second_color is set.
func is_two_tone() -> bool:
	return second_color != COLOR_BY_SIZE

## The colour owning the larger share of the body: base_color() for a body of
## one colour; for a two-tone body base_color() while division_offset >= 0
## (the division shifted toward the second colour's side, or through the
## centre: a tie goes to the primary), else second_color.
func dominant_color() -> Color:
	if is_two_tone() and division_offset < 0.0:
		return second_color
	return base_color()

## The colours the body is drawn in, by value, COLOR_BY_SIZE resolved
## (base_color()): one colour, or two in an order of their own (by red, green,
## blue, then alpha), so two bodies drawn in the same colours compare equal
## (==) whichever is their primary and wherever their division lies. A second
## colour equal to the first counts once.
func color_set() -> PackedColorArray:
	var first := base_color()
	var second := second_base_color()
	if first == second:
		return PackedColorArray([first])
	if _color_before(second, first):
		return PackedColorArray([second, first])
	return PackedColorArray([first, second])

# True if `a` sorts before `b`: by red, then green, blue and alpha.
static func _color_before(a: Color, b: Color) -> bool:
	if a.r != b.r:
		return a.r < b.r
	if a.g != b.g:
		return a.g < b.g
	if a.b != b.b:
		return a.b < b.b
	return a.a < b.a

## Draws the body in two colours: `primary` (its `color`) on this side of a
## division and `second` (its second_color) on the other. The division is a
## straight line fixed in the body's rest space, so it turns with the body as
## it rolls or tips: `axis_rest` (normalised here; division_axis) points toward
## `second`'s side, and `offset` (division_offset) is how far along it, in px
## from the rest centroid, the line crosses it. division_in_rest() turns a
## division given in the world into these. Retints at once (pushing the
## skin's uniforms even while it is settled); a merge flash running carries on
## over both colours.
func set_two_tone(primary: Color, second: Color, axis_rest: Vector2, offset: float) -> void:
	division_axis = _unit_or_right(axis_rest)
	division_offset = offset if is_finite(offset) else 0.0
	second_color = second
	color = primary
	reset_tint()

## Draws the body in its `color` alone again: no second colour, the division
## back to its defaults (Vector2.RIGHT, 0).
func clear_two_tone() -> void:
	division_axis = Vector2.RIGHT
	division_offset = 0.0
	second_color = COLOR_BY_SIZE
	reset_tint()

## A division given in the world (a line across `axis_world`, pointing toward
## the second colour's side, through the point `through_world`) in the rest
## space of a body centred at `center` and turned by `rotation` (its
## ring_rotation()): { "axis": the unit axis in rest space (axis_world turned
## by −rotation), "offset": px from the centre along it to the line ((through
## − center) · axis, which the rotation does not change) }, what
## set_two_tone() takes. A merged body's division is the line between its
## parents' centres crossed at their area ratio; a split piece's is its
## parent's axis through its own centre (offset 0). A zero axis reads as +x.
static func division_in_rest(axis_world: Vector2, through_world: Vector2, center: Vector2,
		rotation: float) -> Dictionary:
	var axis := _unit_or_right(axis_world)
	return { "axis": axis.rotated(-rotation), "offset": (through_world - center).dot(axis) }

# `axis` normalised, or Vector2.RIGHT for one that is zero or not finite.
static func _unit_or_right(axis: Vector2) -> Vector2:
	if not axis.is_finite() or axis.length_squared() <= 0.0:
		return Vector2.RIGHT
	return axis.normalized()

# One step of the merge flash (make_merged()): `k` runs from 1, just merged,
# to 0, its own colours; the body is drawn k × MERGE_FLASH_BLEND of the way
# toward white, both of a two-tone body's colours alike.
func _flash_step(k: float) -> void:
	_flash = clampf(k, 0.0, 1.0) * GooTuning.MERGE_FLASH_BLEND
	reset_tint()

## Takes over the look of `from`: its `color`, its `skin_shader`, and the goo
## look's bubble field (its centre at `from_center`, measured before it changed
## or left): the same bubbles, where they were (GooSkin.inherit()). A two-tone
## `from` passes on both its colours, half and half: the division runs the
## way `from`'s runs in the world now, through this body's own centre (offset
## 0), whatever the cut was. A split piece calls it with the ring it was cut
## from (still in the tree, so its rotation is measured), a merged ring with its
## bigger parent (whose colours make_merged() then replaces by the merged one).
## The look only: the body's `tags` are left alone (the builders set them, from
## what the world passes).
func inherit_look(from: Goo2D, from_center: Vector2) -> void:
	if from == null:
		return
	if from.is_two_tone():
		var axis_world := from.division_axis.rotated(from.ring_rotation())
		var division := division_in_rest(axis_world, Vector2.ZERO, Vector2.ZERO, ring_rotation())
		set_two_tone(from.color, from.second_color, division["axis"], 0.0)
	else:
		if is_two_tone():
			clear_two_tone()
		color = from.color
	skin_shader = from.skin_shader
	skin_roll = from.skin_roll
	if _count == 0:
		return
	_goo.inherit(from._goo, from_center, center(), from.ring_rotation(), ring_rotation())

# The skin: the kernel's skin outline of the beads (skin_pieces(), rebuilt
# every physics frame the ring moved), in the Skin node's space: one polygon,
# or, for an outline that crossed itself, the loops it was cut into as the
# Skin's sub-polygons (Polygon2D.polygons), every one drawn; the previous
# polygon stays when the kernel's could not be drawn (Polygon2D would silently
# draw nothing). And the goo shader's uniforms (GooSkin), from the unsmoothed
# outline (skin_offset()) in global space, over `delta` seconds since the last
# update.
func _update_skin(delta: float = 0.0) -> void:
	if _count == 0 or _kernel == null:
		return
	var version: int = _kernel.skin_version(_key)
	if version != _skin_version:
		_skin_version = version
		var smooth := _kernel.skin(_key)
		if not smooth.is_empty():
			var to_skin := _skin.get_global_transform()
			if to_skin != Transform2D.IDENTITY:
				smooth = to_skin.affine_inverse() * smooth
			_skin.polygon = smooth
			var sizes: PackedInt32Array = _kernel.skin_piece_sizes(_key)
			_skin.polygons = skin_piece_indices(sizes) if sizes.size() > 1 else []
		_shader_points = _kernel.shader_points(_key)
		_goo.set_rotation(ring_rotation())
		_goo.update_padded(_shader_points, mini(_count, GooSkin.MAX_POINTS), center(),
			sqrt(target_area / PI), average_velocity(), delta)
	else:
		# The outline did not change: only the motion uniforms.
		_goo.update_motion(center(), sqrt(target_area / PI), average_velocity(), delta)
	_skin_resting = false
	if settled and _goo.smoothed_velocity().length_squared() <= SKIN_REST_SPEED * SKIN_REST_SPEED:
		_goo.stop()
		_skin_resting = true
		_skin_rest_area = target_area

## The skin of a CCW bead loop `points` whose beads have radius `bead_radius`,
## in the loop's space, as polygons Polygon2D can draw (ones
## Geometry2D.triangulate_polygon() accepts), every one CCW: the loop pushed
## out to the collision outline (skin_offset()), smoothed by SKIN_SMOOTHING
## Chaikin passes except at the beads flagged in `corner_flags`
## (corner_flags()'s format; empty or all 0 for a round ring). One polygon,
## unless the bead loop crosses itself (a ring crushed or folded through
## itself): then it is first cut at its crossings into loops that do not
## (GooLoop.split_at_crossings(), SKIN_MAX_SPLITS), each turned CCW (the lobe
## of a fold is wound the other way, so offset as part of the whole loop its
## skin would shrink) and each given a skin of its own, so the whole body is
## drawn, the folded lobe included. An outline that still crosses itself (the
## offsets crossed at a kink) is cut the same way, and a loop that cannot be
## drawn even so (edges touching or overlapping without crossing) is repaired
## into the largest simple boundary of what it covers (SKIN_REPAIR_GROW). A bead
## loop inside out as a whole (CW) is turned CCW first for the same reason.
## Empty if nothing can be drawn. The Skin draws several as Polygon2D.polygons
## (skin_piece_indices()).
static func skin_pieces(points: PackedVector2Array, bead_radius: float,
		corner_flags: PackedByteArray) -> Array[PackedVector2Array]:
	return _drawable_skin(points, bead_radius, corner_flags)

## Polygon2D.polygons for a Skin whose `polygon` holds polygons of `sizes`
## points one after the other (GooKernel.skin_piece_sizes()): one index list
## per polygon.
static func skin_piece_indices(sizes: PackedInt32Array) -> Array:
	var polygons: Array = []
	var start := 0
	for size: int in sizes:
		polygons.append(PackedInt32Array(range(start, start + size)))
		start += size
	return polygons

## Each bead of the CCW loop `points` pushed `distance` (a bead radius: the
## collision outline) along its outward vertex normal, as the skin draws it.
## Around a concave kink (a turn inward of more than SKIN_KINK_TURN) the offsets
## of beads up to SKIN_KINK_REACH apart converge; where they would close more
## than SKIN_KINK_CLEARANCE of the gap between two beads, both are shortened to
## close just that much (a mitre limit), so the points do not cross. Elsewhere,
## and on any loop without such a kink, every offset is the full `distance`.
static func skin_offset(points: PackedVector2Array, distance: float) -> PackedVector2Array:
	var count := points.size()
	var normals := GooLoop.edge_normals(points)
	var directions := PackedVector2Array()
	directions.resize(count)
	var kinks := PackedInt32Array()
	var min_turn := sin(SKIN_KINK_TURN)
	for i: int in count:
		var before := normals[(i + count - 1) % count]
		var after := normals[i]
		directions[i] = (before + after).normalized()
		# Concave where the edge after the bead heads outward of the edge before
		# it; the cross product of the normals is |before| |after| sin(turn).
		if before.cross(after) > min_turn * before.length() * after.length():
			kinks.append(i)
	var offsets := PackedFloat32Array()
	offsets.resize(count)
	offsets.fill(distance)
	for kink: int in kinks:
		# Every pair (a, b) of beads at most SKIN_KINK_REACH apart with the kink
		# between them or at one end.
		for a: int in range(kink - SKIN_KINK_REACH, kink + 1):
			for b: int in range(maxi(a + 1, kink), mini(a + SKIN_KINK_REACH, a + count - 1) + 1):
				var i := posmod(a, count)
				var j := posmod(b, count)
				var gap := points[j] - points[i]
				var length := gap.length()
				if length <= 0.0:
					continue
				var along := gap / length
				# How fast the two offset points approach each other along the
				# gap per unit of offset; only approach counts, so shortening
				# either offset later never closes the gap further.
				var closing := maxf(directions[i].dot(along), 0.0) + maxf(-directions[j].dot(along), 0.0)
				if closing * distance > SKIN_KINK_CLEARANCE * length:
					var limit := SKIN_KINK_CLEARANCE * length / closing
					offsets[i] = minf(offsets[i], limit)
					offsets[j] = minf(offsets[j], limit)
	var result := PackedVector2Array()
	result.resize(count)
	for i: int in count:
		result[i] = points[i] + directions[i] * offsets[i]
	return result

# skin_pieces(): the skin of the bead loop `points`, or, when it crosses itself,
# of each loop it is cut into at its crossings, turned CCW (its corner flags
# carried along: GooLoop.split_flags()).
static func _drawable_skin(points: PackedVector2Array, bead_radius: float,
		corner_flags: PackedByteArray) -> Array[PackedVector2Array]:
	var pieces: Array[PackedVector2Array] = []
	if GooLoop.first_crossing(points).is_empty():
		var loop := points
		var flags := corner_flags
		if not GooLoop.is_ccw(loop):
			loop = points.duplicate()
			loop.reverse()
			flags = corner_flags.duplicate()
			flags.reverse()
		_drawable_outline(skin_offset(loop, bead_radius), flags, pieces)
		return pieces
	var loops := GooLoop.split_at_crossings(points, SKIN_MAX_SPLITS)
	var loop_flags := GooLoop.split_flags(points, corner_flags, SKIN_MAX_SPLITS)
	for k: int in loops.size():
		var loop := loops[k]
		if loop.size() < 3:
			continue
		var flags := loop_flags[k]
		if not GooLoop.is_ccw(loop):
			loop.reverse()
			flags.reverse()
		_drawable_outline(skin_offset(loop, bead_radius), flags, pieces)
	return pieces

# The smoothed skin of the outline `raw` (skin_offset() of a loop), keeping the
# beads flagged in `corner_flags` sharp, appended to `pieces` as polygons
# checked the way Polygon2D will draw them (Geometry2D.triangulate_polygon(),
# which fails silently on a polygon that crosses itself): the smoothed outline
# when it triangulates, else the loops it is cut into at its crossings, each
# as it is when it triangulates, CCW, else repaired by
# Geometry2D.offset_polygon() (SKIN_REPAIR_GROW), which resolves it into simple
# boundaries, of which the largest is kept. (Geometry2D.merge_polygons() of the
# polygon with itself does not do: it leaves the part a folded loop covers
# twice as a hole touching the outline, which does not triangulate.)
static func _drawable_outline(raw: PackedVector2Array, corner_flags: PackedByteArray,
		pieces: Array[PackedVector2Array]) -> void:
	var smooth := GooLoop.chaikin_keeping(raw, SKIN_SMOOTHING, corner_flags) if corner_flags.has(1) \
		else GooLoop.chaikin(raw, SKIN_SMOOTHING)
	if not Geometry2D.triangulate_polygon(smooth).is_empty():
		pieces.append(smooth)
		return
	for loop: PackedVector2Array in GooLoop.split_at_crossings(smooth, SKIN_MAX_SPLITS):
		if loop.size() < 3:
			continue
		if not Geometry2D.triangulate_polygon(loop).is_empty():
			if not GooLoop.is_ccw(loop):
				loop.reverse()
			pieces.append(loop)
			continue
		var best := _clipper_largest(loop)
		if not best.is_empty():
			pieces.append(best)

# The largest simple boundary (CCW) of what `loop` covers, by
# Geometry2D.offset_polygon() of SKIN_REPAIR_GROW px; empty if Polygon2D could
# not draw it.
static func _clipper_largest(loop: PackedVector2Array) -> PackedVector2Array:
	var best := PackedVector2Array()
	var best_area := 0.0
	for piece: PackedVector2Array in Geometry2D.offset_polygon(loop, SKIN_REPAIR_GROW):
		var piece_area := GooLoop.area(piece)
		if piece_area > best_area:
			best = piece
			best_area = piece_area
	if best.size() < 3 or Geometry2D.triangulate_polygon(best).is_empty():
		return PackedVector2Array()
	if not GooLoop.is_ccw(best):
		best.reverse()
	return best

# ---- Editor preview ----

## The rest outline a body placed in a scene builds itself on, in its own space
## (centred on its origin, its area centroid there): the circle of `radius`, or
## the polygon of `sides` or `outline` at the equivalent radius `radius`. What
## the editor preview draws; the ring's collision outline is this with its
## corners rounded by one bead radius.
func preview_outline() -> PackedVector2Array:
	var placed := _placed_shape()
	return placed.outline if placed.is_round() else placed.scaled(radius).outline

# In the editor only: the rest outline (preview_outline()) as a translucent fill
# in the body's colour with a thin edge. In the game the Skin draws the goo and
# this draws nothing.
func _draw() -> void:
	if not Engine.is_editor_hint():
		return
	var points := preview_outline()
	if points.size() < 3 or GooLoop.area(points) < 1.0:
		return
	var colour := base_color()
	if not Geometry2D.triangulate_polygon(points).is_empty():
		draw_colored_polygon(points, Color(colour, PREVIEW_ALPHA))
	var edge := points.duplicate()
	edge.append(points[0])
	draw_polyline(edge, colour, PREVIEW_EDGE_WIDTH, true)

# An export changed: redraw the preview, in the editor only.
func _preview_changed() -> void:
	if Engine.is_editor_hint():
		queue_redraw()

# ---- Loop helpers ----

# Each point of the CCW loop moved `distance` along its outward vertex normal.
static func _offset_loop(points: PackedVector2Array, distance: float) -> PackedVector2Array:
	var count := points.size()
	var normals := GooLoop.edge_normals(points)
	var result := PackedVector2Array()
	result.resize(count)
	for i: int in count:
		var normal := (normals[(i + count - 1) % count] + normals[i]).normalized()
		result[i] = points[i] + normal * distance
	return result

## MERGE_GROW at the goo's length unit (GooTuning.unit), px.
static func merge_grow() -> float:
	return MERGE_GROW * GooTuning.unit

## Where rebuild_from() puts the `count` beads of a ring with beads of
## `bead_radius` px merged from `bodies`: on their union's collision outline
## (_merged_outline()), its creases filled (grown by MERGE_CLOSE_BEADS bead
## radii and shrunk back) and inset by a bead radius, resampled evenly, or with
## a `rest_loop` placed like it (_place_like(), the rest loop resampled to
## `count` first). Global bead centres, CCW. GooWorld2D.merge_fit() compares
## this loop with the merged ring's rest loop before it swaps a pair.
static func merge_placement(bodies: Array[Goo2D], bead_radius: float, count: int,
		rest_loop: PackedVector2Array = PackedVector2Array()) -> PackedVector2Array:
	var close := MERGE_CLOSE_BEADS * bead_radius
	var inset := _inset(_grown(_merged_outline(bodies), close), close + bead_radius + merge_grow())
	if rest_loop.is_empty():
		return GooLoop.resample(inset, count)
	return _place_like(inset, _rest_of_count(rest_loop, count))

# The outline a merged ring is built in: merged_union() of `bodies`; or, if
# they do not form one outline, the grown outline of the lowest body (the best
# supported).
static func _merged_outline(bodies: Array[Goo2D]) -> PackedVector2Array:
	var outline := merged_union(bodies)
	if not outline.is_empty():
		return outline
	var lowest := 0
	for i: int in bodies.size():
		if bodies[i].center().y > bodies[lowest].center().y:
			lowest = i
	return _offset_loop(bodies[lowest]._frame_points(), bodies[lowest].bead_radius() + merge_grow())

## The union of `bodies`' collision outlines grown by merge_grow(), holes
## filled, CCW, global; empty if they do not form one outline (they do not
## touch). A ring turned inside out (its bead loop clockwise) counts by the
## region its loop encloses, so a merge takes it in like any other.
static func merged_union(bodies: Array[Goo2D]) -> PackedVector2Array:
	var outlines: Array[PackedVector2Array] = []
	for body: Goo2D in bodies:
		var loop := body._frame_points()
		if not GooLoop.is_ccw(loop):
			loop.reverse()
		outlines.append(_offset_loop(loop, body.bead_radius() + merge_grow()))
	if outlines.is_empty():
		return PackedVector2Array()
	var outline := outlines[0]
	for i: int in range(1, outlines.size()):
		var outers: Array[PackedVector2Array] = []
		for piece: PackedVector2Array in Geometry2D.merge_polygons(outline, outlines[i]):
			# merge_polygons returns outer boundaries counter-clockwise and holes
			# clockwise in is_polygon_clockwise()'s sense, whatever the input's
			# winding; dropping the holes fills them.
			if not Geometry2D.is_polygon_clockwise(piece):
				outers.append(piece)
		if outers.size() != 1:
			return PackedVector2Array()
		outline = outers[0]
	if not GooLoop.is_ccw(outline):
		outline.reverse()
	return outline

# `outline` grown by `distance` (round joins), CCW: the largest piece (the
# outer boundary; holes are smaller), or the outline itself if growing it
# gives nothing.
static func _grown(outline: PackedVector2Array, distance: float) -> PackedVector2Array:
	if distance <= 0.0:
		return outline
	var best := PackedVector2Array()
	for piece: PackedVector2Array in Geometry2D.offset_polygon(outline, distance, Geometry2D.JOIN_ROUND):
		if GooLoop.area(piece) > GooLoop.area(best):
			best = piece
	if best.size() < 3:
		return outline
	if not GooLoop.is_ccw(best):
		best.reverse()
	return best

# `outline` shrunk by `distance`, CCW. Where that would split it in pieces (the
# waist of two rings barely touching is narrower than two bead radii: with
# 12-22 beads a ring's beads are big enough for that), it is shrunk by half as
# much, and so on, up to INSET_TRIES times; then the largest piece, or the
# outline itself if nothing is left. Building on one piece alone would put the
# merged ring where one of the pair was.
static func _inset(outline: PackedVector2Array, distance: float) -> PackedVector2Array:
	var best := PackedVector2Array()
	var shrink := distance
	for attempt: int in INSET_TRIES:
		var pieces := Geometry2D.offset_polygon(outline, -shrink, Geometry2D.JOIN_ROUND)
		best = PackedVector2Array()
		for piece: PackedVector2Array in pieces:
			if GooLoop.area(piece) > GooLoop.area(best):
				best = piece
		if pieces.size() == 1:
			break
		shrink *= 0.5
	if best.size() < 3:
		best = outline
	if not GooLoop.is_ccw(best):
		best.reverse()
	return best

# `rest_loop` CCW with `count` points: as given if it has that many, else
# resampled evenly (which can move points off its corners).
static func _rest_of_count(rest_loop: PackedVector2Array, count: int) -> PackedVector2Array:
	var rest := rest_loop.duplicate()
	if not GooLoop.is_ccw(rest):
		rest.reverse()
	if rest.size() != count:
		rest = GooLoop.resample(rest, count)
	return rest

# One point on the closed CCW loop `loop` per point of the rest loop `rest`, at
# the same fraction of the perimeter from a start as that rest point is from
# rest[0]; the start is the point of `loop` nearest rest[0]. So bead i lands
# where rest point i would be on this outline, corners spread like the rest
# loop's, and the two correspond index for index.
static func _place_like(loop: PackedVector2Array, rest: PackedVector2Array) -> PackedVector2Array:
	var count := rest.size()
	var result := PackedVector2Array()
	if loop.is_empty() or count == 0:
		return result
	var start := _nearest(loop, rest[0])
	var ordered := loop.slice(start)
	ordered.append_array(loop.slice(0, start))
	var size := ordered.size()
	var lengths := PackedFloat32Array()
	var total := 0.0
	for i: int in size:
		var length := ordered[i].distance_to(ordered[(i + 1) % size])
		lengths.append(length)
		total += length
	var rest_total := GooLoop.perimeter(rest)
	var rest_walked := 0.0
	var walked := 0.0
	var edge := 0
	for i: int in count:
		if i > 0:
			rest_walked += rest[i - 1].distance_to(rest[i])
		var target := total * rest_walked / rest_total if rest_total > 0.0 else 0.0
		while edge < size - 1 and walked + lengths[edge] < target:
			walked += lengths[edge]
			edge += 1
		var along := clampf((target - walked) / lengths[edge], 0.0, 1.0) if lengths[edge] > 0.0 else 0.0
		result.append(ordered[edge].lerp(ordered[(edge + 1) % size], along))
	return result

static func _nearest(points: PackedVector2Array, target: Vector2) -> int:
	var best := 0
	var best_distance := INF
	for i: int in points.size():
		var distance := points[i].distance_squared_to(target)
		if distance < best_distance:
			best_distance = distance
			best = i
	return best

# ---- Builders ----

## Creates a Goo2D of `radius` (px) centred on `global_pos`, adds it to
## `parent` and builds its ring. The node stays at its parent's origin with no
## transform of its own; the beads are placed so that center() is
## `global_pos`. With a POLYGON `shape`, the body is that outline scaled to the
## equivalent radius `radius` (GooShape.scaled()): tuned by
## GooTuning.tuning_for() and built on its bead loop (the outline inset by
## one bead radius, a bead on every corner) moved to `global_pos`. Without a
## shape, or with a ROUND one, it is the round body of `radius`.
## With a `ring_tuning` (GooWorld2D.tuning_for() of sized_shape(radius, shape)
## and `tags`, as spawn() passes), the ring is built from it instead of from
## GooTuning. The body's `tags` are a copy of `tags`, set before its ring is
## built (so a fallback tuning asked of its world sees them). Sets `shape`.
## Call outside the physics flush.
static func make(radius: float, global_pos: Vector2, parent: Node, shape: GooShape = null,
		ring_tuning: Dictionary = {}, tags: Array = []) -> Goo2D:
	var body := _new_body(radius, parent, tags)
	body._setup_shape(radius, global_pos, shape, ring_tuning)
	return body

## The rest shape make() builds a body of `radius` and `shape` on: a POLYGON
## `shape` scaled to the equivalent radius `radius`, else the round shape of
## `radius`. What a ring_tuning for make() is the tuning of.
static func sized_shape(radius: float, shape: GooShape) -> GooShape:
	if shape != null and not shape.is_round():
		return shape.scaled(radius)
	return GooShape.round(radius)

## Creates the Goo2D of `radius` that replaces the merged pair `from` (two
## bodies still in the tree) and adds it to `parent`: one ring rebuilt around
## their outlines (rebuild_from()), keeping their beads' velocities and
## inflating to `radius`, flashing briefly from near white to its colour.
## With a `fused` outline (GooWorld2D.fused_outline() of the pair: global, in the
## pose the two touched in), the body is that shape instead of round: `shape`
## is GooShape.polygon(fused), its radius the shape's equivalent radius
## (`radius` is not used), tuned by GooTuning.tuning_for(), its beads still
## placed on the pair's current outlines and its rest loop the shape's bead
## loop where `fused` lies, so the ring pulls itself into the fused shape where
## it stands while its target area inflates to the shape's.
## Either way it keeps the bubbles of the bigger of the two (inherit_look()).
## Its `color` is `color` (COLOR_BY_SIZE: by its own size, whatever the pair's
## colours were; GooWorld2D.merged_color() decides it), the colour it flashes
## to, and it is drawn in that colour alone (a two-tone bigger parent's second
## colour is not kept: a world that wants both calls set_two_tone() on it next,
## and the flash, which reads the body's colours at every step, covers both).
## It is tuned by `ring_tuning` when one is given (the tuning of the round shape
## of `radius`, or of GooShape.polygon(fused): GooWorld2D.tuning_for() of it
## and `tags`), else by GooTuning. Its `tags` are a copy of `tags`
## (GooWorld2D.merged_tags() of the pair), set before its ring is built.
## Returns null unless `from` holds two live bodies. Call outside the physics
## flush, before the old bodies leave the tree.
static func make_merged(radius: float, parent: Node, from: Array[Goo2D],
		fused: PackedVector2Array = PackedVector2Array(), color: Color = COLOR_BY_SIZE,
		ring_tuning: Dictionary = {}, tags: Array = []) -> Goo2D:
	var rings: Array[Goo2D] = []
	for body: Goo2D in from:
		if body != null and is_instance_valid(body):
			rings.append(body)
	if from.size() != 2 or rings.size() != 2:
		push_error("make_merged() rebuilds exactly two ring blobs, got %d" % rings.size())
		return null
	var merged: Goo2D = null
	if fused.is_empty():
		merged = _new_body(radius, parent, tags)
		merged.rebuild_from(rings, radius, ring_tuning if not ring_tuning.is_empty() else GooTuning.tuning(radius))
	else:
		var fused_shape := GooShape.polygon(fused)
		if ring_tuning.is_empty():
			ring_tuning = GooTuning.tuning_for(fused_shape)
		var loop := rest_loop_at(fused_shape, ring_tuning, GooShape.area_centroid(fused))
		if loop.is_empty():
			push_error("make_merged(): a fused %d-point shape is too thin for its beads" % fused_shape.outline.size())
			return null
		merged = _new_body(fused_shape.radius(), parent, tags)
		merged.shape = fused_shape
		merged.rebuild_from(rings, fused_shape.radius(), ring_tuning, loop)
	var bigger: Goo2D = from[0] if from[0].radius >= from[1].radius else from[1]
	merged.inherit_look(bigger, bigger.center())
	merged.clear_two_tone()
	merged.color = color
	merged._flash_step(1.0)
	merged.create_tween().tween_method(merged._flash_step, 1.0, 0.0, GooTuning.MERGE_FLASH)
	return merged

## Creates a Goo2D, one piece of a split ring, on the bead-centre loop `points`
## (`velocities` holds one velocity per point, see build_from_loop()) and adds
## it to `parent`. Its radius is `radius`, or with 0 _loop_radius(points): the
## radius whose circle holds what the loop's collision outline encloses now.
## Drawn in its base_color() (by its size until the caller gives it a `color`,
## as inherit_look() does with its parent's). Call outside the physics flush.
## With a POLYGON `shape` (a piece of a polygon body cut in rest space, see
## GooShape.cut_ring()), the body is that shape instead: its radius is the
## shape's equivalent radius whatever `radius` says, it is tuned by
## GooTuning.tuning_for() and its rest shape is `rest_loop` (global, CCW,
## the shape's bead loop in the pose it should take; without one, the shape's
## bead loop centred on the beads), and its `shape` is `shape`. Without a
## shape, or with a ROUND one, it is the round piece it always was.
## With a `ring_tuning` (GooWorld2D.tuning_for() of `shape`, or of the round
## shape of `radius`, and `tags`), the piece is built from it instead of from
## GooTuning. Its `tags` are a copy of `tags` (its parent's), set before its
## ring is built, so the round fallback of a shape too thin for its beads asks
## its world for a tuning with them.
static func make_from_loop(points: PackedVector2Array, velocities: PackedVector2Array, parent: Node,
		radius: float = 0.0, shape: GooShape = null,
		rest_loop: PackedVector2Array = PackedVector2Array(), ring_tuning: Dictionary = {},
		tags: Array = []) -> Goo2D:
	if shape != null and not shape.is_round():
		var shape_tuning := ring_tuning if not ring_tuning.is_empty() else GooTuning.tuning_for(shape)
		var rest := rest_loop
		if rest.is_empty():
			rest = shape.bead_loop(shape_tuning["bead_count"], shape_tuning["bead_radius"])
			var offset := GooLoop.centroid(points) - GooLoop.centroid(rest)
			for i: int in rest.size():
				rest[i] += offset
		if not rest.is_empty():
			var shape_radius := shape.radius()
			var polygon_body := _new_body(shape_radius, parent, tags)
			polygon_body.shape = shape
			polygon_body.build_from_loop(points, velocities, shape_radius, shape_tuning, rest)
			polygon_body.set_tint(polygon_body.base_color())
			return polygon_body
		push_error("make_from_loop(): a %d-point shape of radius %.1f is too thin for its beads; built round"
			% [shape.outline.size(), shape.radius()])
	var piece_radius := radius if radius > 0.0 else _loop_radius(points)
	var body := _new_body(piece_radius, parent, tags)
	var piece_tuning := ring_tuning
	if shape != null and not shape.is_round():
		piece_tuning = body._parent_tuning(GooShape.round(piece_radius))
	elif piece_tuning.is_empty():
		piece_tuning = GooTuning.tuning(piece_radius)
	body.build_from_loop(points, velocities, piece_radius, piece_tuning)
	body.set_tint(body.base_color())
	return body

## The bead loop of `shape` with `ring_tuning` (GooTuning.tuning_for() of
## it) moved so the shape's outline centroid is at `at`; empty if the shape is
## too thin for its beads.
static func rest_loop_at(shape: GooShape, ring_tuning: Dictionary, at: Vector2) -> PackedVector2Array:
	var loop := shape.bead_loop(ring_tuning["bead_count"], ring_tuning["bead_radius"])
	if loop.size() != int(ring_tuning["bead_count"]):
		return PackedVector2Array()
	for i: int in loop.size():
		loop[i] += at
	return loop

# Radius, in px, of the ring whose collision outline around the bead-centre
# loop `points` encloses its target area: r with π r² =
# GooTuning.outline_area(points, GooTuning.bead_radius(r)), found
# by fixed-point iteration from sqrt(area / π) (the bead radius grows about
# linearly with r, so it converges in a few steps).
static func _loop_radius(points: PackedVector2Array) -> float:
	var radius := sqrt(GooLoop.area(points) / PI)
	for _step: int in 6:
		radius = sqrt(GooTuning.outline_area(points, GooTuning.bead_radius(radius)) / PI)
	return radius

# An unbuilt Goo2D of `radius` added to `parent`, round until told otherwise,
# tagged with a copy of `tags` before it enters the tree (and so before any
# builder builds its ring).
static func _new_body(radius: float, parent: Node, tags: Array = []) -> Goo2D:
	var body := Goo2D.new()
	body.radius = radius
	body.shape = GooShape.round(radius)
	body.tags = tags.duplicate()
	body.name = "Blob%d" % roundi(radius)
	parent.add_child(body)
	return body

# Builds this body, in the tree and with a round `shape` of its radius, as
# make() describes: of `from_shape` scaled to `body_radius` if that is a
# POLYGON (setting `shape`), else round, centred on `global_pos`; round, with
# an error, if the polygon is too thin for its beads. Tuned by `ring_tuning`
# (the tuning of sized_shape(body_radius, from_shape)) if one is given, else
# by GooTuning; the round fallback by its parent world (_parent_tuning()).
# make() and _ready() both build through here.
func _setup_shape(body_radius: float, global_pos: Vector2, from_shape: GooShape,
		ring_tuning: Dictionary = {}) -> void:
	if from_shape != null and not from_shape.is_round():
		var body_shape := from_shape.scaled(body_radius)
		if ring_tuning.is_empty():
			ring_tuning = GooTuning.tuning_for(body_shape)
		var loop := body_shape.bead_loop(ring_tuning["bead_count"], ring_tuning["bead_radius"])
		if loop.size() == int(ring_tuning["bead_count"]):
			var offset := global_pos - GooLoop.centroid(loop)
			for i: int in loop.size():
				loop[i] += offset
			shape = body_shape
			setup(body_radius, global_pos, ring_tuning, loop)
			return
		push_error("make(): a %d-point shape of radius %.1f is too thin for its beads; built round"
			% [from_shape.outline.size(), body_radius])
		setup(body_radius, global_pos, _parent_tuning(GooShape.round(body_radius)))
		return
	setup(body_radius, global_pos, ring_tuning if not ring_tuning.is_empty() else GooTuning.tuning(body_radius))

# The tuning of a ring of `ring_shape` for this body, in the tree: its parent
# GooWorld2D's tuning_for() (with the body's `tags`), or
# GooTuning.tuning_for() outside any world. What a builder falls back to when
# the shape it was tuned for cannot be built.
func _parent_tuning(ring_shape: GooShape) -> Dictionary:
	var world := get_parent() as GooWorld2D
	return world.tuning_for(ring_shape, tags) if world != null else GooTuning.tuning_for(ring_shape)
