class_name DropController
extends RefCounted
## Decides what the player launches next, when, and how fast: rolls the next
## size and shape, enforces a cooldown between launches, and turns the aim
## offset into a launch velocity. The shape is rolled right after the size,
## from the same RNG, so a seeded controller always rolls the same drops.

## Range of radii, in px at GooTuning.unit 1, the player drops (the smallest
## is GooTuning.MIN_RADIUS); drop_min_radius() and drop_max_radius() are the
## range at the goo's unit.
const DROP_MIN_RADIUS := 28.0
const DROP_MAX_RADIUS := 48.0
## Launch velocity per pixel of aim offset (mouse minus launch point), in 1/s.
const LAUNCH_GAIN := 3.0
## Fastest launch, in px/s. Fast enough that a blob thrown flat to the left
## from the upper-right launch point reaches the far-left floor: the ~860 px
## fall takes ~1.3 s and small blobs carry linear damp (GooTuning.linear_damp()).
const MAX_LAUNCH_SPEED := 1600.0
## Shapes the player drops, by number of sides (0: a round blob), in the order
## cycle_shape() steps through them: round, square, triangle.
const SHAPE_SIDES: Array[int] = [0, 4, 3]
## How often each of SHAPE_SIDES is rolled; they add up to 1. Round blobs stay
## the common drop, the shapes a spice.
const SHAPE_WEIGHTS: Array[float] = [0.6, 0.2, 0.2]

## Radius, in px, of the next drop; always within drop_min_radius() ..
## drop_max_radius().
var next_radius: float
## Shape of the next drop, at next_radius (GooShape.radius() is
## next_radius); one of SHAPE_SIDES. Read it before take(), which rolls the
## next one.
var next_shape: GooShape
## Seconds until the next drop is allowed; 0 when ready.
var cooldown_remaining: float = 0.0
## Cooldown started by each drop, in seconds.
var cooldown_seconds: float

var _rng: RandomNumberGenerator
# Index into SHAPE_SIDES of next_shape.
var _shape_index: int = 0

func _init(cooldown_s: float = 0.5, rng: RandomNumberGenerator = null) -> void:
	cooldown_seconds = cooldown_s
	if rng == null:
		_rng = RandomNumberGenerator.new()
		_rng.randomize()
	else:
		_rng = rng
	_roll_next()

## Advances the cooldown by `delta` seconds.
func tick(delta: float) -> void:
	cooldown_remaining = maxf(cooldown_remaining - delta, 0.0)

## True when the cooldown has run out.
func can_drop() -> bool:
	return cooldown_remaining <= 0.0

## Returns the radius to drop, starts the cooldown and rolls the next radius
## and shape (read next_shape first for the shape of this drop).
## Returns -1.0 and changes nothing while cooling down.
func take() -> float:
	if not can_drop():
		return -1.0
	var radius: float = next_radius
	cooldown_remaining = cooldown_seconds
	_roll_next()
	return radius

## Swaps next_shape for the next of SHAPE_SIDES (after the last, the first),
## at the same radius. Uses no random numbers, so the drops rolled after it are
## the ones that would have come anyway.
func cycle_shape() -> void:
	_shape_index = (_shape_index + 1) % SHAPE_SIDES.size()
	next_shape = shape_with_sides(SHAPE_SIDES[_shape_index], next_radius)

## Radius, in px, of the smallest drop: the goo's smallest size,
## GooTuning.min_radius() (DROP_MIN_RADIUS at unit 1).
static func drop_min_radius() -> float:
	return GooTuning.min_radius()

## Radius, in px, of the largest drop: DROP_MAX_RADIUS at the goo's length
## unit (GooTuning.unit).
static func drop_max_radius() -> float:
	return DROP_MAX_RADIUS * GooTuning.unit

## A drop radius uniform in [drop_min_radius(), drop_max_radius()], rolled
## with `rng`.
static func random_drop_radius(rng: RandomNumberGenerator) -> float:
	return rng.randf_range(drop_min_radius(), drop_max_radius())

## The drop shape of `sides` sides (0: round) at the equivalent radius
## `radius`: a regular polygon resting on a side.
static func shape_with_sides(sides: int, radius: float) -> GooShape:
	return GooShape.round(radius) if sides == 0 else GooShape.regular(sides, radius)

## Velocity for a launch aimed `offset` px away from the launch point:
## `offset * LAUNCH_GAIN`, no faster than MAX_LAUNCH_SPEED (direction kept), and
## never upward (y >= 0), since the arena has no ceiling.
func launch_velocity(offset: Vector2) -> Vector2:
	var velocity := (offset * LAUNCH_GAIN).limit_length(MAX_LAUNCH_SPEED)
	velocity.y = maxf(velocity.y, 0.0)
	return velocity

# Rolls next_radius, then next_shape at that radius.
func _roll_next() -> void:
	next_radius = random_drop_radius(_rng)
	_shape_index = _roll_shape_index()
	next_shape = shape_with_sides(SHAPE_SIDES[_shape_index], next_radius)

# An index into SHAPE_SIDES, picked with SHAPE_WEIGHTS.
func _roll_shape_index() -> int:
	var roll := _rng.randf()
	for i: int in SHAPE_WEIGHTS.size():
		roll -= SHAPE_WEIGHTS[i]
		if roll < 0.0:
			return i
	return SHAPE_WEIGHTS.size() - 1
