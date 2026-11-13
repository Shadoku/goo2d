# cells

Creatures made of cells, one disc particle per cell (`GooCellWorld2D`, docs/cells.md): a
creature is a design of cells (`GooCellDesign`) with types (`GooCellType`), spawned into the
world as a handle (`GooCellCreature`), not a node, and drawn as one skin, cells of one type as
one piece. Top-down: the tank has no gravity (`gravity_scale` 0 on its world); the water swirls
slowly round the tank's middle, fed to the world per cell (`water_source`), so each cell feels the
water where it is.

In the tank, inside four walls and around a concave rock (both plain `StaticBody2D` collision
shapes, mirrored by `GooStatics`):

- a worm 24 × 5 of body cells with a spine row of another type, driven by its swim drive
  (`set_swim()`: every cell pushed along its own forward, so the push follows the body's curve;
  the spine's `swim_weight` 2 makes that row push hardest) under a gentle pose wave
  (`set_pose_wave()`, slope 0.3: the design bent by a curvature wave running head to tail, the
  visible stroke, with the drive rippling in step with it), and steered toward waypoints round the
  tank by the wave's curvature bias alone: the bent body steers itself;
- a hex blob of four rings whose back rim is thruster cells (`set_cell_thrust()`), turned toward
  the same waypoints by a twist (`twist()`) and pushed only while it roughly faces its goal;
- a mixed-size creature (cells of 10 to 26 px, two types) from a saved design, `mixed.tres`,
  drifting with the water;
- a crawler 12 × 3 of three shape-matched segments (one type, three groups: three regions) whose
  two joints swing out of phase (`set_joint_angle()`).

Run it: `godot --path . examples/cells/cells.tscn` (or open the scene in the editor and press F6).

## Controls

| Input | What it does |
|---|---|
| Left drag | Grabs the creature under the mouse and pulls it (`GooCellWorld2D.grab()`) |
| R | Empties the tank and builds it again |

## Files

- `cells.tscn`: the scene: a backdrop (`assets/shaders/backdrop.gdshader`), `Walls` (a
  `StaticBody2D` on layer 1: four slabs and the rock, a concave `CollisionPolygon2D`, with
  `Polygon2D`s drawing them), `World` (a `GooCellWorld2D`, `gravity_scale` 0), `UI/Label`.
- `cells.gd`: `CellsExample`, the scene script: the types and the built designs (`worm_design()`,
  `blob_design()`, `crawler_design()`), `build()`, the swirl (`swirl()`), the steering, the
  thrusters and joints each physics frame, the mouse grab, R.
- `mixed.tres`: a `GooCellDesign` saved as a resource (70 cells of 10-26 px; its two
  `GooCellType`s inside it): open it in the inspector to see the arrays.
- Tests: `tests/integration/examples/test_cells.gd`.

## Addon hooks it uses

- `GooCellWorld2D.spawn()`, `clear()`, `despawn()`, `creatures()`, `creature_at()`,
  `water_source`, `grab()`, `move_grab()`, `release_grab()`, `gravity_scale`.
- `GooCellCreature.set_swim()`, `set_pose_wave()`, `twist()`, `set_cell_thrust()`, `set_joint_angle()`,
  `center()`, `heading()`, `spin()`, `cell_type()`.
- `GooCellDesign.hex_worm()`, `hex_blob()`, `add_cell()`; `GooCellType` (colour, body mode,
  `swim_weight`).
