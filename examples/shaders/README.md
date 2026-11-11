# shaders: one goo, three skins

Run it with `godot --path . examples/shaders/shaders.tscn`.

Three columns side by side, each its own `GooWorld2D` (a `ShadersWorld`) with its own floor
and walls (a `StaticBody2D` on layer 1) and its own `skin_shader`:

| Column | `skin_shader` | Look |
|---|---|---|
| left | none (null) | the addon's wet goo, `addons/goo2d/goo.gdshader` |
| middle | `assets/goo/cel.gdshader` | flat, cel-shaded, inked |
| right | `assets/goo/gem.gdshader` | a faceted, sparkling stone |

The two skins live in `assets/goo/`.

Every second the same next body drops into all three columns at the same spot: sizes cycle
through 32, 54, 76, 98 and 120 px, shapes through round, square and hexagon (five sizes
against three shapes, so every size comes in every shape), the spot from a seeded
`RandomNumberGenerator` (`ShadersExample.rng`, `drop_seed`). The columns start out alike and
drift apart as the goo settles a little differently in each.

A column keeps at most 8 bodies, covering at most 40% of it: past either, its oldest body is
despawned (`GooWorld2D.despawn()`); a body pushed out of its column is despawned too.
`ShadersWorld` only lets a merge make a body up to 140 px (`max_merged_radius`), so a column
shows several bodies rather than one that fills it (by the default rule two shapes merge flat
face to flat face whatever their sizes).

Controls: click drops the next body at the mouse, in the column under it; R clears every
column and starts the sequence over.

## The shaders

Both are `canvas_item` shaders on the body's `Skin` polygon. They read a fragment's global
position from `MODEL_MATRIX` in `vertex()` and measure its signed distance to the body's
outline (`points`), with the smoothed outward normal there, with the same block as
`goo.gdshader`. Neither cuts alpha: the polygon's antialiased edge is the silhouette.

### `cel.gdshader`

Solid body colour (`COLOR`, no screen texture). The normal is the goo shader's pseudo-3D rim
normal, rolled off over a rim that is a share of the radius (`pillow`) so the whole body is a
soft pillow, plus a faint dome. `dot(normal, light_dir)` is quantised into three flat bands
(shadow, mid, lit: `shadow_threshold`, `lit_threshold`, `*_level`; the shadow leans toward
`shadow_hue`), each edge antialiased over a pixel. On top: a hard-edged specular dot where the
normal meets the half vector (`specular_size`) and a small second dot beside it, a soft
shadow band along the rim on the side away from the light (`rim_shadow_px`,
`rim_shadow_strength`) and a dark ink outline (`outline_px`, `outline_level`). The band edges
wobble faintly with `TIME`, more while the body moves (`wobble`, `motion_wobble`), so it reads
as goo rather than plastic.

Skin uniforms used: `point_count`, `points`, `center`, `radius`, `velocity`, `seed`.

### `gem.gdshader`

Facets: a hashed Voronoi pattern in polar coordinates around `center`, scaled by `radius`,
so every gem has the same cut whatever its size: a ring of crown facets about `facet_size`
of the radius each (a whole number of them around, so the pattern closes) around an octagonal
table (`table_size`), itself cut the same way at its own scale (the pavilion's facets seen
through it). Each facet is a flat plane: a crown facet slopes outward (`crown_slope`), every
one has a random tilt (`tilt_jitter`), and the body's `velocity` (`motion_tilt`) and a slow
`TIME` shimmer turn the tilts. Each facet is lit by `light_dir`: flat diffuse with a little
light bouncing inside, a sharp specular (`specular_power`) and a fresnel edge
(`fresnel_power`). The stone's colour is `COLOR` saturated (`saturation`) and deepening
toward the rim; it covers (`opacity`) the screen behind, sampled with one refraction offset
per facet (`refraction_px`), so neighbouring facets show different slices of the backdrop.
Thin ridges between facets are pale where they face the light and dark otherwise
(`edge_width`). A facet whose reflection lines up with the light (`sparkle_threshold`) flares,
with a four-pointed glint on its site: it happens as the body moves and its tilts turn.

Skin uniforms used: `point_count`, `points`, `center`, `radius`, `velocity`, `rotation` (the
facets are cut in the body's rest pose and turned by it, so they roll and tip with the body
instead of staying fixed around its centre), `seed` (the facet pattern's own seed, kept by a
body's pieces).

## A shader of your own

Write a `canvas_item` shader declaring any subset of the skin's uniforms (`point_count`,
`points[32]`, `center`, `radius`, `velocity`, `seed`, `bubble_origin`, `bubble_cell`: the
contract at the top of `addons/goo2d/goo.gdshader` and in the addon README's "Another skin
shader"); `COLOR` is the body's tint and `TIME` is free. Then:

- for a whole world, set the world's `skin_shader` (in the inspector, or from a script at any
  time): every body registered in it without a shader of its own draws with it, the bodies
  already in the world at once;
- for one body, set its `Goo2D.skin_shader`;
- call `GooSkin.warm_up(self, my_shader)` once at boot (this scene's `_ready()` does it for
  each column's shader), so it compiles before the first body shows and `check.py`'s render
  stage compiles it.

Split pieces and merged bodies keep their parent's shader. Shaders are never compiled
headless: run `python3 tools/check.py --only render`, or render this scene to a PNG with
`tools/screenshot.gd --scene=res://examples/shaders/shaders.tscn` (see CLAUDE.md), to see a
compile error or the look.

## Files

- `shaders.tscn`: the scene (backdrop, three columns of walls, three worlds, the labels).
- `shaders.gd`: `ShadersExample`, the scene script (drops, the cap, click and R, warm-ups).
- `shaders_world.gd`: `ShadersWorld`, the columns' world (the merge size cap).
- `assets/goo/cel.gdshader`, `assets/goo/gem.gdshader`: the two skins (shared with the game's
  earth and metal goo kinds).
- Tests: `tests/integration/examples/test_shaders.gd`.
