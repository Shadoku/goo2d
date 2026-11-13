# rings_and_cells

Both kinds of goo in one top-down tank, colliding: ring bodies (`Goo2D` in a `GooWorld2D`,
the `Rings` node) and creatures made of cells (a `GooCellWorld2D`, the `Cells` node). The cell
world's `ring_world` names the ring world, which couples the two (docs/cells.md, "Rings and
cells"): each frame the cell world steps after the ring world and resolves every contact
between a ring and a cell itself, pushing both. Neither world has gravity.

In the tank, inside four walls:

- seven rings of 30-56 px, round, a square and a triangle, that never merge or split
  (`RingsAndCellsWorld`), drifting in the middle;
- a worm 18 × 4 with a spine row swimming round the tank by its pose wave, through the rings;
- a hex blob of three rings pushed toward one ring after another (three seconds each), shoving
  it about;
- a small blob of seven cells, knocked about by the others.

Run it: `godot --path . examples/rings_and_cells/rings_and_cells.tscn`.

## Controls

| Input | What it does |
|---|---|
| Left drag | Grabs the ring (`GooWorld2D.grab()`) or the creature (`GooCellWorld2D.grab()`) under the mouse |
| R | Empties the tank and builds it again |

## Files

- `rings_and_cells.tscn`: the scene: a backdrop, `Walls` (a `StaticBody2D`: four slabs, which
  both worlds mirror), `Cells` (a `GooCellWorld2D`, `ring_world` `../Rings`; it comes first in
  the tree, and coupling raises its `process_physics_priority` above the ring world's so it
  still steps second), `Rings` (a `RingsAndCellsWorld`), `UI/Label`.
- `rings_and_cells.gd`: `RingsAndCellsExample`: `build()`, the worm's steering and the blob's
  push each physics frame, the mouse grab of either kind, R.
- `rings_world.gd`: `RingsAndCellsWorld` (`may_merge()` and `may_split()` off).
- Tests: `tests/integration/examples/test_rings_and_cells.gd`.

## Addon hooks it uses

- `GooCellWorld2D.ring_world` (or `couple()`), `ring_density`, `ring_rigidity`,
  `coupling_stats()`, `coupled_world()`.
- `GooWorld2D.spawn()`, `body_at()`, `grab()`, `may_merge()`, `may_split()`;
  `GooCellWorld2D.spawn()`, `creature_at()`, `grab()`; `GooCellCreature.set_pose_wave()`,
  `push()`.
