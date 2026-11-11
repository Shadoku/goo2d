# resize

Goo bodies that change size and shape while they live: three breathe between two sizes, a round
one, a square and a triangle (`Goo2D.resize()`, one ease per half breath), and one squashes
rhythmically along its rest pose's horizontal (`Goo2D.set_rest_deform()`, called every physics
frame). A resize eases the body's rest outline, bead radius, target area and size-dependent
tuning into the new size in place; where the size passes a bead count's boundary the ring is
rebuilt on its own beads with the new count (`Goo2D.rebuilt`, `GooWorld2D.body_rebuilt`), the
same node, colour and skin. Nothing merges here (`ResizeWorld.may_merge()` is false), so the
four stay four.

The squasher is squashed from the first frame, so `check.py`'s render stage, which draws only the
first frames, draws a deformed body.

Run it: `godot --path . examples/resize/resize.tscn` (or open the scene in the editor and press
F6).

## Controls

| Input | What it does |
|---|---|
| Mouse wheel | Grows (up) or shrinks (down) the body under the pointer by 12% a notch; a breathing body stops breathing |
| + / - | The same, for the body under the pointer |
| R | Puts the four bodies back |

The label at the top shows each body's eased radius.

## Files

- `resize.tscn`: the scene: a backdrop (`assets/shaders/backdrop.gdshader`, for the goo to
  refract), `Walls` (a `StaticBody2D` on layer 1: the floor and two walls, with their visuals),
  `World` (a `ResizeWorld`), `UI/Label`.
- `resize_world.gd`: `ResizeWorld extends GooWorld2D`: `may_merge()` is false.
- `resize.gd`: `ResizeExample`, the scene script: the breathers (`BREATHERS`: shape, smallest and
  largest radius, seconds per breath), the squasher (`SQUASH_AMPLITUDE`, `SQUASH_FREQUENCY`),
  the wheel and keys (`step_size_at()`, `WHEEL_STEP`), `reset()`, the label.
- Tests: `tests/integration/examples/test_resize.gd`.

## Addon hooks it uses

- `Goo2D.resize(radius, time)`, `eased_radius()`, `is_resizing()`: a breath is one resize each
  way, started when the last one ended.
- `Goo2D.set_rest_deform(squash, axis_rest, area_scale)`: the squasher, every frame.
- `GooWorld2D.body_at()`: the body under the pointer.
- `GooWorld2D.may_merge()` (overridden): never.
- `GooSkin.warm_up(self)` in `_ready()`, so the goo shader compiles at boot.
