# links

Bodies joined by links (`GooWorld2D.link()`): each linked pair holds together, bends at its
joint and is drawn as one blob with a neck (the bridge skin, `GooLink`). Top-down: the tank has
no gravity (`gravity_scale` 0 on its world) and its world never merges bodies (`LinksWorld`;
linked bodies never merge with each other anyway, this keeps a chain's bodies one apart from
merging when they touch).

In the tank: a chain of five round bodies (strength 0.7), a round body linked to a square and to
a triangle (0.8: on a polygon the patch sits on whatever faces the other body, a face or a
corner), three pairs at strengths 0.2, 0.6 and 1 (a thread to a wide neck), and a chain of three
whose first link's rest angle swings ±0.6 rad at 0.5 Hz (`set_link_rest_angle()` every physics
frame), so that joint bends back and forth.

Run it: `godot --path . examples/links/links.tscn` (or open the scene in the editor and press F6).

## Controls

| Input | What it does |
|---|---|
| Left drag | Grabs the body under the mouse and pulls it (`GooWorld2D.grab()`): its group follows |
| R | Empties the tank and builds it again |

## Files

- `links.tscn`: the scene: a backdrop (`assets/shaders/backdrop.gdshader`, for the goo to
  refract), `Walls` (a `StaticBody2D` on layer 1: four walls), `World` (a `LinksWorld`,
  `gravity_scale` 0), `UI/Label`.
- `links_world.gd`: `LinksWorld extends GooWorld2D`: `may_merge()` always false.
- `links.gd`: `LinksExample`, the scene script: builds the groups and links them (`build()`),
  swings the waving chain's first link, the mouse grab, R.
- Tests: `tests/integration/examples/test_links.gd`.

## Addon hooks it uses

- `GooWorld2D.link(a, b, strength)`, `set_link_rest_angle()`, `link_bend()`, `links()`,
  `link_strength()`, `link_info()` (the bridge).
- `GooWorld2D.grab()`, `move_grab()`, `release_grab()`, `body_at()`.
- `GooWorld2D.gravity_scale` (0) and `may_merge()` (overridden).
- `GooSkin.warm_up(self)` in `_ready()`, so the goo shader compiles at boot.
