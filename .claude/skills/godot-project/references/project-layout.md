# Godot 4 project layout and settings

## Contents
1. Folder conventions
2. project.godot settings to set early
3. Scenes and scripts
4. Git hygiene
5. Export

## 1. Folder conventions

```
project.godot
.godot-version              pinned release for tools/install_godot.sh and CI
scenes/<feature>/           player/player.tscn, enemies/slime.tscn, ui/hud.tscn
src/<feature>/              scripts for those scenes plus plain logic classes
src/autoload/               autoload singletons (event bus, game state, settings)
data/                       .tres resources (stats, levels, dialogue) and their Resource scripts
assets/                     art, audio, fonts (imported by Godot; .import files live beside them)
addons/                     plugins; validate_scripts skips one holding VENDORED.md or .gdignore
tests/unit/ tests/integration/ tests/framework/
tools/                      check.py, validate_scripts.gd, install_godot.sh, other headless tools
```

Keep a scene and its script in matching folders rather than one giant `scripts/`
folder; the tree then mirrors the game's features. Small projects can start flat
(`scenes/`, `src/`) and split by feature once a folder passes about ten files.

## 2. project.godot settings to set early

Edit in the editor when possible; these are the sections you will see and can
also add by hand (keep section headers alphabetical, Godot rewrites the file).

```ini
[autoload]
GameState="*res://src/autoload/game_state.gd"   ; leading * = singleton node

[input]
move_left={
"deadzone": 0.2,
"events": [Object(InputEventKey,"physical_keycode":65), Object(InputEventKey,"physical_keycode":4194319)]
}
move_right={
"deadzone": 0.2,
"events": [Object(InputEventKey,"physical_keycode":68), Object(InputEventKey,"physical_keycode":4194321)]
}
move_up={
"deadzone": 0.2,
"events": [Object(InputEventKey,"physical_keycode":87), Object(InputEventKey,"physical_keycode":4194320)]
}
move_down={
"deadzone": 0.2,
"events": [Object(InputEventKey,"physical_keycode":83), Object(InputEventKey,"physical_keycode":4194322)]
}
jump={
"deadzone": 0.5,
"events": [Object(InputEventKey,"physical_keycode":32), Object(InputEventJoypadButton,"button_index":0)]
}

[layer_names]
2d_physics/layer_1="world"
2d_physics/layer_2="player"
2d_physics/layer_3="enemies"

[display]
window/size/viewport_width=640
window/size/viewport_height=360
window/stretch/mode="canvas_items"   ; pixel art: also rendering/textures/canvas_textures/default_texture_filter=0

[rendering]
renderer/rendering_method="gl_compatibility"   ; 2D and web-friendly; forward_plus for 3D desktop
```

The minimal `Object(InputEventKey,"physical_keycode":N)` form above is verified
headless (Godot 4.6 loads it; `InputMap.action_get_events` returns the events;
`Input.parse_input_event` drives the action). The editor writes a longer form
with every property; both work. Key codes: A=65 D=68 S=83 W=87 Space=32
Enter=4194309 Escape=4194305 Left=4194319 Up=4194320 Right=4194321 Down=4194322;
any `KEY_*` constant's value can be printed with `godot --headless -s` and a
one-line script, or looked up in the `@GlobalScope.Key` docs. Lock the format in
with a test that asserts `InputMap.has_action("move_left")`. Name physics layers
before using them so `collision_layer` values in scenes stay readable.

Autoloads named in project.godot are available in headless test runs too.

## 3. Scenes and scripts

- One script per scene root; the script's `class_name` matches the scene
  (`Player` for `player.tscn`).
- `@export` what a designer configures; `@onready var x: Type = $Path` for
  child references; `%UniqueName` for nodes marked unique to survive reparenting.
- Emit signals upward, call methods downward, never reach across siblings.
- Logic that does not need the tree (rules, stats, inventories, state machines)
  goes in `RefCounted`/`Resource` classes so tests can create it with `.new()`.
- Resource subclasses in `data/` with `@export` fields give designers editable
  `.tres` files and give tests plain objects.

## 4. Git hygiene

Ignore `.godot/`, exported builds, and `junit.xml`. Commit `*.import`, `*.uid`,
`export_presets.cfg` (unless it holds signing secrets: keep those in
environment variables and use `--export-release` with them set). Normalize line
endings with `.gitattributes` so Godot's LF-only files do not churn on Windows.

Large binary assets: consider Git LFS for anything over a few MB
(`git lfs track "*.png" "*.ogg"`).

## 5. Export

Export presets live in `export_presets.cfg`, created from the editor. Headless
export needs export templates for the same version: download from
`https://github.com/godotengine/godot/releases/download/<ver>/Godot_v<ver>_export_templates.tpz`
and unpack into `~/.local/share/godot/export_templates/<ver>/`. Then
`godot --headless --path . --export-release "<preset name>" build/out`.
Wire it into CI as a separate job only once the game has something to ship.
