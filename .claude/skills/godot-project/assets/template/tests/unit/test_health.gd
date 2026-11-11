extends TestCase
## Unit tests for the Health example. Shows the patterns: fresh fixture per test,
## value assertions, and capturing signal emissions.

var health: Health
var emitted: Array = []

func before_each() -> void:
	health = Health.new(10)
	emitted.clear()
	health.changed.connect(func(current: int, maximum: int) -> void: emitted.append([current, maximum]))

func test_starts_full() -> void:
	assert_eq(health.current, 10)
	assert_true(health.is_alive())

func test_damage_reduces_and_emits() -> void:
	health.damage(3)
	assert_eq(health.current, 7)
	assert_eq(emitted, [[7, 10]])

func test_damage_clamps_at_zero_and_emits_died() -> void:
	var died := [false]
	health.died.connect(func() -> void: died[0] = true)
	health.damage(50)
	assert_eq(health.current, 0)
	assert_true(died[0], "died should fire when health reaches 0")
	assert_false(health.is_alive())

func test_heal_does_not_exceed_maximum() -> void:
	health.damage(4)
	health.heal(100)
	assert_eq(health.current, 10)

func test_ignores_nonpositive_amounts() -> void:
	health.damage(0)
	health.damage(-5)
	health.heal(-1)
	assert_eq(health.current, 10)
	assert_eq(emitted.size(), 0, "no signal for no-op calls")
