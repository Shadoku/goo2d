# color_merge

Blobs come in four colours (red, yellow, green, blue) and merge only with blobs of their own
colour, whatever their sizes: a 28 px red drop and a 90 px red one combine, two 40 px blobs of
different colours only ever bump into each other. The size rule of the default world is off;
the `GooTuning.MAX_RADIUS` cap stays, so a merged blob is always a size the goo's tuning was
measured for (two blobs whose merge would be bigger just rest against each other).

A hopper drops a blob of a random size (28 … 90 px) and a random colour from a random x every
1.2 s, into a box with a floor and two walls. It waits while the blobs fill `FILL_LIMIT` of the
box, so the pile never spills; a blob that leaves the screen anyway is despawned. The faint
circle above the box is the hopper's next blob, filling in as its drop nears.

Run it: `godot --path . examples/color_merge/color_merge.tscn` (or open the scene in the editor
and press F6).

## Controls

| Input | What it does |
|---|---|
| Left click | Drops a blob where the mouse is (moved inside the box if it is not), in the picked colour; the translucent circle at the mouse previews it |
| 1 / 2 / 3 / 4 | Picks the colour of the next click's blob (the legend left of the box rings it) |
| R | Empties the box and starts the merge count over |

The label at the top counts merges and blobs.

## Files

- `color_merge.tscn`: the scene: a backdrop (the project's `assets/shaders/backdrop.gdshader`, for
  the goo to refract), `Walls` (a `StaticBody2D` on layer 1: the floor and two walls, with
  their visuals), `World` (a `ColorMergeWorld`), `UI/Label`.
- `color_merge_world.gd`: `ColorMergeWorld extends GooWorld2D`, the rule: `PALETTE`,
  `may_merge()`, `merged_color()`, `spawn_colored()`.
- `color_merge.gd`: `ColorMerge`, the scene script: the hopper, the click drop, the colour keys,
  reset, the despawn of lost blobs, the label and the legend. Its `rng`
  (`RandomNumberGenerator`) draws every random number: seed it before the scene enters the tree
  to replay a game; `hopper_enabled` turns the hopper off.
- Tests: `tests/integration/examples/test_color_merge.gd`.

## Addon hooks it uses

- `GooWorld2D.may_merge(a, b)` (overridden): the one place the world asks whether two touching
  bodies combine. Here: `a.color == b.color` and
  `GooTuning.merged_radius(a.radius, b.radius) <= GooTuning.MAX_RADIUS` (two bodies both left at
  `Goo2D.COLOR_BY_SIZE` fall back to the default `can_merge()`).
- `GooWorld2D.merged_color(a, b)` (overridden): the merged body's colour, here the pair's. The
  pair is tinted toward it while it merges.
- `Goo2D.color`: each blob's own colour (set right after `GooWorld2D.spawn()`); a split piece
  keeps its parent's by itself.
- `GooWorld2D.spawn()`, `despawn()`, `clear()`, `bodies()`; the signals `merged` (the merge
  count) and `count_changed` (the blob count).
- `GooSkin.warm_up(self)` in `_ready()`, so the goo shader compiles at boot.
