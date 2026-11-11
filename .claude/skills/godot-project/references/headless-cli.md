# Godot 4 headless CLI

## Contents
1. Flags used by the kit
2. Errors, exit codes, and what to grep for
3. The .godot/ cache and sidecar files
4. Other useful commands

## 1. Flags used by the kit

| Command | Purpose |
|---|---|
| `godot --headless --path . --import` | import assets, rebuild `.godot/`, refresh the `class_name` cache and `*.uid` files. Run after adding scripts/resources outside the editor. |
| `godot --headless --path . --script res://file.gd --check-only` | parse and type-check one script; exit 1 with `SCRIPT ERROR` lines on failure |
| `godot --headless --path . -s res://tools/validate_scripts.gd` | compile every script in one process (much faster than per-file `--check-only`) |
| `godot --headless --path . -s res://tests/framework/runner.gd -- <args>` | run tests. Everything after `--` reaches the script via `OS.get_cmdline_user_args()` |
| `godot --headless --path . --quit-after 30` | run the main scene for 30 frames and exit (smoke test) |
| `godot --headless --path . res://scenes/x.tscn --quit-after 30` | same for a specific scene |
| `xvfb-run -a -s "-screen 0 1920x1080x24" godot --path . --rendering-driver opengl3 --audio-driver Dummy --quit-after 30` | the same with the real OpenGL renderer on a virtual screen: compiles and draws shaders (render stage). `--audio-driver Dummy` avoids an ALSA `ERROR` line |
| `godot --path . --editor` | open the editor (needs a display) |
| `godot --headless --version` | prints e.g. `4.6.stable.official.89cea1439` |

`-s`/`--script` scripts must `extends SceneTree` (or `MainLoop`) and implement
`_initialize()`. Inside `_initialize()` the root is not in the tree yet; `await
process_frame` before adding nodes. Call `quit(code)` to set the exit code.

## 2. Errors, exit codes, and what to grep for

Godot prints errors to stderr in fixed formats:

```
SCRIPT ERROR: Parse Error: Function "foo()" not found in base self.
          at: GDScript::reload (res://src/player.gd:42)
ERROR: Parameter "data.tree" is null.
   at: get_tree (scene/main/node.h:549)
USER ERROR: something you passed to push_error()
   at: my_func (res://src/x.gd:10)
          GDScript backtrace (most recent call first):
              [0] my_func (res://src/x.gd:10)
```

Rules the kit relies on:

- A script error at *load* time makes `--check-only` and `validate_scripts.gd`
  exit non-zero.
- A *runtime* script error (null access, bad call, `push_error`) does **not**
  change the exit code of a game run: `--quit-after` exits 0 after crashing
  `_ready`. Grep for `^(SCRIPT ERROR|SHADER ERROR|ERROR|USER ERROR):` and treat any
  hit as failure. `check.py` does this for the smoke and render stages; the test
  runner does it per test.
- `--headless` uses a dummy renderer that never compiles shaders, so a broken
  `.gdshader` passes every headless run. Only a run with a real renderer (under
  `xvfb-run` on a machine without a display) prints `SHADER ERROR` /
  `Shader compilation failed`, and only for shaders it actually draws.
- Continuation lines are indented; the first line has the message, the `at:`
  line has `file:line`, and Godot 4.5+ adds a GDScript backtrace.
- `print()` goes to stdout, errors to stderr; capture both (`2>&1`).
- Warnings (`WARNING:`) are informational. GDScript analyzer warnings such as
  unused variables are only reported inside the editor, not headless.

Godot's own exit codes: 0 ok, 1 script failed to load or `quit(1)`, 124 is what
`check.py` reports when a stage exceeds its timeout.

## 3. The .godot/ cache and sidecar files

- `.godot/` is machine-local; ignore it in git. `--import` recreates it.
- `.godot/global_script_class_cache.cfg` maps `class_name` to path. A new
  `class_name` is unknown to headless runs until `--import` runs, so `Could not
  find type "Foo"` right after creating `foo.gd` usually means "import first".
- Godot 4.4+ writes `script.gd.uid` next to every script and `.import` next to
  every asset. Commit both; they keep references stable when files move.
- Scene and resource files (`.tscn`, `.tres`) are text. Hand-written scenes can
  omit `uid=` attributes; the editor fills them in on save.
- Deleting or renaming a script without updating scenes that reference it
  produces `ERROR: Failed loading resource` at import; the validate and smoke
  stages will show which scene.

## 4. Other useful commands

| Command | Purpose |
|---|---|
| `godot --headless --path . --export-release "Linux" build/game.x86_64` | export (needs export templates installed and `export_presets.cfg`) |
| `godot --headless --path . --doctool docs --gdscript-docs res://src` | generate XML docs from `##` comments |
| `godot --headless --path . --script res://tools/some_tool.gd` | one-off tooling scripts (`EditorScript` needs the editor; use `SceneTree` scripts headless) |
| `godot --headless --path . --import --verbose` | see why an asset import fails |
| `godot --headless --path . -s res://tests/framework/runner.gd -- --junit=/abs/path.xml` | JUnit output for CI reporters |
