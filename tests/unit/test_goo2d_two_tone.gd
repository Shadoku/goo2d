extends TestCase
## A body's two-tone state as plain values (Goo2D, unbuilt: no ring, no world):
## division_in_rest() maps a division given in the world (an axis and a point
## it passes through) into a body's rest space from its centre and rotation;
## dominant_color() is the colour owning the larger share (the primary on a
## tie); color_set() is the colours a body is drawn in, in an order of their
## own, so two bodies drawn alike compare equal whichever colour is primary,
## COLOR_BY_SIZE resolved; is_two_tone() is a second colour being set.

const RED := Color(0.9, 0.2, 0.25)
const BLUE := Color(0.2, 0.35, 0.9)
const GREEN := Color(0.22, 0.84, 0.46)

func _body(colour: Color, second: Color = Goo2D.COLOR_BY_SIZE, offset: float = 0.0,
		radius: float = 40.0) -> Goo2D:
	var body := Goo2D.new()
	autofree(body)
	body.radius = radius
	body.color = colour
	body.second_color = second
	body.division_offset = offset
	return body

func _assert_vec_near(actual: Vector2, expected: Vector2, tolerance: float, msg: String) -> void:
	assert_true(actual.distance_to(expected) <= tolerance,
		"%s: expected %s, got %s" % [msg, expected, actual])

# --- division_in_rest() ------------------------------------------------------

func test_division_in_rest_unrotated_is_the_world_axis_and_the_dot_product() -> void:
	var division := Goo2D.division_in_rest(Vector2.RIGHT, Vector2(110.0, 50.0), Vector2(100.0, 40.0), 0.0)
	_assert_vec_near(division["axis"], Vector2.RIGHT, 1e-6, "the axis as in the world")
	assert_almost_eq(division["offset"], 10.0, 1e-5, "the offset: (through - centre) · axis")

func test_division_in_rest_turns_the_axis_back_by_the_rotation() -> void:
	# A body turned by 90° sees a world axis along +x along −y in its rest space
	# (the rest frame is the world's turned by the rotation).
	var division := Goo2D.division_in_rest(Vector2.RIGHT, Vector2(100.0, 40.0), Vector2(100.0, 40.0), PI / 2.0)
	_assert_vec_near(division["axis"], Vector2.UP, 1e-6, "+x turned by −90°")
	assert_almost_eq(division["offset"], 0.0, 1e-5, "through the centre: half and half")
	var turned := Goo2D.division_in_rest(Vector2(0.0, 1.0), Vector2.ZERO, Vector2.ZERO, -PI / 4.0)
	_assert_vec_near(turned["axis"], Vector2.DOWN.rotated(PI / 4.0), 1e-6, "+y turned by +45°")

func test_division_in_rest_offset_survives_the_rotation() -> void:
	var centre := Vector2(300.0, 200.0)
	var axis := Vector2(1.0, 1.0).normalized()
	var through := centre + axis * 12.0 + axis.orthogonal() * 30.0
	for angle: float in [0.0, 0.7, -2.1, PI]:
		var division := Goo2D.division_in_rest(axis, through, centre, angle)
		assert_almost_eq(division["offset"], 12.0, 1e-4, "the offset at a rotation of %.2f" % angle)
		# Back into the world, the axis is the one given.
		_assert_vec_near((division["axis"] as Vector2).rotated(angle), axis, 1e-5,
			"the rest axis turned by %.2f is the world's" % angle)

func test_division_in_rest_normalises_the_world_axis() -> void:
	var division := Goo2D.division_in_rest(Vector2(0.0, -5.0), Vector2(0.0, -3.0), Vector2.ZERO, 0.0)
	_assert_vec_near(division["axis"], Vector2.UP, 1e-6, "a unit axis")
	assert_almost_eq(division["offset"], 3.0, 1e-5)

# --- is_two_tone(), dominant_color(), second_base_color() -------------------

func test_a_body_is_two_tone_once_it_has_a_second_colour() -> void:
	assert_false(_body(RED).is_two_tone(), "one colour")
	assert_true(_body(RED, BLUE).is_two_tone(), "two colours")
	assert_false(_body(RED, Goo2D.COLOR_BY_SIZE).is_two_tone(), "COLOR_BY_SIZE as second: none")

func test_dominant_color_is_the_larger_share() -> void:
	assert_eq(_body(RED).dominant_color(), RED, "one colour: that one")
	assert_eq(_body(RED, BLUE, 0.0).dominant_color(), RED, "a tie (half and half): the primary")
	assert_eq(_body(RED, BLUE, 6.0).dominant_color(), RED,
		"the division shifted toward the second's side: the primary owns more")
	assert_eq(_body(RED, BLUE, -6.0).dominant_color(), BLUE, "shifted the other way: the second")
	var by_size := _body(Goo2D.COLOR_BY_SIZE, Goo2D.COLOR_BY_SIZE, 0.0, 50.0)
	assert_eq(by_size.dominant_color(), GooTuning.color(50.0), "COLOR_BY_SIZE resolved")

func test_second_base_color_is_the_second_or_the_body_colour() -> void:
	assert_eq(_body(RED, BLUE).second_base_color(), BLUE)
	assert_eq(_body(RED).second_base_color(), RED, "a single-coloured body: its own")

# --- color_set() -------------------------------------------------------------

func test_color_set_is_equal_across_the_pairs_orderings() -> void:
	assert_eq(_body(RED, BLUE).color_set(), _body(BLUE, RED).color_set(), "red|blue is blue|red")
	assert_eq(_body(RED, BLUE, 5.0).color_set(), _body(RED, BLUE, -5.0).color_set(),
		"the division's place does not matter")
	assert_eq(_body(RED, BLUE).color_set().size(), 2)
	assert_ne(_body(RED, BLUE).color_set(), _body(RED, GREEN).color_set(), "another pair")
	assert_ne(_body(RED, BLUE).color_set(), _body(RED).color_set(), "two colours are not one")

func test_color_set_of_one_colour_holds_it_once() -> void:
	assert_eq(_body(RED).color_set(), PackedColorArray([RED]))
	assert_eq(_body(RED, RED).color_set(), PackedColorArray([RED]), "a colour twice is that colour")

func test_color_set_resolves_color_by_size() -> void:
	var by_size := _body(Goo2D.COLOR_BY_SIZE, Goo2D.COLOR_BY_SIZE, 0.0, 50.0)
	var fixed := _body(GooTuning.color(50.0))
	assert_eq(by_size.color_set(), PackedColorArray([GooTuning.color(50.0)]), "by its size")
	assert_eq(by_size.color_set(), fixed.color_set(), "the same as its size's colour set by hand")
