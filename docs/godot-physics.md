# Goo and Godot's physics

The goo (ring bodies, `Goo2D` in a `GooWorld2D`, and creatures of cells in a
`GooCellWorld2D`) is moved by its own native kernel, not by Godot's physics server. Without help
the two never meet: an `Area2D` never sees goo, a ray passes through it, a `CharacterBody2D`
walks through it and a `RigidBody2D` falls through it. Two opt-in parts of each world bridge
them, both off by default (with both off, nothing of the goo's behaviour changes: the golden
trace is unchanged):

- **`physics_proxies`: goo visible to Godot.** Each body or creature gets a proxy, a kinematic
  body in the world's physics space, moved to the goo's outline after every goo step.
- **`push_bodies`: Godot bodies visible to goo.** Every `AnimatableBody2D`, `CharacterBody2D`
  and `RigidBody2D` on `GooTuning.LAYER_WALLS` becomes a moving obstacle that pushes the goo at
  its own velocity, and a rigid body takes the goo's reaction.

`examples/godot_physics/` shows both: a sensor lit by goo, a crate resting on a blob, a paddle
carrying a blob, a character stopped by a creature.

## Proxies (`physics_proxies`)

`GooProxies` (one per world, `world.proxies()`) keeps one body per goo body or creature, made
directly in the `PhysicsServer2D`: `BODY_MODE_KINEMATIC`, in the world's space, its object the
goo's owner node, so everything in Godot that reports a collider names it:

| Who | What it gets |
|---|---|
| `Area2D.body_entered` / `body_exited` | the `Goo2D`, or the creature's proxy node |
| a ray or shape query (`PhysicsDirectSpaceState2D`) | `collider` the same |
| `CharacterBody2D.get_slide_collision(i).get_collider()` | the same |
| `RigidBody2D` contacts (contact monitor) | the same |

`GooWorld2D.body_of(collider)` returns the `Goo2D` (null for anything else);
`GooCellWorld2D.creature_of(collider)` returns the `GooCellCreature`. A creature is not a node,
so it gets one: `GooCellCreature.proxy_node()`, an internal `Node2D` child of the world kept at
the creature's centre and holding its handle in its metadata (`GooCellCreature.PROXY_META`); it
is freed with the creature.

**Why server bodies.** An `AnimatableBody2D` per body with a `CollisionShape2D` per bead would be
40 nodes for one blob and 4500 for 30 creatures, each moved through the node's transform
notifications. A server body is moved by one `body_set_state()` and one
`body_set_shape_transform()` per shape; circles of one radius share one shape (`RADIUS_STEP`,
0.05 px, so a creature's cells of nearly one size share a few). Godot defers a moved shape's
broad-phase update to its own step, so the moves cost little until then.

**Shapes** (`proxy_shape`):

- `CIRCLES` (default): a circle per bead (rings) or per boundary cell (creatures, their outline:
  42 of a 150-cell blob's cells). Hollow: a point or a small shape wholly inside a blob, clear of
  its rim, meets nothing.
- `HULL`: one convex polygon, the outline's convex hull grown by the bead or cell radius (each
  corner cut to the two points of its round join, `GooProxies.grown_hull()`). Solid, one shape,
  but a concave body (a bent worm, a crescent) has its hollows filled in.

**Velocity.** The proxy's transform is the goo's centre (no rotation); its shapes are placed
about it. Godot gives a kinematic body the velocity of its transform's change over the step, so a
rigid body hitting a proxy meets the goo's mean velocity, not its spin or its local wobble.

**Timing.** Proxies are moved at the end of the world's `_physics_process()`, after the goo's
step; Godot's server moves them during its own step of the same frame. Queries made in the next
frame see where the goo was at the end of this one.

**Layers.** Proxies are on `proxy_layer`, `GooTuning.LAYER_PROXIES` (layer 2), with `proxy_mask`
0: an area, a ray or a body meets the goo when its own mask has layer 2. They are never on
`LAYER_WALLS` by default, and `GooStatics` only reads nodes, so the goo never takes its own
proxies for walls. Per body: override `wants_proxy(body)` (or `wants_proxy(creature)`), asked
every frame. A settled ring's proxy is not moved.

## Moving obstacles (`push_bodies`)

`GooStatics` (each world's mirror of the scene's walls) already mirrored every `StaticBody2D`
on `LAYER_WALLS`, an `AnimatableBody2D` among them, as convex polygons; a moved one jumped to its
new place at the next step and its cells or beads were pushed out of it after the fact (nearest
face, or for cells the face their centre entered by, judged against a still wall). With
`push_bodies` on:

- character and rigid bodies on `LAYER_WALLS` are mirrored too (their `CollisionShape2D` and
  `CollisionPolygon2D` children, as for static bodies);
- every moving body's shapes are moving obstacles in the kernel (`obstacles.rs`):
  - an `AnimatableBody2D`, a `CharacterBody2D` or a frozen `RigidBody2D` is given its pose every
    frame (`set_static_target()`): the solver eases it from where it was to where it is over the
    step's substeps (a path the goo cannot change, one frame behind the body);
  - a `RigidBody2D` is given where it is now, its velocity with gravity's pull over the step, its
    angular velocity, centre of mass, inverse mass and inverse inertia (`set_static_rigid()`;
    divided by the world's `body_mass_scale`): within the step it moves by its own velocity,
    which every contact changes, so the goo pushes a body it meets during the step and not a
    frame later;
- each substep a bead or cell is judged on its motion relative to each obstacle (its start
  carried by the obstacle's own motion that substep): swept along that, stopped at the first
  overlap and pushed out (beads), or pushed out through the face its centre entered by (cells);
  so a thin bar sweeping into the goo pushes it ahead and never leaves a cell behind;
- the contact is inelastic: the normal impulse between the particle and the obstacle
  (`-rel / (w + w_obstacle)`, `w_obstacle` the body's inverse mass seen at that point and along
  that normal; 0 for a path) is what the particle's velocity changes by along the normal (the
  push out of an overlap is not turned into a fling), plus position-based Coulomb friction
  against the surface (the lower of the bead's and the shape's friction for rings, the shape's
  for cells);
- the impulses are summed per shape (`static_impulses()`: the impulse and its moment), and after
  the goo's step `GooStatics.push_back()` applies their sum to each `RigidBody2D`
  (`apply_central_impulse()` at its centre of mass, the rest as `apply_torque_impulse()`),
  divided by `body_mass_scale`; Godot's step then moves it (and resolves its other contacts).

Within a substep the ring kernel's contacts are sequential (each changes the body's motion before
the next is judged); the cells' run in parallel per creature, so each cell judges its contact
alone and the body's inverse mass is shared among the last substep's contacts (mass splitting,
`StaticShape::split`), the impulses given to the body between substeps.

**Which path handles a rigid body.** A `RigidBody2D` the goo pushes (on `LAYER_WALLS` with
`push_bodies` on) is excepted from every proxy (`PhysicsServer2D.body_add_collision_exception`,
`GooProxies.except()`, refreshed every frame), so Godot's solver never also pushes it off a
proxy: the pair is solved once, by the goo. A rigid body not on `LAYER_WALLS` but with layer 2 in
its mask meets the proxies only: Godot treats them as kinematic (infinitely heavy), so it bounces
off the goo and the goo does not feel it. A `CharacterBody2D` may be both: on `LAYER_WALLS` it
pushes the goo (one frame behind it), with layer 2 in its mask it is stopped by the goo; it
takes no reaction either way.

**Masses.** A `Goo2D`'s mass is `body_mass()` (a 48 px blob at unit 1 is about 8); a creature's
is `mass()`, its cells' areas at density 1 (a 37-cell blob of 14 px cells: 22 800). The goo's
impulses are in those units; `body_mass_scale` is the goo's mass per unit of `RigidBody2D.mass`
(1 by default: give the crate a mass in goo units).

## Measured

Tests in `tests/integration/test_goo_godot_physics.gd` (rings) and
`test_goo_cell_godot_physics.gd` (cells), real physics frames (Godot's server steps between the
goo's steps), unit 0.5 and 1 where sizes matter; `cargo test` (`obstacles.rs`) for the kernel's
part.

| Gate | Rings | Cells |
|---|---|---|
| Area2D entered and exited once each by drifting goo | yes (both units) | yes |
| A ray from above and a shape query hit the goo and resolve to it | hit on the rim; 4 shapes in the query | 1 hit; proxy circles 12 of a 19-cell blob |
| A walking `CharacterBody2D` (mask walls and proxies) stopped by resting goo | gap 0.01-0.04 px to the blob's left edge | deepest cell into it -0.01 / -0.08 px (unit 0.5 / 1) |
| A crate thrown at 300 px/s (unit 1; 150 at 0.5), crate mass = the goo's, zero gravity: momentum at the end of the contact | 6.6 % lost (the rings' own damping over the 0.7-1.4 s contact); crate 300 → 97 px/s, blob 0 → 122 px/s; deepest overlap -0.01 px | 0.00 % (2.4e-5); crate 300 → 61 px/s, creature 0 → 239 px/s; deepest overlap -0.29 px |
| The same with proxies on too | identical numbers: the crate is excepted from the proxy | excepted |
| A crate (mass ½ the goo's) resting under gravity, 5 s from 1 s after landing | on a square blob: 1.4 px (unit 0.5) / 5.4 px (unit 1) over the 5 s, then 0.08 / 0.17 px in the last second, drift 1-3 px, turn under 0.02 rad. On a round blob: it rolls off within 1-2 s (see quirks) | 0.00 px over the 5 s at both units, drift under 1 px |
| A pushed creature pushes a crate along | | a 36-cell worm pushed at 200 px/s² moved a crate (½ its mass, damped) 215 px in 3 s, deepest overlap 0.03 px |
| An `AnimatableBody2D` bar sweeping through at 300 px/s (150 at 0.5) | | no cell behind it, at any frame, at both units; the creature leaves at 1.8 × the bar's speed (an elastic creature hit by an unstoppable bar). With `push_bodies` off the old teleported wall also left none at this speed |
| A `CharacterBody2D` on the wall layer (push_bodies) walking into a blob at 100 px/s | shoves it 130 px in 2 s; deepest bead into it 1.67 px (= one frame of its walk: the path is a frame behind) | |
| Kernel alone (`cargo test`) | | a 6 px bar at 300 px/s through a 37-cell creature leaves no cell behind; the reported reaction equals the creature's momentum to 4e-6; a rigid box on a creature on a floor under gravity rests within 0.9 px |

Cost, on this machine (4 threads), `tools/cell_world_bench.gd --real --proxies=...` (30
creatures × 150 cells colliding, unit 0.5, 600 frames, three runs) and
`tools/bench.gd mixed40 round40 --proxies=...` (rings, up to 40 bodies, 27 at the end of
mixed40):

| | Proxies' update (GDScript) | Whole frame median (Godot's step included) | Shapes moved / frame |
|---|---|---|---|
| 30 × 150 cells, none | | 1.98-2.11 ms | 0 |
| 30 × 150 cells, CIRCLES | 0.29 ms (p95 0.41) | 3.00-3.26 ms (+1.0-1.2) | 1260 |
| 30 × 150 cells, HULL | 0.51-0.54 ms (p95 0.72-0.77) | 2.49-2.77 ms (+0.5-0.7) | 30 |
| mixed40 rings, none | | 2.11-2.14 ms | 0 |
| mixed40 rings, CIRCLES | 0.13 ms | 2.56-2.62 ms (+0.45) | 476 |
| mixed40 rings, HULL | 0.25-0.27 ms | 2.36-2.52 ms (+0.25-0.4) | 28 |

The circles cost Godot's server most (about 0.8 ms of the 1.1 for the cells: its broad phase
updates every moved shape); the hull costs GDScript most (the outline gathered and its hull
built per creature every frame), little in the server. p95 rose 1-2.5 ms in the cell runs (the
server's step is not threaded). `push_bodies` adds nothing while no body is mirrored; its cost per
moving body was not measured separately (the tests' scenes show no visible change).

## Quirks a game must design around

- **A box on a round blob rolls off.** A round ring rolls freely on a floor, so a crate on it is
  a box balanced on a ball (a rola-bola): it tips and slides off within one or two seconds. A
  square blob, a blob against a wall or a creature of cells holds it.
- **One frame behind for paths.** An `AnimatableBody2D` or `CharacterBody2D` is replayed over the
  goo's step from where it was to where it is (Godot moved it before the goo's step), so the goo
  is pushed one frame late: up to its speed × one frame inside it (1.7 px at 100 px/s). A rigid
  body is not: it is predicted from its velocity and moved within the step.
- **The reaction is one-sided in time.** A rigid body takes the goo's impulse after the goo's
  step and before Godot's; Godot's step then resolves its other contacts. A body pressed between
  goo and a wall is pushed by both in turn, not solved together; a heavy body falling fast on
  thin goo can still reach the floor through it.
- **Masses are the goo's.** Set a pushed rigid body's mass in goo units, or `body_mass_scale`.
- **Proxies report the centre's velocity only**, and circles leave a body hollow (`HULL` is solid
  but convex).
- **Rings and cells collide only when coupled**, not through this: a paddle in both worlds pushes
  both, and a blob and a creature pass through each other unless the cell world is coupled to the
  ring world (`GooCellWorld2D.couple()`, docs/cells.md's "Rings and cells"). Their proxies never
  meet in Godot's server (kinematic bodies on `proxy_layer` with `proxy_mask` 0).
- **A body coming or going rebuilds the mirror** (`GooStatics`), its moving bodies included, which
  loses one frame of their motion.
- Proxies are made lazily on the first update after `physics_proxies` is turned on; turning it
  off frees them. They live in the world's `World2D`; a world moved to another viewport gets new
  ones when it re-enters the tree.
