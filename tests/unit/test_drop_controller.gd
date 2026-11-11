extends TestCase
## Unit tests for DropController: size and shape rolling, cooldown and launch
## velocity.

var rng: RandomNumberGenerator
var drop: DropController

func before_each() -> void:
	rng = RandomNumberGenerator.new()
	rng.seed = 12345
	drop = DropController.new(0.5, rng)

func after_each() -> void:
	GooTuning.unit = 1.0

func _assert_droppable(radius: float) -> void:
	assert_true(radius >= DropController.DROP_MIN_RADIUS and radius <= DropController.DROP_MAX_RADIUS,
		"radius %.2f outside the drop range" % radius)

func test_starts_ready_with_droppable_radius() -> void:
	assert_true(drop.can_drop())
	assert_almost_eq(drop.cooldown_remaining, 0.0)
	_assert_droppable(drop.next_radius)

func test_next_radius_always_droppable_and_varies() -> void:
	var seen: Dictionary[int, bool] = {}
	for i: int in 200:
		_assert_droppable(drop.next_radius)
		seen[roundi(drop.next_radius)] = true
		drop.take()
		drop.tick(1.0)
	assert_gt(seen.size(), 10, "drop radii should be continuous, not a few fixed sizes")

func test_take_returns_previous_next_radius() -> void:
	for i: int in 20:
		var expected: float = drop.next_radius
		assert_eq(drop.take(), expected)
		drop.tick(1.0)

func test_cooldown_blocks_and_tick_releases() -> void:
	drop.take()
	assert_false(drop.can_drop())
	assert_almost_eq(drop.cooldown_remaining, 0.5)
	drop.tick(0.3)
	assert_false(drop.can_drop())
	assert_almost_eq(drop.cooldown_remaining, 0.2)
	drop.tick(0.3)
	assert_true(drop.can_drop())
	assert_almost_eq(drop.cooldown_remaining, 0.0)

func test_take_while_cooling_returns_minus_one_and_keeps_next() -> void:
	drop.take()
	var pending: float = drop.next_radius
	assert_eq(drop.take(), -1.0)
	assert_eq(drop.next_radius, pending)
	assert_almost_eq(drop.cooldown_remaining, 0.5, 0.00001, "a refused take must not restart the cooldown")

func test_creates_own_rng_when_none_given() -> void:
	var own := DropController.new()
	_assert_droppable(own.next_radius)
	assert_true(own.can_drop())

func test_launch_velocity_scales_offset_by_gain() -> void:
	var v := drop.launch_velocity(Vector2(30.0, 40.0))
	assert_almost_eq(v.x, 30.0 * DropController.LAUNCH_GAIN, 0.001)
	assert_almost_eq(v.y, 40.0 * DropController.LAUNCH_GAIN, 0.001)

func test_launch_velocity_capped_and_keeps_direction() -> void:
	var offset := Vector2(900.0, 1200.0)
	var v := drop.launch_velocity(offset)
	assert_almost_eq(v.length(), DropController.MAX_LAUNCH_SPEED, 0.01)
	assert_almost_eq(v.normalized().dot(offset.normalized()), 1.0, 0.0001, "capping must not turn the launch")
	var sideways := drop.launch_velocity(Vector2(-5000.0, 0.0))
	assert_almost_eq(sideways.x, -DropController.MAX_LAUNCH_SPEED, 0.01)
	assert_almost_eq(sideways.y, 0.0)

func test_launch_velocity_never_upward() -> void:
	var v := drop.launch_velocity(Vector2(50.0, -80.0))
	assert_almost_eq(v.y, 0.0)
	assert_almost_eq(v.x, 50.0 * DropController.LAUNCH_GAIN, 0.001, "an upward aim keeps its sideways part")
	var straight_up: Vector2 = drop.launch_velocity(Vector2(0.0, -100.0))
	assert_eq(straight_up, Vector2.ZERO)

func test_launch_velocity_zero_offset_is_zero() -> void:
	assert_eq(drop.launch_velocity(Vector2.ZERO), Vector2.ZERO)

func test_launch_velocity_does_not_touch_cooldown_or_next() -> void:
	var pending: float = drop.next_radius
	drop.launch_velocity(Vector2(10.0, 10.0))
	assert_true(drop.can_drop())
	assert_eq(drop.next_radius, pending)

# Side count of `shape` as DropController.SHAPE_SIDES counts them (0: round).
func _sides(shape: GooShape) -> int:
	return 0 if shape.is_round() else shape.outline.size()

func test_next_shape_is_rolled_at_the_next_radius() -> void:
	for i: int in 50:
		assert_not_null(drop.next_shape)
		assert_has(DropController.SHAPE_SIDES, _sides(drop.next_shape))
		assert_almost_eq(drop.next_shape.radius(), drop.next_radius, 0.001, "the shape has the drop's size")
		drop.take()
		drop.tick(1.0)

func test_shape_weights_match_the_rolls() -> void:
	assert_eq(DropController.SHAPE_SIDES.size(), DropController.SHAPE_WEIGHTS.size())
	assert_eq(DropController.SHAPE_SIDES, [0, 4, 3] as Array[int], "round, square, triangle")
	var total := 0.0
	for weight: float in DropController.SHAPE_WEIGHTS:
		total += weight
	assert_almost_eq(total, 1.0, 0.0001)
	var counts: Dictionary[int, int] = {}
	var rolls := 3000
	for i: int in rolls:
		var sides := _sides(drop.next_shape)
		counts[sides] = counts.get(sides, 0) + 1
		drop.take()
		drop.tick(1.0)
	for index: int in DropController.SHAPE_SIDES.size():
		var sides := DropController.SHAPE_SIDES[index]
		var share := float(counts.get(sides, 0)) / rolls
		print("    %d sides: %.3f of %d rolls" % [sides, share, rolls])
		assert_almost_eq(share, DropController.SHAPE_WEIGHTS[index], 0.04, "share of %d-sided drops" % sides)

func test_same_seed_rolls_the_same_drops() -> void:
	var other_rng := RandomNumberGenerator.new()
	other_rng.seed = 12345
	var other := DropController.new(0.5, other_rng)
	for i: int in 30:
		assert_eq(other.next_radius, drop.next_radius)
		assert_eq(_sides(other.next_shape), _sides(drop.next_shape))
		drop.take()
		other.take()
		drop.tick(1.0)
		other.tick(1.0)

func test_take_keeps_the_shape_readable_until_the_next_roll() -> void:
	var shape := drop.next_shape
	var radius := drop.next_radius
	assert_eq(drop.take(), radius)
	assert_ne(drop.next_shape, shape, "take() rolls a new shape")
	var pending := drop.next_shape
	assert_eq(drop.take(), -1.0)
	assert_eq(drop.next_shape, pending, "a refused take keeps the next shape")

func test_cycle_shape_steps_through_every_shape_without_rolling() -> void:
	var other_rng := RandomNumberGenerator.new()
	other_rng.seed = 12345
	var other := DropController.new(0.5, other_rng)
	var radius := drop.next_radius
	var start := DropController.SHAPE_SIDES.find(_sides(drop.next_shape))
	for step: int in DropController.SHAPE_SIDES.size() + 1:
		var expected := DropController.SHAPE_SIDES[(start + step) % DropController.SHAPE_SIDES.size()]
		assert_eq(_sides(drop.next_shape), expected, "after %d cycles" % step)
		assert_eq(drop.next_radius, radius, "cycling keeps the radius")
		assert_almost_eq(drop.next_shape.radius(), radius, 0.001)
		drop.cycle_shape()
	# Cycling used no random numbers: the next drops are the uncycled controller's.
	drop.take()
	other.take()
	assert_eq(drop.next_radius, other.next_radius)
	assert_eq(_sides(drop.next_shape), _sides(other.next_shape))

func test_drop_radius_stays_in_range() -> void:
	var seeded_rng := RandomNumberGenerator.new()
	seeded_rng.seed = 4242
	var lowest := INF
	var highest := -INF
	for i: int in 200:
		var radius := DropController.random_drop_radius(seeded_rng)
		assert_true(radius >= DropController.DROP_MIN_RADIUS and radius <= DropController.DROP_MAX_RADIUS,
			"drop radius %.2f out of range" % radius)
		lowest = minf(lowest, radius)
		highest = maxf(highest, radius)
	assert_lt(highest - lowest, DropController.DROP_MAX_RADIUS - DropController.DROP_MIN_RADIUS + 0.0001)
	assert_gt(highest - lowest, 0.5 * (DropController.DROP_MAX_RADIUS - DropController.DROP_MIN_RADIUS),
		"200 rolls should spread over the drop range")

func test_drop_range_follows_the_goo_unit() -> void:
	assert_eq(DropController.drop_min_radius(), DropController.DROP_MIN_RADIUS)
	assert_eq(DropController.drop_max_radius(), DropController.DROP_MAX_RADIUS)
	GooTuning.unit = 0.5
	assert_almost_eq(DropController.drop_min_radius(), GooTuning.min_radius(), 0.000001)
	assert_almost_eq(DropController.drop_max_radius(), 0.5 * DropController.DROP_MAX_RADIUS, 0.000001)
	for i: int in 100:
		var radius := DropController.random_drop_radius(rng)
		assert_true(radius >= 14.0 and radius <= 24.0, "radius %.2f outside the half-size drop range" % radius)
