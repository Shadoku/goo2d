@icon("res://addons/goo2d/icon_goo_world_2d.svg")
class_name GooWorld2D
extends Node2D
## The rules of the goo: owns the Goo2D bodies under it (its direct children)
## and turns their signals into merges and splits. Bodies merge when they touch
## and combine: round ones of close sizes, shapes flat face to flat face (see
## can_merge()), or whatever a subclass's may_merge() says; the merged body's
## colour is merged_color()'s (by size by default). Bodies report what they
## touch once per physics frame
## (Goo2D.touched, from the kernel's step); merges are queued there and
## started in a deferred call at the end of the frame. A started merge is a MergeTransition:
## for its DURATION the pair is pulled together, tinted towards the merged
## body's colour and made frictionless (two soft bodies grinding against each
## other and the floor for that long would otherwise eat most of their
## momentum), then, once the pair is compact (it touches and the merged ring's
## loop fits within MERGE_FIT, merge_fit()), the world swaps them for one ring
## rebuilt around both, which keeps their beads' velocities and eases into its
## rest shape (Goo2D.rebuild_from()). Two shapes are swapped for one shape, the
## union of their outlines in the pose they touched in, fused within a contact
## range of the junction (fused_outline()). A pair that is not compact by
## MergeTransition.MAX_DURATION (it came apart, or is held apart) is let go:
## the transition is cancelled and both are merge-locked for MERGE_LOCK.
##
## Splitting: a ring that is pinched or crushed asks to be split
## (Goo2D.pinched); cut() then cuts its bead loop along the chord it named into
## two rings that share its area by the areas on either side of the chord. A
## polygon body is cut in rest space instead (GooShape.cut_ring()): its rest
## outline, fitted onto its beads, is cut along the chord between its ends
## (other arms of a concave outline stay whole), and each piece is a polygon
## body of the outline piece that holds its own beads. cut_along() cuts a
## body along a line through a point inside it, the way a blade does, and
## pierce() every body a static tip is inside; cut_at_tips() does what a
## blade does for a set of tips at once.
##
## Trimming: a body with a tip inside its bead loop must come off it. When
## the cut a tip asks for would leave a piece too small (MIN_PIECE_RATIO) or
## too thin (GooShape.MIN_PIECE_WIDTH_BEADS), the body is not left as it is:
## it is rebuilt on the larger side of the chord alone, holding its whole area
## (the crumb is absorbed), which puts the tip outside the new ring (`trimmed`).
## A pinch or a direct cut() that would leave a crumb is refused instead: the
## ring has nothing in it and asks again later.
##
## Merge lock: a body made by a merge or a split cannot merge for MERGE_LOCK
## seconds (Goo2D.merge_lock_until; a whole number of physics frames, ending on
## the same frame of its span however long the engine has run, so a replayed
## game merges on the same frame), so a merge does not chain straight into the
## next one and the two pieces of a split do not merge straight back. Spawned
## bodies and bodies placed in a scene are not locked. When the lock runs out,
## the body's contacts are judged again (an awake body reports them every frame
## anyway; a settled one's last known contacts are reported once), so a
## neighbour it has been resting against all along can still merge with it.
##
## Bodies: spawn() builds and registers one, despawn() removes one, clear()
## all of them. A Goo2D child the world did not
## spawn (placed under it in the editor, or added by a script) is registered
## once it is in the tree and built, at the end of the frame it was added in.
## The per-frame work runs in the world's native kernel (GooKernel, see
## kernel()), stepped in the world's _physics_process: every body's beads move
## under the kernel's solver (constraints, contacts with each other and with
## the static shapes GooStatics mirrors from the scene: every StaticBody2D on
## GooTuning.LAYER_WALLS), then settle, pinch and get their skin (see Goo2D),
## and the passes over pairs of bodies run first: the overlap push of the beads
## of a body that got into another one (intrusion(), judged from the bead
## loops, so it holds for shapes too) and the Untangler for rings threaded
## through each other. The merge locks and transitions run before the step (see
## _physics_process()), and the world then turns the step's events into
## signals (Goo2D.dispatch_events()).
##
## Grabbing: grab() holds a body by a point (a pointer, a finger) until
## release_grab(): every physics frame, before the step, a critically damped
## spring (GooTuning.GRAB_STIFFNESS, GRAB_DAMPING) pulls the beads nearest the
## point toward it, weighted by distance (GooTuning.GRAB_REACH), so a body
## held by its rim dangles and stretches under gravity; move_grab() moves the
## point, release_grab() lets go or throws. A held body never settles. A body
## that leaves the world (a split, a merge, a trim, despawn(), clear()) lets
## go of its grabs. body_at() finds the body under a point.
##
## Linking: link() joins two of its bodies so they hold together and bend at
## the joint, drawn as one blob with a neck (GooLink: the kernel's link
## constraints and the bridge skin); unlink() parts them. Linked bodies never
## merge with each other (may_merge() is not asked for them). A body that
## leaves the world (a split, a merge, a trim, despawn(), clear()) releases its
## links (bodies_unlinked), as it lets go of its grabs.

## Emitted after two bodies merged into one of `radius` (px); `position` is the
## merged body's centre when it was made.
signal merged(radius: float, position: Vector2)
## Emitted after a body split into two of `radius_a` and `radius_b` (px);
## `position` is where the split body's centre was.
signal split(radius_a: float, radius_b: float, position: Vector2)
## Emitted after a body with a tip inside it was trimmed off the tip instead of
## split (the cut would have left a crumb): rebuilt as one body of the same
## `radius` (px) on the larger side of the cut; `position` is where the
## trimmed body's centre was.
signal trimmed(radius: float, position: Vector2)
## Emitted whenever the number of bodies changes, with the new number. A merge,
## a split or a trim reports it once its new bodies are in and the old ones out
## (a body registered on the way may report a passing count first; a trim
## reports the same count).
signal count_changed(count: int)
## Emitted when a body split, with the id (Goo2D.id) it had and its two
## `pieces`, registered and listed by bodies(), each with an id of its own:
## for following a body's identity through a split (a running score, a kind
## the game keeps per body). Emitted right after count_changed and before
## `split`, outside the physics flush; the split body is already out of the
## tree and the kernel (not in bodies()), its id still readable until it is
## freed at the end of the frame.
signal body_split(parent_id: int, pieces: Array[Goo2D])
## Emitted when two bodies merged, with the ids (Goo2D.id) the pair had, in
## the order the world swapped them, and the merged `body`, registered with a
## fresh id: for following the pair's identity into the merged body. Emitted
## right after count_changed and before `merged`, outside the physics flush;
## the pair is already out of the tree and the kernel (not in bodies()), their
## ids still readable until they are freed at the end of the frame.
signal bodies_merged(ids: PackedInt32Array, body: Goo2D)
## Emitted when a body was trimmed off a tip (see `trimmed`), with the id
## (Goo2D.id) it had and the `body` rebuilt in its place, registered with a
## fresh id: for following its identity through the trim. Emitted right after
## count_changed and before `trimmed`, outside the physics flush; the old body
## is already out of the tree and the kernel (not in bodies()), its id still
## readable until it is freed at the end of the frame.
signal body_trimmed(old_id: int, body: Goo2D)
## Emitted for every body the world registers, whichever way it came: a
## spawn(), each piece of a split, the body a merge made, the body a trim
## rebuilt, a Goo2D placed under the world (in the editor, or added by code
## and registered at the end of the frame). The body is in the tree, built,
## tuned (tuning_for()), tagged, coloured and registered (its id, listed by
## bodies()) when it fires, and nothing else about it has been emitted yet:
## it comes before the count_changed of its registration and before
## body_split, bodies_merged or body_trimmed. For a game that does something
## to every body it gets (a perk's spin, a kind's look); outside the physics
## flush, so a handler may change the body (its velocity, its colour).
signal body_spawned(body: Goo2D)
## Emitted after one of the world's bodies rebuilt its ring in place with
## another bead count (Goo2D.resize() carried its size past a bead count's
## boundary: Goo2D.rebuilt): the same node, id, tags, colours, skin and
## children, but new beads, so whatever holds it by bead index or by its
## kernel ring must re-attach (by a point, or a rest-space anchor:
## Goo2D.rest_shape and ring_rotation() map one onto the beads). The world's
## own grabs are re-attached at the point they held before it fires. Outside
## the physics flush.
signal body_rebuilt(body: Goo2D)
## Emitted when link() joined `a` and `b` under the link `handle`.
signal bodies_linked(handle: int, a: Goo2D, b: Goo2D)
## Emitted when the link `handle` between the bodies of ids `a_id` and `b_id`
## (Goo2D.id) was released: by unlink(), or by either body leaving the world (a
## split, a merge, a trim, despawn(), clear(); emitted as it goes, before the
## signals announcing what became of it).
signal bodies_unlinked(handle: int, a_id: int, b_id: int)

## Acceleration, in px/s² at GooTuning.unit 1, pulling a merging pair towards
## each other (merge_pull() scales it by the unit).
const MERGE_PULL := 1500.0
## Smallest piece a split may leave, as a fraction of GooTuning.min_radius(): a
## cut that would leave less is not made (the ring asks again later). 0.5 (14
## px at unit 1) lets launch-size blobs (28-48 px) split on the wedge: at 0.8 a
## blob under 32 px could not split at all and a 48 px one only into near-equal
## halves. Pieces under min_radius() tune like the smallest size and merge with
## anything within GooTuning.MERGE_TOLERANCE.
const MIN_PIECE_RATIO := 0.5
## Pixels, at GooTuning.unit 1, between the two pieces' collision outlines at
## the cut (split_gap() scales it by the unit).
const SPLIT_GAP := 2.0
## Largest factor, either way, between the area of a polygon piece's bead loop
## at birth (cut from the body's beads) and that of its rest loop (cut from its
## rest outline) for which _split_shape() makes the cut. A piece built with the
## rest shape of the other side of a concave shape's cut (the mismatch
## GooShape.cut_ring() now rules out) is far off (a U's arm tip given the
## other arm's top: 0.31 ×, the rest of the U 1.54 ×) and blows up or
## collapses within a frame. A sound piece starts below 1 (its beads come from
## the parent's loop, a bead radius of the parent's larger beads in from the
## outline): 0.75-0.97 for halves and large pieces, 0.45-0.6 for small tips
## cut off a coarse ring (tests/integration/test_shape_split.gd), so the bound
## is loose on purpose.
const MAX_PIECE_AREA_MISMATCH := 2.5
## Seconds after a merge or a split during which the body it made cannot merge
## (and after a transition timed out, MergeTransition.MAX_DURATION, during
## which neither of its pair can).
const MERGE_LOCK := 0.3
## How much longer around than its rest loop the loop a merged ring would be
## placed on may be for the world to swap a merging pair (merge_fit()), and
## the pair must touch (their outlines make one): a pair still further from
## compact after MergeTransition.DURATION is pulled on until it is compact, up
## to MergeTransition.MAX_DURATION, and then let go rather than forced (it used
## to be built around the lowest of the two alone, or on a peanut). Measured
## with tools/births.gd (seeds 1-3, before the crease filling of
## Goo2D.MERGE_CLOSE_BEADS): round merges placed within 1.2 of their circle
## were born calm; from 1.2 on, half of them lost 20-70% of their area in one
## step, beads at 1600-4400 px/s. A shorter loop is no worry: the ring
## inflates from it (target_area and rest_blend, Goo2D.rebuild_from()).
const MERGE_FIT := 1.2
## Physics frames between two may_merge() judgements of two shapes that keep
## touching without merging (the default rule's flat_contact() is O(beads²)); a
## pair is judged on the frame it begins touching whatever this says. Every
## other pair is judged every frame it is reported.
const SHAPE_REJUDGE_FRAMES := 4

## The shader every body registered in this world is drawn with when it has
## none of its own (Goo2D.skin_shader null); null leaves those on the addon's
## goo shader. A body is given it at registration (_register(): its
## skin_shader becomes the world's). Set at any time: the bodies already
## registered that draw with the world's (their skin_shader null or the world's
## previous one) take the new one at once; a body with a shader of its own
## keeps it.
@export var skin_shader: Shader = null:
	set(value):
		var previous := skin_shader
		skin_shader = value
		for body: Goo2D in bodies():
			if body.id >= 0 and (body.skin_shader == null or body.skin_shader == previous):
				body.skin_shader = value

## How strongly this world's bodies fall: the gravity its kernel steps them
## with is GooTuning.solver_settings()["gravity"] times this (1, the default:
## the project's gravity; 0.5 half of it; 0 none). Set before the world enters
## the tree, it is applied when kernel() makes the kernel; set afterwards, at
## any time, it is re-sent at once (kernel().set_solver({"gravity": ...})). It
## scales the solver's pull only: ring pressure stays GooTuning's, tuned for
## the project's gravity, and the kernel's gravity-derived thresholds (the
## bounce threshold, settling's margin) follow the scaled vector, since the
## kernel reads them from its solver's settings. A change does not wake settled
## bodies (they fall once something wakes them). Per world, not per body; lone
## bodies outside a world keep GooTuning.make_kernel()'s gravity.
@export_range(0.0, 4.0, 0.01, "or_greater") var gravity_scale: float = 1.0:
	set(value):
		gravity_scale = value
		if _kernel != null:
			_kernel.set_solver({ "gravity": _scaled_gravity() })

## Whether a merge of two bodies of different colours makes a two-tone body:
## drawn in both colours, each on the side its parent came from, the division
## between them crossing the line between the parents' centres at their area
## ratio (the bigger parent owns the bigger side) and turning with the body
## (Goo2D.second_color, division_axis, division_offset). On, merged_colors()
## decides a merged body's colours and merged_color() is not asked; off (the
## default), merged_color() decides its one colour as it always has, and no
## body this world makes is two-tone (a split piece still keeps a two-tone
## parent's colours: a body made two-tone by hand stays so). A world that
## overrides merged_color() and turns this on gets merged_colors()' default
## unless it overrides that too. Read at every merge, so it may change at any
## time.
@export var two_tone_merges: bool = false

var _queue := MergeQueue.new()
var _merge_scheduled: bool = false
var _adopt_scheduled: bool = false
var _next_id: int = 0
var _by_id: Dictionary[int, Goo2D] = {}
var _transitions: Array[MergeTransition] = []
# The kernel stepping this world's bodies (kernel()), made on first use.
var _kernel: GooKernel = null
# The scene's static shapes, mirrored into the kernel (kernel()).
var _statics: GooStatics = null
# Ids of bodies with a split waiting for the deferred cut().
var _pending_splits: Dictionary[int, bool] = {}
# Ids of bodies whose merge lock has not been seen to run out yet.
var _merge_locked: Dictionary[int, bool] = {}
# Pairs reported touching (MergeQueue.key()) on physics frame _touch_frame, and
# on the frame before it, each with the physics frame it was last judged on
# with may_merge() (-1: not yet). See judge_contact().
var _touch_frame: int = -1
var _touching: Dictionary[Vector2i, int] = {}
var _touching_before: Dictionary[Vector2i, int] = {}
# The grabs held (grab()), by handle, and the next handle.
var _grabs: Dictionary[int, Grab] = {}
var _next_grab: int = 0
# The links (link()), by handle, the next handle, and the internal node their
# bridges are drawn in (made with the first link).
var _links: Dictionary[int, GooLink] = {}
var _next_link: int = 0
var _bridges: Node2D = null

# Registers the Goo2D children placed with the world (built in their own
# _ready(), which runs before this one) and listens for bodies added later.
func _ready() -> void:
	child_entered_tree.connect(_on_child_entered)
	_adopt()

# Mirrors the scene's static shapes into the kernel while the world is in the
# tree (GooStatics follows StaticBody2D nodes coming and going).
func _enter_tree() -> void:
	kernel()
	_statics.attach(get_tree())

func _exit_tree() -> void:
	if _statics != null:
		_statics.detach()

## The native kernel this world's bodies are rings of (Goo2D joins it when it is
## built under the world): it runs their per-frame work and the pair passes.
func kernel() -> GooKernel:
	if _kernel == null:
		_kernel = GooTuning.make_kernel()
		_kernel.set_solver({ "gravity": _scaled_gravity() })
		_kernel.set_pair_passes(true)
		_statics = GooStatics.new(_kernel)
	return _kernel

# The gravity this world's kernel steps with: GooTuning's times gravity_scale.
func _scaled_gravity() -> Vector2:
	var gravity: Vector2 = GooTuning.solver_settings()["gravity"]
	return gravity * gravity_scale

## Mirrors the scene's static shapes into the kernel again at the next step:
## after a static body changed in a way GooStatics does not follow (its shape
## resource edited, its layer or group changed). Bodies and shapes added,
## removed or moved are followed on their own.
func refresh_static_shapes() -> void:
	kernel()
	_statics.refresh()

## Makes this world's bodies and `cells`' creatures collide: GooCellWorld2D.couple(self)
## (the cell world resolves the contacts and steps after this one; docs/cells.md, "Rings
## and cells").
func couple(cells: GooCellWorld2D) -> void:
	cells.couple(self)

# Every body's physics frame: the merge locks and transitions (which may swap
# two bodies for their merge), then the kernel's step (the static shapes
# brought up to date, the pair passes, every ring's solver substeps, contacts,
# settling, pinches and skin), then its events as signals (touched,
# pinched...). Code that awaited SceneTree.physics_frame (spawning, throwing)
# has run before this, so what it did is stepped in the same frame. A subclass
# that overrides this calls super(delta).
func _physics_process(delta: float) -> void:
	var goo := kernel()
	_release_merge_locks()
	_advance_transitions(delta)
	_hold_grabs(delta)
	_statics.sync()
	if not _links.is_empty():
		_attach_links()
	goo.set_merge_partners(_partner_keys())
	goo.step(delta)
	Goo2D.dispatch_events(goo.take_events(), self)
	if not _links.is_empty():
		_draw_bridges(delta)

## Spawns a body of `radius` (px) centred on `global_pos`: round, or with a
## `shape` that body's outline at the equivalent radius `radius` (see
## Goo2D.make()), tagged with a copy of `tags` (Goo2D.tags; the caller's array
## is not kept) and tuned by tuning_for() of its shape and those tags. Call
## outside the physics flush.
func spawn(radius: float, global_pos: Vector2, shape: GooShape = null, tags: Array = []) -> Goo2D:
	var ring_tuning := tuning_for(Goo2D.sized_shape(radius, shape), tags)
	return _register(Goo2D.make(radius, global_pos, self, shape, ring_tuning, tags))

# Spawns the body of `radius` that replaces the merged pair `from`, still in
# the tree: one ring rebuilt from their beads (see Goo2D.make_merged()),
# of the `fused` shape if one is given, in the pair's colours (_merge_colors():
# merged_color(), or with two_tone_merges merged_colors(), the first on
# from[0]'s side), tagged with merged_tags() of the pair (asked once, here) and
# tuned by tuning_for() of its shape and those tags, merge-locked. A two-tone
# body gets its division before it is registered, so body_spawned's handlers
# see it: across the line from from[0]'s centre to from[1]'s, crossing it at
# their area ratio (the bigger owns the bigger side), in the merged body's rest
# space as measured right after it was built (Goo2D.division_in_rest()). Call
# outside the physics flush.
func _spawn_merged(radius: float, from: Array[Goo2D],
		fused: PackedVector2Array = PackedVector2Array()) -> Goo2D:
	var a := from[0]
	var b := from[1]
	var tags := merged_tags(a, b)
	var ring_tuning := tuning_for(GooShape.round(radius) if fused.is_empty() else GooShape.polygon(fused), tags)
	var colours := _merge_colors(a, b)
	var centre_a := a.center()
	var centre_b := b.center()
	var area_a := a.area()
	var area_b := b.area()
	var body := Goo2D.make_merged(radius, self, from, fused, colours[0], ring_tuning, tags)
	if body != null and colours.size() > 1:
		var share := area_a / (area_a + area_b) if area_a + area_b > 0.0 else 0.5
		var through := centre_a + (centre_b - centre_a) * share
		var division := Goo2D.division_in_rest(centre_b - centre_a, through, body.center(),
			body.ring_rotation())
		body.set_two_tone(colours[0], colours[1], division["axis"], division["offset"])
	return _register(body, true)

# The colours of the body `a` and `b` merge into: [merged_color()] with
# two_tone_merges off; with it on merged_colors(), one colour or two (a second
# equal to the first, or past the second, dropped; nothing given:
# COLOR_BY_SIZE).
func _merge_colors(a: Goo2D, b: Goo2D) -> PackedColorArray:
	if not two_tone_merges:
		return PackedColorArray([merged_color(a, b)])
	var colours := merged_colors(a, b)
	if colours.is_empty():
		return PackedColorArray([Goo2D.COLOR_BY_SIZE])
	if colours.size() == 1 or colours[1] == colours[0]:
		return PackedColorArray([colours[0]])
	return PackedColorArray([colours[0], colours[1]])

## Removes `body`, one of this world's bodies, now: forgets its pending merges
## (a merge transition it is in is cancelled: its partner may merge again, in
## its own colour), its pending split and its merge lock, takes it out of the
## tree and the kernel at once and frees it at the end of the frame, then emits
## count_changed. Does nothing for a body that is not this world's, or already
## gone. Call outside the physics flush (from _physics_process() or a handler
## of the world's own signals is fine).
func despawn(body: Goo2D) -> void:
	if not _is_live(body):
		return
	_forget(body)
	_remove(body)
	count_changed.emit(bodies().size())

# Forgets what the world keeps about `body` before it goes (despawn()): its
# queued merges, its merge transition (whose partner is let go), its pending
# split and merge lock.
func _forget(body: Goo2D) -> void:
	_queue.forget(body.id)
	_pending_splits.erase(body.id)
	_merge_locked.erase(body.id)
	var running: Array[MergeTransition] = []
	for transition: MergeTransition in _transitions:
		if transition.id_a != body.id and transition.id_b != body.id:
			running.append(transition)
			continue
		var partner_id := transition.id_b if transition.id_a == body.id else transition.id_a
		_cancel(_by_id.get(partner_id))
	_transitions = running

## True while `body` (made by a merge or a split) may not merge: less than
## MERGE_LOCK seconds of physics time have passed since it was made.
func merge_locked(body: Goo2D) -> bool:
	return _physics_time() < body.merge_lock_until

## MERGE_PULL at the goo's length unit (GooTuning.unit), px/s².
static func merge_pull() -> float:
	return MERGE_PULL * GooTuning.unit

## SPLIT_GAP at the goo's length unit (GooTuning.unit), px.
static func split_gap() -> float:
	return SPLIT_GAP * GooTuning.unit

## Radius, in px, of the smallest piece a cut may leave: MIN_PIECE_RATIO ×
## GooTuning.min_radius().
static func min_piece_radius() -> float:
	return GooTuning.min_radius() * MIN_PIECE_RATIO

# Seconds of physics time since the engine started: physics frames over the
# tick rate, so it advances only with the simulation.
static func _physics_time() -> float:
	return float(Engine.get_physics_frames()) / Engine.physics_ticks_per_second

# The physics time `seconds` from now on the frame grid: a whole number of
# physics frames from this one over the tick rate, as _physics_time() will
# read it on that frame, so a lock ends on the same frame of its span however
# long the engine has run (now + seconds would end it a frame early or late
# by a rounding error that depends on the frame it began on).
static func _physics_time_in(seconds: float) -> float:
	var ticks := Engine.physics_ticks_per_second
	return float(Engine.get_physics_frames() + roundi(seconds * ticks)) / ticks

# Gives a freshly made body its id and starts listening to its contacts; with
# `lock_merging`, it may not merge for MERGE_LOCK seconds; announces it
# (body_spawned, then count_changed). A body that already has an id is left as
# it is.
func _register(body: Goo2D, lock_merging: bool = false) -> Goo2D:
	if body.id >= 0:
		return body
	body.id = _next_id
	_next_id += 1
	if body.skin_shader == null:
		body.skin_shader = skin_shader
	_by_id[body.id] = body
	if lock_merging:
		_lock_merging(body)
	body.pinched.connect(_on_pinched.bind(body))
	body.rebuilt.connect(_on_body_rebuilt.bind(body))
	body_spawned.emit(body)
	count_changed.emit(bodies().size())
	return body

# A Goo2D added under the world is registered at the end of the frame, once it
# has built itself (a placed body in its _ready()) or been built by whoever
# added it (a builder adds the body first and builds it after; spawn() then
# registers it straight away, so the deferred call finds nothing to do).
func _on_child_entered(node: Node) -> void:
	if node is Goo2D and not _adopt_scheduled:
		_adopt_scheduled = true
		_adopt.call_deferred()

# Registers every body under the world that has no id yet, in child order.
func _adopt() -> void:
	_adopt_scheduled = false
	for body: Goo2D in bodies():
		if body.id < 0:
			_register(body)

## Removes every body and forgets pending merges and splits (despawn() removes
## one).
func clear() -> void:
	_queue.clear()
	_transitions.clear()
	_pending_splits.clear()
	_merge_locked.clear()
	_touching.clear()
	_touching_before.clear()
	_grabs.clear()
	for body: Goo2D in bodies():
		_remove(body)
	count_changed.emit(0)

## The live bodies, in the order they were added.
func bodies() -> Array[Goo2D]:
	var result: Array[Goo2D] = []
	for child: Node in get_children():
		var body := child as Goo2D
		if body != null and not body.is_queued_for_deletion():
			result.append(body)
	return result

## Queues a merge of `body` and `other` (two registered bodies of this world)
## if they combine (may_merge(); by default can_merge(): by size, or flat face
## to flat face, judged from where their beads are now). The world calls it
## for each contact its
## kernel reports (Goo2D.dispatch_events(), right before the body's `touched`
## signal), both ways round, every physics frame two bodies touch, so the pair
## is judged here once per frame at most: not again in the same frame, not
## while either is merge-locked or the pair already queued, and two shapes that
## keep touching only every SHAPE_REJUDGE_FRAMES frames after the frame they
## began.
func judge_contact(other: Goo2D, body: Goo2D) -> void:
	# Every pair goes through may_merge(), so a subclass decides for all of
	# them. (An early return here used to skip the pairs the default rule can
	# never combine, a shape and a round body or round bodies of sizes too far
	# apart; the default may_merge() turns a round pair down as cheaply, by
	# size, and the bookkeeping below costs two dictionary lookups per contact.)
	var frame := Engine.get_physics_frames()
	if frame != _touch_frame:
		var reused := _touching_before
		_touching_before = _touching
		if frame != _touch_frame + 1:
			_touching_before.clear()
		_touching = reused
		_touching.clear()
		_touch_frame = frame
	if not _links.is_empty() and linked(body, other) >= 0:
		return
	var pair := MergeQueue.key(body.id, other.id)
	if _touching.has(pair):
		return
	var judged: int = _touching_before.get(pair, -1)
	_touching[pair] = judged
	if _queue.has(body.id, other.id):
		return
	if merge_locked(body) or merge_locked(other):
		return
	if judged >= 0 and frame - judged < SHAPE_REJUDGE_FRAMES and both_shapes(body, other):
		return
	_touching[pair] = frame
	if not may_merge(body, other):
		return
	_queue.request(body.id, other.id)
	if not _merge_scheduled:
		_merge_scheduled = true
		_resolve_merges.call_deferred()

# Starts a transition for each queued pair; nothing is swapped here.
func _resolve_merges() -> void:
	_merge_scheduled = false
	for pair: Vector2i in _queue.drain():
		var a: Goo2D = _by_id.get(pair.x)
		var b: Goo2D = _by_id.get(pair.y)
		if not _is_live(a) or not _is_live(b) or not may_merge(a, b):
			continue
		if a.merging or b.merging:
			continue
		if not _links.is_empty() and linked(a, b) >= 0:
			continue
		_begin_merge(a)
		_begin_merge(b)
		var transition := MergeTransition.new(a.id, b.id)
		transition.particle_mass_a = _particle_mass(a)
		transition.particle_mass_b = _particle_mass(b)
		_transitions.append(transition)

func _on_pinched(a: int, b: int, body: Goo2D) -> void:
	_request_cut(body, a, b, false)

# Queues the deferred cut() of `body` from bead `a` to bead `b`, trimming
# instead of refusing a crumb if `trim`, unless the body is going, merging or
# already waiting for a cut, or may_split() refuses it. The one funnel of every
# cut the goo asks for (a pinch or a crush, cut_along(), cut_at_tips(),
# pierce()). Returns true if the cut was queued.
func _request_cut(body: Goo2D, a: int, b: int, trim: bool) -> bool:
	if body.is_queued_for_deletion() or body.merging or _pending_splits.has(body.id):
		return false
	if not may_split(body):
		return false
	_pending_splits[body.id] = true
	cut.call_deferred(body, a, b, trim)
	return true

## Asks for a cut of every body a tip of `tips` touches or is inside, along
## that tip's direction in `axes` (one per tip): what a set of blades does to
## the bodies they reach. Call it every physics frame (from _physics_process(),
## before super(delta)). Each body is asked for at most one cut, by the first
## tip, in order, for which cut_along() requests one: a body is passed over
## unless its box (Goo2D.bead_bounds()) grown by a bead radius holds the tip,
## and cut_along() leaves alone one that is merging, already waiting for a cut,
## split locked with the tip only touching it, or refused by may_split() (it
## counts in no return). Returns how many bodies a cut was requested for (the
## cuts are made at the end of the frame). Tips beyond the last axis are
## ignored.
func cut_at_tips(tips: PackedVector2Array, axes: PackedVector2Array) -> int:
	var count := mini(tips.size(), axes.size())
	var requested := 0
	if count == 0:
		return requested
	for body: Goo2D in bodies():
		# cut_along() passes over a body whose box does not reach the tip; one box
		# per body for all the tips.
		var box := body.bead_bounds().grow(body.bead_radius() * 1.001 + 0.01)
		for k: int in count:
			if box.has_point(tips[k]) and cut_along(body, tips[k], axes[k]):
				requested += 1
				break
	return requested

## Asks for a cut of `body` along the line through `point` in direction `axis`
## if `point` touches or is inside its collision outline (within a bead radius
## of its bead loop): what a blade does to a body its tip reaches, whatever the
## body's speed or pressure. The cut is made by the same deferred cut() a
## pinch uses, along the chord the line cuts the bead loop on
## (GooLoop.chord()). With `point` only touching the body, a cut that would
## leave a crumb is refused there (call this again every frame: the body is
## cut once it has sunk onto the point far enough); with `point` inside the
## bead loop (GooLoop.point_in_loop(): the body is impaled on it), such a cut
## trims the body off the point instead (see `trimmed`), the split lock does
## not hold (a fresh piece falling back onto a blade is cut again) and a
## settled body is woken. Leaves alone a body that is merging, already waiting
## for a cut, split locked with the point only touching it, or refused by
## may_split() (not woken either). Returns true if a cut was requested. A body
## whose box (Goo2D.bead_bounds()) grown by a bead radius does not hold `point`
## is passed over without any loop geometry.
func cut_along(body: Goo2D, point: Vector2, axis: Vector2) -> bool:
	if body.merging or _pending_splits.has(body.id) or body.particle_count() == 0:
		return false
	if not _box_reaches(body, point, body.bead_radius()):
		return false
	var points := body._frame_points()
	var inside := GooLoop.point_in_loop(point, points)
	if not inside and (body.split_lock() > 0.0 or not GooLoop.pierces(points, point, body.bead_radius())):
		return false
	var ends := GooLoop.chord(points, point, axis)
	if ends == GooLoop.NO_CHORD or not _request_cut(body, ends.x, ends.y, inside):
		return false
	if inside and body.settled:
		body.wake()
	return true

## Cuts every body with `point` inside its bead loop along the line through
## `point` in direction `axis` (cut_along(), so a settled body is woken and a
## cut that would leave a crumb trims it off the point): the step for a static
## tip that is not a blade, such as a wedge's apex, which only cuts what it has
## got into; call it every physics frame for each such tip. A body the point
## only touches is left alone, and so is one may_split() refuses. Returns the
## number of cuts requested.
func pierce(point: Vector2, axis: Vector2) -> int:
	var requested := 0
	for body: Goo2D in bodies():
		if body.particle_count() == 0 or not _box_reaches(body, point, 0.0) \
				or not GooLoop.point_in_loop(point, body._frame_points()):
			continue
		if cut_along(body, point, axis):
			requested += 1
	return requested

# False if `point` is certainly further than `reach` px from `body`'s bead loop
# and outside it: outside the box of its bead centres grown by `reach` (with a
# little slack for rounding). Inside the box decides nothing.
static func _box_reaches(body: Goo2D, point: Vector2, reach: float) -> bool:
	return body.bead_bounds().grow(reach * 1.001 + 0.01).has_point(point)

## Cuts the body `body` along the chord from its bead `a` to its bead `b` into
## two bodies: one on beads a, a+1, …, b, the other on b, …, a, each clipped
## back from the cut so the two never overlap (Goo2D.cut_piece()). They share
## the body's area in proportion to their bead loops' areas, keep its beads'
## velocities and inflate to their own radius. Does nothing to a body that is
## merging or gone, or whose loop on either side of the chord crosses itself.
## If either piece would be smaller than min_piece_radius()
## the cut is not made either, unless `trim`: the body is then trimmed instead
## (_trim(): one body of its whole area on the larger side, see `trimmed`). A
## body of a POLYGON shape is cut in rest space instead (_split_shape()). An
## order, not a request: may_split() is not asked (the cuts the goo asks for,
## through a pinch, cut_along(), cut_at_tips() or pierce(), are). Call outside
## the physics flush.
func cut(body: Goo2D, a: int, b: int, trim: bool = false) -> void:
	if not is_instance_valid(body):
		return
	_pending_splits.erase(body.id)
	if not _is_live(body) or body.merging:
		return
	var points := body.bead_points()
	var count := points.size()
	if a < 0 or b < 0 or a >= count or b >= count or a == b:
		return
	var loop_a := Goo2D.sub_loop(points, a, b)
	var loop_b := Goo2D.sub_loop(points, b, a)
	if GooLoop.self_intersects(loop_a) or GooLoop.self_intersects(loop_b):
		return
	if body.shape != null and not body.shape.is_round():
		_split_shape(body, points, a, b, trim)
		return
	var area_a := GooLoop.area(loop_a)
	var area_b := GooLoop.area(loop_b)
	if area_a + area_b <= 0.0:
		return
	var radius_a := body.radius * sqrt(area_a / (area_a + area_b))
	var radius_b := body.radius * sqrt(area_b / (area_a + area_b))
	if minf(radius_a, radius_b) < min_piece_radius():
		if trim:
			var ends := Vector2i(a, b) if area_a >= area_b else Vector2i(b, a)
			_trim(body, points, ends, { "radius": body.radius, "shape": null, "rest_loop": PackedVector2Array() },
				GooTuning.bead_radius(body.radius))
		return
	var overhang := body.bead_radius() + split_gap()
	var piece_a := Goo2D.cut_piece(points, a, b,
		GooTuning.bead_radius(radius_a) + split_gap() / 2.0, overhang)
	var piece_b := Goo2D.cut_piece(points, b, a,
		GooTuning.bead_radius(radius_b) + split_gap() / 2.0, overhang)
	if piece_a.is_empty() or piece_b.is_empty():
		return
	_replace_by_pieces(body, points, [
		{ "loop": piece_a, "radius": radius_a, "shape": null, "rest_loop": PackedVector2Array() },
		{ "loop": piece_b, "radius": radius_b, "shape": null, "rest_loop": PackedVector2Array() },
	] as Array[Dictionary])

# Cuts the polygon body `body`, whose beads are at `points`, along the chord
# from bead `a` to bead `b` in rest space (GooShape.cut_ring()): each piece is a
# polygon body of its side of the fitted rest outline, with that side's area
# and rest loop. The beads still go where cut_piece() of the current bead loop
# says, so the pieces start where the body was and their shape matching pulls
# them into their rest outlines. If cut_ring() refuses the cut (a piece under
# min_piece_radius() or a sliver under
# GooShape.MIN_PIECE_WIDTH_BEADS bead diameters wide), does nothing (the ring
# asks again), or with `trim` trims the body to the larger side scaled to its
# whole area (GooShape.trim_ring(), _trim()). Nor is a cut made whose piece's
# bead loop would enclose over MAX_PIECE_AREA_MISMATCH times more or less than
# its rest loop.
func _split_shape(body: Goo2D, points: PackedVector2Array, a: int, b: int, trim: bool = false) -> void:
	var cut_shapes := body.shape.cut_ring(body.rest_shape, points, a, b, body.bead_radius(),
		min_piece_radius())
	if cut_shapes.size() != 2:
		if trim:
			var kept := body.shape.trim_ring(body.rest_shape, points, a, b, body.bead_radius())
			if not kept.is_empty():
				var shape: GooShape = kept["shape"]
				_trim(body, points, Vector2i(a, b) if int(kept["side"]) == 0 else Vector2i(b, a),
					{ "radius": shape.radius(), "shape": shape, "rest_loop": kept["rest_loop"] },
					float(kept["tuning"]["bead_radius"]))
		return
	var overhang := body.bead_radius() + split_gap()
	var ends: Array[Vector2i] = [Vector2i(a, b), Vector2i(b, a)]
	var pieces: Array[Dictionary] = []
	for k: int in 2:
		var shape: GooShape = cut_shapes[k]["shape"]
		var loop := Goo2D.cut_piece(points, ends[k].x, ends[k].y,
			float(cut_shapes[k]["tuning"]["bead_radius"]) + split_gap() / 2.0, overhang)
		if loop.is_empty():
			return
		# A ring whose beads enclose far more or far less than its rest loop
		# can only blow up or collapse: the skin and bending constraints pull
		# its beads to the rest edge lengths within a frame (thousands of px/s)
		# while the pressure, aimed at the loop's own area at birth, fights them.
		# cut_ring() gives each side the piece holding its own beads, so this
		# is the backstop.
		var rest_loop: PackedVector2Array = cut_shapes[k]["rest_loop"]
		var mismatch := GooLoop.area(loop) / maxf(GooLoop.area(rest_loop), 0.000001)
		if mismatch > MAX_PIECE_AREA_MISMATCH or mismatch < 1.0 / MAX_PIECE_AREA_MISMATCH:
			return
		pieces.append({ "loop": loop, "radius": shape.radius(), "shape": shape, "rest_loop": rest_loop })
	_replace_by_pieces(body, points, pieces)

# Replaces `body`, whose beads are at `points`, by one merge-locked body per
# entry of `pieces` ({ "loop": its bead-centre loop, "radius", "shape" (null
# for round), "rest_loop" }, see Goo2D.make_from_loop()), each bead
# moving like the nearest bead of `body`, and announces the split
# (count_changed, body_split, then split).
func _replace_by_pieces(body: Goo2D, points: PackedVector2Array, pieces: Array[Dictionary]) -> void:
	var position := body.center()
	var parent_id := body.id
	var made := _rebuild(body, points, pieces, true)
	count_changed.emit(bodies().size())
	body_split.emit(parent_id, made)
	split.emit(float(pieces[0]["radius"]), float(pieces[1]["radius"]), position)

# Replaces `body`, whose beads are at `points`, by one body of `kept` ({
# "radius", "shape", "rest_loop" } as for _replace_by_pieces(), holding the
# whole body's area) built on the side of the chord from bead `ends.x` to bead
# `ends.y` (Goo2D.sub_loop() order), clipped back from the chord as a piece of
# a split with beads of `bead_size` px would be, so the tip that asked for the
# cut is outside the new ring. Keeps the body's merge lock, if any, and
# announces the trim (count_changed, body_trimmed, then trimmed). Does nothing
# if the clip leaves nothing.
func _trim(body: Goo2D, points: PackedVector2Array, ends: Vector2i, kept: Dictionary, bead_size: float) -> void:
	var loop := Goo2D.cut_piece(points, ends.x, ends.y, bead_size + split_gap() / 2.0,
		body.bead_radius() + split_gap())
	if loop.is_empty():
		return
	var piece := kept.duplicate()
	piece["loop"] = loop
	var position := body.center()
	var old_id := body.id
	var lock_until := body.merge_lock_until if merge_locked(body) else -INF
	var made := _rebuild(body, points, [piece] as Array[Dictionary], false)[0]
	if lock_until > _physics_time():
		made.merge_lock_until = lock_until
		_merge_locked[made.id] = true
	count_changed.emit(bodies().size())
	body_trimmed.emit(old_id, made)
	trimmed.emit(made.radius, position)

# Replaces `body`, whose beads are at `points`, by one registered body per
# entry of `pieces` (see _replace_by_pieces()), each tagged with a copy of
# `body`'s tags and tuned by tuning_for() of its shape (round of its radius
# when it has none) and those tags, merge-locked if `lock_merging`, and
# returns them.
func _rebuild(body: Goo2D, points: PackedVector2Array, pieces: Array[Dictionary],
		lock_merging: bool) -> Array[Goo2D]:
	var velocities := body.bead_velocities()
	var position := body.center()
	var made: Array[Goo2D] = []
	for piece: Dictionary in pieces:
		var loop: PackedVector2Array = piece["loop"]
		var piece_shape: GooShape = piece["shape"]
		var piece_radius: float = piece["radius"]
		var ring_tuning := {}
		if piece_shape != null and not piece_shape.is_round():
			ring_tuning = tuning_for(piece_shape, body.tags)
		elif piece_radius > 0.0:
			ring_tuning = tuning_for(GooShape.round(piece_radius), body.tags)
		var built := Goo2D.make_from_loop(loop, _velocities_at(loop, points, velocities), self,
			piece_radius, piece_shape, piece["rest_loop"], ring_tuning, body.tags)
		# Its look before it is registered, so body_spawned's handlers see it.
		built.inherit_look(body, position)
		made.append(_register(built, lock_merging))
	_remove(body)
	return made

# For each of `targets`, the velocity in `velocities` of the nearest of `points`.
static func _velocities_at(targets: PackedVector2Array, points: PackedVector2Array,
		velocities: PackedVector2Array) -> PackedVector2Array:
	var result := PackedVector2Array()
	result.resize(targets.size())
	for i: int in targets.size():
		var best := INF
		for j: int in points.size():
			var distance := targets[i].distance_squared_to(points[j])
			if distance < best:
				best = distance
				result[i] = velocities[j]
	return result

# Forgets the merge locks that ran out and reports each such body's contacts
# with other bodies again (its last known ones, Goo2D._touching_rings()): an
# awake body reports them every frame anyway, but a settled one does not.
func _release_merge_locks() -> void:
	for id: int in _merge_locked.keys():
		var body: Goo2D = _by_id.get(id)
		if not _is_live(body):
			_merge_locked.erase(id)
			continue
		if merge_locked(body):
			continue
		_merge_locked.erase(id)
		for other: Goo2D in body._touching_rings():
			if body.report_contact(other):
				judge_contact(other, body)

# Marks `body` as merging and makes it frictionless for the transition.
func _begin_merge(body: Goo2D) -> void:
	body.merging = true
	body.set_frictionless(true)

# Pulls each merging pair together and tints it, and swaps finished pairs for
# the merged body. Runs outside the physics flush, so bodies may be added here.
func _advance_transitions(delta: float) -> void:
	var running: Array[MergeTransition] = []
	for transition: MergeTransition in _transitions:
		var a: Goo2D = _by_id.get(transition.id_a)
		var b: Goo2D = _by_id.get(transition.id_b)
		if not _is_live(a) or not _is_live(b):
			_cancel(a)
			_cancel(b)
			continue
		transition.tick(delta)
		var merged_radius := GooTuning.merged_radius(a.radius, b.radius)
		if transition.done():
			if transition.check_due() and _finish_merge(a, b, merged_radius):
				continue
			if transition.expired():
				_cancel(a, true)
				_cancel(b, true)
				continue
		var toward_b := a.center().direction_to(b.center())
		var pull := merge_pull() * transition.attraction() * delta
		a.apply_impulse(toward_b * pull * transition.particle_mass_a)
		b.apply_impulse(-toward_b * pull * transition.particle_mass_b)
		# A merge into one colour blends the pair toward it; into two, each
		# parent keeps its own colours (both survive; the flash marks the merge).
		var colours := _merge_colors(a, b)
		if colours.size() == 1:
			var tint := colours[0]
			if tint == Goo2D.COLOR_BY_SIZE:
				tint = GooTuning.color(merged_radius)
			_blend_toward(a, tint, transition.progress())
			_blend_toward(b, tint, transition.progress())
		running.append(transition)
	_transitions = running

# Tints `body` `progress` (0..1) of the way from its own colours to `tint`,
# both colours of a two-tone body.
static func _blend_toward(body: Goo2D, tint: Color, progress: float) -> void:
	if body.is_two_tone():
		body.set_tint(body.base_color().lerp(tint, progress), body.second_base_color().lerp(tint, progress))
	else:
		body.set_tint(body.base_color().lerp(tint, progress))

# Replaces `a` and `b` with one ring of `merged_radius` rebuilt around them,
# its beads moving like theirs; two shapes with one ring of their fused shape
# (of its own equivalent radius). Only once the pair is compact: their
# collision outlines make one outline (Goo2D.merged_union(): they touch), the
# loop the merged ring would be placed on is at most MERGE_FIT times as long
# around as its rest loop (merge_fit()) and, for two shapes, they still fuse
# into one. Returns true if it swapped them (and announced the merge:
# count_changed, bodies_merged with a's and b's ids in that order, then
# merged), false if the pair is not compact yet (the transition pulls on, see
# _advance_transitions()).
func _finish_merge(a: Goo2D, b: Goo2D, merged_radius: float) -> bool:
	if not _may_touch(a, b) or Goo2D.merged_union([a, b] as Array[Goo2D]).is_empty():
		return false
	var fused := PackedVector2Array()
	if both_shapes(a, b):
		fused = fused_outline(a, b)
		if fused.is_empty():
			return false
	var fit := merge_fit(a, b, fused)
	if fit <= 0.0 or fit > MERGE_FIT:
		return false
	# Built from the live pair, which leaves the physics space right after, before
	# any physics step could see the old and new bodies overlap.
	var body := _spawn_merged(merged_radius, [a, b] as Array[Goo2D], fused)
	_remove(a)
	_remove(b)
	count_changed.emit(bodies().size())
	bodies_merged.emit(PackedInt32Array([a.id, b.id]), body)
	merged.emit(body.radius, body.center())
	return true

# False if the collision outlines of `a` and `b`, grown by Goo2D.merge_grow(),
# cannot even overlap: their boxes do not. A cheap test before the outlines'
# union (they came apart: a pair thrown off each other, or one whose contact
# was stale).
static func _may_touch(a: Goo2D, b: Goo2D) -> bool:
	var reach_a := a.bead_radius() + Goo2D.merge_grow()
	var reach_b := b.bead_radius() + Goo2D.merge_grow()
	return a.bead_bounds().grow(reach_a).intersects(b.bead_bounds().grow(reach_b))

# Lets the survivor of a cancelled transition merge again, in its own colour
# and friction; with `lock`, only after MERGE_LOCK (a pair that never got
# compact is not pulled straight into another transition).
func _cancel(body: Goo2D, lock: bool = false) -> void:
	if _is_live(body):
		body.merging = false
		body.reset_tint()
		body.set_frictionless(false)
		if lock:
			_lock_merging(body)

# Keeps `body` from merging for MERGE_LOCK seconds (merge_locked()); its
# contacts are judged again when the lock runs out (_release_merge_locks()).
func _lock_merging(body: Goo2D) -> void:
	body.merge_lock_until = _physics_time_in(MERGE_LOCK)
	_merge_locked[body.id] = true

# Mass of one particle of `body`: the pull gives every particle the same
# acceleration, whatever the ring's size.
func _particle_mass(body: Goo2D) -> float:
	return body.body_mass() / maxi(body.particle_count(), 1)

# The ring keys (instance ids) of each merging pair, [a, b, a, b, ...], for the
# kernel's overlap push, which leaves a pair being pulled together alone (not
# third bodies).
func _partner_keys() -> PackedInt64Array:
	var keys := PackedInt64Array()
	for transition: MergeTransition in _transitions:
		var a: Goo2D = _by_id.get(transition.id_a)
		var b: Goo2D = _by_id.get(transition.id_b)
		if _is_live(a) and _is_live(b):
			keys.append(a.get_instance_id())
			keys.append(b.get_instance_id())
	return keys

func _is_live(body: Goo2D) -> bool:
	return body != null and is_instance_valid(body) and not body.is_queued_for_deletion() \
		and body.get_parent() == self

# Takes the body out of the physics space now, so the body replacing it never
# overlaps it, then frees it at the end of the frame, letting go of its grabs
# and releasing its links (bodies_unlinked for each).
# Emits nothing: the caller announces the new count once all its removals are
# done (count_changed).
func _remove(body: Goo2D) -> void:
	if not _links.is_empty():
		_release_links(body)
	_by_id.erase(body.id)
	if not _grabs.is_empty():
		for handle: int in _grabs.keys():
			if _grabs[handle].body == body:
				_grabs.erase(handle)
	remove_child(body)
	body.queue_free()

# ---- Grabbing ----
#
# A grab holds a body by a point: the beads within GooTuning.GRAB_REACH ×
# radius beyond the one nearest the point, each weighted from 1 (the nearest)
# down to 0, each kept at its offset from the point as it was when grabbed.
# Its grab point is where those beads carry the point (grab_point(): their
# weighted mean less their offsets). Each physics frame, before the step,
# each held bead's velocity is set by one implicit (backward Euler) step of a
# critically damped spring toward the point plus its offset, of
# GooTuning.GRAB_STIFFNESS × its weight and GRAB_DAMPING × √weight (critical
# at any weight), moving with the point (its motion since the last frame, so a
# dragged body does not trail it). The beads not held get GRAB_CARRY of the
# velocity change the same spring gives the held beads' grab point as a whole:
# the rest of the ring is carried a little with the hold, which keeps a fast
# drag from tearing the body, and otherwise follows through the ring's
# constraints, so the body hangs from the held beads under gravity.
# Velocities, not forces: stable at any stiffness, and the kernel's speed cap
# (GooTuning.MAX_BEAD_SPEED) applies to them. A body may still tear (a pinch
# splits it, which releases the grab) when shaken hard by its rim; one held
# at its centre is carried whole. GooTuning's GRAB_ constants have the
# measurements.

## Grabs `body`, one of this world's built bodies, at the global `point` (on
## it or near it: body_at() finds the body under a point) and returns the
## grab's handle, for move_grab() and release_grab(); -1, with an error, for
## a body that is not this world's. The body is woken and held there until the
## grab is released, by release_grab() or by the body leaving the world (a
## split, a merge, a trim, despawn() or clear()). Several grabs may hold at
## once, on several bodies or on one (each pulls its own beads).
func grab(body: Goo2D, point: Vector2) -> int:
	if not _is_live(body) or body.id < 0 or body.particle_count() == 0:
		push_error("GooWorld2D.grab(): %s is not one of this world's bodies" % body)
		return -1
	var held := Grab.new(body, point)
	if held.beads.is_empty():
		return -1
	var handle := _next_grab
	_next_grab += 1
	_grabs[handle] = held
	body.wake()
	return handle

## Moves grab `handle`'s point to the global `point`: its body is pulled
## there over the next frames. Does nothing for a grab that was released.
func move_grab(handle: int, point: Vector2) -> void:
	var held: Grab = _grabs.get(handle)
	if held != null:
		held.target = point

## Lets go of grab `handle`; with a `velocity` (px/s, not zero) it throws its
## body: every bead's velocity changes by the same amount, so the body's mean
## velocity (Goo2D.average_velocity()) becomes `velocity` and its wobble is
## kept (each bead capped at the kernel's speed cap). Without one the body goes
## on as it moves. Returns true if the grab was held, false for one already
## released (by this or by its body leaving the world).
func release_grab(handle: int, velocity: Vector2 = Vector2.ZERO) -> bool:
	var held: Grab = _grabs.get(handle)
	if held == null:
		return false
	_grabs.erase(handle)
	if velocity != Vector2.ZERO and _is_live(held.body):
		var body := held.body
		body.apply_impulse((velocity - body.average_velocity()) * body.body_mass() / body.particle_count())
	return true

## True while a grab holds `body`.
func grabbed(body: Goo2D) -> bool:
	for held: Grab in _grabs.values():
		if held.body == body:
			return true
	return false

## The body grab `handle` holds; null once it was released.
func grab_body(handle: int) -> Goo2D:
	var held: Grab = _grabs.get(handle)
	return held.body if held != null else null

## Where grab `handle`'s body is held now, global: the point it was grabbed at
## as its held beads carry it (their weighted mean less their offsets), which
## the spring pulls toward the grab's point (move_grab()). Vector2.INF once
## the grab was released.
func grab_point(handle: int) -> Vector2:
	var held: Grab = _grabs.get(handle)
	return held.held_point() if held != null else Vector2.INF

## The body whose collision outline holds the global `point`
## (Goo2D.has_point()), the one drawn on top (added last) where several do;
## null where none does. What a pointer grabs.
func body_at(point: Vector2) -> Goo2D:
	var all := bodies()
	for k: int in range(all.size() - 1, -1, -1):
		if all[k].id >= 0 and all[k].has_point(point):
			return all[k]
	return null

# `body` rebuilt its ring with another bead count (Goo2D.rebuilt; its beads
# were at `old_points`): each grab on it is made again at the point its held
# beads carried there, pulled toward the same point, under the same handle;
# then body_rebuilt.
func _on_body_rebuilt(old_points: PackedVector2Array, body: Goo2D) -> void:
	for handle: int in _grabs.keys():
		var held: Grab = _grabs[handle]
		if held.body != body:
			continue
		var fresh := Grab.new(body, held.held_point_on(old_points))
		if fresh.beads.is_empty():
			_grabs.erase(handle)
			continue
		fresh.target = held.target
		fresh.last_target = held.last_target
		_grabs[handle] = fresh
	body_rebuilt.emit(body)

# Pulls every held body toward its grab's point (see "Grabbing" above),
# keeping it awake; forgets grabs whose body is gone.
func _hold_grabs(delta: float) -> void:
	if _grabs.is_empty() or delta <= 0.0:
		return
	for handle: int in _grabs.keys():
		var held: Grab = _grabs[handle]
		if not _is_live(held.body):
			_grabs.erase(handle)
			continue
		held.pull(delta)

## One grab (GooWorld2D.grab()): the body, its held beads with their weights
## and their offsets from the grab point, and the point it is pulled toward.
class Grab extends RefCounted:
	## The body held.
	var body: Goo2D
	## The held beads' indices, their weights (0..1] and their offsets from the
	## grab point when grabbed.
	var beads: PackedInt32Array = PackedInt32Array()
	var weights: PackedFloat32Array = PackedFloat32Array()
	var offsets: PackedVector2Array = PackedVector2Array()
	## 1 for each of the body's beads that is held, 0 for the others (carried).
	var held: PackedByteArray = PackedByteArray()
	## The point the beads are pulled toward (global), and where it was on the
	## last frame pulled (its motion is the spring's rest velocity).
	var target: Vector2
	var last_target: Vector2
	## The body's size when grabbed (Goo2D.eased_radius()): a body resized
	## while held has its offsets scaled by its size now over this (scale()).
	var size: float = 0.0

	func _init(grabbed_body: Goo2D, point: Vector2) -> void:
		body = grabbed_body
		target = point
		last_target = point
		size = grabbed_body.eased_radius()
		var points := grabbed_body.bead_points()
		held.resize(points.size())
		var nearest := INF
		for bead: Vector2 in points:
			nearest = minf(nearest, bead.distance_to(point))
		var reach := maxf(GooTuning.GRAB_REACH * grabbed_body.radius, 0.000001)
		for i: int in points.size():
			var weight := 1.0 - (points[i].distance_to(point) - nearest) / reach
			if weight > 0.0:
				beads.append(i)
				weights.append(minf(weight, 1.0))
				offsets.append(points[i] - point)
				held[i] = 1

	## The grab point as the held beads carry it: their weighted mean less
	## their offsets.
	func held_point() -> Vector2:
		var sum := Vector2.ZERO
		var total := 0.0
		var factor := scale()
		for k: int in beads.size():
			sum += (body.bead_position(beads[k]) - offsets[k] * factor) * weights[k]
			total += weights[k]
		return sum / total if total > 0.0 else target

	## held_point() with the body's beads at `points` (its bead loop before it
	## was rebuilt with another count: GooWorld2D re-attaches the grab there).
	func held_point_on(points: PackedVector2Array) -> Vector2:
		var sum := Vector2.ZERO
		var total := 0.0
		var factor := scale()
		for k: int in beads.size():
			if beads[k] < points.size():
				sum += (points[beads[k]] - offsets[k] * factor) * weights[k]
				total += weights[k]
		return sum / total if total > 0.0 else target

	## One frame of the grab (see "Grabbing" above): each held bead's velocity
	## from its own spring toward `target` + its offset, and the other beads
	## GooTuning.GRAB_CARRY of the change the held ones' spring, taken as one,
	## gives their grab point.
	func pull(delta: float) -> void:
		body.wake()
		var target_velocity := (target - last_target) / delta
		last_target = target
		var points := body.bead_points()
		var velocities := body.bead_velocities()
		if points.size() != held.size():
			return
		var factor := scale()
		if GooTuning.GRAB_CARRY > 0.0:
			var point := Vector2.ZERO
			var velocity := Vector2.ZERO
			var total := 0.0
			for k: int in beads.size():
				point += (points[beads[k]] - offsets[k] * factor) * weights[k]
				velocity += velocities[beads[k]] * weights[k]
				total += weights[k]
			point /= total
			velocity /= total
			var carried := (spring(point, velocity, target, target_velocity, GooTuning.GRAB_STIFFNESS,
				GooTuning.GRAB_DAMPING, delta) - velocity) * GooTuning.GRAB_CARRY
			for i: int in points.size():
				if held[i] == 0:
					body.set_bead_velocity(i, velocities[i] + carried)
		for k: int in beads.size():
			var i := beads[k]
			body.set_bead_velocity(i, spring(points[i] - offsets[k] * factor, velocities[i], target, target_velocity,
				GooTuning.GRAB_STIFFNESS * weights[k], GooTuning.GRAB_DAMPING * sqrt(weights[k]), delta))

	## How much the held beads' offsets are scaled now: the body's size over its
	## size when grabbed (1 for a body never resized).
	func scale() -> float:
		return body.eased_radius() / size if size > 0.0 else 1.0

	## The velocity one backward Euler step of `delta` s of a damped spring of
	## `stiffness` (1/s²) and `damping` (1/s) gives a point at `position` moving
	## at `velocity`, pulled toward `goal` moving at `goal_velocity` (the spring
	## rests when the point moves with its goal). Stable at any stiffness.
	static func spring(position: Vector2, velocity: Vector2, goal: Vector2, goal_velocity: Vector2,
			stiffness: float, damping: float, delta: float) -> Vector2:
		var relative := (velocity - goal_velocity - delta * stiffness * (position - goal)) \
			/ (1.0 + delta * damping + delta * delta * stiffness)
		return goal_velocity + relative

# ---- Links ----
#
# A link ties a patch of beads on one body to a patch on another in the
# kernel (GooLink, the kernel's links.rs): compliant distance constraints
# pair by pair, and an angular term pulling the bodies' relative rotation
# toward the link's rest angle (set_link_rest_angle(): a joint a game bends).
# Its patches are named by anchors in each body's rest space; `strength`
# sets how wide they are. A new link eases into its rest pose over
# GooTuning.LINK_EASE_TIME, so bodies linked apart are drawn together. The
# kernel drops a link whose ring leaves it; the world sends it again at the
# next physics frame while both bodies are still its own (a ring rebuilt in
# place: the patch is found again from the anchors), and releases it when
# either leaves the world (_release_links(), from _remove()). Each link's
# bridge skin is drawn after every step (GooLink.draw_bridge()).

## Links `a` and `b`, two of this world's built bodies, and returns the link's
## handle (for unlink(), set_link_strength(), set_link_rest_angle()...); -1,
## with an error, for a body that is not this world's, the same body twice or
## a pair already linked (linked() gives that link). `strength` (0..1) sets
## how wide the neck is: from one pair of beads (a thread) to a patch about as
## wide as the smaller body's radius at 1 (GooTuning.LINK_PATCH_RATIO), and how
## stiffly the joint keeps its angle. `anchor_a` and `anchor_b` are the
## patches' middles in each body's REST space (Goo2D.rest_shape's frame;
## GooLink.rest_anchor() turns a global point into one); left at
## Vector2.INF, the points of the two bodies nearest each other now
## (GooLink.facing_anchors()). Bodies apart are drawn together over
## GooTuning.LINK_EASE_TIME; their rest pose is the two patches facing each
## other, the angle between the bodies' frames there being the link's rest
## angle 0. Linked bodies never merge with each other; a merge transition
## between them is cancelled. Emits bodies_linked.
func link(a: Goo2D, b: Goo2D, strength: float = 1.0, anchor_a: Vector2 = Vector2.INF,
		anchor_b: Vector2 = Vector2.INF) -> int:
	if not _is_live(a) or not _is_live(b) or a.id < 0 or b.id < 0 \
			or a.particle_count() == 0 or b.particle_count() == 0:
		push_error("GooWorld2D.link(): %s and %s must both be this world's bodies" % [a, b])
		return -1
	if a == b:
		push_error("GooWorld2D.link(): a body cannot be linked to itself")
		return -1
	if linked(a, b) >= 0:
		push_error("GooWorld2D.link(): %s and %s are linked already (link %d)" % [a, b, linked(a, b)])
		return -1
	var facing := GooLink.facing_anchors(a, b)
	var held := GooLink.new(_next_link, a, b, strength,
		facing[0] if not anchor_a.is_finite() else anchor_a,
		facing[1] if not anchor_b.is_finite() else anchor_b)
	if not held.attach(kernel()):
		push_error("GooWorld2D.link(): the kernel refused the link of %s and %s" % [a, b])
		return -1
	var handle := _next_link
	_next_link += 1
	_links[handle] = held
	var running: Array[MergeTransition] = []
	for transition: MergeTransition in _transitions:
		var pair := MergeQueue.key(transition.id_a, transition.id_b)
		if pair == MergeQueue.key(a.id, b.id):
			_cancel(a)
			_cancel(b)
		else:
			running.append(transition)
	_transitions = running
	a.wake()
	b.wake()
	bodies_linked.emit(handle, a, b)
	return handle

## Releases link `handle`: its bodies part (the kernel's constraints and their
## bridge gone at once). Returns true if it was held, false for one released
## already. Emits bodies_unlinked.
func unlink(handle: int) -> bool:
	var held: GooLink = _links.get(handle)
	if held == null:
		return false
	_links.erase(handle)
	kernel().remove_link(handle)
	held.free_bridge()
	if is_instance_valid(held.a):
		held.a.wake()
	if is_instance_valid(held.b):
		held.b.wake()
	bodies_unlinked.emit(handle, held.a.id if is_instance_valid(held.a) else -1,
		held.b.id if is_instance_valid(held.b) else -1)
	return true

## Sets link `handle`'s strength (0..1, see link()): its patch is found again
## at the new width and eased into from where the bodies are.
func set_link_strength(handle: int, strength: float) -> void:
	var held: GooLink = _links.get(handle)
	if held == null:
		return
	held.strength = clampf(strength, 0.0, 1.0)
	held.attach(kernel())

## Link `handle`'s strength; -1 for a link released.
func link_strength(handle: int) -> float:
	var held: GooLink = _links.get(handle)
	return held.strength if held != null else -1.0

## Sets link `handle`'s rest angle, radians: the turn of its second body
## relative to its first in the rest pose, about the neck (0: the patches
## facing each other, as linked; positive turns the second body as
## Node2D.rotation does, clockwise on screen). The kernel's targets move at
## once and the bodies follow over a few frames; smooth when set every frame
## (a joint swept by a game).
func set_link_rest_angle(handle: int, radians: float) -> void:
	var held: GooLink = _links.get(handle)
	if held == null:
		return
	held.rest_angle = radians
	kernel().set_link_param(handle, &"rest_angle", radians)

## Link `handle`'s rest angle, radians; 0 for a link released.
func link_rest_angle(handle: int) -> float:
	var held: GooLink = _links.get(handle)
	return held.rest_angle if held != null else 0.0

## How far link `handle`'s joint is bent now, radians, in the terms of its
## rest angle (the second body's turn relative to the first, less the rest
## pose's); 0 for a link released.
func link_bend(handle: int) -> float:
	if not _links.has(handle):
		return 0.0
	return float(kernel().link_info(handle).get("bend", 0.0))

## The handles of the links `body` is in, in the order they were made.
func links_of(body: Goo2D) -> PackedInt32Array:
	var handles := PackedInt32Array()
	for handle: int in _links:
		var held := _links[handle]
		if held.a == body or held.b == body:
			handles.append(handle)
	return handles

## The handle of the link between `a` and `b` (either way round); -1 if none.
func linked(a: Goo2D, b: Goo2D) -> int:
	for handle: int in _links:
		var held := _links[handle]
		if (held.a == a and held.b == b) or (held.a == b and held.b == a):
			return handle
	return -1

## The two bodies of link `handle`, [a, b] as link() was given them; empty
## for a link released.
func link_bodies(handle: int) -> Array[Goo2D]:
	var held: GooLink = _links.get(handle)
	var result: Array[Goo2D] = []
	if held != null:
		result.append(held.a)
		result.append(held.b)
	return result

## The handles of every link, in the order they were made.
func links() -> PackedInt32Array:
	return PackedInt32Array(_links.keys())

## The GooLink of `handle` (its anchors, patch and bridge), null for a link
## released: for reading; change it through the functions above.
func link_info(handle: int) -> GooLink:
	return _links.get(handle)

# Releases every link of `body`, which is leaving the world (_remove()).
func _release_links(body: Goo2D) -> void:
	for handle: int in links_of(body):
		unlink(handle)

# Sends the kernel again any link it dropped (a ring rebuilt in place leaves
# the kernel and comes back without its links), while both bodies are live.
func _attach_links() -> void:
	var goo := kernel()
	for handle: int in _links.keys():
		var held: GooLink = _links[handle]
		if goo.has_link(handle):
			continue
		if not _is_live(held.a) or not _is_live(held.b):
			unlink(handle)
			continue
		if held.a.particle_count() > 0 and held.b.particle_count() > 0:
			held.attach(goo)

# Draws every link's bridge skin (GooLink.draw_bridge()), in an internal node
# in front of the world's children, so every body is drawn over it.
func _draw_bridges(delta: float) -> void:
	if _bridges == null:
		_bridges = Node2D.new()
		_bridges.name = "LinkBridges"
		add_child(_bridges, false, Node.INTERNAL_MODE_FRONT)
	var goo := kernel()
	for held: GooLink in _links.values():
		held.draw_bridge(_bridges, goo, delta)

# ---- Merge rules ----
#
# Which bodies combine, and into what. The world asks may_merge(), which a
# subclass may override; by default (can_merge()) round bodies merge by size
# (GooTuning.can_merge()), shapes (GooShape.has_flat_surface()) stick when they
# touch flat face to flat face, whatever their sizes (flat_contact()), and a
# shape and a round body never merge. Two shapes fuse into the union of their
# outlines (fused_outline(), GooShape.fused()), any other pair into a round
# body. The merged body is drawn in merged_color().

## How far from opposite, in radians, the outward normals of two touching
## beads' rest edges may be for the contact to count as flat face to flat face
## (35°). A square resting on another at a slant of a few degrees still sticks;
## faces meeting at 45° (a square on its corner, the neighbours of the corner
## bead) or more do not.
const FLAT_CONTACT_ANGLE: float = PI * 35.0 / 180.0
## How much further apart than the closest bead pair, in bead radii (the
## larger ring's), other bead pairs may be and still count as the contact.
## Two squares pressed face to face touch along a whole face, the corner beads
## at its ends as close as any: judging only the single closest pair would let
## a tie decide. A corner pressed into a face leaves its neighbours, a bead
## spacing (1.7 bead radii) along its sides, at least 1.2 bead radii further
## off (at 45°), outside this slack.
const CONTACT_SLACK_BEADS: float = 0.5
## Contact range of a fusion, in bead radii of the larger of the two rings:
## GooShape.fused() fills the creases of the junction up to this far. Two
## bead radii is one bead diameter: a crease narrower than that is a waist the
## beads cannot form, so the rest shape must not ask for one.
const CONTACT_RANGE_BEADS: float = 2.0

## Which touching pairs combine. Override in a subclass to change the rule; the
## default is the static can_merge() (round bodies by size, shapes flat face to
## flat face, never a shape with a round body). Called for every contact the
## kernel reports (once per pair per physics frame at most), so keep it cheap:
## the size test first, geometry after. The merged body is round unless both are
## shapes (then it is their fused outline), whatever this returns. Not asked
## while either body is merge-locked or the pair already queued; asked again
## for a queued pair before its transition starts.
func may_merge(a: Goo2D, b: Goo2D) -> bool:
	return can_merge(a, b)

## Which bodies the goo may cut. Override in a subclass to keep some bodies
## whole (a body of stone); the default, true, lets every body split. Asked in
## the cut request of every cut the goo asks for: a pinch or a crush (through
## Goo2D.pinched, dispatched from the world's _physics_process()), a blade
## (cut_along(), cut_at_tips()) and a tip (pierce()), called from a subclass's
## _physics_process() or wherever the game calls them: outside the physics
## flush, before anything is queued. A body it refuses is neither cut nor
## trimmed, is not woken, and counts in none of their returns. Asked again
## every frame the neck or the tip persists, so keep it cheap. Not asked for a
## body that is merging or already waiting for a cut, nor by a direct cut(),
## which is an order.
func may_split(_body: Goo2D) -> bool:
	return true

## The colour the body merged from `a` and `b` is drawn in (its Goo2D.color),
## and the one the pair is tinted toward while it merges. Override in a
## subclass; the default, Goo2D.COLOR_BY_SIZE, colours it by its size
## (GooTuning.color() of the merged radius), whatever the pair's colours.
## Asked every physics frame of a merge transition, so keep it cheap. Not
## asked while two_tone_merges is on (merged_colors() is).
func merged_color(_a: Goo2D, _b: Goo2D) -> Color:
	return Goo2D.COLOR_BY_SIZE

## The colours of the body `a` and `b` merge into, when two_tone_merges is on:
## one colour (a body of one colour; Goo2D.COLOR_BY_SIZE: by its own size), or
## two, the first on a's side of the division and the second on b's (a
## two-tone body; never more than two). `a` is the pair's first as the merge
## got them. Override in a subclass for rules of its own; the default:
## - two bodies of one colour each, both Goo2D.COLOR_BY_SIZE: by size, as
##   merged_color()'s default;
## - the same colour combination (Goo2D.color_set() equal: the same colour, or
##   the same two): that combination, a's dominant colour (dominant_color()) on
##   a's side when there are two;
## - any other pair: each one's dominant colour on its own side, [a's, b's],
##   or one colour when those are equal (never a two-tone body of one colour
##   twice): two two-tone bodies of different combinations lose their two
##   smaller shares.
## Asked every physics frame of a merge transition (one colour: the pair is
## blended toward it; two: each keeps its own) and once at the swap, so keep it
## cheap.
func merged_colors(a: Goo2D, b: Goo2D) -> PackedColorArray:
	if not a.is_two_tone() and not b.is_two_tone() \
			and a.color == Goo2D.COLOR_BY_SIZE and b.color == Goo2D.COLOR_BY_SIZE:
		return PackedColorArray([Goo2D.COLOR_BY_SIZE])
	var set_a := a.color_set()
	if set_a == b.color_set():
		if set_a.size() == 1:
			return set_a
		var first := a.dominant_color()
		return PackedColorArray([first, set_a[1] if set_a[0] == first else set_a[0]])
	var dominant_a := a.dominant_color()
	var dominant_b := b.dominant_color()
	if dominant_a == dominant_b:
		return PackedColorArray([dominant_a])
	return PackedColorArray([dominant_a, dominant_b])

## The tags (Goo2D.tags) of the body merged from `a` and `b`, `a` the pair's
## first as the merge got them. Override in a subclass to merge kinds into new
## ones (call super() for the default otherwise); the default is their union
## in order without duplicates: `a`'s tags, then each of `b`'s not already
## there, as a new array. Asked once per merge, at the swap for the merged
## body (outside the physics flush, the pair still in the tree), before the
## merged ring is tuned: tuning_for() sees what it returns.
func merged_tags(a: Goo2D, b: Goo2D) -> Array:
	var tags := a.tags.duplicate()
	for tag: Variant in b.tags:
		if not tags.has(tag):
			tags.append(tag)
	return tags

## How this world's bodies are tuned: the dictionary a ring of `shape` (the
## body's rest shape at its own size, round or polygon) with `tags` (the body's
## Goo2D.tags: what spawn() was given, a split piece's or trimmed body's
## parent's, merged_tags() of a merged pair; [] for a body placed in a scene
## unless they were set before it entered the tree) is built from, with
## GooTuning.tuning_for()'s keys. The first tag is the one a world reads for
## now (Goo2D.tag()); the default ignores the tags, so a world that does not
## read them is unchanged. Override in a subclass to change how this
## world's bodies are tuned (stiffness, damping, pressure, shape matching,
## masses) without changing GooTuning's numbers for every world: call super()
## and change values. The keys that shape the ring (`bead_count`,
## `bead_radius`, `spacing`, `target_area`) must stay what GooTuning gives,
## since GooShape.cut_ring() and the merge placement (merge_fit(),
## fused_outline()) count beads from them. Every body the world builds goes
## through it: spawn(), the merged body, split pieces and trims, and a Goo2D
## placed in a scene under the world (it asks in its _ready()). Asked once per
## body built, never per frame.
func tuning_for(shape: GooShape, _tags: Array = []) -> Dictionary:
	return GooTuning.tuning_for(shape)

## True if the touching bodies `a` and `b` combine, from their current state,
## by the default rule (what may_merge() asks unless a subclass overrides it):
## - two round bodies: by size, GooTuning.can_merge();
## - two shapes: when they touch flat face to flat face, whatever their sizes
##   (flat_contact() of their beads, corner flags and fitted rest normals);
## - a shape and a round body: never. A subclass that wants them to overrides
##   may_merge(): the world asks nothing else (both_shapes() then says how the
##   merged body is built).
static func can_merge(a: Goo2D, b: Goo2D) -> bool:
	var shape_a := _is_shape(a)
	var shape_b := _is_shape(b)
	if not shape_a and not shape_b:
		return GooTuning.can_merge(a.radius, b.radius)
	if shape_a != shape_b:
		return false
	if a.particle_count() == 0 or b.particle_count() == 0:
		return false
	var points_a := a._frame_points()
	var points_b := b._frame_points()
	return flat_contact(points_a, a.corner_flags(), fitted_normals(a.rest_shape, points_a),
		points_b, b.corner_flags(), fitted_normals(b.rest_shape, points_b),
		CONTACT_SLACK_BEADS * maxf(a.bead_radius(), b.bead_radius()))

## True if `a` and `b` are both shapes, merged into a shape by
## GooShape.fused(); false for a round pair, merged into a round body.
static func both_shapes(a: Goo2D, b: Goo2D) -> bool:
	return _is_shape(a) and _is_shape(b)

## True if two touching rings meet flat face to flat face. Each ring is given
## by its bead centres (`points_*`), one corner flag per bead (non-zero where
## the rest shape turns by more than Goo2D.CORNER_ANGLE, see
## Goo2D.corner_flags()) and one unit outward normal per bead of its
## rest edges in the fitted pose (fitted_normals()). The contact is the closest
## bead pair across the two rings and every pair at most `slack` px further
## apart (see CONTACT_SLACK_BEADS); it is flat if one of those pairs has no
## corner bead and normals within FLAT_CONTACT_ANGLE of opposite.
static func flat_contact(points_a: PackedVector2Array, corners_a: PackedByteArray,
		normals_a: PackedVector2Array, points_b: PackedVector2Array, corners_b: PackedByteArray,
		normals_b: PackedVector2Array, slack: float = 0.0) -> bool:
	if points_a.is_empty() or points_b.is_empty():
		return false
	var closest := INF
	for p: Vector2 in points_a:
		for q: Vector2 in points_b:
			closest = minf(closest, p.distance_squared_to(q))
	var reach := sqrt(closest) + slack
	var facing := cos(FLAT_CONTACT_ANGLE)
	for i: int in points_a.size():
		if _flag(corners_a, i) or i >= normals_a.size():
			continue
		for j: int in points_b.size():
			if _flag(corners_b, j) or j >= normals_b.size():
				continue
			if points_a[i].distance_to(points_b[j]) > reach:
				continue
			if -normals_a[i].dot(normals_b[j]) >= facing:
				return true
	return false

## One unit outward normal per point of the rest loop `rest` (CCW, see
## GooLoop): the mean of its two rest edges' normals, turned by the
## rotation that best fits `rest` onto the bead centres `points`
## (GooLoop.best_fit_rotation()). For a bead on a straight side it is that
## side's normal, wherever the ring has been squashed.
static func fitted_normals(rest: PackedVector2Array, points: PackedVector2Array) -> PackedVector2Array:
	var angle := GooLoop.best_fit_rotation(rest, points)
	var edges := GooLoop.edge_normals(rest)
	var count := rest.size()
	var normals := PackedVector2Array()
	normals.resize(count)
	for i: int in count:
		var normal := edges[(i + count - 1) % count].normalized() + edges[i].normalized()
		normals[i] = normal.normalized().rotated(angle)
	return normals

## Contact range, px, of a fusion of rings with beads of `bead_a` and `bead_b`
## px into a ring with beads of `merged_bead` px: CONTACT_RANGE_BEADS × the
## larger of the two, never under one bead diameter of the merged ring.
static func contact_range(bead_a: float, bead_b: float, merged_bead: float) -> float:
	return maxf(CONTACT_RANGE_BEADS * maxf(bead_a, bead_b), 2.0 * merged_bead)

## The outline the shapes `a` and `b` (both POLYGON, still in the tree) fuse
## into, for Goo2D.make_merged(): their outlines fitted onto their beads
## (GooShape.fitted_outline()) fused by GooShape.fused() within
## contact_range() of the two rings' bead radii, global. If the
## fused shape's own beads are larger than that range allows for, it is fused
## again within one bead diameter of them. Empty if the outlines do not make
## one polygon (the pair came apart) or the fused shape is too thin for its
## beads: the pair then does not merge. The result is scaled about its
## centroid to hold the two shapes' areas (GooShape.scaled_to_area()), as a
## round merge keeps its pair's area.
static func fused_outline(a: Goo2D, b: Goo2D) -> PackedVector2Array:
	var none := PackedVector2Array()
	if a.shape == null or b.shape == null or a.particle_count() == 0 or b.particle_count() == 0:
		return none
	var outline_a := a.shape.fitted_outline(a.rest_shape, a.bead_points(), a.bead_radius())
	var outline_b := b.shape.fitted_outline(b.rest_shape, b.bead_points(), b.bead_radius())
	var reach := contact_range(a.bead_radius(), b.bead_radius(), 0.0)
	var fused := GooShape.fused(outline_a, outline_b, reach)
	if fused.is_empty():
		return none
	var ring_tuning := GooTuning.tuning_for(GooShape.polygon(fused))
	var wider := contact_range(a.bead_radius(), b.bead_radius(), ring_tuning["bead_radius"])
	if wider > reach:
		fused = GooShape.fused(outline_a, outline_b, wider)
		if fused.is_empty():
			return none
	fused = GooShape.scaled_to_area(fused, a.shape.area() + b.shape.area())
	var shape := GooShape.polygon(fused)
	if Goo2D.rest_loop_at(shape, GooTuning.tuning_for(shape), Vector2.ZERO).is_empty():
		return none
	return fused

## How well the loop a merge of `a` and `b` would place its ring on
## (Goo2D.merge_placement(), from where their beads are now) fits the merged
## ring's rest loop: the ratio of their perimeters, 1 for the same length. A
## round pair's rest loop is the circle of the merged radius, two shapes' the
## bead loop of their `fused` outline (fused_outline(); 0 if it is too thin for
## its beads). Round pairs, creases filled (Goo2D.MERGE_CLOSE_BEADS): 1.0 with
## centres 70% of the sum of their radii apart, 1.07-1.09 at 80%, 1.16-1.18
## at 95%, 1.20-1.22 just touching; without the filling a peanut gave 1.5. A
## pair that does not touch gives well under 1 (the loop is the lowest ring's
## alone): GooWorld2D does not swap it (merged_union()).
static func merge_fit(a: Goo2D, b: Goo2D, fused: PackedVector2Array = PackedVector2Array()) -> float:
	var pair: Array[Goo2D] = [a, b]
	var rest := PackedVector2Array()
	var placed := PackedVector2Array()
	if fused.is_empty():
		var ring_tuning := GooTuning.tuning(GooTuning.merged_radius(a.radius, b.radius))
		var count: int = ring_tuning["bead_count"]
		rest = GooLoop.circle_points(Vector2.ZERO, ring_tuning["ring_radius"], count)
		placed = Goo2D.merge_placement(pair, ring_tuning["bead_radius"], count)
	else:
		var shape := GooShape.polygon(fused)
		var shape_tuning := GooTuning.tuning_for(shape)
		rest = Goo2D.rest_loop_at(shape, shape_tuning, GooShape.area_centroid(fused))
		if rest.is_empty():
			return 0.0
		placed = Goo2D.merge_placement(pair, shape_tuning["bead_radius"], rest.size(), rest)
	var rest_perimeter := GooLoop.perimeter(rest)
	return GooLoop.perimeter(placed) / rest_perimeter if rest_perimeter > 0.0 else 0.0

static func _is_shape(body: Goo2D) -> bool:
	return body.shape != null and body.shape.has_flat_surface()

static func _flag(flags: PackedByteArray, i: int) -> bool:
	return i < flags.size() and flags[i] != 0

# ---- Overlap push ----
#
# Pushes back the beads of a body that got into another one: through a skin
# stretched open under an impact or a pile's load, or squeezed in by a merge.
# Overlap is judged from the bead loops themselves, not from the nominal radii,
# so it holds for any shape, sees a single bead that slipped through an edge,
# and never mistakes rings flattened against each other for sunk in (their
# centres sit 25-35% of their radii inside each other at rest, with no bead
# anywhere near the other's loop).
#
# A bead counts as intruding when its centre is inside the other ring's bead
# loop or within INTRUSION_MARGIN_BEADS of that ring's bead radius outside it.
# It is pushed along the outward normal of the other loop's nearest edge, and
# the two beads of that edge take the reaction, split by where along the edge
# the bead is: equal and opposite, like a contact between the bead and the
# edge, and sized like one (intrusion()): a stiff spring on its depth past the
# margin, critically damped while the bead still sinks in. Rings that only
# touch, however squashed, keep their beads further out than the margin and
# feel nothing.
#
# The pass runs every physics frame in the world's kernel, before its solver
# (a port of intrusion() and the Untangler's push below, which stay here as the
# reference test_goo_kernel.gd checks it against): for each pair of bodies whose
# boxes, grown by their margins, overlap, the push above, as forces over the
# frame's substeps; a bead whose centre is inside the other ring's bead loop
# passes through that ring's beads until it is back out by more than the margin
# (an exclusion in the kernel's contacts): its contacts there would hold it in,
# or pull it further in,
# while the rest of both rings keep colliding and carrying whatever presses them
# together. A pair of settled bodies is left asleep unless a bead of one is
# inside the other's loop; then both are woken. A pair deep inside each other
# (Intrusion.deep(): a centre inside the other ring, as when one is spawned on
# or engulfed by the other) is handed to the Untangler, which lets the pair pass
# through each other and pushes them apart. The two bodies of a merge
# transition are exempt from each other (the pull drives them together), not
# from third bodies.

## How far outside another ring's bead loop a bead centre starts being pushed
## back, in that ring's bead radii. Touching beads keep their centres at least
## one sum of bead radii apart, which leaves a bead resting in the notch between
## two beads of a ring 1.8 bead radii outside its loop when the beads are of one
## size, and 0.95 of the ring's bead radius outside it in the worst case (a
## launch-size bead in the notch of the largest ring's beads), so 0.5 never
## pushes on rings at rest.
const INTRUSION_MARGIN_BEADS: float = 0.5
## Stiffness of the push, as the natural frequency (rad/s) of a bead held out
## of the other ring by it: the force is INTRUSION_FREQUENCY² × the reduced
## mass of the bead and the other ring's beads × the depth past the margin
## (px), plus 2 × INTRUSION_FREQUENCY × that mass × the speed at which the bead
## still sinks in (critical damping, only while it does). At 60 physics steps a
## second, 60 rad/s takes back a bead's whole depth in about one step, as a
## contact does, and the damping stops a bead pressed in by a pile's load from
## sinking further. Measured on bench.gd's pile40 and mixed40 over three seeds,
## with Untangler.STRENGTH 200 (pair-samples inside each other per run): an
## undamped 60 rad/s left 33-38 and 43-63, damped 60 rad/s 24-28 and 40-45,
## damped 80 rad/s 22-32 and 32-37 (but it overshoots a step's worth); a
## velocity-level push sized by the bead's own mass, taking back 0.3 of the
## depth per step, 40-51 and 62-266 (the ring's springs soak it up).
const INTRUSION_FREQUENCY: float = 60.0

## A ring as the overlap push sees it: its bead centres and velocities, bead
## radius and the mass of one bead, its loop grown by the margin (made on first
## use) and the box around that.
class OverlapRing extends RefCounted:
	## Bead centres, CCW (see GooLoop).
	var points: PackedVector2Array
	## One velocity per bead, px/s; empty for beads at rest.
	var velocities: PackedVector2Array
	## Collision radius of each bead, px.
	var bead_radius: float = 0.0
	## Mass of each bead.
	var bead_mass: float = 0.0
	## INTRUSION_MARGIN_BEADS × bead_radius, px.
	var margin: float = 0.0
	## The bounding box of `points` grown by `margin`.
	var bounds: Rect2

	var _grown := PackedVector2Array()
	var _normals := PackedVector2Array()

	func _init(bead_points: PackedVector2Array, radius: float, mass: float,
			bead_velocities: PackedVector2Array = PackedVector2Array(), box: Variant = null) -> void:
		points = bead_points
		velocities = bead_velocities
		bead_radius = radius
		bead_mass = mass
		margin = INTRUSION_MARGIN_BEADS * radius
		if points.is_empty():
			return
		if box is Rect2:
			bounds = (box as Rect2).grow(margin)
			return
		var low := points[0]
		var high := points[0]
		for point: Vector2 in points:
			low = low.min(point)
			high = high.max(point)
		bounds = Rect2(low, high - low).grow(margin)

	## Velocity of bead `i` (zero without velocities).
	func velocity(i: int) -> Vector2:
		return velocities[i] if i < velocities.size() else Vector2.ZERO

	## One unit outward normal per edge i → i+1 (outward for a CCW loop, flipped
	## for a loop turned inside out, so they still point away from its inside).
	func normals() -> PackedVector2Array:
		if _normals.is_empty() and points.size() >= 3:
			_normals = GooLoop.edge_normals(points)
			var outward := 1.0 if GooLoop.is_ccw(points) else -1.0
			for i: int in _normals.size():
				_normals[i] = _normals[i].normalized() * outward
		return _normals

	## The bead loop with each point moved `margin` along its outward vertex
	## normal: a bead centre inside it is inside the loop or about `margin` from it.
	func grown() -> PackedVector2Array:
		if _grown.is_empty() and points.size() >= 3:
			var edge_normals := normals()
			var count := points.size()
			_grown.resize(count)
			for i: int in count:
				var normal := (edge_normals[(i + count - 1) % count] + edge_normals[i]).normalized()
				_grown[i] = points[i] + normal * margin
		return _grown

## What intrusion() found between two rings `a` and `b`.
class Intrusion extends RefCounted:
	## One force per bead of `a` (empty while nothing is pressed).
	var forces_a := PackedVector2Array()
	## One force per bead of `b` (empty while nothing is pressed).
	var forces_b := PackedVector2Array()
	## Beads of `a` whose centres are inside `b`'s bead loop.
	var inside_a: int = 0
	## Beads of `b` whose centres are inside `a`'s bead loop.
	var inside_b: int = 0
	## Number of beads of `a` and of `b`.
	var count_a: int = 0
	var count_b: int = 0
	## True if any bead of either ring is inside the other's loop or within its
	## margin of it (whether or not it needed a push this step).
	var pressed: bool = false
	## Indices of the beads of `a` (of `b`) inside the other ring's bead loop.
	var beads_in_a := PackedInt32Array()
	var beads_in_b := PackedInt32Array()
	## Indices of the beads of `a` (of `b`) inside the other ring's bead loop or
	## within its margin of it.
	var reach_a := PackedInt32Array()
	var reach_b := PackedInt32Array()

	## True if the centre (bead centroid) of `a` is inside `b`'s bead loop.
	var centre_in_a: bool = false
	## True if the centre of `b` is inside `a`'s bead loop.
	var centre_in_b: bool = false

	## True if the rings are deep inside each other: the centre of one inside
	## the other's loop, or every bead of one inside it (one ring swallowed by
	## the other). Pushing each bead out through the nearest edge cannot part
	## them then (the nearest edges face every way, so the push would only swell
	## the inner ring), so GooWorld2D hands such a pair to the Untangler.
	func deep() -> bool:
		return centre_in_a or centre_in_b or (count_a > 0 and inside_a == count_a) \
			or (count_b > 0 and inside_b == count_b)

## The push between the rings `a` and `b`. For each bead of either ring inside
## the other's bead loop or within its margin (OverlapRing.margin), with depth
## the distance inside the loop plus the margin and n the outward unit normal
## of the other loop's nearest edge: a force along n of push_stiffness() ×
## depth, plus push_damping() × the speed at which the bead sinks into that
## edge (the point of it nearest the bead, moving like its two beads in
## proportion) while it does; and the opposite force on that edge's two beads,
## split by where the point lies. Sums to zero over both rings.
static func intrusion(a: OverlapRing, b: OverlapRing) -> Intrusion:
	var result := Intrusion.new()
	result.count_a = a.points.size()
	result.count_b = b.points.size()
	if result.count_a < 3 or result.count_b < 3 or not a.bounds.intersects(b.bounds):
		return result
	result.inside_a = _intrude(a, b, result, true)
	result.inside_b = _intrude(b, a, result, false)
	if result.inside_a > 0:
		result.centre_in_a = Geometry2D.is_point_in_polygon(GooLoop.centroid(a.points), b.points)
	if result.inside_b > 0:
		result.centre_in_b = Geometry2D.is_point_in_polygon(GooLoop.centroid(b.points), a.points)
	return result

## Force per px of depth between beads of mass `mass_a` and `mass_b`:
## INTRUSION_FREQUENCY² × their reduced mass.
static func push_stiffness(mass_a: float, mass_b: float) -> float:
	return INTRUSION_FREQUENCY * INTRUSION_FREQUENCY * _reduced(mass_a, mass_b)

## Force per px/s of sinking speed between beads of mass `mass_a` and
## `mass_b`: 2 × INTRUSION_FREQUENCY × their reduced mass (critical damping).
static func push_damping(mass_a: float, mass_b: float) -> float:
	return 2.0 * INTRUSION_FREQUENCY * _reduced(mass_a, mass_b)

static func _reduced(mass_a: float, mass_b: float) -> float:
	var total := mass_a + mass_b
	return 0.0 if total <= 0.0 else mass_a * mass_b / total

# Pushes the beads of `ring` that got into `other` out of it, adding to
# `result`'s forces and bead lists (`ring` as `a` if `ring_is_a`); returns how
# many of them are inside `other`'s bead loop.
static func _intrude(ring: OverlapRing, other: OverlapRing, result: Intrusion, ring_is_a: bool) -> int:
	var stiffness := push_stiffness(ring.bead_mass, other.bead_mass)
	var damping := push_damping(ring.bead_mass, other.bead_mass)
	var box := other.bounds
	var loop := other.points
	var count := loop.size()
	var forces_ring := result.forces_a if ring_is_a else result.forces_b
	var forces_other := result.forces_b if ring_is_a else result.forces_a
	var beads_in := PackedInt32Array()
	var reach := PackedInt32Array()
	for i: int in ring.points.size():
		var point := ring.points[i]
		if not box.has_point(point) or not Geometry2D.is_point_in_polygon(point, other.grown()):
			continue
		var in_loop := Geometry2D.is_point_in_polygon(point, loop)
		var nearest := -1
		var best := INF
		var closest := Vector2.ZERO
		for j: int in count:
			var on_edge := Geometry2D.get_closest_point_to_segment(point, loop[j], loop[(j + 1) % count])
			var distance := point.distance_squared_to(on_edge)
			if distance < best:
				best = distance
				nearest = j
				closest = on_edge
		var depth := other.margin + (sqrt(best) if in_loop else -sqrt(best))
		if depth <= 0.0 and not in_loop:
			continue
		if forces_ring.is_empty():
			forces_ring.resize(ring.points.size())
			forces_other.resize(count)
		if in_loop:
			beads_in.append(i)
		reach.append(i)
		var next := (nearest + 1) % count
		var length := loop[nearest].distance_to(loop[next])
		var along := clampf(loop[nearest].distance_to(closest) / length, 0.0, 1.0) if length > 0.0 else 0.5
		var normal := other.normals()[nearest]
		var edge_velocity := other.velocity(nearest).lerp(other.velocity(next), along)
		var sinking := (edge_velocity - ring.velocity(i)).dot(normal)
		var push := stiffness * maxf(depth, 0.0) + damping * maxf(sinking, 0.0)
		if push <= 0.0:
			continue
		var force := normal * push
		forces_ring[i] += force
		forces_other[nearest] -= force * (1.0 - along)
		forces_other[next] -= force * along
	if reach.is_empty():
		return 0
	result.pressed = true
	if ring_is_a:
		result.forces_a = forces_ring
		result.forces_b = forces_other
		result.beads_in_a = beads_in
		result.reach_a = reach
	else:
		result.forces_b = forces_ring
		result.forces_a = forces_other
		result.beads_in_b = beads_in
		result.reach_b = reach
	return beads_in.size()

# ---- MergeQueue ----

class MergeQueue extends RefCounted:
	## Collects contact pairs reported during a physics frame so they can be
	## resolved once. A pair is stored once, however many times it is
	## reported, in the order it was first reported. Each id ends up in at most
	## one drained pair, so a body touching two equal neighbours merges with
	## only the first one reported.
	## Pairs are Vector2i, whose components are 32-bit: use small ids such as a
	## per-world counter, not Object instance ids (those are 64-bit and get truncated).

	var _pairs: Array[Vector2i] = []
	var _queued: Dictionary[Vector2i, bool] = {}

	## Records a contact between two ids. Self-contacts are ignored, and so is
	## a pair already waiting.
	func request(id_a: int, id_b: int) -> void:
		if id_a == id_b:
			return
		var pair := key(id_a, id_b)
		if _queued.has(pair):
			return
		_queued[pair] = true
		_pairs.append(pair)

	## True if no pairs are waiting.
	func is_empty() -> bool:
		return _pairs.is_empty()

	## True if the pair of `id_a` and `id_b` (either order) is waiting.
	func has(id_a: int, id_b: int) -> bool:
		return _queued.has(key(id_a, id_b))

	## The pair of `id_a` and `id_b`, either order, as stored: smaller id first.
	static func key(id_a: int, id_b: int) -> Vector2i:
		return Vector2i(mini(id_a, id_b), maxi(id_a, id_b))

	## Number of distinct pairs waiting.
	func size() -> int:
		return _pairs.size()

	## Returns the pending pairs (smaller id first, first-requested order, every id
	## in at most one pair) and clears the queue.
	func drain() -> Array[Vector2i]:
		var result: Array[Vector2i] = []
		var used: Dictionary[int, bool] = {}
		var pairs := _pairs
		clear()
		for pair: Vector2i in pairs:
			if used.has(pair.x) or used.has(pair.y):
				continue
			used[pair.x] = true
			used[pair.y] = true
			result.append(pair)
		return result

	## Discards every pending pair that holds `id` (a body that is going), so it
	## keeps no partner of it out of another pair at drain().
	func forget(id: int) -> void:
		var kept: Array[Vector2i] = []
		for pair: Vector2i in _pairs:
			if pair.x == id or pair.y == id:
				_queued.erase(pair)
			else:
				kept.append(pair)
		_pairs = kept

	## Discards all pending pairs.
	func clear() -> void:
		_pairs = []
		_queued = {}

# ---- MergeTransition ----

class MergeTransition extends RefCounted:
	## The short pull-together between two touching bodies that combine before
	## the world swaps them for one holding both their areas. Pure timing: the
	## world applies the forces and tint.

	## Seconds from the first contact to the swap, at the earliest: the world
	## swaps the pair only once it is compact (GooWorld2D.MERGE_FIT).
	const DURATION := 0.25
	## Seconds after which a pair that never got compact is let go (the
	## transition is cancelled) instead of swapped.
	const MAX_DURATION := 3.0 * DURATION
	## Physics frames between two checks of whether a pair waiting past
	## DURATION is compact yet (each costs a few hundred µs: the merged ring's
	## placement, for shapes their fused outline too).
	const RECHECK_FRAMES := 4
	## Seconds over which the pull ramps up from nothing to full strength.
	const RAMP := 0.1

	## World id of the first body.
	var id_a: int = -1
	## World id of the second body.
	var id_b: int = -1
	## Mass of one bead of the first and of the second body (the pull gives
	## every bead the same acceleration), set when the world starts the
	## transition: the bodies do not change while it runs.
	var particle_mass_a: float = 0.0
	var particle_mass_b: float = 0.0
	## Seconds since the transition started.
	var elapsed: float = 0.0
	# Ticks that began with the transition already done().
	var _ticks_done: int = 0

	func _init(first_id: int, second_id: int) -> void:
		id_a = first_id
		id_b = second_id

	## Advances the transition by `delta` seconds.
	func tick(delta: float) -> void:
		if done():
			_ticks_done += 1
		elapsed += delta

	## How far along the transition is, from 0 at contact to 1 at the swap.
	func progress() -> float:
		return clampf(elapsed / DURATION, 0.0, 1.0)

	## True once the bodies may be swapped for the merged one (if compact).
	func done() -> bool:
		return elapsed >= DURATION

	## True on the frames the world checks whether the pair is compact enough
	## to swap: the tick done() first holds, and every RECHECK_FRAMES ticks
	## after.
	func check_due() -> bool:
		return done() and _ticks_done % RECHECK_FRAMES == 0

	## True once the transition has run MAX_DURATION: a pair not swapped by
	## then is let go.
	func expired() -> bool:
		return elapsed >= MAX_DURATION

	## Strength of the pull, 0..1: ramps up over RAMP, then holds at full.
	func attraction() -> float:
		return clampf(elapsed / RAMP, 0.0, 1.0)

# ---- Untangler ----

class Untangler extends RefCounted:
	## Frees rings deep inside each other (Intrusion.deep(): the centre of one
	## inside the other's loop, as for a ring spawned on or inside another, or
	## engulfed by a merged ring inflating around it). Contacts hold them in, and
	## the per-bead push cannot part them. The world's kernel runs it: when its
	## overlap pass finds such a pair, the two rings are let pass through each
	## other (every bead pair, an exclusion in the kernel's contacts) and pushed apart along
	## the centre line every physics frame (push(), as impulses shared by every
	## bead) until neither ring's beads reach far into the other's outline
	## (RELEASE_MARGIN, Goo2D.beads_inside()), then collide again. Skins that
	## merely crossed (some beads of one, or of both, inside the other) are the
	## per-bead push's, each bead inside let through on its own, so the rest of
	## both rings keep colliding. What stays here is the rule's numbers and its
	## impulse, the reference the kernel's port is tested against.

	## Acceleration (px/s²) per pixel of nominal overlap, up to SEPARATION_SPEED:
	## GooTuning.UNTANGLE_STRENGTH, the solver's knob the kernel pushes with
	## (GooTuning.solver_settings()), where its measurements are.
	const STRENGTH: float = GooTuning.UNTANGLE_STRENGTH
	## Speed, px/s at GooTuning.unit 1, at which the push stops adding to the
	## pair's parting along the centre line: GooTuning.UNTANGLE_SEPARATION_SPEED
	## (scaled by the unit in GooTuning.solver_settings()).
	const SEPARATION_SPEED: float = GooTuning.UNTANGLE_SEPARATION_SPEED
	## A pair collides again once no bead centre of either ring is within this
	## fraction of their two bead radii of the other's bead loop: the beads overlap
	## by at most half then, and contacts push them out on the right side. Rings
	## pressed together in a pile keep their beads about one sum of radii from each
	## other's loop, so a full margin would never let go.
	const RELEASE_MARGIN: float = 0.5
	## Smallest overlap, as a fraction of the two radii, the push is computed with:
	## threaded rings keep being pushed apart past their nominal radii.
	const MIN_OVERLAP_RATIO: float = 0.2

	## Impulses for two threaded rings, centres `a`/`b`, nominal radii and masses,
	## over `delta` seconds: equal and opposite along the centre line, sized to
	## part the two at STRENGTH px/s² per px of nominal overlap (so the lighter ring
	## moves more), the overlap never counted as less than MIN_OVERLAP_RATIO of
	## their radii.
	##
	## With the rings' velocities `velocity_a`/`velocity_b`, the push never takes
	## their parting speed along the centre line past SEPARATION_SPEED: it is cut
	## to what reaches that speed, and is zero for a pair already parting faster.
	static func push(center_a: Vector2, radius_a: float, mass_a: float,
			center_b: Vector2, radius_b: float, mass_b: float, delta: float,
			velocity_a: Vector2 = Vector2.ZERO, velocity_b: Vector2 = Vector2.ZERO) -> Array[Vector2]:
		var reach := radius_a + radius_b
		var distance := center_a.distance_to(center_b)
		var overlap := maxf(reach - distance, MIN_OVERLAP_RATIO * reach)
		var direction := Vector2.RIGHT
		if distance > 0.0001:
			direction = (center_a - center_b) / distance
		var mass_sum := mass_a + mass_b
		var reduced := 0.0 if mass_sum <= 0.0 else mass_a * mass_b / mass_sum
		var parting := (velocity_a - velocity_b).dot(direction)
		var change := minf(STRENGTH * overlap * delta, maxf(SEPARATION_SPEED - parting, 0.0))
		var impulse := direction * change * reduced
		return [impulse, -impulse] as Array[Vector2]
