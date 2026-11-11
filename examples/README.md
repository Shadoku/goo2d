# Goo2D examples

Small scenes that each show one way of using the addon in `addons/goo2d/`. Every example is
a directory with an entry scene named after it; run one with

```
godot --path . examples/<name>/<name>.tscn
```

`python3 tools/check.py` boots every example headless (`smoke examples/<name>`) and draws it
with the real renderer (`render examples/<name>`), so their scenes and shaders are checked with
the rest of the project; their tests live in `tests/integration/examples/`.

| Example | Shows | Addon hooks it uses |
|---|---|---|
| [`color_merge/`](color_merge/README.md) | Blobs in four colours that merge only with their own colour, whatever their sizes | `Goo2D.color`, `GooWorld2D.may_merge()`, `GooWorld2D.merged_color()` |
| [`tower/`](tower/README.md) | A tower-building minigame: stiff square blobs dropped onto a narrow platform, won when the stack stands above the goal line | `GooWorld2D.tuning_for()` (stiffer bodies in one world), `may_merge()` (off, so the blocks stay separate), editor-placed platform and goal line |
| [`two_tone/`](two_tone/README.md) | Blobs that merge whatever their colours, a merged body drawn in both its parents' colours with a soft division that turns with it as it rolls | `GooWorld2D.two_tone_merges`, `GooWorld2D.merged_colors()` (its default), `Goo2D.set_two_tone()`, `Goo2D.second_color` |
| [`resize/`](resize/README.md) | Bodies that breathe between two sizes (round, square, triangle; their rings rebuilt where the bead count changes) and one that squashes rhythmically; the wheel resizes the body under the pointer | `Goo2D.resize()`, `Goo2D.set_rest_deform()`, `GooWorld2D.body_rebuilt`, `GooWorld2D.body_at()`, `may_merge()` (off) |
| [`links/`](links/README.md) | Bodies joined by links in a top-down tank: a chain, a round body linked to a square and a triangle, links of three strengths, a joint swung back and forth; each pair drawn as one blob with a neck | `GooWorld2D.link()`, `set_link_rest_angle()`, `link_bend()`, `grab()`, `gravity_scale` 0, `may_merge()` (off) |
| [`shaders/`](shaders/README.md) | The same goo drawn by three skins: the addon's wet goo, a cel-shaded solid, a faceted gem | `GooWorld2D.skin_shader`, `Goo2D.skin_shader`, the uniform contract in `goo.gdshader` |

The gaps these examples exposed in the addon (the merge rule as an override, a body's own
colour, a swappable skin shader, `despawn()`, per-world tuning, blade cutting in the addon) are
all closed; the plan that found them is in the git history.

Each example depends only on the addon, the backdrop shader in `assets/shaders/` (the goo needs
something behind it to refract) and, for shaders, the cel and gem skins in `assets/goo/`.
