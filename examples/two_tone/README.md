# two_tone

A body merged from two blobs of different colours is drawn in both: each colour on the side its
parent came from, a soft division between them (faded over the shader's `division_fade`, 10 px),
the bigger parent owning the bigger side, and the division turning with the body as it rolls or
tips. Blobs here merge whatever their colours (up to `TwoToneWorld.MAX_MERGED_RADIUS`, 110 px, so
the box keeps a few blobs); a merge of two two-tone blobs keeps their dominant colours, two per
body at most. The world turns it on with one switch, `GooWorld2D.two_tone_merges`.

At start six blobs in the colour merge example's palette fall in three pairs that meet in the
first second, and one blob already red over blue rolls left along the floor from the first frame
(so `check.py`'s render stage, which draws only the first frames, draws a division).

Run it: `godot --path . examples/two_tone/two_tone.tscn` (or open the scene in the editor and
press F6).

## Controls

| Input | What it does |
|---|---|
| Space | Drops a blob of a random size and palette colour from the top, at a random x |
| Left click | Drops one where the mouse is (moved inside the box if it is not) |
| R | Empties the box and starts the merge count over |

The label at the top counts merges, blobs and the two-tone ones.

## Files

- `two_tone.tscn`: the scene: a backdrop (`assets/shaders/backdrop.gdshader`, for the goo to
  refract), `Walls` (a `StaticBody2D` on layer 1: the floor and two walls, with their visuals),
  `World` (a `TwoToneWorld` with `two_tone_merges` on, set in the scene), `UI/Label`.
- `two_tone_world.gd`: `TwoToneWorld extends GooWorld2D`: `may_merge()` lets any two blobs merge
  up to `MAX_MERGED_RADIUS`; the colours are the default `merged_colors()`'.
- `two_tone.gd`: `TwoTone`, the scene script: the opening (`OPENING`, the rolling two-tone
  `ROLLER`), Space, the click, reset, the despawn of lost blobs, the label. Its `rng` draws the
  dropped blobs' sizes, colours and x; `opening` turns the opening off (the tests place their
  own).
- Tests: `tests/integration/examples/test_two_tone.gd`.

## Addon hooks it uses

- `GooWorld2D.two_tone_merges` (on): merges of two colours make two-tone bodies, their colours
  `GooWorld2D.merged_colors()`' default (the same combination merges as usual, any other pair
  takes the two dominant colours).
- `GooWorld2D.may_merge(a, b)` (overridden): any colours, up to a size.
- `Goo2D.set_two_tone(primary, second, axis_rest, offset)`: the roller is made two-tone by hand,
  its division across its rest pose's vertical (`Vector2.DOWN`: the second colour below).
- `Goo2D.color`, `second_color`, `is_two_tone()`; a split piece keeps both colours by itself
  (`Goo2D.inherit_look()`).
- `GooSkin.warm_up(self)` in `_ready()`, so the goo shader compiles at boot.
