# Testing Godot 4 headless

## Contents
1. How the runner works
2. TestCase API
3. Patterns: logic classes, scenes, signals, input, physics, resources, autoloads
4. What headless mode cannot test
5. Using GUT or gdUnit4 instead

## 1. How the runner works

`tests/framework/runner.gd` is a `SceneTree` script. `check.py` (or you) launches it:

```
godot --headless --path . -s tests/framework/runner.gd -- [--filter=<substr>] [--verbose] [--junit=<abs path>]
```

The runner re-launches Godot as a child process and reads its merged
stdout/stderr. The child discovers `res://tests/**/test_*.gd`, and for each
`test_*` method creates a fresh instance of the script, adds it to the tree, runs
`before_each`, the test, `after_each`, then frees it. Each phase has a timeout
(`timeout_sec`, default 10 s) implemented by polling `process_frame`, so
coroutine tests work.

The parent attributes every `ERROR`, `SCRIPT ERROR`, or `USER ERROR` block
printed between a test's start and end markers to that test and fails it. That
is the mechanism that turns "it printed an error but the assertion passed" into
a red test. Set `allow_errors = true` inside a test that provokes an error on
purpose.

Exit code 0 only when every test passed and no error was printed outside a test.
A run with zero tests fails, so an empty test folder is noticed.

Filters match against `tests/unit/test_health.gd::test_heal`, so `--filter=health`
selects a file and `--filter=::test_heal` a method.

## 2. TestCase API

`tests/framework/test_case.gd`, `class_name TestCase extends Node`.

Lifecycle: `before_each()`, `after_each()`; both may `await`.

Assertions return `bool` and record a failure message with `[file:line]` of the
caller. Every one takes an optional trailing `msg` for context.

| Method | Checks |
|---|---|
| `assert_true(cond)` / `assert_false(cond)` | boolean |
| `assert_eq(actual, expected)` / `assert_ne(a, b)` | equality via `==` (int and float compare across types) |
| `assert_almost_eq(a, b, tolerance = 1e-5)` | float closeness |
| `assert_gt(a, b)` / `assert_lt(a, b)` | ordering |
| `assert_null(v)` / `assert_not_null(v)` | null check |
| `assert_has(container, item)` | `Array`, `PackedStringArray`, `Dictionary` key, or `String` substring |
| `fail(msg)` | unconditional failure |
| `skip(reason)` | marks the test skipped (call at the top) |

Async helpers: `await wait_frames(n)`, `await wait_seconds(s)`,
`var fired: bool = await await_signal(sig, timeout := 1.0)`.

Settings: `timeout_sec` (may be set inside the test body), `allow_errors`.

Cleanup: the test instance is a Node; `add_child()` anything scene-like and it is
freed with the test. `autofree(obj)` frees non-RefCounted objects that are not
in the tree.

## 3. Patterns

### Logic classes (fastest, prefer these)

```gdscript
extends TestCase

var inv: Inventory

func before_each() -> void:
	inv = Inventory.new(3)  # GDScript has no keyword arguments

func test_rejects_when_full() -> void:
	for i in 3:
		assert_true(inv.add("potion"))
	assert_false(inv.add("potion"), "4th item must be rejected")
	assert_eq(inv.count("potion"), 3)
```

### Scenes and nodes

```gdscript
const PLAYER := preload("res://scenes/player/player.tscn")

func test_player_moves_right() -> void:
	var player: Player = PLAYER.instantiate()
	add_child(player)
	player.velocity = Vector2.ZERO
	player.apply_input(Vector2.RIGHT, 1.0 / 60.0)
	await wait_frames(2)  # let _physics_process run
	assert_gt(player.position.x, 0.0)
```

`@onready` variables are only set after `add_child`, so never touch them before.
Nodes that look up siblings with `$../Foo` fail in isolation; instantiate the
parent scene instead, or pass dependencies through `@export`/setters.

### Signals

Synchronous emission: connect a lambda that records into an Array (captured by
reference; a plain `var` would be copied).

```gdscript
var hits := []
enemy.hit.connect(func(dmg: int) -> void: hits.append(dmg))
enemy.take_hit(5)
assert_eq(hits, [5])
```

Emission later (timers, tweens, animations): `assert_true(await await_signal(door.opened, 2.0))`.

### Input

```gdscript
func test_jump_on_action() -> void:
	var ev := InputEventAction.new()
	ev.action = "jump"
	ev.pressed = true
	Input.parse_input_event(ev)
	await wait_frames(1)
	assert_true(player.is_jumping)
	# release so the next test starts clean
	ev.pressed = false
	Input.parse_input_event(ev)
	await wait_frames(1)
```
Actions must exist in the project's input map; `Input.is_action_pressed` reads
the same state the game does.

### Physics

Physics runs headless. Bodies need a frame or two after `add_child` before
collisions and `move_and_slide()` report anything. `await get_tree().physics_frame`
is available through `get_tree()` on the test node. Keep timing loose: assert on
direction or `>` thresholds rather than exact positions.

### Resources

`load("res://data/enemies/slime.tres")` works headless after `--import`. Test
that resources you depend on exist and have valid fields, so a broken `.tres`
fails a test instead of the game.

### Autoloads

Autoloads registered in project.godot are instantiated when the runner starts,
so `GameState.reset()` style calls work in tests. Reset autoload state in
`before_each`, because it persists across tests within a run.

### Deterministic randomness

Seed anything random (`seed(42)` or pass a `RandomNumberGenerator` into the
class under test) so failures reproduce.

## 4. What headless mode cannot test

No window, no rendering, no audio playback. Do not assert on rendered pixels,
viewport textures, `AudioStreamPlayer.playing` after autoplay, or window size.
Shaders compile but never run. `get_viewport().size` reflects the project's
configured size, not a real window. Timers, tweens, animations, physics,
navigation, input events, signals, resources, and file access all work.

`--quit-after N` (used by the smoke stage) runs the main scene for N frames, so
anything that must happen at boot is covered there. The smoke and render stages
also run each example scene, `examples/<name>/<name>.tscn`, the same way.

## 5. Using GUT or gdUnit4 instead

The bundled framework is deliberately small so the whole thing is readable.
Reach for GUT (`addons/gut`) or gdUnit4 (`addons/gdUnit4`) when the project
needs doubles/mocks, parameterized tests, or an editor test panel.

- GUT headless: `godot --headless -s addons/gut/gut_cmdln.gd -gdir=res://tests -gexit`
- gdUnit4 headless: `godot --headless -s addons/gdUnit4/bin/GdUnitCmdTool.gd --add res://tests`

Keep `tools/check.py` and point its `test` stage at the new command; the
import, validate, and smoke stages stay useful with any framework.
