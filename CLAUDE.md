# Goo2D (Godot 4.7)

Godot 4 project set up for AI-assisted development: every change is verified by
`python3 tools/check.py`, which runs headless without the editor. Trust its
output over your own reasoning about whether code works.

This repository is the home of the Goo2D addon (`addons/goo2d/`: soft goo bodies for
Godot 4, moved by its own native kernel). It was split out of `Shadoku/goo_pachinko` at
commit f359711 (2026-11-11). Games vendor the addon from here: they copy `addons/goo2d/`
whole, libraries included, with a `VENDORED.md` naming the commit, and never edit their
copy. A change the addon needs is made here first, with its test, then copied.

## Commands

| What | Command |
|---|---|
| Everything (build, import, validate, tests, smoke, render) | `python3 tools/check.py` |
| Only the unit tests | `python3 tools/check.py --only test` |
| One test file or method | `python3 tools/check.py --only test --filter=merge` |
| Fastest loop (no new files since last import) | `python3 tools/check.py --only test --no-import` |
| Full engine output | `python3 tools/check.py --verbose` |
| Compile shaders and draw a few frames with the real renderer (needs `xvfb-run`; the main scene, then each example) | `python3 tools/check.py --only render` |
| Run the game (needs a display) | `godot --path .` |
| Open the editor | `godot --path . --editor` |
| Download the prebuilt native kernel instead of building it (no cargo; check.py's `build` stage does it when cargo is missing) | `bash tools/install_native.sh` (this branch's rolling build, or the tag in `.goo2d-kernel-version`); `--update` to refresh one already in place |
| Build the native kernel (Rust, into `addons/goo2d/bin/`; check.py's `build` stage runs it) | `bash tools/build_native.sh` or `python3 tools/check.py --only build` |
| Render the main scene with a few blobs to a PNG (then look at it); `--scene=res://examples/<name>/<name>.tscn` renders that scene as it is instead (`--frames=N` frames, no blobs, no `--split`) | `xvfb-run -a -s "-screen 0 1920x1080x24" godot --path . --rendering-driver opengl3 --audio-driver Dummy -s tools/screenshot.gd -- out.png [--scene=res://...]` |
| Print the golden trace (a fixed game's final bodies; diff it before and after a refactoring) | `godot --headless --fixed-fps 60 --path . -s tools/trace.gd > trace.txt` |
| Benchmark fixed piles (frame time per scenario; compare before and after a performance change; `--unit=0.5` plays them at half size) | `godot --headless --fixed-fps 60 --path . -s tools/bench.gd -- pile40 mixed40` |
| Play the stability repros (pass-through, overlap, skins, impalement, births, links; name scenarios to run only those, `--seed=N` for `births` and `links`, `--unit=0.5` for all of them at half size; `scale`, only when named, is the length unit's gate) | `godot --headless --fixed-fps 60 --path . -s tools/stability.gd [-- births --seed=2]` |

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
| `Can't open dynamic library ... Error 1114` (Windows), `Parameter "mb" is null` and a crash in the editor, or a crash inside `dlopen` (Linux), then `Could not find type "GooKernel"` everywhere | a committed kernel library is corrupt: a mixture of a fresh build and a stale copy (`kernel.yml` once merged overlapping artifacts into one directory) | `kernel.yml` now uploads one library per job, verifies checksums and images (`tools/verify_kernel_bin.sh`, `tools/check_kernel_image.py`) and loads each in Godot (`tools/kernel_smoke.gd`); pull a commit whose libraries passed that, or `bash tools/install_native.sh --update` |

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
  (see `src/drop_controller.gd`; the addon's `GooTuning`, `GooShape` and `GooLoop`
  are the same kind). They need no scene tree and test in milliseconds.
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
project.godot          engine settings; main scene is the demo's, scenes/main.tscn; a 1920 × 1080 canvas (canvas_items); black clear colour; enables the goo2d plugin; physics layer 1 named `walls`; Godot's default 2D physics (it steps nothing of the goo)
.godot-version         pinned Godot release used by CI and the session hook
.goo2d-kernel-version  what tools/install_native.sh downloads: `branch` (the current branch's rolling build, kernel-<branch>, else kernel-main) or a release tag
addons/goo2d/          the Goo2D addon, what this repository is for; the rest of it is the addon's demo, examples, tests and tools
addons/goo2d/README.md the addon's map: requirements, quick start, where each system lives, tuning knobs, limits
addons/goo2d/goo2d.gd  Goo2D: a goo body: its ring of beads in a GooKernel (its world's, or the lone bodies' one; no bead nodes, only the Skin child), the kernel's events as signals and node state (touched, pinched, waking); queries and actions on its beads (bead_points, bead_position/velocity, set_bead_velocity/position, bead_gripping, ring_rotation, apply_impulse, set_velocity...); has_point(global) (inside its collision outline); its state (radius, shape, color/base_color, two-tone: second_color (an export; COLOR_BY_SIZE none), division_axis/division_offset (in rest space), set_two_tone(primary, second, axis_rest, offset), clear_two_tone(), is_two_tone(), dominant_color(), color_set(), second_base_color(), set_tint(tint, second)/get_second_tint()/reset_tint(), the static division_in_rest(), split pieces half and half (inherit_look()), the merge flash over both colours; id, tags (a game's kinds, in order; tag() the first, the one that counts; copied to split pieces and trims), merging, merge lock); builders make/make_merged/make_from_loop (their last parameter the body's tags); GDScript reference versions of the kernel's math (find_pinch, hull_depths, skin_pieces); skin_roll (the skin's patterns rolling with the body's sideways motion, GooSkin.motion_roll; kept by pieces and merges); editor exports radius/sides/outline/color/second_color and their outline preview (@tool)
addons/goo2d/goo_world_2d.gd GooWorld2D: owns the world's GooKernel and its GooStatics (stepped in _physics_process); the rules over its Goo2D children (spawn(radius, pos, shape, tags), despawn, clear): merges (judge_contact, may_merge (the override point; default can_merge), merged_color, two_tone_merges (an export, off: merged bodies drawn in both parents' colours, the division from their centres and areas, set before body_spawned) and merged_colors(a, b) (its rules: the same combination merges as usual, else the two dominant colours), merged_tags (default the pair's deduped union), transition, fused outline), tuning_for(shape, tags) (the override point for how its bodies are tuned, with their tags; default GooTuning.tuning_for), cuts (cut, cut_along, cut_at_tips, pierce; trims a body off a tip; may_split, the override point asked before every cut the goo asks for, default true; a direct cut is not asked), which bodies became which (body_split, bodies_merged, body_trimmed: Goo2D ids and the new bodies, emitted before split, merged, trimmed), body_spawned(body) (every body it registers: a spawn, a split's pieces, a merge, a trim, a placed child; built, tuned and in the tree, before any other signal about it), merge lock (on the physics frame grid: MERGE_LOCK's frames from the one it began on, whatever the engine's frame count, so a replay merges on the same frame); gravity_scale (an export, 1.0: the kernel's gravity × it, re-sent when set); grabs (grab(body, global_point) -> handle (-1 and an error for a body not its own), move_grab(handle, point), release_grab(handle, velocity = ZERO) -> bool (a velocity: a throw, the body's mean velocity set, its wobble kept), grabbed(body), grab_body(handle), grab_point(handle); several at once; each physics frame before the step each bead within GooTuning.GRAB_REACH × radius beyond the nearest (weighted 1 to 0) gets its velocity from an implicit critically damped spring toward the point plus its offset, moving with the point, and the beads not held GRAB_CARRY of the held ones' change, so a body held by its rim dangles without tearing off; a held body woken every frame, never settling; a split, merge, trim, despawn or clear releases its grabs (inner class Grab)), body_at(global_point) -> Goo2D (the topmost whose outline holds it, or null); links (link(a, b, strength = 1.0, anchor_a = INF, anchor_b = INF) -> handle (-1 and an error for a body not its own, the same body twice or a pair linked already; anchors in each body's rest space, by default the points nearest each other), unlink(handle) -> bool, set_link_strength(), link_strength(), set_link_rest_angle(handle, radians) (a joint a game bends every frame), link_rest_angle(), link_bend(), links(), links_of(body), linked(a, b) -> handle or -1, link_bodies(handle), link_info(handle) -> GooLink; signals bodies_linked(handle, a, b), bodies_unlinked(handle, a_id, b_id); linked bodies never merge with each other; a split, cut, trim, merge, despawn or clear releases a body's links; a link the kernel dropped (a ring rebuilt) is sent again from its anchors; each link's bridge drawn after the step in an internal node in front of the world's children); skin_shader (an export: its bodies' shader when they have none of their own, given at registration; set at any time, those already in it that draw with the world's follow at once); the overlap push (intrusion) and the Untangler as GDScript references of the kernel's pair passes
addons/goo2d/goo_link.gd GooLink: one link of a GooWorld2D (its bodies, strength, rest angle, anchors in each body's rest space, the patch sent to the kernel: attach()) and its bridge skin (draw_bridge(): a Polygon2D drawn under every body with a GooSkin of its own, the larger body's tint, shader and look); pure statics: patch(rest_a, anchor_a, rest_b, anchor_b, strength, radius_a, radius_b) (the tied bead pairs, from one pair to a patch LINK_PATCH_RATIO × the smaller radius wide, and the beads that pass through), facing_anchors(), rest_anchor(), kernel_params(), ease_time(), bridge_polygon(points_a, beads_a, bead_radius_a, points_b, beads_b, bead_radius_b) (a simple drawable polygon spanning the neck with two waist curves, or its corners' convex hull, or empty)
addons/goo2d/goo_link_2d.gd GooLink2D (@tool Node2D): a link placed in the editor as a child of a GooWorld2D: body_a, body_b (NodePaths to Goo2D siblings), strength, rest_angle; linked once both bodies are registered, unlinked when freed; draws a line and the neck's width in the editor
addons/goo2d/goo_statics.gd GooStatics: mirrors the scene's StaticBody2D shapes on GooTuning.LAYER_WALLS into a GooKernel as convex polygons (friction, bounce, grip), follows them as they move or come and go; and every TileMapLayer with collision_enabled whose TileSet physics layer is on LAYER_WALLS: its cells' polygons (cell_polygons(), at map_to_local(), flipped as the cell says) merged and split into few convex pieces per physics layer (bake_cells(layer, clip, physics), convex_pieces(), merge() (holes filled with a warning), join_convex(), the per-cell fallback; layer_pieces(layer): what the mirror takes of a layer), the physics layer's material or the layer's own PhysicsMaterial in its metadata MATERIAL_META (tile_material()), grip unless the layer is in NO_GRIP_GROUP, cells wholly outside the Rect2 in its metadata CLIP_META left out (tile_clip()); follows the layer's transform, its `changed` (TileSet, collision_enabled) and its cells (tile_map_data compared each sync: set_cell() emits nothing), its merged pieces kept while TileSet, cells and clip stay; refresh() for what it cannot see (a TileSet's polygons edited, metadata or group changed)
addons/goo2d/goo_tuning.gd GooTuning: every size-dependent number of the goo (sizes, colour, merge-by-size, bead physics, the wall layer, the pressure ring's tuning) and the solver's knobs (SUBSTEPS, contact slop, waking, the Untangler's push; make_kernel; the grab's GRAB_STIFFNESS 3600 /s², GRAB_DAMPING 120 /s (critical), GRAB_REACH 0.8 of the radius, GRAB_CARRY 0.3, none scaled by unit; the links' LINK_STIFFNESS, LINK_DAMPING, LINK_BEND_STIFFNESS, LINK_BEND_DAMPING (per reduced mass / moment of inertia), LINK_PATCH_RATIO, LINK_GAP, LINK_MIN_REST, LINK_THROUGH_BEADS, LINK_EASE_TIME, none scaled by unit, and LINK_EASE_SPEED (link_ease_speed(), × unit)); the length unit `unit` (static, 1.0; at 0.5 every absolute px, px/s and px/s² of the goo is half, read through min_radius()/max_radius(), gravity(), settle_speed(), solver_settings(); the README's "What `unit` scales")
addons/goo2d/goo_shape.gd GooShape: a body's rest outline (round or polygon), equivalent radius, corners, bead loop, fusing; a polygon body's cut in rest space along a chord, each side getting the piece that holds its beads (sliver guard), and trim (trim_ring)
addons/goo2d/goo_loop.gd GooLoop: closed point loops (area, normals, smoothing, shape matching, where one crosses itself and the loops it is cut into there) and the chord a line cuts one on
addons/goo2d/goo_skin.gd GooSkin: a body skin's goo ShaderMaterial and the per-body uniforms it pushes each frame (and a two-tone body's second_color, division_axis, division_offset: set_two_tone(second, axis, offset), clear_two_tone(), pushed at once; the bubble field fixed in the body's rest pose: bubble_origin turns with the body about its centre, bubble_turn the turn it was inherited with, inherit(from, from_center, own_center, from_rotation, own_rotation) keeping a split's or a merge's bubbles where they were; motion_roll: the patterns rolling with the body's sideways motion as a wheel of its radius would, on top of the ring's rotation, roll() so far, handed on) (remembered, so set_shader() swaps in any canvas_item shader at once: Goo2D.skin_shader, GooWorld2D.skin_shader); warm_up(parent, shader)
addons/goo2d/goo.gdshader the addon's wet goo shader GooSkin draws body skins with by default; its head documents the uniform contract a replacement may use (rotation declared; the bubbles in a field fixed in the body's rest pose, rotation + bubble_turn, rising world-up, trailing the motion by bubble_lag (0.05 s); a two-tone body's second_color, division_axis, division_offset mixed in by two_tone(), faded over the look uniform division_fade, 10 px; assets/goo/cel.gdshader and gem.gdshader mix them alike)
addons/goo2d/native/   the native kernel's Rust crate (goo2d_kernel, godot-rust 0.5 api-4-7): GooKernel (RefCounted) owns the goo's beads as particles and moves them with a position-based (XPBD) solver (substeps, skin/bending/stretch constraints, shape matching, contacts with each other through a hashed grid and with registered static shapes), plus settling, pinch scan, skin outline, overlap push, Untangler, links between rings (links.rs: bead pairs as compliant distance constraints and an angular term toward a rest angle, both from one rest pose; add_link, set_link_param, remove_link, link_ids, link_info; removed with either ring; tied beads pass through each other; cargo test runs its unit tests), and static versions of its math for the tests; kernel.rs, statics.rs, grid.rs, forces.rs, links.rs, pinch.rs, skin.rs, geom.rs, consts.rs, lib.rs; docs/native-kernel-plan.md; .gdignore'd, target/ gitignored
addons/goo2d/goo2d.gdextension loads the kernel from addons/goo2d/bin/ (committed for linux x86_64, windows x86_64 and macOS: kernel.yml builds and commits them back on every push that touches the kernel; bin/kernel-commit.txt names the commit; tools/build_native.sh rebuilds this machine's)
addons/goo2d/plugin.cfg, plugin.gd   the editor plugin: registers the addon
addons/goo2d/icon_goo2d.svg, icon_goo_world_2d.svg, icon_goo_link_2d.svg   the three node types' icons
assets/goo/            two more goo skin shaders, written against the uniform contract in addons/goo2d/goo.gdshader: cel.gdshader (cel-shaded, inked) and gem.gdshader (faceted), the shaders example's middle and right columns
assets/shaders/backdrop.gdshader the dotted backdrop behind the goo (Main's and the examples' Backdrop), for the goo to refract
docs/native-kernel-plan.md  the plan that moves the goo's per-frame physics into a Rust GDExtension (GooKernel), in stages with measured gates; all done: 0 (the scaffold), 1 (the per-frame math, Rapier keeps the beads), 2 (the kernel's own particles and solver), 3 (Rapier removed, release binaries); ends with the before/after numbers
scenes/main.tscn       the demo's main scene: Backdrop, Arena, Game, Dropper, a UI label
scenes/arena.tscn      the arena: walls, floor, wedge, two blades
src/main.gd            the main scene's script: wires Arena, Game and Dropper, warms up the goo shader
src/game.gd            Game extends GooWorld2D: the demo's game (launch from the arena, cut on its blades, reset)
src/arena.gd           Arena: the walls, floor and wedge (one StaticBody2D) and its Blade children
src/blade.gd           Blade: a steel spike in the arena; Game cuts blobs its tip touches (geometry in GooLoop)
src/dropper.gd         Dropper: player input (aim, launch, reset, cycle shape) and the next-drop preview
src/drop_controller.gd DropController: the next drop's size and shape, the cooldown, the launch velocity
tests/framework/       test runner + TestCase base (no addons required)
tests/unit/            fast tests of plain classes (test_goo_*.gd: one per addon file (test_goo_link.gd: GooLink's patch and bridge polygon; test_goo_kernel.gd's links: rest lengths held, removed with a ring, pass-through, the rest angle's direction); test_goo2d_two_tone.gd: a body's two-tone state as values; test_drop_controller.gd: the demo's)
tests/integration/     tests that instantiate scenes: the goo in the demo's arena (merges, splits, shapes, overlap, bounce, skins, hooks, editor-placed nodes; test_goo_grab.gd: GooWorld2D's grab; test_two_tone_merge.gd: GooWorld2D.two_tone_merges; test_goo_links.gd: GooWorld2D's links: pulls, a chain of ten whipped at unit 1 and 0.5, every shape combination, strengths, the ease, a swept rest angle, never merging, release on despawn/cut/merge/clear, a hanging chain, the GooLink2D fixture, the bridge) and the demo itself (test_main_scene.gd, test_arena.gd, test_blade.gd, test_backdrop.gd)
tests/integration/scenes/ .tscn fixtures: a GooWorld2D with Goo2D nodes placed as in the editor; goo_editor_links.tscn: placed bodies joined by two GooLink2D nodes
tests/integration/examples/ one test file per example (test_<name>.gd)
examples/              examples of the addon in use, one directory each, entry scene examples/<name>/<name>.tscn (run with `godot --path . examples/<name>/<name>.tscn`; check.py smokes and renders each); examples/README.md is the index
examples/color_merge/  blobs in four colours that merge only with their own colour whatever their sizes (Goo2D.color, GooWorld2D.may_merge/merged_color)
examples/tower/        a tower-building minigame: stiff square blobs stacked on a narrow platform above a goal line (GooWorld2D.tuning_for, may_merge off, editor-placed platform and goal line)
examples/shaders/      the goo drawn by three skins side by side: the addon's, cel-shaded (assets/goo/cel.gdshader), faceted gem (assets/goo/gem.gdshader) (GooWorld2D.skin_shader)
examples/links/        a top-down tank of linked bodies: a chain of five, a round body linked to a square and a triangle, links of strengths 0.2, 0.6 and 1, a chain of three whose first joint's rest angle swings; drag a body to pull its group (GooWorld2D.link, set_link_rest_angle, grab, gravity_scale 0, may_merge off)
examples/two_tone/     blobs that merge whatever their colours in a world with two_tone_merges on: a merged body drawn in both its parents' colours, the division turning as it rolls; one body two-tone and rolling at frame 0 for the render stage (TwoToneWorld.may_merge up to MAX_MERGED_RADIUS, Goo2D.set_two_tone)
tools/check.py         the one command to verify the project (its smoke and render stages also boot each example, examples/<name>/<name>.tscn)
tools/build_native.sh  builds the native kernel with cargo and copies it into addons/goo2d/bin/ (--check: is it there)
tools/validate_scripts.gd   compiles every script; used by check.py
tools/install_godot.sh downloads the pinned Godot into ~/.cache/godot (linux, macOS, windows from Git Bash)
tools/check_kernel_image.py  kernel.yml's check of a built library's image: a DLL ends at its last section and was linked within the build, an ELF file holds its section table and a dynamic section, a Mach-O file its magic
tools/verify_kernel_bin.sh  kernel.yml's check of addons/goo2d/bin/ after the build jobs' artifacts were gathered: every library present, each matching its build job's SHA-256, each a sound image
tools/kernel_smoke.gd  kernel.yml's load test: the real Godot loads the GDExtension, makes a GooKernel and steps a ring, or exits 1
tools/install_native.sh downloads a prebuilt kernel (goo2d-kernel.zip of the branch's rolling build or a release) into addons/goo2d/bin/ (cached in ~/.cache/goo2d-kernel, refreshed when its SHA-256 changes)
tools/screenshot.gd    renders the main scene with a few blobs, or any scene with --scene=, to a PNG (run under xvfb-run, see Commands), in a 1920 × 1080 window
tools/trace.gd         golden trace: plays a fixed game headless, prints every body's beads (byte-identical = same behaviour)
tools/bench.gd         benchmark: plays fixed piles headless, prints the wall clock per physics frame and how often bodies end up inside each other; `--unit=U` plays them at GooTuning.unit U (the arena scaled)
tools/stability.gd     stability repros: pass-through, bodies spawned inside each other, undrawable and wrongly drawn skins, impalement on the wedge and blades, births (a seeded random game watched after every step: explosions, tangled bodies, births gone wrong by split/merge/trim with dumps, the speed cap's work), links (a seeded random game of linking, unlinking and throwing: links made and released by cause, unsound linked bodies, beads inside a partner, the longest stretch); `--unit=U` plays them at GooTuning.unit U (the arena scaled, every size and speed with it); `scale` (only when named): the unit's gate (rebound, settling, the wedge's splits)
.github/workflows/ci.yml    runs check.py on push and pull request
.github/workflows/kernel.yml  on every push that touches the kernel (and on a tag v<crate version>): builds it for linux x86_64, windows x86_64 and macOS (universal) and publishes goo2d-kernel.zip (+ .sha256) as the branch's rolling pre-release kernel-<branch>, or as the tag's release
```

## Conventions

- GDScript: tabs, static types on every declaration, `class_name` for anything
  referenced from other scripts, `## doc comments` on exported properties.
- Commit `*.uid` and `*.import` sidecar files; never commit `.godot/`. The kernel's
  libraries in `addons/goo2d/bin/` are committed too, by `kernel.yml`'s bot (a bot commit
  carrying the skip-ci marker, which skips every workflow of a push whose head commit
  mentions it, so never write that marker in a commit message by hand); do not commit a
  local rebuild unless the Rust changed in the same commit (`check.py`'s build stage
  rebuilds this machine's library when cargo is installed: `git checkout addons/goo2d/bin`
  afterwards). `bin/kernel-commit.txt` names the commit the libraries were built from.
- After adding a `class_name` or a new resource, `check.py` re-imports
  automatically. If you run Godot by hand, run `godot --headless --import` first.
- Prefer editing `.tscn` files through small, reviewable diffs; they are text.
