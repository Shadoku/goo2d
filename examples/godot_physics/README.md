# godot_physics

Goo meeting Godot's own physics nodes (docs/godot-physics.md). Both kinds of goo have
`physics_proxies` (each body or creature stands in Godot's physics as a kinematic body of
circles) and `push_bodies` (Godot bodies on the wall layer that move push the goo) on:

- a **sensor** (`Area2D`, its mask the proxies' layer, `GooTuning.LAYER_PROXIES`) lights up
  while goo is inside it (`body_entered` / `body_exited`, the body a `Goo2D`);
- a **crate** (`RigidBody2D` on `GooTuning.LAYER_WALLS`) rests on a square blob: the goo pushes
  it within its step as a rigid body and the reaction is applied to it after the step; it is
  excepted from the proxies, so the pair is solved once;
- a **paddle** (`AnimatableBody2D`, a cup of two bars) carries a small blob in and out of the
  sensor, pushing it at its own velocity;
- a **character** (`CharacterBody2D`, its mask walls and the proxies' layer) walks into a
  creature of cells (`GooCellWorld2D`), is stopped by its proxy and turns round.

The ring world never merges (`GodotPhysicsWorld.may_merge()`), so the three blobs stay apart.
A round blob would not hold the crate: a box on a ball that rolls freely slides off
(docs/godot-physics.md, quirks); the square does.

Run it: `godot --path . examples/godot_physics/godot_physics.tscn`.

## Controls

| Input | What it does |
|---|---|
| Left drag | Grabs the ring body under the mouse (`GooWorld2D.grab()`) |
| R | Builds the scene again |

## Files

- `godot_physics.tscn`: the scene: a backdrop, `Walls` (a `StaticBody2D` on layer 1: a floor and
  two walls), `World` (a `GodotPhysicsWorld`, `physics_proxies` and `push_bodies` on), `Cells`
  (a `GooCellWorld2D`, the same, drag off), `UI/Label`.
- `godot_physics_world.gd`: `GodotPhysicsWorld extends GooWorld2D`: `may_merge()` always false.
- `godot_physics.gd`: `GodotPhysicsExample`, the scene script: `build()` spawns the blobs and
  the creature and makes the sensor, crate, paddle and character; the paddle's sweep and the
  character's walk in `_physics_process()`.

Its test: `tests/integration/examples/test_godot_physics.gd`.
