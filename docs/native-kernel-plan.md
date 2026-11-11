# Native kernel plan: the goo's hot path in a Rust GDExtension

Follow-up to the performance and stability plan (Rapier era; in the git history since the 2026-10-30 docs pass). That plan's measurements (its section
6) ended with the frame at mixed40 split about half and half: roughly 5.5 ms of GDScript
per-frame loops over 580 beads (about 9 µs per bead-frame for arithmetic that is under
1 µs native) and roughly 4.7 ms of Rapier plus Godot's node layer, which grows faster than
linearly with the pile (27 ms at 1700 beads). GDScript cannot be made much faster than
that plan's section 3.4 left it, and Rapier's share is contact pairs, not settings.

Decision: move the goo's physics into a native kernel, in two stages. Stage 1 moves the
per-frame math into a Rust GDExtension while Rapier still owns the beads (a measured win
on its own, the test suite stays green). Stage 2 replaces the beads with the kernel's own
particles under a position-based solver and drops Rapier from the goo. Identical
behaviour is not a goal: the golden trace and the feel may change, the addon is early
and nothing depends on it. The GDScript face of the addon (the `Goo2D` and `GooWorld2D`
nodes, their signals, the builders, `GooShape`/`GooLoop` geometry, the skin shader) stays;
only what runs every frame moves.

Toolchain: Rust with godot-rust (`godot` crate 0.5.5 with its `api-4-7` feature; the
crate also has `experimental-wasm` for a web build, to be tried in stage 3), matching the
vendored Rapier addon, itself a Rust GDExtension. Cargo 1.97 is installed here and
crates.io is reachable.

## Stage 0: toolchain, scaffold, build in the loop

Goal: a `GooKernel` class, callable from GDScript, built by the check loop and by CI, with
nothing of the goo in it yet.

- Crate at `addons/goo2d/native/` (`Cargo.toml`, `src/lib.rs`), library name
  `goo2d_kernel`, `crate-type = ["cdylib"]`, release profile with `opt-level = 3`, `lto =
  "thin"`. One `#[derive(GodotClass)]` `GooKernel` (`RefCounted`) with a `version()` and a
  trivial numeric function to prove the round trip (`sum(PackedFloat32Array) -> f32`).
- `addons/goo2d/goo2d.gdextension` with `entry_symbol`, `compatibility_minimum = 4.7`,
  library paths under `addons/goo2d/bin/` for linux.x86_64 (built here), and entries for
  windows.x86_64, macos (universal) and web.wasm32 pointing at the same naming scheme so a
  release can fill them in later. `addons/goo2d/bin/` is gitignored like Rapier's; the
  crate's `target/` too.
- `tools/build_native.sh`: `cargo build --release` in the crate and copy the library into
  `addons/goo2d/bin/` with the name the `.gdextension` expects. Idempotent, fast when
  nothing changed.
- `tools/check.py`: a `build` stage before `import` that runs `build_native.sh`. If
  `cargo` is missing: skip with `[SKIP] build (no cargo)` when the library is already in
  `bin/`, fail with a clear message when it is not. `--only build` works. Seed
  `.godot/extension_list.cfg` with both `.gdextension` paths (the Godot-crashes-on-first-
  import workaround in the plan's upstream notes applies to every extension).
- CI (`.github/workflows/ci.yml`): install a stable Rust toolchain, cache
  `~/.cargo` and the crate's `target/`, then `check.py` as before. The session-start hook
  runs `build_native.sh` after installing Godot (cargo is present in this environment).
- The template under `.claude/skills/godot-project/assets/template/` gets the `build`
  stage of `check.py` ported (generic: "run `tools/build_native.sh` if it exists"), per
  CLAUDE.md's rule.
- Tests: `tests/unit/test_goo_kernel.gd` instantiates `GooKernel`, checks `version()`
  and the round trip. `tools/validate_scripts.gd` must not choke on the `.gdextension`.
- Docs: README "Requirements" and "Install" (the native library, how to build it, that
  Rapier stays for now), CLAUDE.md commands and layout, `docs/upstream-notes.md` if the
  extension list workaround changes.

Gate: `python3 tools/check.py` → `CHECK: PASS` from a clean clone with cargo, and with the
library prebuilt and cargo hidden from PATH (`[SKIP] build`).

## Stage 1: the per-frame math in the kernel, Rapier keeps the beads

Goal: `Goo2D._physics_process` and `GooWorld2D._physics_process` become a handful of
kernel calls; every per-bead loop runs native. Measured gate below.

Boundary (what moves, what stays):

- Moves into the kernel, per ring: the rest shape, tuning values, bead RIDs, the
  position/velocity snapshot read through `PhysicsServer2D` from Rust
  (`body_get_state`), the pressure + shape-matching + internal-damping forces, the
  stretch limiter, calm detection and the history window, the settle/wake logic (sleeping
  beads through the server), the contact poll (`body_get_direct_state` from Rust: ring
  contacts, static-body grip), the pinch scan and splat check, the skin outline (offset
  with the kink clamp, Chaikin, triangulation check and repair: the kernel returns the
  Skin polygon and the raw outline for the shader; the GooSkin uniform pushes stay in
  GDScript since they are per body, not per bead).
- Moves into the kernel, per world: the pair passes (bounding boxes, the intrusion push
  with per-bead pass-through exceptions through the server, the Untangler's deep-pair
  push), so the kernel sees every ring of a world. `GooWorld2D` owns one `GooKernel`; a
  `Goo2D` outside any world makes its own.
- Stays in GDScript: everything event-driven. Merge decisions (`can_merge`,
  `flat_contact`, `fused_outline`), transitions, cuts, trims, `pierce`, the builders and
  `GooShape`/`GooLoop` geometry they use, signals, tints, the editor preview, the Dropper
  and the demo.

API shape (the agent settles the details; these are the constraints):

- `GooKernel.add_ring(id, bead_rids: Array[RID], rest_shape, tuning: Dictionary) ->
  void`, `remove_ring(id)`, `set_ring_param(id, name, value)` for the few things GDScript
  changes per frame or per event (`target_area` during the inflate tween, `merging`,
  frictionless, split lock, `merge_lock_until`).
- `GooKernel.step(delta: float) -> void` once per physics frame from the world (or the
  lone ring), after `SceneTree.physics_frame`, doing everything above for every ring in
  one call. Then GDScript reads events: `take_events() -> Array[Dictionary]` or typed
  arrays (`pinched(id, a, b)`, `splat`, `touched(id, other_id)`, `settled(id)`,
  `woke(id)`), each ring's `points(id) -> PackedVector2Array` (the snapshot), `center`,
  `area`, `bounds`, `average_velocity`, `skin(id) -> PackedVector2Array`, `raw_outline(id)`.
- Memory and lifetime: rings are removed before their beads are freed; the kernel never
  holds Godot objects, only RIDs and ids. Instance ids of static bodies for the grip
  group come in as a set GDScript passes (`set_no_grip_ids`), or the kernel reads the
  group through the server's collider object; the agent picks the cheaper one.
- Keep the pure GDScript functions that tests call (`find_pinch`, `hull_depths`,
  `intrusion`, `stretch_impulses`, `skin_outline`, `GooLoop.*`) as thin wrappers over
  kernel statics, or keep them in GDScript as reference implementations with a test that
  the kernel agrees with them on random loops (the latter is better: it is how the
  kernel's math is checked without physics).

Tests: the existing suite must pass, with thresholds moved only where float differences
force it (say so in the commit). New `tests/unit/test_goo_kernel.gd`: the kernel's
static math against the GDScript reference on random loops (forces, pinch, skin,
intrusion, stretch). The golden trace changes; re-record it.

Gate: `bench.gd` mixed40 mean at least 30% under the head before this stage (10.3 → at
most 7.2 ms; the plan's section 6 has the numbers to compare against on this machine),
pile40 and shapepile40 in proportion, no scenario slower; stability (`stability.gd`)
equal or better on every line: 0 invisible skins, 0 impaled, pile40 inside pair-samples
about 16, mixed40 about 34. Profile what is left (a scratch section timer is fine) and
record it in this document.

## Stage 2: the kernel's own particles, Rapier out of the goo

Goal: no `RigidBody2D` per bead, no `DampedSpringJoint2D`, no Rapier step for the goo. A
position-based (XPBD) solver in the kernel:

- Particles: position, previous position, velocity, inverse mass, radius; per ring the
  same rest shape and tuning as today, bead counts as a tuning knob (the measured 12-22
  range is on the table now: the plan's section 3.5 note says it was worth 30% with
  Rapier and needed the split thresholds re-measured; do that re-measuring here).
- Constraints per substep (4 to 8 substeps per 60 Hz frame; measure): distance for skin
  and bending edges with XPBD compliance from the current spring frequencies
  (`compliance = 1 / (k)`, k from `GooTuning.skin_stiffness`, so the tuning carries
  over), a maximum-stretch hard limit (the stretch limiter becomes a constraint), the
  pressure/area constraint toward `target_area` (Müller's volume constraint in 2D),
  shape matching toward the rest shape with the same gain, internal damping, gravity from
  `GooTuning.gravity()`.
- Collisions: particle-particle through a uniform grid (cell = largest bead diameter),
  every pair within the sum of radii pushed apart (that is the self-collision, the
  ring-ring contact and the intrusion push in one rule; beads of the same ring 1-2 hops
  apart are skipped as today), with friction and restitution from the tuning; particle
  versus static geometry through shapes GDScript registers with the kernel
  (`add_static_shape(id, transform, shape)` for the rectangles and convex polygons the
  arena, wedge and blades use; `StaticBody2D` stays in the scene for anything else and
  for the editor), with the wall grip and the no-grip group handled here; a per-substep
  swept check for fast particles replaces CCD.
- Sleeping: the calm/settle logic as today, on the kernel's own particles.
- `Goo2D`: builds rings through the kernel only (`particles()` and `Bead` go; what tests
  need instead: `bead_velocity(i)`, `set_bead_velocity`, `bead_position(i)`, with
  `particle_count()`, `bead_points()`, `center()`, `average_velocity()`, `apply_impulse`,
  `set_velocity`, `set_frictionless`, `wake` kept). The `Beads` and `Joints` child nodes
  go; the `Skin` stays. Merges and cuts rebuild rings exactly as today (they only use
  points and velocities). The physics layers and `PhysicsMaterial` tuning leave
  `GooTuning` or stay as documentation of the solver's equivalents.
- Tuning pass: re-measure the feel tests' thresholds (rest height, bounce from a 500 px
  drop, settle time, wedge splits, square and triangle rest shapes, merge rebuild
  placement) and set the solver's substeps, compliance and friction so they land within
  the ranges the tests describe. Record what moved and why in this document.

Gate: `bench.gd` mixed40 mean at most 3 ms, scaling about linearly to 80 bodies (add a
`mixed80` scenario to the bench); stability equal or better on every line;
`check.py` green with the retuned thresholds; the screenshot tool still shows the same
kind of goo.

## Stage 3: cleanup

- Remove the Rapier addon, `install_rapier.sh`, `.rapier-version` and the extension-list
  seeding for it; switch `physics/2d/physics_engine` back to the default (the arena's
  `StaticBody2D` nodes need no physics engine beyond that; the Dropper and UI never did).
  Delete the Rapier workarounds (`WALL_GRIP_DAMP` as a damping hack, the bounce-sum
  tuning, the velocity-from-positions workaround) where the solver made them moot, and
  update `docs/upstream-notes.md`: most of its entries become history.
- Prebuilt binaries: a release workflow that builds linux/windows/macos (and web if
  gdext's wasm target works on this Godot) and attaches them, plus a
  `tools/install_native.sh` that fetches them for a checkout without cargo, mirroring
  what `install_rapier.sh` did.
- README: the kernel in "Where each system lives", the tuning table's new knobs
  (substeps, compliance, bead range), the build requirement.

## Order and gates

Stages run in order, each one an agent, each gated by its measured numbers before the
next starts. Stage 0 first, alone. Stage 1 on the merged stage 0. Stage 2 on stage 1, in
two commits at least (solver running with tests adjusted; then the tuning pass). Stage 3
after stage 2's gate. Benchmarks are compared on the same machine, back to back, using
the per-bead-frame line of `bench.gd` as well as the mean frame.

## Results

(Filled in per stage.)

### Stage 0: done

- [x] Crate `addons/goo2d/native/` (`goo2d_kernel`, cdylib, release `opt-level = 3`, thin
  LTO), `godot = { version = "0.5", features = ["api-4-7"] }`, resolved to **godot 0.5.5**
  (gdextension-api 0.5.1; Godot prints `Initialize godot-rust (API v4.7.stable.official,
  runtime v4.7.2.stable.official)`). `GooKernel` (`RefCounted`): `version()` and
  `sum(PackedFloat32Array) -> f32`, registered through `#[gdextension] ExtensionLibrary`.
  `Cargo.lock` is committed; the crate folder has a `.gdignore` so Godot does not scan
  `target/`.
- [x] `addons/goo2d/goo2d.gdextension`: `entry_symbol = "gdext_rust_init"` (gdext's default),
  `compatibility_minimum = 4.7`; libraries named like Rapier's
  (`bin/libgoo2d_kernel.<os>.<rust triple>.<ext>`): linux x86_64 and arm64, windows x86_64,
  a macos framework (`bin/libgoo2d_kernel.macos.framework`, which `build_native.sh` fills with
  the dylib and an Info.plist on a Mac; untested here), web threads `bin/goo2d_kernel.wasm`
  and no-threads `bin/wasm-nothreads/goo2d_kernel.wasm`. `addons/goo2d/bin/` and
  `addons/goo2d/native/target/` are gitignored.
- [x] `tools/build_native.sh`: `cargo build --release`, copies the library into `bin/` only
  when it changed (prints which), last line the library path; `--check` reports whether the
  library is there without cargo. A no-op run takes 0.1 s.
- [x] `tools/check.py`: a `build` stage before `import` (`[SKIP] build (no cargo)` when cargo
  is not on PATH but the library is built, a failure naming the fix when it is not; `--only
  build`). The extension list already globbed every `*.gdextension`, but only seeded a missing
  file; it now also rewrites a file that misses one (this checkout's `.godot/` listed only
  Rapier). Both ported to the template's `check.py`.
- [x] CI: `dtolnay/rust-toolchain@stable` and `Swatinem/rust-cache@v2` (cargo registry and
  the crate's `target/`) before `check.py`. The session hook runs `build_native.sh` after
  Godot and Rapier and carries on with a message if it fails.
- [x] `tests/unit/test_goo_kernel.gd`: the class is registered (`ClassDB`), `version()`,
  the `sum()` round trip.
- Build time on this machine: first release build 2 min 04 s including the crate downloads,
  1 min 54 s from an empty `target/` with the registry cached (the gate's `[PASS] build
  (113.8s)`); a rebuild with nothing changed 0.1 s. The library is 3.4 MB.
- Gate, from `rm -rf addons/goo2d/bin addons/goo2d/native/target .godot` with cargo:
  `[PASS] build (113.8s)`, `[PASS] import`, `[PASS] validate` (43 scripts), `[PASS] test`
  (296 passed), `[PASS] smoke`, `[PASS] render`, `CHECK: PASS`. With cargo hidden from PATH
  and the library prebuilt: `[SKIP] build (no cargo)`, then the same five `[PASS]` lines
  (296 tests passed) and `CHECK: PASS`.

### Stage 1: done

What moved. `GooKernel` (`addons/goo2d/native/src/`: `kernel.rs` the rings and the step,
`forces.rs`, `pinch.rs`, `skin.rs`, `geom.rs`, `consts.rs`, `lib.rs` the class) holds one ring per
`Goo2D` (bead RIDs and instance ids, rest shape, rest edges and hull depths, corner flags, tuning,
the per-frame state) and never a Godot object. Per ring it does what `Goo2D._physics_process`,
`_poll_contacts` and `_update_skin`'s geometry did: the snapshot (position and velocity through
`body_get_direct_state`, fetched and dropped within the step), the contact poll (rings touched,
static-body grip, the no-grip group read from the collider object once per collider and step),
motion from positions, calm detection over the history window, settling by contact groups
(sleeping through the server), the split lock, pinch scan and splat check, the pressure +
shape-matching + damping forces, the stretch limiter, and the skin outline (kink-clamped offset,
Chaikin keeping corners, a native simplicity check before `Geometry2D.triangulate_polygon`, the
Clipper repair) plus the shader's padded outline. Per world: the overlap push (box broad phase,
`intrusion()`, per-bead pass-through exceptions through the server) and the Untangler. GDScript
keeps everything event-driven and reads the kernel's events (`take_events()`: four integers per
record, touched/pinched/settled/woke/grip) and per-ring results (`points`, `velocities`, `center`,
`bounds`, `area`, `average_velocity`, `skin`, `raw_outline`, `shader_points`, `skin_version`,
`touching`, `beads_inside`...).

Frame order: a `GooWorld2D` takes the kernel's snapshot at `SceneTree.physics_frame`
(`begin_step()`: code awaiting the signal reads this frame's beads), and runs the merge locks and
transitions, the rest of the step (`step()`) and the event dispatch in its `_physics_process`,
where the world's and the rings' per-frame code ran before; both are after the physics flush.
Lone bodies share one kernel stepped whole at `physics_frame`. The GDScript reference functions
stay (`Goo2D.find_pinch`, `hull_depths`, `short_axis_beads`, `skin_offset`, `skin_outline`,
`stretch_impulses`, `GooWorld2D.intrusion`, `Untangler.push`, `GooLoop.*`) and
`tests/unit/test_goo_kernel.gd` checks the kernel's statics against them on random loops (the ring
forces against a GDScript copy of the removed `_apply_forces`, kept in the test). The kernel's
point-in-polygon is a port of Godot's own (`Geometry2D.is_point_in_polygon`), so the two agree on
every bead, not only away from edges.

Benchmarks: `bench.gd -- pile40 shapepile40 mixed40`, three runs per tree, alternating, the Stage 0
head (34b0bf1, a worktree) against this head, same machine. This machine ran Stage 0 at 14-15 ms
on mixed40, not the 10.3 ms of the performance plan's section 6 (it is slower than
when that was measured, and noisy: ±5-10% between runs, one 178 ms stall in a Stage 0 run), so
the gate is read relatively. Means of the three runs:

| scenario | mean frame, before → after | p95, before → after | µs per bead-frame, before → after | live beads |
|---|---|---|---|---|
| pile40 | 7.38 → 5.50 ms (−25%) | 13.65 → 10.07 ms (−26%) | 18.9 → 13.2 (−30%) | 390 → 417 |
| shapepile40 | 9.09 → 5.58 ms (−39%) | 16.98 → 11.23 ms (−34%) | 20.3 → 13.1 (−36%) | 447 → 426 |
| mixed40 | 15.34 → 9.64 ms (−37%; −33% against the two runs without the stall) | 29.3 → 18.1 ms (−38%) | 24.9 → 14.7 (−41%) | 616 → 657 |

mixed40 and shapepile40 pass the 30% gate; pile40's frame is 25% faster and its cost per
bead-frame 30% (it keeps more beads alive: 27 merges instead of 31). No scenario is slower.

Stability (`stability.gd`, both trees back to back): 0 invisible skins in every scenario, impale
189 cases with 0 ending with the tip inside a loop, 0 settled impaled, 0 stuck; impale_pile 0
with the tip inside on all four piles; inside: the same "apart after" times as Stage 0 (0.07,
0.08, 0.03, 0.02 s); passthrough: the same widest holes (6.0/5.2 px at 2500 px/s, 0.1/1.1 px at
1500) and distances within 0.06 radii. bench.gd's bodies-inside-each-other pair-samples: pile40
27 → 21, shapepile40 42 → 23, mixed40 36 → 29.

What is left of the frame (mixed40, a scratch section timer, not committed; ms per frame, the
timers add their own cost, frame 10.1 ms in that run):

| section | ms | what it is |
|---|---|---|
| kernel: snapshot reads | 1.05 | per bead `body_get_direct_state` (0.3 µs), transform, velocity, contact count (0.15 µs each) |
| of which contacts | 0.46 | Rapier's per-contact query costs about 1.9 µs whichever field is asked (collider id, RID, shape or object), about 2 contacts per bead |
| kernel: apply forces | 0.57 | one `body_apply_central_force` per bead, about 0.65 µs each in Rapier |
| kernel: skins | 0.35 | offset, Chaikin, the simplicity check (0.15), the rare triangulation and repair |
| kernel: pair passes | 0.17 | overlap push and Untangler |
| kernel: ring math | 0.09 | motion, calm, pinch scan, forces, stretch |
| world: locks and transitions | 0.44 | of which 0.18 the merge rebuild (node creation) |
| world: event dispatch | 0.31 | `touched` signals (every frame per touching pair) and `_on_touched` |
| deferred cuts | 0.23 | splits and trims (node creation) |
| `Goo2D._process` (skin node, uniforms) | 0.19 | 28 bodies |
| `Game._check_blades` | 0.15 | |
| the rest | ~6.5 | Rapier's step, Godot's sync of ~650 `RigidBody2D` nodes, `Polygon2D` redraws |

The kernel's own arithmetic is a few hundred µs; about 1.9 ms of its 2.25 ms is calls into the
physics server, which Stage 2 removes with the beads. The ~6.5 ms outside the scripts is the
same Rapier and node cost section 6 of the performance plan measured, now about two thirds of
the frame.

Deviations from the API sketch above:

- Events are a flat `PackedInt64Array` of `[kind, ring, x, y]` records, not dictionaries.
- `set_ring_param` takes `target_area` and `split_lock` only. `merging` reaches the kernel as the
  merging pairs (`set_merge_partners()`, every frame), frictionless stays a material swap on the
  bead nodes and the merge lock a world rule; the kernel needs neither.
- The grip group: `set_no_grip_group(name)`, the kernel asks a static collider's object once per
  step (cheaper than keeping a set of ids current).
- The step is split in two (`begin_step()` at `physics_frame`, `step()` in the world's
  `_physics_process`, see above): with the whole step at `physics_frame`, a body a script spawned
  or threw at that signal was first stepped a frame later than before, which showed in
  `test_split.gd` and in the stability repro's untangling times.
- Added: `set_velocities()` (velocities set on the bead nodes, which `average_velocity()` reports
  until the next step measures motion), `set_points()` (after beads were moved by hand),
  `shader_points()`/`skin_version()` (the skin is pulled only when it changed), and the statics
  for the tests.
- A game rule changed: `GooLoop.chord()` cuts off a bead hooked over a tip (the line crossing
  only that bead's two edges around the tip) between its neighbours. The new trajectories put a
  body in that pose on the floor blade in `impale_pile`, where no cut could be made and it hung
  on the tip; the weakness predates the kernel.
- `bench.gd` counts bodies inside each other right after the world's snapshot (connected to
  `physics_frame` after the world), so it reads that frame's beads.
- The golden trace changed (Stage 0: 6 bodies, 2 merges, 2 splits; now 8 bodies, 1 merge, 3
  splits): the order within a frame and float rounding differ. No threshold of the test suite
  moved; `TESTS: 310 passed`.

### Stage 2: done

What moved. `GooKernel` owns the beads. A ring is a contiguous range of particles in flat arrays
(`Particles` in `kernel.rs`: position, previous position, velocity, the step's force and
displacement, radius, owning ring; the inverse mass is the ring's), and `step()` moves them with a
position-based solver; nothing of the goo touches `PhysicsServer2D` any more. Per step: the split
locks; the pair passes (overlap push, Untangler); the step's forces from its starting state (the
pressure and internal damping, see below); `GooTuning.SUBSTEPS` (6) substeps, more (up to 12) while
a bead would move further than its radius in one, each: predict (gravity, the step's forces,
linear damping plus the project's default, `WALL_GRIP_DAMP` on a bead that touched a gripping
shape), the ring constraints (skin and bending distances, XPBD with compliance 1 / stiffness and
the springs' damping, from the same `skin_stiffness`/`bending_stiffness`/`*_damping` as the
joints had; shape matching toward the best-fit rest shape at `shape_match_k` per unit mass; the
hard stretch limit at `MAX_STRETCH`), the contacts (static shapes, swept for a bead moving more
than its radius; particle pairs from candidate pairs found once a step on a hashed grid, beads 1-2
apart along one ring skipped, pass-through exclusions honoured, a settled ring immovable unless the
contact presses in by `WAKE_DEPTH` or closes at `WAKE_SPEED`), the velocities from the positions,
then restitution (the sum of the two bounces, clamped, above 2 g h of closing speed) and Coulomb
friction (the lower of the two) on the contacts; then per ring the views (`points`,
`velocities`), the rings touched (the solver's own contacts within `TOUCH_SLOP`), calm detection
and settling by contact groups, the pinch scan and splat check, and the skin. `statics.rs` holds
the static shapes (convex polygons in global space, friction, bounce, grip); `GooStatics`
(GDScript, `addons/goo2d/goo_statics.gd`) mirrors every `StaticBody2D` on `LAYER_WALLS` into the
kernel (rectangles, convex polygons, circles and capsules as polygons, `CollisionPolygon2D`
decomposed), rebuilds the mirror when a static body or collision node enters or leaves the tree,
and moves shapes whose nodes moved (the self-collision test's `AnimatableBody2D` slab). `Goo2D`
builds no nodes but its `Skin`; it keeps its beads' positions and velocities while out of the
tree. `particles()`, `Goo2D.Bead`, `invalidate_points()`, `stretch_impulses()` and
`GooTuning.physics_material()` are gone; `bead_position()`, `set_bead_position()`,
`bead_velocity()`, `set_bead_velocity()`, `bead_gripping()`, `passes_through()`,
`is_frictionless()` are new. The plugin no longer warns about the physics engine.

Frame order: the world steps its kernel in `_physics_process` (merge locks and transitions, the
statics' sync, the step, the events); there is no snapshot at `physics_frame` any more (the kernel
holds the positions), so code that awaited the signal and spawned or threw a body is stepped in
the same frame, as before. Lone bodies' kernel steps at `physics_frame`.

Benchmarks: `bench.gd -- pile40 shapepile40 mixed40 mixed80`, three runs per tree, alternating,
the Stage 1 head (52cafc2, a worktree) against this head, same machine and session. The machine
ran the Stage 1 head at 10.4-12.4 ms on mixed40 this time (10.1-10.2 when this stage started), so
read the gate relatively too. Means of the three runs:

| scenario | mean frame, before → after | p95, before → after | µs per bead-frame, before → after | live beads | inside pair-samples |
|---|---|---|---|---|---|
| pile40 | 6.28 → 1.52 ms (−76%) | 11.61 → 2.45 ms | 15.07 → 4.97 (−67%) | 417 → 306 | 21 → 12 |
| shapepile40 | 6.32 → 2.25 ms (−64%) | 13.48 → 4.39 ms | 14.83 → 5.69 (−62%) | 426 → 395 | 23 → 15 |
| mixed40 | 11.48 → 2.65 ms (−77%) | 21.65 → 5.13 ms | 17.47 → 5.66 (−68%) | 657 → 468 | 29 → 21 |
| mixed80 | 18.15 → 5.03 ms (−72%) | 35.92 → 10.87 ms | 19.66 → 6.52 (−67%) | 924 → 771 | 102 → 76 |

Gate: mixed40 2.65 ms (at most 3); mixed80 1.90 × mixed40 (at most about 2.2; per bead-frame it
costs 15% more than mixed40 with 1.65 × the beads); pile40 and shapepile40 in proportion. Fewer
live beads is the bead-count change (below), and the runs play out differently from the first
frame on (different merges and splits), which is why the per-bead-frame column is the fair one.

Stability (`stability.gd`, this head): 0 invisible skins in every scenario; impale: 189 cases, 64
split, 0 with the tip inside a bead loop, 0 settled impaled, 0 stuck, 52 trims (26 in Stage 1: the
apex gets between the bigger beads more often, and each such time the body is trimmed off it);
impale_pile: 0 with the tip inside on all four piles; inside: apart after 0.02, 0.03, 0.07, 0.02,
0.02 s (Stage 1: merged, 0.07, 0.08, 0.03, 0.02), never settled overlapping; passthrough: the big
ring's widest neighbour gap −5.4/−5.2 px at 1500/2500 px/s from above, round and square (Stage 1:
0.1/6.0 and 1.1/5.2 px open), so the skin never opens; side hits −13.6 px.

Tuning pass (each in its commit with the measurement):

- Bead counts 12-22 (`MIN_BEADS`/`MAX_BEADS`, from 16-30; `bead_count()` now spans
  `MAX_BEADS - MIN_BEADS`), `MAX_POLYGON_BEADS` 44 (from 60): mixed40 4.0 → 2.8 ms by itself.
- `GooShape.MIN_PIECE_WIDTH_BEADS` 3.0 → 2.2: the same pieces are a third fewer of the bigger bead
  diameters wide (the halves of a 48 px square 2.5 instead of 3.3); 2.2 cuts what 3.0 cut and
  refuses the real slivers (1.3).
- `Goo2D.PINCH_SCAN_FRAMES` 4 → 2 (`SPLIT_HOLD` stays 0.08 s, now three scans): a launch-size blob
  thrown onto the wedge's apex wraps it for 5-7 frames and springs off; a 4-frame scan saw the neck
  once or twice by phase.
- `GooWorld2D.Untangler.SEPARATION_SPEED` 800 → 1600 px/s: under Rapier the parting speed it read
  lagged its own push by a frame, so pairs parted at about 1600 anyway; read live, 800 halved it.
- `Goo2D._inset()` halves its distance while a merged outline's inset falls apart in pieces (a
  bigger bead's inset no longer fits the waist of two touching rings; the merged ring was built on
  one of them, 28 px off).
- Substeps 6: 4 measured (7 tests fail: wobble dying out in 3.5 s instead of under 2.5, a launch
  triangle and a 48 px one splitting on landing, the thin post not splitting a big blob), 8 no
  better on the feel tests than 6 and slower.
- Compliance: the skin and bending springs' stiffness and damping as they were; shape matching at
  the same gain, solved every substep.
- Pressure and internal damping: forces over the step from its starting state, not constraints.
  Measured: the pressure as Müller's area constraint every substep (compliance area / pressure_k,
  so the same law) and damping every substep made rings stiffer against impacts: the smallest blob
  rebounded 17 px from a 500 px drop (about 40 under Rapier) and held the wedge's apex wrapped
  longer; as a step force (what the tuning was found with, a 60 Hz force) it rebounds 31 px with
  16-30 beads. Shape matching as a step force kept polygons from settling (explicit at 4 × gain
  against hard contacts), so it stays a constraint.
- Restitution and friction: Rapier's combine rules kept (sum of bounces, lower friction), the
  restitution threshold 2 g h, the closing speed the lower of the substep's and the step's start.
  Tried for the bounce test and not kept: restitution scaled up (no effect: the skin takes a
  bead's bounce back within a substep), restitution carried through the skin by velocity
  iterations (less bounce), soft contacts (25 px at the cost of beads sinking into blades).
- Collision margin: `TOUCH_SLOP` 1 px (touched and grip within it, no push); the candidate pairs'
  reach 1.5 × (speed × step + ½ (g + force/m) step²) + 1 px.
- The overlap push also moves an intruding bead out by its share of the depth (the force over its
  stiffness), spread over the step's substeps without touching velocities: bench.gd's
  inside pair-samples pile40 22 → 12, mixed40 27-33 → 21. A pair whose beads stay inside for 12
  steps (a wall or a pile holding them) goes to the Untangler.
- Skins: rebuilt once a bead moved 0.25 px from where the last one was built; a skin that needed
  the Clipper repair waits 2 steps.

Thresholds moved in the tests, with the reasons in the commits and next to the assertions:
`test_bounce` smallest rebound > 12 px (was 40: the solver's contacts are position constraints;
15-20 px measured; small blobs still rebound higher than the largest); `test_shapes` a square's
skin covers 96% of its target (was 97%; 96.7% with the bigger beads); `test_goo_tuning` the new
counts and a 4% rounded-corner allowance for triangles (was 3%; 3.4% with 12-22 beads);
`test_split` the trimming tip 0.7 bead radii in from a blob's edge (was 1.0: the beads are a
third bigger); `test_goo2d_skin` the folded ring's repaired skin no longer asserted to cover the
centre (with 15 beads three folded beads are a fifth of the ring; it covers 99% of the ring's area).
Tests of removed APIs were rewritten for their replacements (beads, joints, materials, collision
exceptions, grip damping); the kernel's solver has its own unit tests (`test_goo_kernel.gd`:
gravity, resting on and gripping a static floor, the hard stretch limit, a 6000 px/s ring against a
4 px wall, pass-through, sleeping and waking, static shape transforms). `TESTS: 311 passed`.

What is left of the frame (mixed40, scratch section timers, not committed; ms per frame, frame
2.7-2.9 ms in those runs):

| section | ms | what it is |
|---|---|---|
| kernel: solver | 0.50-0.57 | candidate pairs 0.20-0.23, ring constraints 0.15, static contacts 0.06, particle contacts 0.05, predict and velocities 0.05 |
| kernel: skins | 0.18-0.30 | 25-30 rebuilds; about one Clipper repair per frame for a ring folded through itself (folded rings: 630 body-frames of 13,900 here, 457 of 13,200 under Stage 1) |
| kernel: pair passes, ring logic | 0.10 | overlap push, Untangler, calm, pinch scan |
| world: merge locks and transitions | 0.21 | mostly building the merged rings |
| world: event dispatch | 0.16-0.19 | about 44 touched events a frame |
| `Game._check_blades` | 0.08 | |
| `Goo2D._process` (skin node, uniforms) | 0.15-0.19 | |
| `bench.gd`'s own inside count | 0.07-0.10 | |
| the rest | ~1.2 | Godot: the `Polygon2D` skins redrawn (about 0.9 ms: skipping the polygon assignment took a run from 3.4 to 2.4 ms; about 15 µs a redraw, a third of it the triangulation), deferred cuts and merges, the empty Rapier step, the canvas and material updates |

The kernel is about a third of the frame; the skins' redraw in Godot is the largest single item
left, then GDScript's event-driven work. Rapier still runs a step every frame for the arena's
static bodies alone (stage 3 removes it).

Deviations from the plan's Stage 2:

- The pressure and internal damping are forces over the step from its starting state, not an
  area constraint and per-substep damping (measured above); shape matching is a per-substep
  constraint as planned.
- The overlap push and the Untangler stay (as the plan's "or go, if" allowed measuring): bodies
  spawned or merged into each other still need them; the per-bead pass-through and the
  Untangler's pair exclusion are kernel-side exclusions (`set_pass_through`/`set_bead_pass_through`
  kept as their API). The push also displaces (above), and stuck intruders are untangled.
- `_release_merge_locks()` still re-reports a settled body's last contacts: the kernel reports
  touching pairs every frame only for awake rings (reporting settled ones every frame would cost
  a dispatch per resting pair for nothing).
- `GooWorld2D` judges its bodies' contacts as it dispatches the kernel's events
  (`judge_contact()`), before each `touched` signal, instead of through a bound connection to
  every body's signal (dispatch 0.23 → 0.16 ms).
- Static shapes come from every `StaticBody2D` on `LAYER_WALLS` anywhere in the scene tree (a world
  and the lone bodies' kernel each keep a `GooStatics`), not only the world's scene; the arena's
  `StaticBody2D` nodes stay as the mirror's source. Bodies of different kernels do not collide.
- Removed rather than kept as documentation: `GooTuning.physics_material()` (the solver reads
  `bounce` and `friction` from the tuning); kept: `LAYER_WALLS` (what `GooStatics` mirrors),
  `LAYER_BLOBS` and `ANGULAR_DAMP` as documentation.
- `tools/screenshot.gd --split` freezes the goo with `Game.set_physics_process(false)` instead of
  `PhysicsServer2D.set_active(false)`.
- The golden trace changed (Stage 1: 8 bodies, 1 merge, 3 splits; now 6 bodies, 2 merges, 2
  splits); it is deterministic run to run.

### Stage 3: done

What went. The Rapier addon (`addons/godot-rapier2d/`), `tools/install_rapier.sh`,
`.rapier-version`, `physics/2d/physics_engine="Rapier2D"` (the project runs on Godot's default 2D
physics, which steps nothing of the goo: the arena's `StaticBody2D` nodes are only read, by
`GooStatics`), the Rapier download in `check.py` (now identical to the skill template's again), in
the session hook and in CI, the `blobs` layer name, `GooTuning.LAYER_BLOBS` and
`GooTuning.ANGULAR_DAMP` (nothing read either), and every comment that explained a value by
Rapier. The engine test asserts the default engine and the kernel loaded. Nothing dynamic
depended on the engine: with Rapier gone, every scenario of `bench.gd` plays out the same (the
same merges, splits, bead counts and inside counts in all seven) and `stability.gd` prints the
same numbers; the golden trace is 6 bodies, 2 merges, 2 splits as after stage 2.

What stayed, re-documented. `WALL_GRIP_DAMP` (the kernel's `grip_damp`: extra linear damping on a
bead touching a gripping static shape) is how the goo clings to walls, not a workaround: the
solver's Coulomb friction is kept at the lower of the two frictions and the bounce at the clamped
sum, by choice, so the stage 2 tuning holds. Replacing the grip with per-shape friction would be
a feel change and a tuning pass, not a cleanup; not done. `LAYER_WALLS` is the layer `GooStatics`
mirrors. The velocity-from-positions workaround was already gone in stage 2 (the kernel's
velocities are its own). The plugin's engine warning was gone too; `plugin.cfg`'s description no
longer names Rapier. The generic "skip a vendored addon" rule of `validate_scripts.gd` and
`--include-addons` stay (they are the template's, and cost nothing).

Prebuilt binaries. `.github/workflows/kernel.yml` (first written as `release.yml`, tag-only; it now also builds on every push that touches the kernel and keeps a rolling pre-release `kernel-<branch>` per branch, which `install_native.sh` downloads by default): on a tag `v*` (it must equal the crate's
version) or by hand, builds the kernel through `build_native.sh` on `ubuntu-latest` (linux x86_64)
and `windows-latest` (x86_64, msvc, so the library keeps the `.gdextension`'s
`x86_64-pc-windows-msvc` name; a windows runner instead of cross-compiling with
`x86_64-pc-windows-gnu`, which would have needed a mingw toolchain and a renamed library), and on
`macos-latest` builds `build_native.sh`'s framework and replaces its dylib with a universal one
(`lipo` of the `aarch64-apple-darwin` and `x86_64-apple-darwin` builds, ad-hoc signed;
`build_native.sh` builds the host architecture only). A packaging job zips `addons/goo2d/bin/`
as `goo2d-kernel.zip` with its SHA-256 and attaches both to the release (`gh release`).
`tools/install_native.sh [tag]` downloads that zip for the tag in `.goo2d-kernel-version`
(`v0.2.0`, the crate's version; not released yet) into `addons/goo2d/bin/`, cached in
`~/.cache/goo2d-kernel/<tag>/`, verifying the checksum when it is published, and does nothing
when the library is already there. `check.py`'s build stage runs it when cargo is missing and no
library is in place (`[SKIP] build (no cargo; downloaded a prebuilt library with
tools/install_native.sh, ...)`, or a failure naming both); generic (only when the project has the
script), so ported to the template with its CLAUDE.md row. The session hook falls back to it too.
Not run here: the workflow (YAML checked with PyYAML; it needs GitHub's runners) and a real
release download; `install_native.sh` was tested against a local `file://` zip (installs, then
idempotent), a wrong checksum, an unreachable host and a 404 (the tag not released), and
`check.py --only build` with cargo hidden from PATH against the last two and the local zip.

Web: not built. The crate compiles for `wasm32-unknown-emscripten` with `experimental-wasm` on
stable (`cargo check --release --target wasm32-unknown-emscripten --features
godot/experimental-wasm,godot/lazy-function-tables`), but there is no emscripten here to link
it, so nothing was built or run; the steps left are in `docs/upstream-notes.md`, "Native kernel
builds".

Docs: `docs/upstream-notes.md` rewritten for the kernel era (the Godot items that still apply,
the kernel's builds, the Rapier items as one-line history), the addon README (requirements: Godot
4.7 and the kernel library, built or downloaded, no physics engine; the kernel and `GooStatics`
in "Where each system lives"; the grip knob; limits), the root README, CLAUDE.md. The tuning
table has the solver's knobs since stage 2 (`SUBSTEPS`, `MAX_SUBSTEPS`, `TOUCH_SLOP`,
`WAKE_DEPTH`, `WAKE_SPEED`, the bead range `MIN_BEADS`/`MAX_BEADS`); the compliance has no knob
of its own (it is 1 / the springs' stiffness, from `JOINT_FREQUENCY_*`, `SKIN_FREQUENCY_RATIO`,
`BENDING_RATIO`).

Gate: `python3 tools/check.py` → `CHECK: PASS` without Rapier present (`TESTS: 311 passed`).
Bench and stability against the stage 2 head on this machine, the same session (two runs each):
every scenario faster, by the empty Rapier step every frame (mixed40 3.02/3.23 → 2.54/2.57 ms,
6.11/6.54 → 5.15/5.21 µs per bead-frame; pile40 1.60/1.50 → 1.23/1.16 ms), and the inside counts
and every stability line identical. The machine ran the stage 2 head at 3.0-3.2 ms on mixed40
this session, not the 2.65 ms its section records, and the stage 2 head counts 24 mixed40 inside
pair-samples here, not 21 (the same before and after this stage; the 21 was likely measured
before stage 2's last commit).

## Results: before and after the kernel

The Rapier-era head is the performance plan's section 6 (in the git history) (e290ad5: GDScript per-frame
loops, the beads `RigidBody2D` circles on Rapier, 16-30 beads per ring); the kernel's head is
this plan after stage 3. Both are `tools/bench.gd` on all scenarios, two runs each, and
`tools/stability.gd` once. They were measured in different sessions, and this machine's speed
drifts between sessions (stage 1 found it running the same tree 40% slower than when section 6
was measured, stage 3 10-20% slower than stage 2 did), so the absolute times compare only
roughly; the per-bead-frame column (frame time over live beads) is the fair one, and the two
heads also keep different numbers of beads alive (12-22 beads per ring now, and different
merges and splits from the first frame on).

| scenario | mean frame, Rapier-era head | mean frame, kernel | µs per bead-frame, Rapier-era head | µs per bead-frame, kernel | live beads, Rapier-era → kernel |
|---|---|---|---|---|---|
| round40 | 6.61 / 6.69 ms | 1.12 / 1.26 ms | 16.0 / 16.2 | 3.74 / 4.21 (−75%) | 414 → 300 |
| packed30 | 4.33 / 4.43 ms | 1.90 / 1.51 ms | 16.8 / 17.1 | 7.81 / 6.18 (−59%) | 258 → 244 |
| big12 | 7.09 / 6.98 ms | 1.23 / 1.25 ms | 16.5 / 16.2 | 3.92 / 4.00 (−76%) | 430 → 313 |
| mixed40 | 10.28 / 10.36 ms | 2.54 / 2.57 ms | 17.6 / 17.8 | 5.15 / 5.21 (−71%) | 583 → 494 |
| pile40 | 6.73 / 6.77 ms | 1.23 / 1.16 ms | 15.6 / 15.7 | 4.02 / 3.80 (−75%) | 431 → 305 |
| shapepile40 | 8.49 / 8.18 ms | 1.93 / 1.87 ms | 17.4 / 16.8 | 4.86 / 4.73 (−72%) | 488 → 396 |
| mixed80 | (not measured then) | 4.36 / 4.10 ms | | 6.18 / 5.80 | 706 |

mixed80 has 1.43 × mixed40's live beads and costs 1.65 × its frame (1.15 × per bead-frame): the
step's pair work grows a little faster than the beads, as stage 2 measured. packed30 is the
least improved per bead-frame: it is the most merge-heavy scenario (33 merges and 9 splits among
6 surviving bodies), and merges and cuts are GDScript work done per event, not per bead.

| stability measure | Rapier-era head | kernel |
|---|---|---|
| pile40: pair-samples with a bead inside another body / longest | 16 / 0.1 s | 12 / 0.1 s |
| mixed40: pair-samples / longest | 34 / 0.4 s | 24 / 0.1 s |
| shapepile40: pair-samples / longest | 21 / 0.1 s | 15 / 0.1 s |
| packed30: pair-samples / longest | 49 / 0.6 s | 14 / 0.1 s |
| round40, big12, mixed80: pair-samples / longest | (not reported) | 8 / 0.1 s, 11 / 0.1 s, 49 / 0.4 s |
| passthrough, widest gap in the big ring, 2500 px/s from above, round / square | 6.0 / 5.2 px open | −5.2 / −5.1 px (closed) |
| passthrough, 1500 px/s from above, round / square | 0.1 / 1.1 px open | −5.4 / −5.3 px (closed) |
| inside: a body spawned half inside another, apart after | 0.02 to 0.08 s | 0.02 to 0.07 s |
| undrawable skin body-frames (all scenarios) | 0 | 0 of 79,180 |
| impale, 189 cases: bodies left with a tip inside their loop | 0 (26 trims) | 0 (52 trims, 64 splits) |
| impale_pile: bodies with the tip inside their loop | 0 | 0 |

What got worse, plainly:

- **Bounce.** The smallest blob rebounds 15-20 px from a 500 px drop instead of about 40: the
  solver's contacts are position constraints and the skin takes a bead's bounce back within a
  substep, so a ring rebounds on its pressure (stage 2 tried scaled restitution, velocity
  iterations through the skin and soft contacts; none kept). `test_bounce` asserts more than 12 px
  and that small blobs still rebound higher than big ones.
- **Trims.** Twice as many impale cases end in a trim instead of a split (52 against 26): the
  bigger beads let the apex get between them more often. Every one leaves the body off the tip,
  which is the rule; it is a change in how a cut looks, not a failure.
- **Faceting.** 12-22 beads per ring (from 16-30) make skins slightly more faceted and moved a few
  thresholds (stage 2's list); the cost of a frame was the reason.
- **Native code to build or download.** The addon is no longer pure GDScript: it needs a library
  per platform (Rust to build it, or a release to download), and there is no web build yet.

Nothing in the bench or stability tables is worse than the Rapier-era head.
