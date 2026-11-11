extends TestCase
## Two-tone merges (GooWorld2D.two_tone_merges): a body merged from two of
## different colours is drawn in both, each on the side its parent came from,
## the division between them crossing the line between the parents' centres at
## their area ratio (the bigger parent owns the bigger side), fixed in the
## merged body's rest space. The colours are merged_colors()' (the same
## combination merges as usual; any other pair takes the two dominant colours;
## two per body at most). The merged body is two-tone before anyone hears of
## it (body_spawned), flashes in both colours, and while the pair is pulled
## together neither parent's tint moves when the result is two-tone. With the
## switch off, merged_color() rules as before and nothing is two-tone.
## Played in the demo's arena with plain worlds: nothing here is the demo's.

const MERGE_TIMEOUT: float = 2.0
const RED := Color(0.9, 0.2, 0.25)
const BLUE := Color(0.2, 0.35, 0.9)
const GREEN := Color(0.22, 0.84, 0.46)

## A world with two-tone merges on whose bodies merge whatever their colours
## and sizes, up to GooTuning.max_radius().
class AnyColourWorld extends GooWorld2D:
	func _init() -> void:
		two_tone_merges = true

	func may_merge(a: Goo2D, b: Goo2D) -> bool:
		return GooTuning.merged_radius(a.radius, b.radius) <= GooTuning.max_radius()

## The same rule with two-tone merges off and a merged colour of its own.
class GreenWorld extends GooWorld2D:
	func may_merge(a: Goo2D, b: Goo2D) -> bool:
		return GooTuning.merged_radius(a.radius, b.radius) <= GooTuning.max_radius()

	func merged_color(_a: Goo2D, _b: Goo2D) -> Color:
		return GREEN

var arena: Arena
var world: GooWorld2D
## What body_spawned saw of the merged body, while both parents were still there.
var seen: Dictionary = {}

func before_each() -> void:
	arena = (load("res://scenes/arena.tscn") as PackedScene).instantiate() as Arena
	add_child(arena)

func _use(made: GooWorld2D) -> void:
	world = made
	add_child(world)
	seen = {}
	world.body_spawned.connect(_on_spawned)

# Records, for a merged body (one registered while two other bodies are
# merging), its state and the merging parents' centres by colour.
func _on_spawned(body: Goo2D) -> void:
	var parents: Array[Goo2D] = []
	for other: Goo2D in world.bodies():
		if other != body and other.merging:
			parents.append(other)
	if parents.size() != 2:
		return
	seen = {
		"two_tone": body.is_two_tone(),
		"color": body.color,
		"second": body.second_color,
		"axis_world": body.division_axis.rotated(body.ring_rotation()),
		"offset": body.division_offset,
		"tint": body.get_tint(),
		"second_tint": body.get_second_tint(),
		"centres": { parents[0].color: parents[0].center(), parents[1].color: parents[1].center() },
	}

# A body of `radius` in `colour` resting on the floor with its centre at `x`.
func _on_floor(radius: float, x: float, colour: Color) -> Goo2D:
	var body := world.spawn(radius, Vector2(x, arena.floor_y() - radius))
	body.color = colour
	return body

# A body of `radius`, `colour` and `second` (the division across +x in rest
# space at `offset`), unbuilt and outside any world: merged_colors() reads only
# its colours and division.
func _loose(colour: Color, second: Color = Goo2D.COLOR_BY_SIZE, offset: float = 0.0,
		radius: float = 40.0) -> Goo2D:
	var body := Goo2D.new()
	autofree(body)
	body.radius = radius
	body.color = colour
	body.second_color = second
	body.division_offset = offset
	return body

# Steps physics until the world has one body or `seconds` pass; true on a merge.
func _until_merged(seconds: float) -> bool:
	for _frame: int in roundi(seconds * Engine.physics_ticks_per_second):
		await get_tree().physics_frame
		if world.bodies().size() == 1:
			return true
	return false

# --- merged_colors(), the rules ----------------------------------------------

func test_two_bodies_of_one_colour_merge_into_that_colour() -> void:
	_use(AnyColourWorld.new())
	assert_eq(world.merged_colors(_loose(RED), _loose(RED)), PackedColorArray([RED]))

func test_two_colours_merge_into_both_the_first_on_the_first_bodys_side() -> void:
	_use(AnyColourWorld.new())
	assert_eq(world.merged_colors(_loose(RED), _loose(BLUE)), PackedColorArray([RED, BLUE]))
	assert_eq(world.merged_colors(_loose(BLUE), _loose(RED)), PackedColorArray([BLUE, RED]))

func test_the_same_two_colours_merge_into_that_pair() -> void:
	_use(AnyColourWorld.new())
	assert_eq(world.merged_colors(_loose(RED, BLUE, 3.0), _loose(RED, BLUE, -2.0)),
		PackedColorArray([RED, BLUE]), "red|blue and red|blue: red|blue, a's dominant on a's side")
	assert_eq(world.merged_colors(_loose(RED, BLUE, -3.0), _loose(BLUE, RED, 0.0)),
		PackedColorArray([BLUE, RED]), "blue dominant in a: blue on a's side, red kept")

func test_two_combinations_merge_into_their_dominant_colours() -> void:
	_use(AnyColourWorld.new())
	assert_eq(world.merged_colors(_loose(RED, BLUE, 4.0), _loose(GREEN)),
		PackedColorArray([RED, GREEN]), "red|blue (red dominant) and green: red|green")
	assert_eq(world.merged_colors(_loose(GREEN), _loose(RED, BLUE, -4.0)),
		PackedColorArray([GREEN, BLUE]), "green and red|blue (blue dominant): green|blue")

func test_equal_dominant_colours_merge_into_one() -> void:
	_use(AnyColourWorld.new())
	assert_eq(world.merged_colors(_loose(RED, BLUE, 1.0), _loose(RED, GREEN, 1.0)),
		PackedColorArray([RED]), "red|blue and red|green, both red dominant: red")
	assert_eq(world.merged_colors(_loose(RED, BLUE, 1.0), _loose(RED)), PackedColorArray([RED]),
		"red|blue (red dominant) and red: red")

func test_two_bodies_coloured_by_size_merge_by_size() -> void:
	# Two bodies both left at COLOR_BY_SIZE keep today's rule: the merged body
	# is coloured by its own size, not by the two sizes it came from.
	_use(AnyColourWorld.new())
	var small := _loose(Goo2D.COLOR_BY_SIZE, Goo2D.COLOR_BY_SIZE, 0.0, 30.0)
	var big := _loose(Goo2D.COLOR_BY_SIZE, Goo2D.COLOR_BY_SIZE, 0.0, 60.0)
	assert_eq(world.merged_colors(small, big), PackedColorArray([Goo2D.COLOR_BY_SIZE]))
	assert_eq(world.merged_colors(small, _loose(RED)), PackedColorArray([GooTuning.color(30.0), RED]),
		"a body by size and a coloured one: its size's colour, resolved, and the other")

# --- a merge in the world ----------------------------------------------------

# Merges a red body of `red_radius` (spawned first: the pair's `a`) and a blue
# one of `blue_radius` side by side on the floor; returns the merged body.
func _merge_red_and_blue(red_radius: float, blue_radius: float) -> Goo2D:
	var x := arena.inner_left() + 800.0
	var gap := (red_radius + blue_radius) * 0.97
	_on_floor(red_radius, x - gap / 2.0, RED)
	_on_floor(blue_radius, x + gap / 2.0, BLUE)
	var merged := await _until_merged(MERGE_TIMEOUT)
	assert_true(merged, "the pair merges within %.1f s" % MERGE_TIMEOUT)
	return world.bodies()[0] if merged else null

func test_a_red_and_a_blue_body_merge_into_a_two_tone_body() -> void:
	_use(AnyColourWorld.new())
	var body := await _merge_red_and_blue(60.0, 40.0)
	if body == null:
		return
	assert_true(body.is_two_tone(), "both colours")
	assert_eq(body.color, RED, "the first body's colour is the primary")
	assert_eq(body.second_color, BLUE)
	assert_false(seen.is_empty(), "body_spawned saw the merged body with its parents")
	if seen.is_empty():
		return
	assert_true(seen["two_tone"], "body_spawned sees the merged body already two-tone")
	var centres: Dictionary = seen["centres"]
	var red_to_blue := (centres[BLUE] as Vector2 - centres[RED] as Vector2).normalized()
	var axis: Vector2 = seen["axis_world"]
	print("    the division's axis in the world: %s; red to blue: %s" % [axis, red_to_blue])
	assert_gt(axis.dot(red_to_blue), 0.97, "the axis points from red's side to blue's in the world")
	assert_gt(float(seen["offset"]), 0.0, "the bigger (red) parent owns the bigger side")
	assert_eq(body.dominant_color(), RED)

func test_the_smaller_first_body_owns_the_smaller_side() -> void:
	_use(AnyColourWorld.new())
	var body := await _merge_red_and_blue(40.0, 60.0)
	if body == null or seen.is_empty():
		fail("no merge seen")
		return
	assert_eq(body.color, RED)
	assert_lt(float(seen["offset"]), 0.0, "the division shifted toward red: blue owns more")
	assert_eq(body.dominant_color(), BLUE)

func test_the_merged_body_flashes_in_both_colours_then_shows_them() -> void:
	_use(AnyColourWorld.new())
	var body := await _merge_red_and_blue(50.0, 50.0)
	if body == null or seen.is_empty():
		fail("no merge seen")
		return
	assert_ne(seen["tint"], RED, "the primary starts flashed toward white")
	assert_ne(seen["second_tint"], BLUE, "and so does the second")
	assert_gt((seen["second_tint"] as Color).b, BLUE.b - 0.001, "the second flashes from near white")
	await wait_seconds(GooTuning.MERGE_FLASH + 0.1)
	assert_eq(body.get_tint(), body.base_color(), "after the flash: the primary")
	assert_eq(body.get_second_tint(), body.second_base_color(), "and the second colour")

func test_a_two_tone_result_leaves_the_parents_tints_alone_while_they_merge() -> void:
	_use(AnyColourWorld.new())
	var x := arena.inner_left() + 800.0
	var red := _on_floor(50.0, x - 48.0, RED)
	var blue := _on_floor(50.0, x + 48.0, BLUE)
	var merging_frames := 0
	for _frame: int in roundi(MERGE_TIMEOUT * Engine.physics_ticks_per_second):
		await get_tree().physics_frame
		if world.bodies().size() == 1:
			break
		if red.merging:
			merging_frames += 1
			assert_eq(red.get_tint(), RED, "red keeps its colour while pulled")
			assert_eq(blue.get_tint(), BLUE, "blue too")
	assert_gt(merging_frames, 0, "the pair was seen merging")

func test_a_single_coloured_result_still_blends_the_parents() -> void:
	# red|blue (red dominant) and red merge into red: the pair is blended
	# toward it as before, both colours of the two-tone parent.
	_use(AnyColourWorld.new())
	var x := arena.inner_left() + 800.0
	var a := _on_floor(50.0, x - 48.0, RED)
	a.set_two_tone(RED, BLUE, Vector2.RIGHT, 2.0)
	_on_floor(50.0, x + 48.0, RED)
	var blended := false
	for _frame: int in roundi(MERGE_TIMEOUT * Engine.physics_ticks_per_second):
		await get_tree().physics_frame
		if world.bodies().size() == 1:
			break
		if a.merging and a.get_second_tint() != BLUE:
			blended = true
			assert_eq(a.get_tint(), RED, "the primary blends toward red: stays red")
	assert_true(blended, "the second colour blends toward the merged colour")
	assert_eq(world.bodies().size(), 1)
	if world.bodies().size() == 1:
		assert_false(world.bodies()[0].is_two_tone(), "red|blue and red make a red body")
		assert_eq(world.bodies()[0].color, RED)

func test_with_the_switch_off_merged_color_rules_and_nothing_is_two_tone() -> void:
	_use(GreenWorld.new())
	assert_false(world.two_tone_merges, "off by default")
	var body := await _merge_red_and_blue(50.0, 40.0)
	if body == null:
		return
	assert_false(body.is_two_tone(), "one colour")
	assert_eq(body.color, GREEN, "merged_color() decides it")
	await wait_seconds(GooTuning.MERGE_FLASH + 0.1)
	assert_eq(body.get_tint(), GREEN)

func test_with_the_switch_off_a_two_tone_parent_makes_a_single_coloured_body() -> void:
	_use(GreenWorld.new())
	var x := arena.inner_left() + 800.0
	var big := _on_floor(60.0, x - 48.0, RED)
	big.set_two_tone(RED, BLUE, Vector2.RIGHT, 0.0)
	_on_floor(40.0, x + 48.0, RED)
	var merged := await _until_merged(MERGE_TIMEOUT)
	assert_true(merged)
	if merged:
		assert_false(world.bodies()[0].is_two_tone(), "the bigger parent's second colour is not kept")
		assert_eq(world.bodies()[0].color, GREEN)
