# thrusters

Thruster cells and spike tips on creatures of cells (`GooCellWorld2D`, docs/cells.md,
"Thrusters" and "Spike tips"), top-down:

- a hex blob of three rings whose rim cells are thrusters (`GooCellType.max_thrust`), each
  facing inward (`GooCellDesign.angles`), flies round four waypoints. Once a frame it reads its
  thrusters (`GooCellCreature.thrusters()`: each one's index, facing and maximum force) and sets
  every level in one call (`set_thrust_levels()`): a thruster facing the way fires by how
  squarely it does, the simplest allocator;
- a block 6 × 7 whose front column is spikes (`GooCellType.tip_length`, `tip_radius`: a small
  disc out along each cell's facing, held rigidly by the cell) is pushed at the right wall and
  back again; its tips meet the wall first and hold its cells off it. Its heading is held by the
  spin servo: a creature pushed onto a wall by spikes ahead of its centre would turn off them.

The skin draws neither thrusters nor spikes: the scene draws a plume behind each firing thruster
and a spike to each tip (`tips()`), once a frame. R rebuilds.

Run it: `godot --path . examples/thrusters/thrusters.tscn`.
