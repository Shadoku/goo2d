extends TestCase
## The hooks a GooWorld2D subclass and a game build on: may_merge() decides
## which touching pairs combine (here: by colour, whatever their sizes or
## shapes) and merged_color() what colour the merged body is; a body's own
## `color` (Goo2D.COLOR_BY_SIZE: by size) survives a split; despawn() removes
## one body; cut_at_tips() cuts the bodies static tips reach; a body's `tags`
## ride along with it (copied to the pieces of a split and to a trimmed body,
## merged_tags() of the pair on a merge); tuning_for() tunes every body the
## world builds (spawned, merged, cut, placed in a scene), seeing its tags;
## body_split, bodies_merged and body_trimmed say which bodies became which;
## body_spawned announces every body the world registers (spawned, a split's
## pieces, merged, trimmed, placed), built, tuned and in the tree, before any
## other signal about it;
## may_split() refuses the cuts the goo asks for (blades, tips, the wedge) but
## not a direct cut(); gravity_scale scales the world's gravity at any time.
## Played in the demo's arena (walls, floor, wedge, two blades), with a plain
## world: nothing here is the demo Game's.

## Seconds a merge of two touching bodies may take: settling onto each other,
## then the transition.
const MERGE_TIMEOUT: float = 1.5
const RED := Color(0.9, 0.2, 0.25)
const BLUE := Color(0.2, 0.35, 0.9)

## A world whose bodies merge when their colours are equal, whatever their
## sizes or shapes, up to the merged size the tuning knows (GooTuning.MAX_RADIUS);
## the merged body takes the pair's colour.
class ColourWorld extends GooWorld2D:
	## Pairs may_merge() was asked about.
	var asked: int = 0

	func may_merge(a: Goo2D, b: Goo2D) -> bool:
		asked += 1
		return a.color == b.color and GooTuning.merged_radius(a.radius, b.radius) <= GooTuning.MAX_RADIUS

	func merged_color(a: Goo2D, _b: Goo2D) -> Color:
		return a.color

## A world whose merged body is tagged mud when the pair's first tags differ,
## and as the default merges them otherwise.
class MudWorld extends GooWorld2D:
	func merged_tags(a: Goo2D, b: Goo2D) -> Array:
		if a.tag() != b.tag():
			return [&"mud"]
		return super(a, b)

## A world that tunes its bodies by their first tag: a heavy body's masses are
## HEAVY times GooTuning's, every other body is GooTuning's.
class KindWorld extends GooWorld2D:
	const HEAVY: float = 2.0
	## The tags of every ring tuning_for() was asked about, in order (copies).
	var asked: Array[Array] = []

	func tuning_for(shape: GooShape, tags: Array = []) -> Dictionary:
		asked.append(tags.duplicate())
		var values := super(shape, tags)
		if not tags.is_empty() and tags[0] == &"heavy":
			for key: String in ["blob_mass", "bead_mass"]:
				values[key] = float(values[key]) * HEAVY
		return values

## A world whose bodies are STIFFNESS times stiffer than GooTuning makes them:
## skin, bending and shape matching (the ring's own geometry unchanged).
class StiffWorld extends GooWorld2D:
	const STIFFNESS: float = 4.0
	## Shapes tuning_for() was asked about.
	var asked: int = 0

	func tuning_for(shape: GooShape, tags: Array = []) -> Dictionary:
		asked += 1
		var values := super(shape, tags)
		for key: String in ["skin_stiffness", "bending_stiffness", "shape_match_k"]:
			values[key] = float(values[key]) * STIFFNESS
		return values

## A world that pierces its arena's wedge apex every physics frame, as the
## demo's Game does (GooWorld2D.pierce()), when `arena` is set.
class WedgeWorld extends GooWorld2D:
	var arena: Arena = null

	func _physics_process(delta: float) -> void:
		if arena != null:
			pierce(arena.wedge_apex(), arena.wedge_axis())
		super(delta)

## A world whose bodies never split: may_split() refuses every cut the goo asks
## for, and counts the asks.
class NoSplitWorld extends WedgeWorld:
	## Times may_split() was asked.
	var asked: int = 0

	func may_split(_body: Goo2D) -> bool:
		asked += 1
		return false

## A world whose blue bodies never split; every other body does.
class SelectiveWorld extends GooWorld2D:
	func may_split(body: Goo2D) -> bool:
		return body.color != BLUE

var arena: Arena
var world: GooWorld2D
var merges: Array[float] = []
var splits: int = 0
var trims: int = 0

func before_each() -> void:
	arena = (load("res://scenes/arena.tscn") as PackedScene).instantiate() as Arena
	add_child(arena)

# Adds `made` as the world under test and counts its merges and splits.
func _use(made: GooWorld2D) -> void:
	world = made
	add_child(world)
	merges.clear()
	splits = 0
	trims = 0
	world.merged.connect(func(radius: float, _position: Vector2) -> void: merges.append(radius))
	world.split.connect(func(_a: float, _b: float, _position: Vector2) -> void: splits += 1)
	world.trimmed.connect(func(_radius: float, _position: Vector2) -> void: trims += 1)

# Spawns a body of `radius` (round, or of `shape`) in `colour` resting on the
# floor with its centre at `x`.
func _spawn_on_floor(radius: float, x: float, colour: Color, shape: GooShape = null) -> Goo2D:
	var body := world.spawn(radius, Vector2(x, arena.floor_y() - radius), shape)
	body.color = colour
	return body

# Steps physics for up to `seconds` or until a merge, then two more frames.
# Returns the seconds until the merge, -1 if none.
func _watch_merge(seconds: float) -> float:
	var merge_time := -1.0
	for frame: int in roundi(seconds * Engine.physics_ticks_per_second):
		await get_tree().physics_frame
		if not merges.is_empty():
			merge_time = float(frame + 1) / Engine.physics_ticks_per_second
			break
	await wait_frames(2)
	return merge_time

# --- may_merge() and merged_color() ------------------------------------------

func test_bodies_of_one_colour_merge_whatever_their_sizes() -> void:
	_use(ColourWorld.new())
	assert_false(GooTuning.can_merge(40.0, 90.0), "the default rule keeps 40 and 90 px apart")
	var x := arena.inner_left() + 800.0
	_spawn_on_floor(40.0, x - 63.0, RED)
	_spawn_on_floor(90.0, x + 63.0, RED)
	var merge_time := await _watch_merge(MERGE_TIMEOUT)
	print("    40 + 90 px, both red: %s" % ("merged after %.2f s" % merge_time if merge_time >= 0.0 else "no merge"))
	assert_true(merge_time >= 0.0, "touching bodies of one colour merge within %.1f s" % MERGE_TIMEOUT)
	assert_eq(world.bodies().size(), 1)
	if world.bodies().size() != 1:
		return
	var merged := world.bodies()[0]
	assert_almost_eq(merged.radius, GooTuning.merged_radius(40.0, 90.0), 0.01, "the merged body holds both areas")
	assert_eq(merged.color, RED, "the merged body has the colour merged_color() returned")
	assert_eq(merged.base_color(), RED)
	await wait_seconds(GooTuning.MERGE_FLASH + 0.1)
	assert_eq(merged.get_tint(), RED, "after its flash the merged body is drawn in its colour")

func test_bodies_of_different_colours_do_not_merge() -> void:
	_use(ColourWorld.new())
	assert_true(GooTuning.can_merge(40.0, 40.0), "the default rule merges two 40 px bodies")
	var x := arena.inner_left() + 800.0
	var lower := _spawn_on_floor(40.0, x, RED)
	var upper := world.spawn(40.0, Vector2(x, arena.floor_y() - 40.0 * 3.0 + 4.0))
	upper.color = BLUE
	var merge_time := await _watch_merge(2.0)
	assert_eq(merge_time, -1.0, "a blue body resting on a red one does not merge with it in 2 s")
	assert_eq(world.bodies().size(), 2)
	assert_gt((world as ColourWorld).asked, 0, "the pair touched and may_merge() was asked")
	assert_eq(lower.get_tint(), RED)
	assert_eq(upper.get_tint(), BLUE)

func test_a_subclass_may_merge_a_shape_with_a_round_body() -> void:
	_use(ColourWorld.new())
	var x := arena.inner_left() + 800.0
	_spawn_on_floor(40.0, x - 40.0, RED, GooShape.regular(4, 40.0))
	_spawn_on_floor(40.0, x + 40.0, RED)
	var merge_time := await _watch_merge(MERGE_TIMEOUT)
	print("    a 40 px square and a 40 px round body, both red: %s"
		% ("merged after %.2f s" % merge_time if merge_time >= 0.0 else "no merge"))
	assert_true(merge_time >= 0.0, "may_merge() is asked about a shape and a round body too")
	assert_eq(world.bodies().size(), 1)

func test_the_default_world_merges_and_colours_by_size() -> void:
	_use(GooWorld2D.new())
	var x := arena.inner_left() + 800.0
	var a := world.spawn(40.0, Vector2(x - 38.0, arena.floor_y() - 40.0))
	world.spawn(40.0, Vector2(x + 38.0, arena.floor_y() - 40.0))
	assert_eq(a.color, Goo2D.COLOR_BY_SIZE, "a spawned body is coloured by size")
	assert_eq(a.base_color(), GooTuning.color(40.0))
	assert_eq(world.merged_color(a, a), Goo2D.COLOR_BY_SIZE, "the default merged colour is by size")
	var merge_time := await _watch_merge(MERGE_TIMEOUT + 1.0)
	assert_true(merge_time >= 0.0)
	if world.bodies().size() != 1:
		fail("one body after the merge, got %d" % world.bodies().size())
		return
	var merged := world.bodies()[0]
	assert_eq(merged.color, Goo2D.COLOR_BY_SIZE)
	await wait_seconds(GooTuning.MERGE_FLASH + 0.1)
	assert_eq(merged.get_tint(), GooTuning.color(merged.radius), "the merged body is drawn in its size's colour")

# --- a body's own colour -----------------------------------------------------

func test_setting_color_retints_a_built_body_and_the_sentinel_goes_back_to_size() -> void:
	_use(GooWorld2D.new())
	var body := world.spawn(50.0, Vector2(arena.inner_left() + 800.0, arena.floor_y() - 50.0))
	assert_eq(body.get_tint(), GooTuning.color(50.0))
	body.color = BLUE
	assert_eq(body.get_tint(), BLUE, "a built body is retinted at once")
	assert_eq(body.base_color(), BLUE)
	body.color = Goo2D.COLOR_BY_SIZE
	assert_eq(body.get_tint(), GooTuning.color(50.0), "the sentinel colours it by size again")

# Cuts `body` across its middle from its top bead, as tools/screenshot.gd's
# --split does, and returns the bodies after the cut.
func _cut_through(body: Goo2D) -> Array[Goo2D]:
	var points := body.bead_points()
	var top := 0
	for i: int in points.size():
		if points[i].y < points[top].y:
			top = i
	world.cut(body, top, (top + points.size() / 2) % points.size())
	return world.bodies()

func test_split_pieces_keep_their_parents_colour() -> void:
	_use(GooWorld2D.new())
	var x := arena.inner_left() + 800.0
	var shapes: Array[GooShape] = [null, GooShape.regular(4, 60.0)]
	for shape: GooShape in shapes:
		world.clear()
		await wait_frames(1)
		var body := _spawn_on_floor(60.0, x, BLUE, shape)
		await wait_frames(5)
		var pieces := _cut_through(body)
		var label := "round" if shape == null else "square"
		assert_eq(pieces.size(), 2, "the %s body is cut in two" % label)
		for piece: Goo2D in pieces:
			assert_eq(piece.color, BLUE, "a piece of the %s body keeps its colour" % label)
			assert_eq(piece.get_tint(), BLUE, "a piece of the %s body is drawn in it" % label)
	await wait_frames(5)

# --- despawn() ---------------------------------------------------------------

func test_despawn_removes_one_body_and_reports_the_count() -> void:
	_use(GooWorld2D.new())
	var x := arena.inner_left() + 300.0
	var a := world.spawn(40.0, Vector2(x, arena.floor_y() - 40.0))
	var b := world.spawn(60.0, Vector2(x + 400.0, arena.floor_y() - 60.0))
	await wait_frames(2)
	var counts: Array[int] = []
	world.count_changed.connect(func(count: int) -> void: counts.append(count))
	world.despawn(a)
	assert_eq(counts, [1] as Array[int], "count_changed reports the one body left")
	assert_eq(world.bodies(), [b] as Array[Goo2D], "bodies() no longer lists it")
	assert_false(a.is_inside_tree(), "it left the tree (and the kernel) at once")
	await wait_frames(2)
	assert_false(is_instance_valid(a), "it is freed")
	world.despawn(b)
	world.despawn(b)
	assert_eq(counts, [1, 0] as Array[int], "a body despawned twice is removed once")
	assert_eq(world.bodies().size(), 0)

func test_despawning_one_of_a_merging_pair_lets_the_other_go() -> void:
	_use(GooWorld2D.new())
	var x := arena.inner_left() + 800.0
	var a := world.spawn(40.0, Vector2(x - 38.0, arena.floor_y() - 40.0))
	var b := world.spawn(40.0, Vector2(x + 38.0, arena.floor_y() - 40.0))
	for frame: int in 120:
		await get_tree().physics_frame
		if a.merging:
			break
	assert_true(a.merging and b.merging, "the pair started merging")
	world.despawn(a)
	await wait_frames(3)
	assert_true(is_instance_valid(b) and b.is_inside_tree(), "its partner stays")
	assert_false(b.merging, "its partner's transition is cancelled")
	assert_eq(b.get_tint(), b.base_color(), "its partner is drawn in its own colour again")
	assert_eq(merges.size(), 0)
	assert_eq(world.bodies(), [b] as Array[Goo2D])

# --- cut_at_tips() -----------------------------------------------------------

func test_cut_at_tips_splits_a_body_on_a_blade_tip_once() -> void:
	_use(GooWorld2D.new())
	var blade := arena.get_node("FloorBlade") as Blade
	var tip := blade.tip()
	var axis := blade.axis()
	var body := world.spawn(50.0, tip)
	assert_eq(world.cut_at_tips(PackedVector2Array([tip + Vector2(0.0, -400.0)]), PackedVector2Array([axis])), 0,
		"a tip far from every body cuts nothing")
	var tips := PackedVector2Array([tip, tip + Vector2(6.0, 0.0)])
	var axes := PackedVector2Array([axis, axis])
	assert_eq(world.cut_at_tips(tips, axes), 1, "two tips inside one body ask for one cut")
	assert_eq(world.cut_at_tips(tips, axes), 0, "a body waiting for its cut is not asked again")
	await wait_frames(2)
	assert_false(is_instance_valid(body) and body.is_inside_tree(), "the body was cut")
	assert_eq(splits, 1, "into two pieces")
	assert_eq(world.bodies().size(), 2)

# --- tags --------------------------------------------------------------------

# Lets `body` settle (up to 3 s), then pierces it 0.7 bead radii in from its
# right-most bead, level with its centre, which trims it off the tip as
# test_split.gd's trim test does. Returns the bodies two frames after the
# cut; empty if the body did not settle.
func _trim_near_edge(body: Goo2D) -> Array[Goo2D]:
	for _frame: int in roundi(3.0 * Engine.physics_ticks_per_second):
		await get_tree().physics_frame
		if body.settled:
			break
	assert_true(body.settled, "the body settles")
	if not body.settled:
		return [] as Array[Goo2D]
	var right := -INF
	for point: Vector2 in body.bead_points():
		right = maxf(right, point.x)
	var tip := Vector2(right - 0.7 * body.bead_radius(), body.center().y)
	assert_eq(world.pierce(tip, Vector2.UP), 1, "the tip near the settled body's edge cuts it")
	await wait_frames(2)
	return world.bodies()

func test_spawn_tags_a_body_with_a_copy_of_its_tags() -> void:
	_use(GooWorld2D.new())
	var x := arena.inner_left() + 800.0
	var given: Array = [&"earth"]
	var earth := world.spawn(40.0, Vector2(x - 200.0, arena.floor_y() - 40.0), null, given)
	assert_eq(earth.tags, [&"earth"], "spawn() sets the tags given")
	assert_eq(earth.tag(), &"earth", "tag() is the first")
	given.append(&"water")
	given[0] = &"fire"
	assert_eq(earth.tags, [&"earth"], "the body's list is not the caller's array")
	var plain := world.spawn(40.0, Vector2(x + 200.0, arena.floor_y() - 40.0))
	assert_eq(plain.tags, [], "spawn() without tags leaves the list empty")
	assert_null(plain.tag(), "tag() of an untagged body is null")
	var unbuilt := Goo2D.new()
	assert_eq(unbuilt.tags, [], "a new body has no tags")
	unbuilt.free()

func test_split_pieces_carry_a_copy_of_their_parents_tags() -> void:
	_use(GooWorld2D.new())
	var x := arena.inner_left() + 800.0
	var shapes: Array[GooShape] = [null, GooShape.regular(4, 60.0)]
	for shape: GooShape in shapes:
		world.clear()
		await wait_frames(1)
		var body := world.spawn(60.0, Vector2(x, arena.floor_y() - 60.0), shape, [&"earth", &"old"])
		await wait_frames(5)
		var pieces := _cut_through(body)
		var label := "round" if shape == null else "square"
		assert_eq(pieces.size(), 2, "the %s body is cut in two" % label)
		if pieces.size() != 2:
			continue
		for piece: Goo2D in pieces:
			assert_eq(piece.tags, [&"earth", &"old"], "a piece of the %s body carries its tags" % label)
			assert_eq(piece.tag(), &"earth")
		assert_false(is_same(pieces[0].tags, pieces[1].tags), "each %s piece has its own list" % label)
		pieces[0].tags.append(&"new")
		assert_eq(pieces[1].tags, [&"earth", &"old"], "changing one %s piece's tags leaves the other's" % label)
	await wait_frames(5)

func test_a_trimmed_body_carries_its_tags() -> void:
	timeout_sec = 10.0
	_use(GooWorld2D.new())
	var body := world.spawn(40.0, Vector2(arena.inner_left() + 800.0, arena.floor_y() - 40.0), null,
		[&"earth"])
	var after := await _trim_near_edge(body)
	assert_eq(trims, 1, "the body is trimmed off the tip")
	assert_eq(splits, 0, "not split")
	assert_eq(after.size(), 1)
	if after.size() == 1:
		assert_ne(after[0], body, "the trimmed body is a new one")
		assert_eq(after[0].tags, [&"earth"], "the trimmed body carries its tags")

func test_merged_tags_is_a_deduped_union_in_order() -> void:
	_use(GooWorld2D.new())
	var x := arena.inner_left() + 800.0
	var lists: Array[Array] = [[&"earth", &"old"], [&"old", &"earth"], [&"water"], []]
	var made: Array[Goo2D] = []
	for i: int in lists.size():
		made.append(world.spawn(40.0, Vector2(x - 600.0 + 300.0 * i, arena.floor_y() - 40.0), null, lists[i]))
	assert_eq(world.merged_tags(made[0], made[1]), [&"earth", &"old"], "a's tags, then b's not already there")
	assert_eq(world.merged_tags(made[1], made[0]), [&"old", &"earth"], "in a's order")
	assert_eq(world.merged_tags(made[0], made[2]), [&"earth", &"old", &"water"])
	assert_eq(world.merged_tags(made[2], made[3]), [&"water"], "an untagged body adds nothing")
	assert_eq(world.merged_tags(made[3], made[3]), [], "two untagged bodies merge untagged")
	var union := world.merged_tags(made[0], made[3])
	assert_false(is_same(union, made[0].tags), "a new array, not a's")
	union.append(&"new")
	assert_eq(made[0].tags, [&"earth", &"old"])

func test_merged_bodies_carry_the_union_of_their_tags() -> void:
	_use(GooWorld2D.new())
	var x := arena.inner_left() + 800.0
	world.spawn(40.0, Vector2(x - 38.0, arena.floor_y() - 40.0), null, [&"earth"])
	world.spawn(40.0, Vector2(x + 38.0, arena.floor_y() - 40.0), null, [&"water"])
	var merge_time := await _watch_merge(MERGE_TIMEOUT + 1.0)
	assert_true(merge_time >= 0.0, "an earth and a water body merge")
	assert_eq(world.bodies().size(), 1)
	if world.bodies().size() == 1:
		var merged := world.bodies()[0]
		print("    earth + water merged into %s" % [merged.tags])
		assert_eq(merged.tags.size(), 2, "the merged body has both tags")
		assert_true(merged.tags.has(&"earth") and merged.tags.has(&"water"), "earth and water")
		assert_true(merged.tag() == &"earth" or merged.tag() == &"water", "its first is one of the pair's")
		assert_eq(merged.tag(), merged.tags[0], "tag() is its first")

	world.clear()
	merges.clear()
	await wait_frames(1)
	world.spawn(40.0, Vector2(x - 38.0, arena.floor_y() - 40.0), null, [&"earth", &"old"])
	world.spawn(40.0, Vector2(x + 38.0, arena.floor_y() - 40.0), null, [&"old", &"earth"])
	merge_time = await _watch_merge(MERGE_TIMEOUT + 1.0)
	assert_true(merge_time >= 0.0, "two bodies of the same tags in another order merge")
	assert_eq(world.bodies().size(), 1)
	if world.bodies().size() == 1:
		var merged := world.bodies()[0]
		print("    [earth, old] + [old, earth] merged into %s" % [merged.tags])
		assert_true(merged.tags == [&"earth", &"old"] or merged.tags == [&"old", &"earth"],
			"deduped, in one of the pair's orders (the first's): %s" % [merged.tags])

func test_a_world_may_merge_tags_into_a_new_one() -> void:
	_use(MudWorld.new())
	var x := arena.inner_left() + 800.0
	world.spawn(40.0, Vector2(x - 38.0, arena.floor_y() - 40.0), null, [&"earth"])
	world.spawn(40.0, Vector2(x + 38.0, arena.floor_y() - 40.0), null, [&"water"])
	var merge_time := await _watch_merge(MERGE_TIMEOUT + 1.0)
	assert_true(merge_time >= 0.0, "an earth and a water body merge")
	assert_eq(world.bodies().size(), 1)
	if world.bodies().size() == 1:
		assert_eq(world.bodies()[0].tags, [&"mud"], "into a mud body")

	world.clear()
	merges.clear()
	await wait_frames(1)
	world.spawn(40.0, Vector2(x - 38.0, arena.floor_y() - 40.0), null, [&"earth"])
	world.spawn(40.0, Vector2(x + 38.0, arena.floor_y() - 40.0), null, [&"earth"])
	merge_time = await _watch_merge(MERGE_TIMEOUT + 1.0)
	assert_true(merge_time >= 0.0, "two earth bodies merge")
	assert_eq(world.bodies().size(), 1)
	if world.bodies().size() == 1:
		assert_eq(world.bodies()[0].tags, [&"earth"], "into an earth one")

# --- tuning_for() ------------------------------------------------------------

# Checks that `body` is tuned as StiffWorld tunes a ring of its shape: its
# stiffnesses STIFFNESS times GooTuning's, its ring's geometry GooTuning's.
func _assert_stiff(body: Goo2D, label: String) -> void:
	var plain := GooTuning.tuning_for(body.shape)
	for key: String in ["skin_stiffness", "bending_stiffness", "shape_match_k"]:
		assert_almost_eq(float(body.tuning[key]), StiffWorld.STIFFNESS * float(plain[key]),
			0.000001 * absf(float(plain[key])), "%s: %s is the world's" % [label, key])
	for key: String in ["bead_count", "bead_radius", "spacing", "target_area", "skin_damping"]:
		assert_eq(body.tuning[key], plain[key], "%s: %s is GooTuning's" % [label, key])
	assert_eq(body.particle_count(), int(plain["bead_count"]), "%s: its ring has GooTuning's beads" % label)

func test_a_world_tunes_the_bodies_it_spawns() -> void:
	_use(StiffWorld.new())
	var x := arena.inner_left() + 800.0
	var ball := world.spawn(40.0, Vector2(x, arena.floor_y() - 40.0))
	var square := world.spawn(60.0, Vector2(x + 400.0, arena.floor_y() - 60.0), GooShape.regular(4, 40.0))
	assert_gt((world as StiffWorld).asked, 0, "spawn() asked tuning_for()")
	assert_true(ball.shape.is_round())
	assert_false(square.shape.is_round())
	assert_almost_eq(square.radius, 60.0, 0.001, "the square is scaled to the radius spawned")
	_assert_stiff(ball, "a spawned round body")
	_assert_stiff(square, "a spawned square")
	assert_eq(square.tuning["skin_stiffness"],
		StiffWorld.STIFFNESS * float(GooTuning.tuning_for(square.shape)["skin_stiffness"]))

func test_the_default_world_tunes_by_gooTuning() -> void:
	_use(GooWorld2D.new())
	var square_shape := GooShape.regular(4, 60.0)
	assert_eq(world.tuning_for(GooShape.round(40.0)), GooTuning.tuning(40.0), "round: GooTuning.tuning()")
	assert_eq(world.tuning_for(square_shape), GooTuning.tuning_for(square_shape), "a shape: GooTuning.tuning_for()")
	var square := world.spawn(60.0, Vector2(arena.inner_left() + 800.0, arena.floor_y() - 60.0), square_shape)
	assert_eq(square.tuning, GooTuning.tuning_for(square.shape))

func test_cut_pieces_carry_the_worlds_tuning() -> void:
	_use(StiffWorld.new())
	var x := arena.inner_left() + 800.0
	var shapes: Array[GooShape] = [null, GooShape.regular(4, 60.0)]
	for shape: GooShape in shapes:
		world.clear()
		await wait_frames(1)
		var body := _spawn_on_floor(60.0, x, BLUE, shape)
		await wait_frames(5)
		var pieces := _cut_through(body)
		var label := "round" if shape == null else "square"
		assert_eq(pieces.size(), 2, "the %s body is cut in two" % label)
		for piece: Goo2D in pieces:
			assert_eq(piece.shape.is_round(), shape == null, "a piece of the %s body is %s" % [label, label])
			_assert_stiff(piece, "a piece of the %s body" % label)
	await wait_frames(5)

func test_merged_bodies_carry_the_worlds_tuning() -> void:
	_use(StiffWorld.new())
	var x := arena.inner_left() + 800.0
	world.spawn(40.0, Vector2(x - 38.0, arena.floor_y() - 40.0))
	world.spawn(40.0, Vector2(x + 38.0, arena.floor_y() - 40.0))
	var merge_time := await _watch_merge(MERGE_TIMEOUT + 1.0)
	assert_true(merge_time >= 0.0, "two 40 px round bodies merge")
	assert_eq(world.bodies().size(), 1)
	if world.bodies().size() == 1:
		assert_true(world.bodies()[0].shape.is_round())
		_assert_stiff(world.bodies()[0], "the merged round body")

	world.clear()
	merges.clear()
	await wait_frames(1)
	# Launch-size squares standing on the floor, their collision outlines
	# overlapping by 2 px, as test_shape_merge.gd fuses them.
	var square_radius := 34.0
	var side := sqrt(PI) * square_radius
	for dx: float in [-side / 2.0 + 1.0, side / 2.0 - 1.0]:
		world.spawn(square_radius, Vector2(x + dx, arena.floor_y() - side / 2.0), GooShape.regular(4, square_radius))
	merge_time = await _watch_merge(MERGE_TIMEOUT + 1.0)
	assert_true(merge_time >= 0.0, "two 34 px squares side by side merge")
	assert_eq(world.bodies().size(), 1)
	if world.bodies().size() == 1:
		assert_false(world.bodies()[0].shape.is_round(), "into their fused shape")
		_assert_stiff(world.bodies()[0], "the merged shape")

func test_a_body_placed_under_a_world_is_tuned_by_it() -> void:
	# A scene as the editor saves one: a StiffWorld with a round Goo2D and a
	# `sides = 4` square under it, every node owned by the scene's root.
	var source := Node2D.new()
	source.name = "Placed"
	var stiff := StiffWorld.new()
	stiff.name = "World"
	source.add_child(stiff)
	stiff.owner = source
	var sides: Array[int] = [0, 4]
	for i: int in sides.size():
		var placed := Goo2D.new()
		placed.name = "Body%d" % i
		placed.radius = 40.0
		placed.sides = sides[i]
		placed.position = Vector2(arena.inner_left() + 300.0 + 500.0 * i, arena.floor_y() - 200.0)
		stiff.add_child(placed)
		placed.owner = source
	var packed := PackedScene.new()
	assert_eq(packed.pack(source), OK)
	source.free()

	var scene := packed.instantiate()
	add_child(scene)
	var placed_world := scene.get_node("World") as StiffWorld
	assert_not_null(placed_world, "the World node is a StiffWorld")
	if placed_world == null:
		return
	var ball := scene.get_node("World/Body0") as Goo2D
	var square := scene.get_node("World/Body1") as Goo2D
	assert_gt(ball.particle_count(), 0, "the round body built itself in _ready()")
	assert_gt(square.particle_count(), 0, "the square built itself in _ready()")
	assert_false(square.shape.is_round())
	_assert_stiff(ball, "a placed round body")
	_assert_stiff(square, "a placed square")
	await wait_frames(2)

# Checks that `body`'s masses are `factor` times GooTuning's for its shape and
# the rest of its tuning GooTuning's.
func _assert_masses(body: Goo2D, factor: float, label: String) -> void:
	var plain := GooTuning.tuning_for(body.shape)
	for key: String in ["blob_mass", "bead_mass"]:
		assert_almost_eq(float(body.tuning[key]), factor * float(plain[key]),
			0.000001 * absf(float(plain[key])), "%s: %s is %.0f × GooTuning's" % [label, key, factor])
	for key: String in ["bead_count", "bead_radius", "spacing", "target_area", "skin_stiffness"]:
		assert_eq(body.tuning[key], plain[key], "%s: %s is GooTuning's" % [label, key])

func test_a_world_tunes_its_bodies_by_their_first_tag() -> void:
	_use(KindWorld.new())
	var kinds := world as KindWorld
	var x := arena.inner_left() + 800.0
	var heavy := world.spawn(40.0, Vector2(x - 300.0, arena.floor_y() - 40.0), null, [&"heavy"])
	var plain := world.spawn(40.0, Vector2(x, arena.floor_y() - 40.0))
	var light_first := world.spawn(40.0, Vector2(x + 300.0, arena.floor_y() - 40.0), null, [&"light", &"heavy"])
	var square := world.spawn(60.0, Vector2(x + 600.0, arena.floor_y() - 60.0), GooShape.regular(4, 40.0),
		[&"heavy"])
	assert_eq(kinds.asked, [[&"heavy"], [], [&"light", &"heavy"], [&"heavy"]] as Array[Array],
		"spawn() asked tuning_for() with each body's tags")
	_assert_masses(heavy, KindWorld.HEAVY, "a heavy body")
	_assert_masses(square, KindWorld.HEAVY, "a heavy square")
	_assert_masses(plain, 1.0, "an untagged body")
	_assert_masses(light_first, 1.0, "a light, heavy body (only the first tag counts)")

func test_the_default_world_ignores_tags_when_tuning() -> void:
	_use(GooWorld2D.new())
	var square_shape := GooShape.regular(4, 60.0)
	assert_eq(world.tuning_for(GooShape.round(40.0), [&"anything"]), GooTuning.tuning(40.0), "round")
	assert_eq(world.tuning_for(square_shape, [&"anything"]), GooTuning.tuning_for(square_shape), "a shape")

func test_cut_and_trimmed_heavy_bodies_stay_heavy() -> void:
	timeout_sec = 15.0
	_use(KindWorld.new())
	var x := arena.inner_left() + 800.0
	var shapes: Array[GooShape] = [null, GooShape.regular(4, 60.0)]
	for shape: GooShape in shapes:
		world.clear()
		await wait_frames(1)
		var body := world.spawn(60.0, Vector2(x, arena.floor_y() - 60.0), shape, [&"heavy"])
		await wait_frames(5)
		var pieces := _cut_through(body)
		var label := "round" if shape == null else "square"
		assert_eq(pieces.size(), 2, "the heavy %s body is cut in two" % label)
		for piece: Goo2D in pieces:
			_assert_masses(piece, KindWorld.HEAVY, "a piece of the heavy %s body" % label)

	world.clear()
	await wait_frames(1)
	trims = 0
	var settled := world.spawn(40.0, Vector2(x, arena.floor_y() - 40.0), null, [&"heavy"])
	var after := await _trim_near_edge(settled)
	assert_eq(trims, 1, "the heavy body is trimmed off the tip")
	assert_eq(after.size(), 1)
	if after.size() == 1:
		_assert_masses(after[0], KindWorld.HEAVY, "the trimmed heavy body")

func test_merged_bodies_are_tuned_by_their_merged_tags() -> void:
	_use(KindWorld.new())
	var kinds := world as KindWorld
	var x := arena.inner_left() + 800.0
	world.spawn(40.0, Vector2(x - 38.0, arena.floor_y() - 40.0), null, [&"heavy"])
	world.spawn(40.0, Vector2(x + 38.0, arena.floor_y() - 40.0), null, [&"heavy"])
	var merge_time := await _watch_merge(MERGE_TIMEOUT + 1.0)
	assert_true(merge_time >= 0.0, "two heavy bodies merge")
	assert_eq(world.bodies().size(), 1)
	if world.bodies().size() == 1:
		assert_eq(world.bodies()[0].tags, [&"heavy"])
		_assert_masses(world.bodies()[0], KindWorld.HEAVY, "the merged heavy body")

	world.clear()
	merges.clear()
	await wait_frames(1)
	world.spawn(40.0, Vector2(x - 38.0, arena.floor_y() - 40.0), null, [&"heavy"])
	world.spawn(40.0, Vector2(x + 38.0, arena.floor_y() - 40.0), null, [&"light"])
	kinds.asked.clear()
	merge_time = await _watch_merge(MERGE_TIMEOUT + 1.0)
	assert_true(merge_time >= 0.0, "a heavy and a light body merge")
	assert_eq(world.bodies().size(), 1)
	if world.bodies().size() != 1:
		return
	var merged := world.bodies()[0]
	print("    heavy + light merged into %s" % [merged.tags])
	assert_eq(kinds.asked, [merged.tags] as Array[Array],
		"the merged ring was tuned once, with its merged tags")
	_assert_masses(merged, KindWorld.HEAVY if merged.tag() == &"heavy" else 1.0,
		"the merged %s body" % merged.tag())

func test_a_body_placed_under_a_world_is_tuned_with_no_tags() -> void:
	var source := Node2D.new()
	source.name = "Placed"
	var kinds := KindWorld.new()
	kinds.name = "World"
	source.add_child(kinds)
	kinds.owner = source
	var placed := Goo2D.new()
	placed.name = "Body"
	placed.radius = 40.0
	placed.position = Vector2(arena.inner_left() + 300.0, arena.floor_y() - 200.0)
	kinds.add_child(placed)
	placed.owner = source
	var packed := PackedScene.new()
	assert_eq(packed.pack(source), OK)
	source.free()

	var scene := packed.instantiate()
	add_child(scene)
	var placed_world := scene.get_node("World") as KindWorld
	assert_not_null(placed_world, "the World node is a KindWorld")
	if placed_world == null:
		return
	var body := scene.get_node("World/Body") as Goo2D
	assert_gt(body.particle_count(), 0, "the body built itself in _ready()")
	assert_eq(placed_world.asked, [[]] as Array[Array], "it asked tuning_for() once, with no tags")
	assert_eq(body.tags, [])
	_assert_masses(body, 1.0, "a placed body")
	await wait_frames(2)

# The least height of `body`'s bead loop over its height at rest, over
# `frames` physics frames, and the least area() / target_area alike.
static func _squash(heights: Array[float], areas: Array[float], body: Goo2D, rest_height: float) -> void:
	var points := body.bead_points()
	var top := INF
	var bottom := -INF
	for point: Vector2 in points:
		top = minf(top, point.y)
		bottom = maxf(bottom, point.y)
	heights.append((bottom - top) / rest_height)
	areas.append(body.area() / body.target_area)

func test_a_stiffer_world_squashes_less_on_landing() -> void:
	# Two worlds side by side over the same floor: a plain one and a StiffWorld,
	# each dropping a 60 px square from 300 px above the floor.
	_use(GooWorld2D.new())
	var plain := world
	var stiff := StiffWorld.new()
	add_child(stiff)
	var drop := 300.0
	var bodies: Array[Goo2D] = [
		plain.spawn(60.0, Vector2(arena.inner_left() + 250.0, arena.floor_y() - drop - 60.0), GooShape.regular(4, 60.0)),
		stiff.spawn(60.0, Vector2(arena.inner_left() + 800.0, arena.floor_y() - drop - 60.0), GooShape.regular(4, 60.0)),
	]
	var rest_heights: Array[float] = []
	for body: Goo2D in bodies:
		var points := body.bead_points()
		var top := INF
		var bottom := -INF
		for point: Vector2 in points:
			top = minf(top, point.y)
			bottom = maxf(bottom, point.y)
		rest_heights.append(bottom - top)
	var heights: Array[Array] = [[] as Array[float], [] as Array[float]]
	var areas: Array[Array] = [[] as Array[float], [] as Array[float]]
	for _frame: int in Engine.physics_ticks_per_second:
		await get_tree().physics_frame
		for i: int in bodies.size():
			_squash(heights[i], areas[i], bodies[i], rest_heights[i])
	var least_height: Array[float] = [heights[0].min(), heights[1].min()]
	var least_area: Array[float] = [areas[0].min(), areas[1].min()]
	print("    60 px square dropped 300 px, least height / rest height: plain %.3f, 4x stiff %.3f"
		% [least_height[0], least_height[1]])
	print("    least area / target area: plain %.3f, 4x stiff %.3f" % [least_area[0], least_area[1]])
	for i: int in bodies.size():
		assert_lt(bodies[i].center().y, arena.floor_y(), "the square landed on the floor")
		assert_lt(least_height[i], 0.99, "the square was squashed at all")
	assert_gt(least_height[1], least_height[0], "the stiffer square squashes less")
	assert_gt(least_height[1] - least_height[0], 0.01, "by a measurable margin")

# --- identity through splits, merges and trims -------------------------------

## What the world announced since _watch_identity() (or since it was last
## cleared), in order: one entry per signal, { "signal": its name, its
## arguments by name, "live": the ids bodies() listed when it fired, "old": for
## each of `watched`, [is_instance_valid, is_inside_tree, id] when it fired }.
var announced: Array[Dictionary] = []
## The bodies about to go whose state a handler sees, logged in `announced`.
var watched: Array[Goo2D] = []

# Logs the world's identity signals, the old ones and count_changed into
# `announced`. Call once per world.
func _watch_identity() -> void:
	world.body_split.connect(func(parent_id: int, pieces: Array[Goo2D]) -> void:
		_note({ "signal": "body_split", "parent_id": parent_id, "pieces": pieces.duplicate() }))
	world.bodies_merged.connect(func(ids: PackedInt32Array, body: Goo2D) -> void:
		_note({ "signal": "bodies_merged", "ids": ids, "body": body }))
	world.body_trimmed.connect(func(old_id: int, body: Goo2D) -> void:
		_note({ "signal": "body_trimmed", "old_id": old_id, "body": body }))
	world.split.connect(func(radius_a: float, radius_b: float, _position: Vector2) -> void:
		_note({ "signal": "split", "radius_a": radius_a, "radius_b": radius_b }))
	world.merged.connect(func(radius: float, _position: Vector2) -> void:
		_note({ "signal": "merged", "radius": radius }))
	world.trimmed.connect(func(radius: float, _position: Vector2) -> void:
		_note({ "signal": "trimmed", "radius": radius }))
	world.count_changed.connect(func(count: int) -> void:
		_note({ "signal": "count_changed", "count": count }))
	world.body_spawned.connect(func(body: Goo2D) -> void:
		_note({ "signal": "body_spawned", "body": body, "in_tree": body.is_inside_tree(), "id": body.id,
			"beads": body.particle_count(), "skin_stiffness": float(body.tuning.get("skin_stiffness", 0.0)),
			"tags": body.tags.duplicate(), "color": body.color }))

# Appends `entry` to `announced` with what a handler sees at that moment.
func _note(entry: Dictionary) -> void:
	var live: Array[int] = []
	for body: Goo2D in world.bodies():
		live.append(body.id)
	entry["live"] = live
	var seen: Array = []
	for body: Variant in watched:
		if is_instance_valid(body):
			seen.append([true, (body as Goo2D).is_inside_tree(), (body as Goo2D).id])
		else:
			seen.append([false, false, -2])
	entry["old"] = seen
	announced.append(entry)

# The names of the signals in `announced`, in order.
func _announced_names() -> Array[String]:
	var names: Array[String] = []
	for entry: Dictionary in announced:
		names.append(String(entry["signal"]))
	return names

# How many times `signal_name` is in `announced`.
func _times(signal_name: String) -> int:
	return _announced_names().count(signal_name)

# The first entry of `signal_name` in `announced`, empty if none.
func _first(signal_name: String) -> Dictionary:
	for entry: Dictionary in announced:
		if entry["signal"] == signal_name:
			return entry
	return {}

# Checks that `signal_name`, a new signal, came right after the last
# count_changed (with `count`) and before the old signal `old_name`.
func _assert_announced_in_order(signal_name: String, old_name: String, count: int, label: String) -> void:
	var names := _announced_names()
	var at := names.find(signal_name)
	assert_gt(at, 0, "%s: %s is announced after count_changed" % [label, signal_name])
	if at <= 0:
		return
	assert_eq(names[at - 1], "count_changed", "%s: count_changed comes right before %s" % [label, signal_name])
	assert_eq(int(announced[at - 1]["count"]), count, "%s: with the new count" % label)
	assert_gt(names.find(old_name), at, "%s: %s's handler has run when %s's runs" % [label, signal_name, old_name])

func test_a_cut_announces_its_parents_id_and_its_pieces() -> void:
	_use(GooWorld2D.new())
	_watch_identity()
	var x := arena.inner_left() + 800.0
	var shapes: Array[GooShape] = [null, GooShape.regular(4, 60.0)]
	for shape: GooShape in shapes:
		var label := "round" if shape == null else "square"
		watched = []
		world.clear()
		await wait_frames(1)
		var body := _spawn_on_floor(60.0, x, BLUE, shape)
		await wait_frames(5)
		var parent_id := body.id
		assert_true(parent_id >= 0, "the %s body has an id" % label)
		watched = [body]
		announced.clear()
		var after := _cut_through(body)
		print("    a cut %s body announces %s" % [label, _announced_names()])
		assert_eq(_times("body_split"), 1, "the %s body's cut fires body_split once" % label)
		assert_eq(_times("split"), 1, "%s: and split once" % label)
		assert_eq(_times("body_trimmed"), 0, "%s: and no body_trimmed" % label)
		assert_eq(_times("bodies_merged"), 0, "%s: and no bodies_merged" % label)
		if _times("body_split") != 1:
			continue
		var entry := _first("body_split")
		assert_eq(int(entry["parent_id"]), parent_id, "%s: parent_id is the id the body had" % label)
		var pieces: Array = entry["pieces"]
		assert_eq(pieces.size(), 2, "%s: two pieces" % label)
		if pieces.size() != 2:
			continue
		var piece_a := pieces[0] as Goo2D
		var piece_b := pieces[1] as Goo2D
		for piece: Goo2D in [piece_a, piece_b]:
			assert_true(is_instance_valid(piece) and piece.is_inside_tree(), "%s: a piece is a live body" % label)
			assert_true(piece.id >= 0, "%s: a piece has an id" % label)
			assert_ne(piece.id, parent_id, "%s: a piece's id is not its parent's" % label)
			assert_true(after.has(piece), "%s: a piece is one of the bodies bodies() lists afterwards" % label)
		assert_ne(piece_a.id, piece_b.id, "%s: the pieces' ids differ" % label)
		assert_eq(after.size(), 2, "%s: bodies() lists the two pieces and nothing else" % label)
		_assert_announced_in_order("body_split", "split", 2, label)
		var old_split := _first("split")
		assert_almost_eq(float(old_split["radius_a"]), piece_a.radius, 0.0001,
			"%s: split still reports the first piece's radius" % label)
		assert_almost_eq(float(old_split["radius_b"]), piece_b.radius, 0.0001, "%s: and the second's" % label)
		# What body_split's handler saw.
		var live: Array[int] = entry["live"]
		assert_false(live.has(parent_id), "%s: the parent is not in bodies() for the handler" % label)
		assert_true(live.has(piece_a.id) and live.has(piece_b.id), "%s: its pieces are" % label)
		assert_eq(entry["old"], [[true, false, parent_id]],
			"%s: the handler can read the parent's id, out of the tree but not freed yet" % label)
	await wait_frames(5)

func test_a_merge_announces_the_two_old_ids_and_the_merged_body() -> void:
	_use(GooWorld2D.new())
	_watch_identity()
	var x := arena.inner_left() + 800.0
	var a := world.spawn(40.0, Vector2(x - 38.0, arena.floor_y() - 40.0))
	var b := world.spawn(40.0, Vector2(x + 38.0, arena.floor_y() - 40.0))
	var old_ids: Array[int] = [a.id, b.id]
	watched = [a, b]
	announced.clear()
	var merge_time := await _watch_merge(MERGE_TIMEOUT + 1.0)
	print("    two 40 px bodies: %s, announced %s"
		% ["merged after %.2f s" % merge_time if merge_time >= 0.0 else "no merge", _announced_names()])
	assert_true(merge_time >= 0.0, "two 40 px round bodies merge")
	assert_eq(_times("bodies_merged"), 1, "the merge fires bodies_merged once")
	assert_eq(_times("merged"), 1, "and merged once")
	assert_eq(_times("body_split"), 0, "and no body_split")
	if _times("bodies_merged") != 1 or world.bodies().size() != 1:
		fail("one bodies_merged and one body left, got %d and %d" % [_times("bodies_merged"), world.bodies().size()])
		return
	var entry := _first("bodies_merged")
	var ids: PackedInt32Array = entry["ids"]
	var sorted_ids := ids.duplicate()
	sorted_ids.sort()
	var sorted_old := old_ids.duplicate()
	sorted_old.sort()
	assert_eq(sorted_ids, PackedInt32Array(sorted_old), "ids holds exactly the two old ids")
	var body := entry["body"] as Goo2D
	assert_eq(body, world.bodies()[0], "body is the one body left")
	assert_true(body.id >= 0 and not old_ids.has(body.id), "the merged body has a fresh id")
	_assert_announced_in_order("bodies_merged", "merged", 1, "a merge")
	assert_almost_eq(float(_first("merged")["radius"]), body.radius, 0.0001, "merged still reports the merged radius")
	assert_eq(entry["live"], [body.id] as Array[int], "for the handler, bodies() lists the merged body alone")
	assert_eq(entry["old"], [[true, false, old_ids[0]], [true, false, old_ids[1]]],
		"the handler can read the old bodies' ids, out of the tree but not freed yet")

# A point inside the bead loop of `blob`, 0.7 bead radii in from its
# right-most bead centre, level with its centre: a vertical cut through it
# leaves a crumb on the right (as test_split.gd's _near_right_edge()).
static func _near_right_edge(blob: Goo2D) -> Vector2:
	var right := -INF
	for point: Vector2 in blob.bead_points():
		right = maxf(right, point.x)
	return Vector2(right - 0.7 * blob.bead_radius(), blob.center().y)

func test_a_trim_announces_the_old_id_and_the_rebuilt_body() -> void:
	timeout_sec = 10.0
	_use(GooWorld2D.new())
	_watch_identity()
	var radius := 40.0
	var body := world.spawn(radius, Vector2(arena.inner_left() + 220.0, arena.floor_y() - radius))
	for _frame: int in 3 * Engine.physics_ticks_per_second:
		await get_tree().physics_frame
		if body.settled:
			break
	assert_true(body.settled, "the body settles within 3 s")
	if not body.settled:
		return
	var old_id := body.id
	watched = [body]
	announced.clear()
	var tip := _near_right_edge(body)
	assert_eq(world.pierce(tip, Vector2.UP), 1, "the settled body is cut")
	await wait_frames(2)
	print("    a tip near a settled %.0f px body's edge: announced %s" % [radius, _announced_names()])
	assert_eq(_times("body_trimmed"), 1, "the trim fires body_trimmed once")
	assert_eq(_times("trimmed"), 1, "and trimmed once")
	assert_eq(_times("body_split"), 0, "and no body_split")
	assert_eq(_times("split"), 0, "and no split")
	if _times("body_trimmed") != 1 or world.bodies().size() != 1:
		fail("one body_trimmed and one body left, got %d and %d" % [_times("body_trimmed"), world.bodies().size()])
		return
	var entry := _first("body_trimmed")
	assert_eq(int(entry["old_id"]), old_id, "old_id is the id the body had")
	var made := entry["body"] as Goo2D
	assert_eq(made, world.bodies()[0], "body is the one body left")
	assert_true(made.id >= 0 and made.id != old_id, "the trimmed body has a fresh id")
	_assert_announced_in_order("body_trimmed", "trimmed", 1, "a trim (the count unchanged)")
	assert_almost_eq(float(_first("trimmed")["radius"]), made.radius, 0.0001, "trimmed still reports the radius")
	assert_eq(entry["live"], [made.id] as Array[int], "for the handler, bodies() lists the trimmed body alone")
	assert_eq(entry["old"], [[true, false, old_id]],
		"the handler can read the old body's id, out of the tree but not freed yet")

# --- body_spawned -------------------------------------------------------------

# Checks a body_spawned entry of `announced`: when its handler ran, the body
# was in the tree, registered (an id, listed by bodies()), built (its beads)
# and tuned by the world (its skin stiffness `factor` times GooTuning's for its
# shape: StiffWorld's STIFFNESS, 1 for a plain world).
func _assert_spawned_entry(entry: Dictionary, factor: float, label: String) -> void:
	var body := entry["body"] as Goo2D
	assert_true(bool(entry["in_tree"]), "%s: in the tree when announced" % label)
	assert_true(int(entry["id"]) >= 0, "%s: registered, with an id" % label)
	var live: Array[int] = entry["live"]
	assert_true(live.has(int(entry["id"])), "%s: listed by bodies() for the handler" % label)
	assert_gt(int(entry["beads"]), 0, "%s: its ring built" % label)
	if is_instance_valid(body):
		var plain := float(GooTuning.tuning_for(body.shape)["skin_stiffness"])
		assert_almost_eq(float(entry["skin_stiffness"]), factor * plain, 0.000001 * plain,
			"%s: tuned by the world" % label)

# The index of the first entry of `signal_name` in `announced` whose `key` is
# `value`; -1 if none.
func _index_of(signal_name: String, key: String, value: Variant) -> int:
	for i: int in announced.size():
		if announced[i]["signal"] == signal_name and announced[i].get(key) == value:
			return i
	return -1

func test_spawn_announces_the_body_built_and_tuned() -> void:
	_use(StiffWorld.new())
	_watch_identity()
	var body := world.spawn(40.0, Vector2(arena.inner_left() + 800.0, arena.floor_y() - 40.0), null,
		[&"earth"])
	assert_eq(_times("body_spawned"), 1, "spawn() announces its body once")
	if _times("body_spawned") != 1:
		return
	var entry := _first("body_spawned")
	assert_eq(entry["body"], body, "the body spawn() returns")
	_assert_spawned_entry(entry, StiffWorld.STIFFNESS, "a spawned body")
	assert_eq(entry["tags"], [&"earth"], "with its tags set")
	assert_eq(_announced_names(), ["body_spawned", "count_changed"] as Array[String],
		"before the count it changes")

func test_a_cut_announces_its_pieces_as_spawned_before_body_split() -> void:
	_use(StiffWorld.new())
	_watch_identity()
	var x := arena.inner_left() + 800.0
	var shapes: Array[GooShape] = [null, GooShape.regular(4, 60.0)]
	for shape: GooShape in shapes:
		var label := "round" if shape == null else "square"
		world.clear()
		await wait_frames(1)
		var body := _spawn_on_floor(60.0, x, BLUE, shape)
		await wait_frames(5)
		announced.clear()
		_cut_through(body)
		assert_eq(_times("body_split"), 1, "the %s body is cut" % label)
		assert_eq(_times("body_spawned"), 2, "%s: each piece is announced once" % label)
		if _times("body_split") != 1 or _times("body_spawned") != 2:
			continue
		var at_split := _announced_names().find("body_split")
		var pieces: Array = announced[at_split]["pieces"]
		for piece: Variant in pieces:
			var at := _index_of("body_spawned", "body", piece)
			assert_true(at >= 0, "%s: a piece of body_split was announced" % label)
			if at < 0:
				continue
			assert_lt(at, at_split, "%s: before body_split" % label)
			_assert_spawned_entry(announced[at], StiffWorld.STIFFNESS, "a piece of the %s body" % label)
			assert_eq(announced[at]["color"], BLUE, "%s: with its parent's colour already" % label)
	await wait_frames(5)

func test_a_merge_announces_the_merged_body_as_spawned_before_bodies_merged() -> void:
	_use(StiffWorld.new())
	_watch_identity()
	var x := arena.inner_left() + 800.0
	world.spawn(40.0, Vector2(x - 38.0, arena.floor_y() - 40.0), null, [&"earth"])
	world.spawn(40.0, Vector2(x + 38.0, arena.floor_y() - 40.0), null, [&"water"])
	announced.clear()
	var merge_time := await _watch_merge(MERGE_TIMEOUT + 1.0)
	assert_true(merge_time >= 0.0, "two 40 px round bodies merge")
	assert_eq(_times("bodies_merged"), 1)
	assert_eq(_times("body_spawned"), 1, "the merged body is announced once")
	if _times("bodies_merged") != 1 or _times("body_spawned") != 1:
		return
	var merged_entry := _first("bodies_merged")
	var at := _index_of("body_spawned", "body", merged_entry["body"])
	assert_true(at >= 0, "the body of bodies_merged was announced")
	if at < 0:
		return
	assert_lt(at, _announced_names().find("bodies_merged"), "before bodies_merged")
	_assert_spawned_entry(announced[at], StiffWorld.STIFFNESS, "the merged body")
	var tags: Array = announced[at]["tags"]
	assert_eq(tags.size(), 2, "with the merged tags set: %s" % [tags])
	assert_true(tags.has(&"earth") and tags.has(&"water"), "the pair's union: %s" % [tags])

func test_a_trim_announces_the_rebuilt_body_as_spawned_before_body_trimmed() -> void:
	timeout_sec = 10.0
	_use(GooWorld2D.new())
	_watch_identity()
	var body := world.spawn(40.0, Vector2(arena.inner_left() + 220.0, arena.floor_y() - 40.0), null,
		[&"earth"])
	for _frame: int in 3 * Engine.physics_ticks_per_second:
		await get_tree().physics_frame
		if body.settled:
			break
	assert_true(body.settled, "the body settles within 3 s")
	if not body.settled:
		return
	announced.clear()
	assert_eq(world.pierce(_near_right_edge(body), Vector2.UP), 1, "the settled body is cut")
	await wait_frames(2)
	assert_eq(_times("body_trimmed"), 1, "the body is trimmed")
	assert_eq(_times("body_spawned"), 1, "the rebuilt body is announced once")
	if _times("body_trimmed") != 1 or _times("body_spawned") != 1:
		return
	var trimmed_entry := _first("body_trimmed")
	var at := _index_of("body_spawned", "body", trimmed_entry["body"])
	assert_true(at >= 0, "the body of body_trimmed was announced")
	if at < 0:
		return
	assert_lt(at, _announced_names().find("body_trimmed"), "before body_trimmed")
	_assert_spawned_entry(announced[at], 1.0, "the trimmed body")
	assert_eq(announced[at]["tags"], [&"earth"], "with its tags set")

func test_bodies_placed_under_a_world_are_announced_as_spawned() -> void:
	# A scene as the editor saves one: a StiffWorld with a round Goo2D and a
	# `sides = 4` square under it, every node owned by the scene's root.
	var source := Node2D.new()
	source.name = "Placed"
	var stiff := StiffWorld.new()
	stiff.name = "World"
	source.add_child(stiff)
	stiff.owner = source
	var sides: Array[int] = [0, 4]
	for i: int in sides.size():
		var placed := Goo2D.new()
		placed.name = "Body%d" % i
		placed.radius = 40.0
		placed.sides = sides[i]
		placed.position = Vector2(arena.inner_left() + 300.0 + 500.0 * i, arena.floor_y() - 200.0)
		stiff.add_child(placed)
		placed.owner = source
	var packed := PackedScene.new()
	assert_eq(packed.pack(source), OK)
	source.free()

	var scene := packed.instantiate()
	world = scene.get_node("World") as GooWorld2D
	_watch_identity()
	add_child(scene)
	await wait_frames(2)
	assert_eq(_times("body_spawned"), 2, "each placed body is announced once")
	for name: String in ["World/Body0", "World/Body1"]:
		var at := _index_of("body_spawned", "body", scene.get_node(name))
		assert_true(at >= 0, "%s was announced" % name)
		if at >= 0:
			_assert_spawned_entry(announced[at], StiffWorld.STIFFNESS, name)

# --- may_split() -------------------------------------------------------------

func test_a_body_that_may_not_split_stays_whole_on_a_blade_tip() -> void:
	_use(NoSplitWorld.new())
	var no_split := world as NoSplitWorld
	var trims: Array[float] = []
	world.trimmed.connect(func(radius: float, _position: Vector2) -> void: trims.append(radius))
	var blade := arena.get_node("FloorBlade") as Blade
	var tips := PackedVector2Array([blade.tip()])
	var axes := PackedVector2Array([blade.axis()])
	var body := world.spawn(50.0, blade.tip())
	assert_true(GooLoop.point_in_loop(blade.tip(), body.bead_points()), "the tip starts inside the body")
	assert_eq(world.cut_at_tips(tips, axes), 0, "cut_at_tips() requests no cut of a body that may not split")
	assert_gt(no_split.asked, 0, "may_split() was asked")
	var asked := no_split.asked
	assert_eq(world.pierce(blade.tip(), blade.axis()), 0, "pierce() requests none either")
	assert_gt(no_split.asked, asked, "pierce() asked may_split() too")
	for _frame: int in 10:
		await get_tree().physics_frame
		world.cut_at_tips(tips, axes)
	await wait_frames(2)
	print("    50 px body on the floor blade's tip, may_split() false: asked %d times, %d splits, %d trims, %d bodies"
		% [no_split.asked, splits, trims.size(), world.bodies().size()])
	assert_true(is_instance_valid(body) and body.is_inside_tree(), "the body is alive")
	assert_eq(world.bodies(), [body] as Array[Goo2D], "it is still the one body")
	assert_eq(splits, 0, "it was not cut")
	assert_eq(trims.size(), 0, "it was not trimmed")
	assert_almost_eq(body.radius, 50.0, 0.001, "its radius is unchanged")

func test_a_body_that_may_not_split_lands_on_the_wedge_whole() -> void:
	timeout_sec = 15.0
	# Two worlds over the one arena, each piercing the wedge's apex as the demo's
	# Game does, each dropping the big body test_split.gd splits on the wedge:
	# the default world splits it, the NoSplitWorld does not.
	var control := WedgeWorld.new()
	control.arena = arena
	_use(control)
	var no_split := NoSplitWorld.new()
	no_split.arena = arena
	add_child(no_split)
	var trims: Array[float] = []
	no_split.trimmed.connect(func(radius: float, _position: Vector2) -> void: trims.append(radius))
	var no_split_splits: Array[int] = [0]
	no_split.split.connect(func(_a: float, _b: float, _position: Vector2) -> void: no_split_splits[0] += 1)
	var radius := GooTuning.radius_at(0.9)
	var apex := arena.wedge_apex()
	var x := minf(apex.x, arena.inner_right() - radius - 2.0)
	var start := Vector2(x, apex.y - 200.0 - radius)
	control.spawn(radius, start)
	var body := no_split.spawn(radius, start)
	var split_time := -1.0
	var peak_speed := 0.0
	for frame: int in 3 * Engine.physics_ticks_per_second:
		await get_tree().physics_frame
		if split_time < 0.0 and splits > 0:
			split_time = float(frame + 1) / Engine.physics_ticks_per_second
		if is_instance_valid(body) and body.is_inside_tree():
			for velocity: Vector2 in body.bead_velocities():
				peak_speed = maxf(peak_speed, velocity.length())
	await wait_frames(2)
	print("    %.1f px body dropped on the wedge: the default world %s; may_split() false: asked %d times, %d splits, %d trims, %d bodies, peak bead speed %.0f px/s (cap %.0f)"
		% [radius, "split it after %.2f s" % split_time if split_time >= 0.0 else "did not split it",
			no_split.asked, no_split_splits[0], trims.size(), no_split.bodies().size(), peak_speed,
			GooTuning.MAX_BEAD_SPEED])
	assert_true(split_time >= 0.0, "the default world splits the body on the wedge within 3 s")
	assert_gt(no_split.asked, 0, "the goo asked to split the other one")
	assert_true(is_instance_valid(body) and body.is_inside_tree(), "the body that may not split is alive")
	assert_eq(no_split.bodies(), [body] as Array[Goo2D], "and still the one body")
	assert_eq(no_split_splits[0] + trims.size(), 0, "it was neither cut nor trimmed")
	assert_almost_eq(body.radius, radius, 0.001, "its radius is unchanged")
	assert_lt(peak_speed, GooTuning.MAX_BEAD_SPEED, "its beads stay under the speed cap")

func test_may_split_chooses_which_bodies_split_but_not_a_direct_cut() -> void:
	_use(SelectiveWorld.new())
	var floor_blade := arena.get_node("FloorBlade") as Blade
	var wall_blade := arena.get_node("WallBlade") as Blade
	var red := world.spawn(50.0, floor_blade.tip())
	red.color = RED
	var blue := world.spawn(50.0, wall_blade.tip())
	blue.color = BLUE
	var tips := PackedVector2Array([floor_blade.tip(), wall_blade.tip()])
	var axes := PackedVector2Array([floor_blade.axis(), wall_blade.axis()])
	assert_eq(world.cut_at_tips(tips, axes), 1, "a cut is requested for the red body only")
	await wait_frames(2)
	assert_false(is_instance_valid(red) and red.is_inside_tree(), "the red body was cut")
	assert_eq(splits, 1, "into two pieces")
	assert_true(is_instance_valid(blue) and blue.is_inside_tree(), "the blue body was not")
	assert_true(world.bodies().has(blue))
	assert_eq(world.bodies().size(), 3)
	_cut_through(blue)
	await wait_frames(2)
	assert_false(is_instance_valid(blue) and blue.is_inside_tree(), "a direct cut() of the blue body cuts it")
	assert_eq(splits, 2)
	assert_eq(world.bodies().size(), 4)

# --- gravity_scale -----------------------------------------------------------

# True if the gravity `world`'s kernel steps with is GooTuning's times `scale`.
static func _kernel_gravity_is(world_under_test: GooWorld2D, scale: float) -> bool:
	var gravity: Vector2 = world_under_test.kernel().solver()["gravity"]
	var expected: Vector2 = GooTuning.solver_settings()["gravity"] * scale
	return gravity.is_equal_approx(expected)

func test_half_gravity_halves_a_free_fall() -> void:
	# Two worlds side by side over the one arena: a plain one and one at half
	# gravity, each dropping a 40 px body from 600 px above the floor.
	_use(GooWorld2D.new())
	var plain := world
	var half := GooWorld2D.new()
	half.gravity_scale = 0.5
	add_child(half)
	assert_eq(plain.gravity_scale, 1.0, "the default scale is 1")
	assert_true(_kernel_gravity_is(plain, 1.0), "a plain world's kernel has GooTuning's gravity")
	assert_true(_kernel_gravity_is(half, 0.5),
		"a scale set before the world entered the tree is applied when its kernel is made: %s"
			% half.kernel().solver()["gravity"])
	var y := arena.floor_y() - 600.0
	var bodies: Array[Goo2D] = [
		plain.spawn(40.0, Vector2(arena.inner_left() + 300.0, y)),
		half.spawn(40.0, Vector2(arena.inner_left() + 800.0, y)),
	]
	var starts: Array[float] = [bodies[0].center().y, bodies[1].center().y]
	for _frame: int in 30:
		await get_tree().physics_frame
	var fall_full := bodies[0].center().y - starts[0]
	var fall_half := bodies[1].center().y - starts[1]
	print("    40 px bodies falling for 30 frames: %.1f px at full gravity, %.1f px at half (%.3f of it)"
		% [fall_full, fall_half, fall_half / fall_full])
	assert_gt(fall_full, 50.0, "the plain world's body fell")
	assert_lt(fall_full, 600.0 - 40.0, "without reaching the floor")
	assert_gt(fall_half / fall_full, 0.4, "the half-gravity body falls about half as far")
	assert_lt(fall_half / fall_full, 0.6, "the half-gravity body falls about half as far")

func test_gravity_scale_set_at_run_time_is_sent_at_once() -> void:
	_use(GooWorld2D.new())
	assert_true(_kernel_gravity_is(world, 1.0))
	world.gravity_scale = 0.25
	assert_true(_kernel_gravity_is(world, 0.25),
		"the solver's gravity changes as soon as the scale is set: %s" % world.kernel().solver()["gravity"])
	world.gravity_scale = 0.0
	assert_true(_kernel_gravity_is(world, 0.0))
	var body := world.spawn(40.0, Vector2(arena.inner_left() + 800.0, arena.floor_y() - 400.0))
	await wait_frames(2)
	var start := body.center()
	for _frame: int in 30:
		await get_tree().physics_frame
	var moved := body.center().distance_to(start)
	print("    40 px body in mid air at gravity_scale 0: moved %.3f px in 30 frames" % moved)
	assert_lt(moved, 1.0, "at scale 0 a body hangs where it is")
	world.gravity_scale = 1.0
	assert_true(_kernel_gravity_is(world, 1.0), "back to GooTuning's gravity")
	var lone := GooTuning.make_kernel()
	assert_eq(lone.solver()["gravity"], GooTuning.solver_settings()["gravity"],
		"GooTuning.make_kernel()'s gravity is GooTuning's, whatever a world's scale")
