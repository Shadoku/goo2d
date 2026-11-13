# elastic

Elastic bodies and head-led turning on creatures of cells (`GooCellWorld2D`, docs/cells.md,
"Elastic bodies" and "Head-led turning"), top-down, in four lanes of one world at
`elasticity` 0.65 (14 px cells at `GooTuning.unit` 1: the fluid game's creatures twice as
large):

- a 37-cell blob, its own elasticity 0.8 (`GooCellCreature.set_elasticity()`), thrown at the
  left wall every 2.5 s: it flattens where it hits and rounds out within a fifth of a second;
- a 16 × 5 worm struck amidships by a small heavy blob held stiff (its own elasticity 0): it
  bends round the blow and straightens;
- two ships of 10 × 5 cells (the game's thruster ship's layout, its rear cells orange) turning
  180° back and forth by the spin servo at the game's profile: the left one head-led
  (`set_turn_lead(1)`), so its nose swings first and the body follows; the right one turned as
  a stick (lead 0);
- a blob of jelly (its own elasticity 1) pushed through a gap 0.8 of its width, and brought
  back each time it is through.

The skin is the default goo skin. R rebuilds. `tools/elastic_shot.gd` renders contact sheets of
each lane.

Run it: `godot --path . examples/elastic/elastic.tscn`.
