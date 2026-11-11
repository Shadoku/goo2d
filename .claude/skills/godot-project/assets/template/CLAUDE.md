# __PROJECT_NAME__ (Godot __GODOT_FEATURE__)

Godot 4 project set up for AI-assisted development: every change is verified by
`python3 tools/check.py`, which runs headless without the editor. Trust its
output over your own reasoning about whether code works.

## Commands

| What | Command |
|---|---|
| Everything (import, validate, tests, smoke, render) | `python3 tools/check.py` |
| Only the unit tests | `python3 tools/check.py --only test` |
| One test file or method | `python3 tools/check.py --only test --filter=health` |
| Fastest loop (no new files since last import) | `python3 tools/check.py --only test --no-import` |
| Full engine output | `python3 tools/check.py --verbose` |
| Compile shaders and draw a few frames with the real renderer (needs `xvfb-run`; the main scene, then each example) | `python3 tools/check.py --only render` |
| Run the game (needs a display) | `godot --path .` |
| Open the editor | `godot --path . --editor` |

`check.py` finds Godot via `$GODOT`, then `godot` on PATH, then
`~/.cache/godot/<version>/godot` (installed by `tools/install_godot.sh`, which
the Claude Code session hook and CI both use). The pinned version is in
`.godot-version`.

## The development loop

1. Before changing behaviour, write or adjust a test in `tests/` that describes
   the intended behaviour. Run it and watch it fail for the right reason.
2. Implement the change.
3. Run `python3 tools/check.py`. Read the output from the top: the first failing
   stage usually explains the rest (a parse error makes tests fail too).
4. Fix and re-run until the last line is `CHECK: PASS`.
5. Only then report done, quoting the `TESTS:` summary line.

Never say a change works without a passing check. If you cannot run Godot
(no binary, no network), say so explicitly instead of guessing.

## Reading failures

| Output | Meaning | Fix |
|---|---|---|
| `[FAIL] validate` + `SCRIPT ERROR: Parse Error ... (res://x.gd:12)` | script does not compile | fix the line; static typing errors count |
| `Could not find type "Foo" in the current scope` | `class_name` not in the cache yet, or typo | `check.py` runs `--import` first; if it persists the name is wrong |
| `[FAIL] tests/unit/test_x.gd::test_y` + `assert_eq failed: expected A, got B [file:line]` | assertion failure | look at the cited test line |
| `engine errors were printed during this test` | `push_error`, null access, missing node... during the test | the block below it has the message and backtrace |
| `timed out after 10.0s` | the test awaits something that never fires | check the signal or use `await_signal(sig, timeout)` |
| `[FAIL] smoke` / `[FAIL] smoke examples/<name>` | the main scene (or that example's `examples/<name>/<name>.tscn`) printed an error in its first frames | the block shows file:line; often a bad node path or missing resource |
| `[FAIL] render` (or `render examples/<name>`) + `SHADER ERROR: ... (res://x.gdshader:12)` / `Shader compilation failed` | a shader does not compile, or something errors only with the real OpenGL renderer | fix the cited shader line; headless stages cannot see this (they use a dummy renderer) |
| `[SKIP] render (no xvfb-run)` | Xvfb is not installed, so shaders were not compiled | `sudo apt-get install -y xvfb`; CI installs it |
| `test did not finish (inner process died)` | Godot crashed | run with `--verbose` and look for the last line before the crash |
| `[FAIL] build` + compiler output | `tools/build_native.sh` (the project's native code, if it has any) failed | fix the cited source line; run `bash tools/build_native.sh` for the full output |
| `[FAIL] build` + `cargo is not on PATH and the native library has not been built` | no Rust toolchain and no library from an earlier build (and no `tools/install_native.sh`, or it could not download one) | install Rust (https://rustup.rs) or copy a prebuilt library into place |
| `[SKIP] build (no cargo)` | no Rust toolchain, but a library from an earlier build is in place | fine as long as you did not change the native code |
| `[SKIP] build (no cargo; downloaded a prebuilt library ...)` | no Rust toolchain; `tools/install_native.sh` fetched a released library | fine as long as you did not change the native code (the release may lag the source) |
| `[FAIL] import` with exit code 134 and no message, on the first import of a fresh `.godot/` in a project with a GDExtension | Godot crashes at shutdown when it discovers extensions mid-import | `check.py` seeds `.godot/extension_list.cfg` (one `res://` path per `*.gdextension`, rewritten when one is missing) before importing; when running Godot by hand, write that file first or just import twice |

## Writing tests

- Files: `tests/**/test_*.gd`, `extends TestCase`, methods named `test_*`.
- A fresh instance runs per test method: `before_each` / `after_each` for fixtures.
- Assertions: `assert_eq`, `assert_ne`, `assert_true`, `assert_false`, `assert_null`,
  `assert_not_null`, `assert_almost_eq`, `assert_gt`, `assert_lt`, `assert_has`, `fail`, `skip`.
- Tests are Nodes in the tree: `add_child(node)` to test scenes; children are
  freed automatically. `await wait_frames(n)`, `await wait_seconds(s)`,
  `await await_signal(sig, timeout)` for async behaviour.
- Any `ERROR`/`SCRIPT ERROR` printed while a test runs fails it. Set
  `allow_errors = true` in a test that deliberately triggers one.
- Run without `check.py`: `godot --headless --path . -s tests/framework/runner.gd -- --filter=name --verbose`.

## Design for testability

- Put rules and state in plain `RefCounted` / `Resource` classes under `src/`
  (see `src/health.gd`). They need no scene tree and test in milliseconds.
- Keep node scripts thin: read input, call the logic class, update visuals.
- Communicate upward with signals; only call down into children directly.
- Headless mode has no rendering, audio output, or window: do not assert on
  pixels or sounds. It never compiles shaders either: a `.gdshader` error only
  shows in the `render` stage (`xvfb-run` + OpenGL), and only for shaders the
  main scene (or an example, `examples/<name>/<name>.tscn`: the smoke and render
  stages run each one too) actually draws in its first frames. Physics, timers, signals, input events
  (`Input.parse_input_event`), resources, and scene instantiation all work.

## Layout

```
project.godot          engine settings; main scene is scenes/main.tscn
.godot-version         pinned Godot release used by CI and the session hook
scenes/                .tscn files (one folder per feature as the game grows)
src/                   GDScript: logic classes and node scripts
tests/framework/       test runner + TestCase base (no addons required)
tests/unit/            fast tests of plain classes
tests/integration/     tests that instantiate scenes
tools/check.py         the one command to verify the project (its smoke and render stages also boot each example, examples/<name>/<name>.tscn)
tools/validate_scripts.gd   compiles every script; used by check.py
tools/install_godot.sh downloads the pinned Godot into ~/.cache/godot
.github/workflows/ci.yml    runs check.py on push and pull request
```

## Conventions

- GDScript: tabs, static types on every declaration, `class_name` for anything
  referenced from other scripts, `## doc comments` on exported properties.
- Commit `*.uid` and `*.import` sidecar files; never commit `.godot/`.
- After adding a `class_name` or a new resource, `check.py` re-imports
  automatically. If you run Godot by hand, run `godot --headless --import` first.
- Prefer editing `.tscn` files through small, reviewable diffs; they are text.
