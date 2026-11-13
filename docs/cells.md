# Creatures of cells, one particle per cell (`GooCellWorld2D`)

The addon's second kind of goo: creatures made of many cells, each cell **one disc
particle**, for games that want dozens of creatures of 100-200 cells on screen. Built
2026-11-13 as "port stage P1" from the exploration in docs/explore-cells.md (kept as that
exploration's record: the model's derivation, the alternatives tried, Primordialis). This
document is the feature as built: the model, the API, the knobs and why, the measured
numbers, the limits and the quirks a game should be designed around.

| | |
|---|---|
| `addons/goo2d/goo_cell_world_2d.gd` | `GooCellWorld2D` (Node2D): the world: owns a `GooCells`, walls through `GooStatics`, steps, draws, signals |
| `addons/goo2d/goo_cell_creature.gd` | `GooCellCreature` (RefCounted): a handle to one creature: queries and forces |
| `addons/goo2d/goo_cell_design.gd` | `GooCellDesign` (Resource): a creature's cells, saved as `.tres` |
| `addons/goo2d/goo_cell_type.gd` | `GooCellType` (Resource): a kind of cell: look, mass, body mode, collisions, joining |
| `addons/goo2d/goo_cells.gdshader` | the default skin shader (flat, an edge band) |
| `addons/goo2d/native/src/cells.rs` | `Cells`, the solver; `GooCells` (lib.rs) its Godot class |
| `addons/goo2d/native/src/cells_draw.rs` | the skins' meshes |
| `addons/goo2d/goo_cells_sim.gd` | `GooCellsSim`, the exploration's thin layer (still used by its tools) |
| `examples/cells/` | a tank of four creatures (the example) |
| `addons/goo2d/native/src/couple.rs` | rings and cells colliding (below, "Rings and cells") |
| `examples/rings_and_cells/` | ring bodies and creatures in one tank |
| `tools/cell_world_bench.gd` | cost, draw and swimming through the world node |
| tests | `tests/integration/test_goo_cell_spin_servo.gd` (the spin servo and the contact query), `tests/integration/test_goo_cell_world.gd`, `tests/unit/test_goo_cell_design.gd`, `tests/integration/examples/test_cells.gd`, `tests/unit/test_goo_cells.gd` (the exploration's), cargo tests in `cells.rs`; the coupling's `tests/integration/test_goo_ring_cells.gd`, `tests/integration/examples/test_rings_and_cells.gd`, cargo tests in `couple.rs` |

A `GooWorld2D`'s ring bodies and a `GooCellWorld2D`'s creatures collide once the two worlds
are **coupled** (`couple()`, below "Rings and cells"); uncoupled, they pass through each other.
Both read the same walls. `GooColony` (the ring-per-cell colony) is untouched.


## The model

A **cell** is one disc: position, angle, velocity, spin, mass (its area × the world's
density × its type's `mass_factor`), radius (the design's × its type's `radius_factor`, ×
a muscle scale), type, a persistent uid. A **creature** is a set of cells joined by
**links**, made when it is spawned between every two cells closer than
(r_a + r_b) × `link_tolerance` (1.08), crossing links dropped, so the link graph is planar
and has an outline (its outer face). Radii are free: hex lattices, free packings and mixed
sizes (10-44 px measured) all work.

Each link holds its length (XPBD, `stretch_hz` 60 over the pair's reduced mass). How a
creature holds its **shape** is chosen per type (`GooCellType.body`, else the world's
`body_mode`):

- **SHAPE** (the world's default): shape matching. Each cell and its linked neighbours of its
  **region** (cells of one type and one group joined by links) are pulled toward their
  design (`shape_stiffness` 0.3 a substep). A region holds its shape as a whole. A cell's
  angle follows its neighbourhood's fit (thrust and types read it); a cell with fewer than
  two linked neighbours of its region cannot be fitted and bends by its links instead.
- **LINKS**: oriented links. Each link remembers its direction in both end cells' frames
  (`bend_hz` 40). Local: hinges, per-link bending.
- **NONE**: lengths only, floppy.

The links **between two regions** are a **joint**: they always bend (oriented), and a game
turns one region against the other with `set_joint_angle()`. A design gives two parts of one
type different `groups` to joint them; cells of two types meeting are a joint too.

**Muscles**: the **pose wave** (`set_pose_wave()`: the design bent along a curvature wave
running head to tail; the swimmer's stroke; a curvature bias steers), **joint angles**,
**radius muscles** (`set_muscles()`: a size scale per cell, the links following), the **swim
drive** (`set_swim()`: every cell pushed along its own forward, below), **thrust** per cell
along its heading (`set_cell_thrust()`), and whole-creature **push** and **twist** (kept, or
for one step: `push_once()`, `twist_once()`, `add_cell_forces_once()`). A creature's mean
motion and rigid spin relative to the water can be **damped** (`set_damping()`), and its spin
held by the solver's **spin servo** (`set_spin_servo()`, below "Turning by the spin servo").

**Contacts**: a creature's outline cells collide with other creatures' outline cells
(rigid, one pass a substep, a broad phase over creatures' boxes); every cell collides with
the walls; a creature's own unlinked cells that share no neighbour collide (`SelfCollision.FAR`,
on a Verlet list rebuilt every 4 frames). Nothing has friction.

**Water**: drag on the outline's edges, the fluid game's law: per edge, the velocity relative
to the water split across and along the edge,
`−(normal |v_n| + linear_normal) v_n − (normal/ratio |v_t| + linear_normal/ratio) v_t` × the
edge's length × density. The water's velocity is per cell: the world's `current`, a
creature's own (`set_current()`), or one value per cell (`set_water()`, or the world's
`water_source` for every cell of every creature in one call).

**Breaking**: a link breaks past `break_force` (× the smaller of its two types'
`break_factor`); with `break_leaves_out_own_share` (default on), the load tested is what
exceeds the link's **own envelope**: the largest load it carried over the last 2 s while its
creature touched nothing (no wall, no other creature, no script force). Swimming, thrust
and drag raise the envelope; a crash rises above it. A creature whose links break into separate
graphs **splits**: each part but one becomes a new creature (`creature_split`).

**Joining** happens only at a **retopology** the game asks for
(`request_retopology()`, after the next step, or `retopology()` now): every two outline cells
within `capture` (4 px at unit 1) of touching, of different creatures (and of one creature,
not sharing a neighbour, when asked), whose types' join layers match and that `may_join()`
allows, are linked; joined creatures merge into one. Cells are added (`add_cell()`, eased in
from 0.3 of their size over 0.5 s) and removed (`remove_cell()`) at any time.

**Stepping**: per frame, in parallel per creature (`threads`; 0, the default, picks 1, 2 or 4
by the live cells: "Threads" below): forces, drag, rest values
(pose, joints, muscles), then 6 substeps of links, shape matching, wall and own contacts;
contacts between creatures serially; velocities; breaks. Threaded is bit-identical to
serial, and a replay is identical (tested).

**Drawing**: one triangle mesh for the whole world, built per creature from its link graph
(below).


## API

`GooCellWorld2D` (a Node2D; put it in the scene with the walls):

- `spawn(design, at: Transform2D) -> GooCellCreature`, `despawn(creature)`, `clear()`,
  `creatures()`, `creature(slot)`, `creature_at(global_point)`.
- `add_cell(creature, at, radius, type, group) -> uid`, `remove_cell(creature, uid)`.
- `request_retopology(capture = -1, same = false)`, `retopology(...) -> links made`, and the
  override `may_join(a, uid_a, b, uid_b) -> bool`.
- `grab(creature, point) -> handle`, `move_grab(handle, point)`, `release_grab(handle)`.
- `water_source: Callable` (cell centres in, velocities out: empty, one, or one per point),
  `current`, `refresh_walls()`, `wall_count()`, `step(delta)` (what `_physics_process`
  does), `redraw()`, `draw_stats`, `type_slot()`, `update_type(type)`, `region_key()`,
  `cells()` (the `GooCells`, for anything else).
- Signals: `creature_spawned(creature)`, `creature_despawned(creature)`,
  `cells_parted(creature, uid_a, uid_b)`, `cells_joined(creature, uid_a, uid_b)`,
  `creature_split(parent, child)` (then `creature_spawned(child)`),
  `creatures_merged(into, from)`.
- Exports: `threads` (0: by size; `threads_in_use()` says what the last step ran on),
  `substeps`, `stretch_hz`, `bend_hz`, `body_mode`, `shape_stiffness`,
  `self_collision`, `gravity_scale` (1: GooTuning's gravity; 0 top-down), `drag_enabled`,
  `drag_normal`, `drag_linear_normal`, `drag_ratio`, `drag_linear_tangent` (below 0:
  `drag_linear_normal / drag_ratio`), `drag_density`, `current`,
  `break_force`, `break_leaves_out_own_share`, `draw_skins`, `skin_mesh` (GOO, the default,
  or FLAT), `skin_material`, `skin_preset` (GooCellLook's), `draw_borders` (off; lines between
  types), `border_color`, `border_width`, `default_type`; `current_skin_material()`,
  `look_table()`, `cell_table()` (the goo skin's, "Drawing").

`GooCellCreature` (a handle; creatures are not nodes): `is_alive()`, `center()`,
`velocity()`, `turn()`, `heading()`, `spin()`, `mass()`, `cell_count()`, `positions()`,
`velocities()`, `radii()`, `uids()`, `type_slots()`, `outline()`, `cell_index(uid)`,
`cell_position(i)`, `cell_angle(i)`, `cell_type(i)`, `is_boundary(i)`, `cell_at(point)`;
`push(acceleration)`, `twist(angular_acceleration)`, `set_cell_thrust(i, force)`,
`set_cell_force(i, force)`, `set_swim(acceleration, pulse = 0.3)`, `stop_swim()`,
`push_once(acceleration)`, `twist_once(angular_acceleration)`,
`add_cell_forces_once(forces)`, `set_damping(linear, angular)`, `set_muscles(scales)`, `set_pose_wave(slope, wavelength,
frequency, bias, envelope)`, `stop_wave()`, `set_joint_angle(type_a, group_a, type_b,
group_b, angle)`, `set_water(velocities)`, `set_current(v)`, `translate()`,
`set_velocity()`, `add_cell()`, `remove_cell(uid)`; the spin servo: `set_spin_servo(target_spin,
max_angular_acceleration, max_tip_speed = INF, contact_yield = 1.0)`, `set_spin_target(target_spin)`
(cheap, every frame), `stop_spin_servo()`, `spin_servo()` (its state: the spin measured, the
target after the tip cap, the yield's scale and contact share), the static
`spin_toward(angle_error, max_spin, max_angular_acceleration, delta = 0)` (a heading servo's
target); contacts: `contacts()` (what its cells touched in the last step: cell, uid, `Touch`
kind, id, the thing, normal), `contact_counts()`, `touching_walls()`, `touching(kind)`,
`set_contact_tracking(on)`, `contact_tracking()`, enum `Touch { WALL, OBSTACLE, RING,
CREATURE }`; `design`, `axis` (its forward at
spawn), `data` (a dictionary for the game; copied to split parts). Forces set stay until
set again, but the `_once` ones, which add to the next step's and clear themselves (calls
before a step add up; `add_cell_forces_once()` counts as outside the creature for the break
test, as `set_cell_force()` does). A split part keeps its parent's swim drive, damping, spin
servo and contact tracking. `GooCellWorld2D.touched_thing(kind, id)` resolves a contact's id.
Cell indices change at every topology change: keep uids.

`GooCellDesign` (a Resource, `.tres`, editable in the inspector): `types`
(`Array[GooCellType]`), parallel arrays `positions`, `radii`, `cell_types`, `groups`,
`angles`, plus `forward` and `link_tolerance`; `add_cell()`, `remove_cell()`, `clear()`,
`links()`, `bounds()`, `length()`, `centroid()`, `problems()` (arrays out of step, bad radii,
overlaps, unlinked cells), the builders `hex_worm(long, wide, radius)` and
`hex_blob(rings, radius)`.

`GooCellType` (a Resource): `name`, `color`, `mass_factor`, `radius_factor`, `stretch`,
`bend`, `break_factor`, `body`, `collides`, `collides_walls`, `self_collides`,
`contact_pad`, `join_layer`, `join_mask`, `swim_weight` (its cells' share of the swim drive,
1), `behaviours` (a free dictionary for a game's
thrusters, spikes, sensors...). The kernel has 16 type slots; a world gives each distinct
type one the first time it is used (a 17th is an error and gets the default's).

A minimal use:

```gdscript
var world := GooCellWorld2D.new()
world.gravity_scale = 0.0
add_child(world)
var worm := world.spawn(GooCellDesign.hex_worm(24, 5, 14.0), Transform2D(0.0, Vector2(600, 400)))
worm.set_pose_wave(0.3, worm.design.length(), 1.0)   # a gentle stroke, to show it swims
worm.set_swim(55.0, 0.3)                              # the drive: about 160 px/s along +x
# let go: worm.stop_swim(); worm.stop_wave(); worm.set_damping(1.5, 1.5)
world.water_source = my_flow_field.velocities_at        # water per cell, one call a frame
```

`GooTuning.unit` is read like the ring world's: the capture distance, the solver's margin
and speed cap, the grab's pick distance, the border width and a type's `contact_pad` are px
at unit 1, scaled by it; designs' radii are canvas px as drawn (a game at unit 0.5 designs
14 px cells); gravity is GooTuning's (× unit) × `gravity_scale`.


## Knobs and why

| knob | value | why |
|---|---|---|
| `substeps` | 6 | 4 lose 25 % of the swimming speed (the pose is held less firmly); 8 gain 2 %. A game that moves only by thrust can take 4 (25 % cheaper; crashes stay sound) |
| `stretch_hz` / `bend_hz` | 60 / 40 | the exploration's: stiff enough to read as solid in crashes, soft enough not to need more substeps |
| `body_mode` | SHAPE | about 0.8 × the oriented links' cost (30 × 150 colliding 1.84 against 2.33 ms on 4 threads), better shape memory, swims alike; LINKS per type where a game wants hinges |
| `shape_stiffness` | 0.3 | 0.6 holds a load better but swims 14 % slower (exploration) |
| `self_collision` | FAR | a bent worm never folds through itself, +0.2 ms at 30 × 150 on 4 threads |
| `drag_normal`, `drag_linear_normal` | 0.1, 60 px/s | the fluid game's numbers (src/game_settings.gd) |
| **`drag_ratio`** | **20** | the tangential drag is the normal ÷ this. A 24 × 5 worm swims 0.168 / 0.188 / 0.222 / 0.241 body lengths a cycle at ratios 7.5 / 10 / 20 / 40 (shape matching; oriented links 0.178 / 0.197 / 0.228 / 0.245). The fluid game's rings use 7.5-10; 20 gives undulation a fifth more and is still a modest anisotropy (real slender swimmers have about 2, but their bodies are continuous; here the outline is a polygon of cells and the along-edge drag sees its bumps). Above 20 the gain flattens and a creature slides sideways more freely. A knob: a game wanting the rings' feel sets 10 |
| `drag_linear_tangent` | −1 (= `drag_linear_normal / drag_ratio`, 3 px/s) | a brake against the glide of its own; it brakes swimming by the drive as much (below), so `set_damping()` is the better brake |
| swim `pulse` | 0.3 | the drive's ripple with the stroke: organic, never a jerk; 0 steady |
| `swim_weight` | 1 | a type's share; the creature's whole push stays what `set_swim()` asks |
| `threads` | 0 | by size; 4 explicitly was the old default (below) |
| `break_force` | INF | games set it; with the own share left out, one value separates crashes from swimming (below) |
| `break_leaves_out_own_share` | on | without it, swimming loads links more than a 600 px/s crash (the exploration's quirk 6) |
| `CAPTURE` | 4 px at unit 1 | a retopology joins cells this close to touching |
| `MARGIN` / `MAX_SPEED` | 6 px / 6000 px/s at unit 1 | the solver's contact margin and speed cap (3 px, 3000 px/s at the game's 0.5); the swept wall test covers the cap |
| `GRAB_STIFFNESS` / `GRAB_DAMPING` / `GRAB_REACH` | 400 /s², 40 /s, 3 radii | critically damped; the cells within 3 radii of the grabbed one share the pull |
| spin servo `max_angular_acceleration` | a game's (e.g. 16 rad/s² for a 690 px worm's 1 s half turn, 254 for an 84 px blob's 0.25 s) | the trapezoid `turn_profile()` of the tests: cruise at 1.5 π / T, accelerate at spin × (1 + 1/0.8) / (2 (T − π/spin)), brake at 0.8 of it |
| spin servo `max_tip_speed` | INF (off) | a game's swat limit; a tip of 300-600 px/s tames a worm most (below), but caps its spin at tip / farthest radius |
| spin servo `contact_yield` | 1 (off) | 0.1-0.3 tame (below); the release `SERVO_RELEASE` 0.1 s |


## Walls

The walls are whatever `GooStatics` mirrors, exactly as for the rings: every
`StaticBody2D` (and `AnimatableBody2D`) collision shape and polygon on
`GooTuning.LAYER_WALLS`, and every `TileMapLayer` with collision on that layer, as convex
pieces (a concave `CollisionPolygon2D` split by Godot's decomposition: the example's rock is
5 pieces). Moving walls are followed each step (`GooStatics.sync()`), and push cells (a wall
at 240 px/s carried a resting blob 391 px, 0 px overlap). The wall test is swept: a cell is
tested along its path within the substep against each piece, so neither a thin wall nor the
seam between two convex pieces of a concave wall is tunnelled (18 shots at 3000 px/s, the
speed cap at unit 0.5, into a 4 px wall and a V's seam: none through). A blob pushed into a
U of three convex pieces for 3 s: 0.00 px overlap.

With `push_bodies` on, character and rigid bodies on that layer are walls too, and every body
that moves is a moving obstacle judged on the cells' motion relative to it (a rigid body moved
by its own velocity, mass and inertia within the step and taking the reaction after it); with
`physics_proxies` on, each creature stands in Godot's physics as a kinematic body of circles
(its boundary cells) so areas, rays, characters and rigid bodies meet it: docs/godot-physics.md.


## Water per cell

`water_source` is called once a frame with every live cell's centre (one
`PackedVector2Array`) and returns the water's velocity there; the world hands it to the
kernel in one call (`set_water_all()`). The fluid game's `FlowField.velocities_at` has that
signature. Measured: a 37-cell blob in a uniform 60 px/s current reaches 59.8 px/s in 8 s
(20, 43, 53, 57, 58, 59, 59.6, 59.8 px/s, second by second; drag on the outline only, so a
blob's inside cells are carried by its rim); a 12 × 3 worm in a shear of 0.5 /s turns with
it (−0.69 rad in 2 s, spinning −0.37 rad/s where the water's vorticity / 2 is −0.25).
Feeding 4500 cells from a GDScript closure costs 0.24 ms a frame (30 × 150 swimming, 4
threads: 3.18 ms against 2.88 without water); the uniform per-creature current
(`set_current()`) costs nothing extra.


## Swimming, regions and joints

`tools/cell_world_bench.gd -- --swim-test` (a 24 × 5 worm alone, 14 px cells, slope 1, a body
length's wave, 1 Hz, drag ratio 20, 8 s after 2 s):

| body | px/s | body lengths a cycle |
|---|---|---|
| shape matching, one region | 152.2 | 0.222 |
| oriented links | 156.1 | 0.228 |
| 3 / 6 / 12 / 24 shape-matched segments joined by joints | 154.8 / 157.9 / 163.7 / 171.4 | 0.226 / 0.230 / 0.239 / 0.250 |

(The exploration: oriented links 0.222, shape matching 0.209.) A worm of three regions side
by side (a spine row of another type between two strips) swims like one region. A crawler
of three segments with its joints set to ±0.5 rad turns its segments −0.23, 0.27, −0.23 rad
(relative 0.50 and −0.50).

### The swim drive

`set_swim(acceleration, pulse)` pushes every cell along its **own** forward: the creature's
forward (its `axis`) turned by the cell's angle now, which for shape-matched cells is their
neighbourhood's fit plus the bent pose's own turn at the cell. So the push follows the
body's curve: a body bent by the pose wave's curvature bias steers itself with no twist.
Each cell's force is acceleration × M / Σ(mᵢ wᵢ pᵢ) × mᵢ wᵢ pᵢ, with wᵢ its type's
`swim_weight` and pᵢ = 1 + pulse × sin(the pose wave's phase at the cell), so the forces'
magnitudes always sum to the commanded acceleration × the creature's mass M (a spine of
weight 4 and flanks of weight 0 push exactly as hard as an even body, from fewer cells), and
the pulse only moves the push along the body, head to tail, in step with the stroke (it
eases in with the wave; without a pose wave the drive is steady). Negative swims backward.
The drive is not contact for the break test (its loads join the creature's own envelope).
Cargo tests check the sum, the weights, a cell's angle, and threaded == serial.

The purpose: the undulation becomes mostly a visual indicator with some organic variation,
the drive doing the work. `tests/integration/test_goo_cell_swim.gd`, the 24 × 5 worm (14 px
cells, drag ratio 20, a body length's wave at 1 Hz, 8 s after 2 s):

| | px/s |
|---|---|
| the full stroke alone (slope 1, as before) | 152.6 |
| the toned-down stroke alone (slope 0.3) | 27.7 |
| the drive alone (55 px/s², pulse 0.3) | 154.1 |
| **both** (slope 0.3 + 55 px/s²) | **162.5** |
| the drive alone at −55 px/s² | −154.0 (backward) |

The drive's share of "both" depends on how it is counted, since the drag is not linear: 95 %
by the drive alone's speed, 83 % by what the stroke adds on top of it, **86 % by thrust** (the
slope-0.3 stroke alone swims as fast as a drive of 9.1 px/s² would: 55 / (55 + 9.1)). The
worm is far more efficient driven than undulating: 55 px/s² does what the full stroke did.
(At higher drives the stroke costs speed: 200 px/s² alone 458 px/s, with slope 0.3 445.)

Turning by the curvature bias alone (both as above, no twist; turn rate over the path):

| bias (1/px) | rad/s | px/s along the path | the drive alone, bent: rad/s at px/s |
|---|---|---|---|
| 0.0005 | 0.072 | 161 | 0.065 at 153 |
| 0.001 | 0.141 | 158 | 0.130 at 150 |
| 0.002 | 0.274 | 145 | 0.253 at 137 |
| 0.004 | 0.531 | 109 | 0.473 at 101 |
| −0.002 | −0.268 | | |

It turns at about its speed × the bias (the path follows the body's curvature), slowing as
it bends harder (the bent body's drag). The pose wave's curvature clamp (quirk 9) caps the
bias at about 1 / (2 × the half width): a 5-wide worm of 14 px cells near 0.008 /px.

### Braking

A worm let go at full speed glides far: the along-edge drag is a twentieth of the across-edge
drag, and the drive is nearly all along. Driven at 162 px/s (172 px/s at the moment it is let
go), drive and stroke stopped: 590 px before it is under a tenth of its speed, still 14 px/s
after 10 s (602 px).

`set_damping(linear, angular)` damps the creature's mean velocity and its rigid spin about its
centre, both relative to the water at its cells (the mass-weighted mean of v − water, and the
spin of that about the centre of mass), by exp(−rate × h) every substep: an exact exponential
decay, stable at any rate, with no force that could overshoot. The cells' motion relative to
that rigid motion (the stroke, a wobble) is untouched: a cargo test runs a pose wave under
damping 10 and its bend is within 10 % of the undamped one, and a creature moving with the
water feels nothing. It damps the creature's own swimming too while it is set, so a game sets
it when it lets go and clears it when it swims again. The worm above, let go with damping
set (linear and angular alike):

| damping (1/s) | under a tenth of its speed | under 5 px/s | after 10 s |
|---|---|---|---|
| 0 | 9.25 s, 590 px | never | 602 px, 14.2 px/s |
| 0.5 | 3.03 s, 198 px | 4.70 s, 214 px | 221 px |
| 1.0 | 1.82 s, 119 px | 2.82 s, 129 px | 133 px |
| 1.5 | 1.30 s, 86 px | 2.02 s, 92 px | 95 px |
| 2.0 | 1.02 s, 67 px | 1.57 s, 72 px | 74 px |
| 3.0 | 0.70 s, 46 px | 1.08 s, 50 px | 51 px |
| 4.0 | 0.55 s, 36 px | 0.83 s, 38 px | 39 px |

An exponential decay stops in about v / k px and takes ln(v / v_stop) / k s, so "about 150 px
**and** 1.5 s" from 170 px/s cannot both be met by one rate: about 1 /s gives the distance
(119 px to a tenth, 133 px in all) but takes 1.8-2.8 s; about 2 /s gives the time (1.57 s to
5 px/s) but stops in 72 px. A game wanting both can raise the rate as the creature slows (a
decay with a constant-deceleration part), e.g. 1 /s for the first half second and 3 /s after;
that is the game's to set, not built here.

`drag_linear_tangent` (the along-edge linear drag on its own, px/s; −1, the default, keeps
`drag_linear_normal / drag_ratio` = 3 px/s, so nothing changes) is the other brake, and a
poorer one: it is always on, so it brakes the drive as much. The same drive (55 px/s²), no
damping:

| along-edge linear drag | swims | let go: under 5 px/s | after 10 s |
|---|---|---|---|
| 3 px/s (the default) | 172 px/s | never | 602 px, 14.2 px/s |
| 10 px/s | 133 px/s | 8.57 s, 325 px | 331 px |
| 20 px/s | 96 px/s | 5.28 s, 157 px | 167 px |
| 40 px/s | 58 px/s | 2.60 s, 55 px | 61 px |

### Turning by the spin servo

`set_spin_servo(target_spin, max_angular_acceleration, max_tip_speed = INF, contact_yield = 1)`
runs in the solver, every substep, per creature (in its parallel part: threaded is still
bit-identical to serial, and a replay identical; cargo-tested), until `stop_spin_servo()`:

- **What it holds**: the creature's spin, its cells' angular momentum about the centre of mass
  over their moment of inertia with the mean velocity taken out. That is the world's frame and
  any frame moving with the water without turning alike (not relative to a vortex's rotation):
  `spin()`, and what a heading changes by. Positive is clockwise on screen.
- **How**: a rigid turn of every cell about the centre of mass, `vel += perp(p − c) × Δω` (and the
  cells' own spin), Δω = the target less the spin, at most `max_angular_acceleration` × the
  substep. No net force: Σ m (p − c) = 0, the centre refined by the residual of its f32 sum. It
  stops on the target (a target of 0 stops the spin and holds it: a heading held straight
  while nothing turns it). A velocity change, not a force, so it holds its target exactly
  against drag at any acceleration, and no overshoot comes of the servo itself.
- **Tip cap**: the target is clamped to `max_tip_speed` / the farthest cell centre's distance
  from the centre of mass (measured each substep, so a creature bent shorter may spin faster).
  A spin above the cap from outside is braked to it.
- **Contact yield**: with the contacts its cells had in the previous substep (any kind: below,
  "Contacts"), the share g = the largest cosine between the commanded turn's motion at a
  touching cell (perp(p − c) × the sign of the target) and that contact's normal into the
  other thing; it rises at once and fades over `SERVO_RELEASE` (0.1 s) once gone, and a turn
  the other way starts afresh, so a contact found in one substep and lost the next never makes
  it chatter. The scale 1 − (1 − `contact_yield`) × g multiplies both the target it holds and
  its acceleration toward it; a spin above that share is braked at the full acceleration. A
  cell sliding along a wall (g ≈ 0) or turned away from a contact (g = 0) does not yield, so a
  turn begun with the tail on a wall goes at full power. The last substep's contacts, not a
  prediction: the first substep of a contact is unyielded.
- **Damping**: while the servo is on it owns the spin: `set_damping()`'s angular part is not
  applied (its linear part is).
- **Cost**: nothing while off (one flag); on, two passes over the cells a substep and the
  contacts recorded. 30 worms of 150 cells all servoed: 2.96-2.98 ms a frame swimming against
  2.85-2.93 without (4 threads; tools/cell_world_bench.gd --servo=1, below).

`GooCellCreature.spin_toward(error, max_spin, a, delta)` is the target a heading servo gives
it each frame: the braking curve sign × min(max_spin, √(2 a |error|)), and with `delta` at most
|error| / delta so a target set once a frame never carries the turn past the heading within the
frame. Brake at a little under the servo's acceleration (0.8 of it here).

Measured (`tests/integration/test_goo_cell_spin_servo.gd`, unit 0.5, 14 px cells, the world's
drag, real physics frames). **Half turns from rest in open water**, against the fluid game's
times (0.25 s at 84 px to 1 s at 690 px, by the design's longest extent), with the trapezoid
profile above (overshoot past the heading; the error 1 s after reaching it):

| creature | size | the game's | servo: spin, acceleration | half turn | overshoot | tip speed | ×2 spin, ×3 acceleration |
|---|---|---|---|---|---|---|---|
| blob of 7 | 84 px | 0.25 s | 18.8 rad/s, 254 rad/s² | 0.217 s | 7.5° | 527 px/s | 0.200 s, 0.2° |
| blob of 19 | 140 px | 0.32 s | 14.8, 156 | 0.283 s | 4.7° | 826 px/s | 0.150 s, 12.0° |
| blob of 37 | 196 px | 0.39 s | 12.1, 105 | 0.350 s | 3.2° | 1018 px/s | 0.183 s, 8.9° |
| worm 24 × 5 | 690 px | 1.00 s | 4.7, 16 | 0.967 s | 0.4° | 1539 px/s | 0.533 s, 1.2° |

Every heading held to 0.00° a second later. The overshoot is the blobs' elasticity (the rim lags
the turn and springs on), not the servo, which arrives on its target spin; the game's times are
all met within the profile.

**A worm spun into a floor** (its line 160 px above it, so its head swings in a third of the way
round at the 1 s profile; the first cell to touch, its speed the frame before; the worm's centre
flung off the floor within 1 s):

| setting | first cell hits at | flung off at | half turn |
|---|---|---|---|
| yield 1, no tip cap (full power) | 857 px/s | 568 px/s | 1.23 s (it vaults over its head) |
| yield 0.3 | 857 | 395 | 1.40 s |
| yield 0.1 | 857 | 361 | 1.50 s |
| yield 0.1, tip 600 px/s | 580 | 181 | 2.45 s |
| yield 0.1, tip 300 px/s | 290 | 90 | not made in 2.5 s (59°) |

A spinning worm's angular momentum is what flings it: when its head stops on the floor it keeps
turning about the head and vaults (a rod hitting a floor end-first). The yield stops the servo
adding to that (a third less fling), the tip cap stores less of it (a sixth of the fling at
300 px/s). **Turns begun against a wall**: the tail end on a wall behind it, the half turn takes
0.97-0.98 s at yields 1, 0.3 and 0.1 (open water 0.97 s: the tail slides along the wall and
nothing yields); lying along a floor, turning its near half into it, 1.32 s at yield 1, 1.92 s at
0.3, 2.52 s at 0.1 (it levers itself off the floor, at the yield's share).

**A worm turning into a crate** (the game's: 60 px, mass 10 at `body_mass_scale` 1000, damped
1.5 / 3 per second; `push_bodies`; 250 px from the worm's centre, 50° into its turn) **and into a
coupled 28 px ring** (`ring_density` 1), the thing's fastest speed and its speed 1 s after the
first contact:

| setting | crate | ring |
|---|---|---|
| yield 1, no tip cap (full power) | 953 px/s, 306 later | 1342 px/s, 936 later |
| yield 0.3 | 691, 204 | 580, 400 |
| yield 0.1 | 672, 218 | 573, 384 |
| yield 0.1, tip 600 px/s | 348, 181 | 248, 224 |
| yield 0.1, tip 300 px/s | 142, 93 | 99, 75 |

The yield alone takes off 30 % (the crate) to 57 % (the ring); what remains is the hit itself, the
turning worm's momentum meeting the thing in the first substeps of the contact. Only the tip cap
lowers that, and it lengthens every turn (a 690 px worm at 600 px/s cannot spin faster than
1.8 rad/s, a half turn about 2 s). A game wanting both a 1 s turn and no swat cannot have them
from the servo alone: it could cap the tip only near things (lowering `max_tip_speed` when a
crate is within reach), or accept the yield's 30-60 %. Before this the game's GDScript servo
(`twist_once()` every frame) swatted the crate at up to 890 px/s and bounced the head off a wall at
up to 507 px/s.

**Recommended for the fluid game**: full power `set_spin_servo(target, a, INF, 1.0)`; tame
`set_spin_servo(target, a, INF, 0.3)`, which keeps every game turn time (contacts aside) and takes
30-57 % off a swat; tamer still a tip cap, which costs turn time wherever the creature's tip
would pass it (at the game's times the 7-cell blob's tip reaches 527 px/s, the 19-cell blob's
826, the 37-cell blob's 1018, the worm's 1539: a cap of 600 px/s slows all but the smallest);
`a` from the turn time as above; the target each frame `spin_toward(heading_error, max_spin,
0.8 × a, delta)`.

### Contacts

Each creature can record what its cells touched in the last step (`set_contact_tracking(true)`;
the spin servo records them while it is on, whatever this says; off, nothing is recorded and it
costs nothing). Every contact the solver resolves is noted where it is resolved, in fixed order
(walls and moving obstacles in the creature's parallel part, other creatures and rings in the
serial passes), so threaded == serial (cargo-tested): the cell, what it touched (`Touch.WALL`: a
static shape, its id GooStatics' kernel id; `OBSTACLE`: a moving obstacle, the same; `RING`: the
ring's kernel key, its Goo2D's instance id; `CREATURE`: the other creature's slot) and the unit
normal pushing the cell out (for an edge contact between creatures, the edge's nearer cell).
At the step's end they are sorted by cell, kind and id, one per cell and thing (the last
substep's normal). `contacts()` returns them with the thing resolved (`touched_thing()`: the
`PhysicsBody2D` or `TileMapLayer` through `GooStatics.node_of()`, the `Goo2D`, the
`GooCellCreature`; a first call turns tracking on and returns what the last step recorded);
`contact_counts()` (`[walls, obstacles, rings, creatures]`), `touching_walls()` and
`touching(kind)` build no dictionaries. A topology change finds the step's contacts again by
uid. Rings (`GooWorld2D`) have no such query: their contacts are the kernel's own
(`touched` events, `Goo2D.touching()`), not recorded this way.

### Two kernel bugs

Two kernel bugs were found and fixed here (both cargo-tested): a shape-matched cell with
fewer than two neighbours of its region kept its angle forever and pinned the creature's
turn through its joint links (a blob with a rim of thruster cells could not be turned); and
under the pose wave a shape-matched cell's angle left out the bent pose's own turn, so joint
links fought the stroke (that three-region worm crabbed sideways, 1000 px/s along a wall).


## Threads

`threads = 0` (the world's default since this stage; it was 4) picks the thread pool every step
from the live cells: 1 below 800, 2 below 1600, else 4 (`cells.rs`' `AUTO_THREADS`), at most one
per live creature (creatures are what run in parallel) and the machine's cores. Pools made for
other counts are kept, so switching costs nothing; an explicit count works as before. Threaded
is bit-identical to serial, so the choice never changes what happens. Measured with
`tools/cell_world_bench.gd` (medians, ms a frame, 4 cores, one run each; a second run of 7 × 150
gave collide 0.80 / 0.74 / 0.70, swim 1.36 / 1.15 / 1.02: noise is about ±0.15 ms):

| creatures × cells | live cells | collide 1 / 2 / 4 threads | swim 1 / 2 / 4 threads | auto |
|---|---|---|---|---|
| 2 × 100 | 200 | **0.11** / 0.28 / 0.50 | **0.20** / 0.38 / 0.52 | 1 |
| 4 × 125 | 500 | **0.33** / 0.53 / 0.96 | **0.60** / 0.63 / 1.05 | 1 |
| 7 × 150 | 1050 | 0.70 / 0.73 / 0.86 | 1.33 / **1.16** / 1.27 | 2 |
| 10 × 150 | 1500 | 1.03 / 1.04 / **0.88** | 1.95 / 1.41 / **1.27** | 2 |
| 13 × 150 | 1950 | 1.34 / **1.15** / **1.15** | 2.61 / **1.85** / 1.92 | 4 |
| 20 × 150 | 3000 | 2.27 / 1.69 / **1.48** | 4.61 / 2.86 / **2.38** | 4 |
| 30 × 150 | 4500 | 3.73 / 2.46 / **1.85** | 7.12 / 4.29 / **3.04** | 4 |

Below about 800 cells a pool costs more than it saves (two blobs of 100 cells: 0.11 ms on one
thread, 0.50 on four); from about 1500 four threads win and keep winning. Between, two and four
are within the noise. The default became 0 because a game with a few small creatures (the
example's 287 cells) was paying 0.3-0.5 ms a frame for threads, and at the sizes where threads
pay the choice is what 4 was. One machine: a game targeting other hardware can measure and set
an explicit count.


## Breaking

The world test: break force 1.5e8 (unit 0.5), a worm swimming at full stroke and a crash of
two blobs at 600 px/s each. With the own share left out: 0 links parted swimming, 2 in the
crash. Counted whole: 21 parted swimming, 2 in the crash. Splits and their events are kept:
a single file of 12 pulled apart parts 11 links into 11 splits (`cells_parted`, then
`creature_split` and `creature_spawned` per new part). The envelope is held still while the
creature touches anything, so a crash, a wall or a script force (`set_cell_force()`, the
grab) always counts in full; a creature that swims hard for the first time after 2 s of rest
can exceed its own envelope (its muscles' share is learned, not computed).


## Drawing

One `canvas_item_add_triangle_array()` for the whole world, indexed, built in the kernel per
creature (threaded) from its link graph:

- inside the outline, every face of the planar link graph: a face of one type is one
  triangle (or a fan); a face of mixed types is cut into one quad per cell (the cell, its two
  links' midpoints, the face's centre), each in its cell's colour, so **each type's cells are
  one contiguous piece** with a straight border (drawn as lines when `draw_borders` is on);
- around the outline, per outline cell a fan from its centre to its stretch of the skin, a
  quadratic B-spline through the midpoints of the outline pushed out by each cell's radius;
- a link is split at its midpoint only where a triangle on either side ends there (the rim, a
  mixed face), so neighbouring triangles share whole edges: **no T-junction, no pinholes**
  (a cargo test checks no vertex lies inside another triangle's edge);
- **gaps in mixed-size packings** (faces of four or more cells) are filled when the cells'
  discs nearly cover them (no point of the face farther than 0.6 of the mean radius from a
  disc); a real pocket stays open;
- the faces are walked once per topology change, not per frame.

That is the flat mesh (`skin_mesh` FLAT): vertex colours are the types' colours; UV.x is 1
inside and 0 on the skin; UV.y is the type's slot / 16. `goo_cells.gdshader` draws them flat
with a darker edge band; `skin_material` replaces it (the contract is in the shader's head).

### The goo skin (the default)

`skin_mesh` GOO (the default) draws the same outline and faces as a mesh that tells the shader,
`goo_honeycomb.gdshader`, enough to draw the ring bodies' wet goo (`goo.gdshader`'s tint, rim,
fresnel and refraction) honeycombed by the cells' walls inside a membrane, with a light stage on
top in which each cell is a small lit volume of its own.
`cells_draw.rs`'s `creature_mesh_goo()`:

- **Each triangle names three cells**, the same three on its three corners (COLOR.xyz: their
  indices into the world's **cell table**; a face's triangles name the face's cells, a rim fan
  its cell and that cell's two outline neighbours, a larger face's fan triangle its two cells
  and the face's cell nearest its centre). The cell table is a float texture the world
  updates each frame (`cell_table()`: 512 cells a row, two RGBA texels a cell: centre, radius,
  turn; type slot, a seed from the uid, its distance to the outline, on the outline). From
  the three cells the shader works out, per fragment and exactly: which cell it is in and its
  distance to that cell's walls in px (the **power diagram**, |p − c|² − r² equal on both
  sides, so the walls are a constant width at any size and right between mixed sizes), a
  coordinate fixed in the cell and turned with it (its dome, its bubble), and the types'
  blend.
- **Borders between types are smooth**: each triangle's types blend by its barycentric
  coordinates among its three cells (a rim fan's by projection along its two links, which
  agree on every shared edge), sharpened (`border_sharpness`): the 50 % line runs straight
  through the link midpoints, so a row of another type reads as a band with soft straight
  edges, not the packing's zigzag, and the walls run on across it.
- **COLOR.w is the distance to the outline in px** (0 on the skin), so the rim has a constant
  width at any cell size; exact (against the skin curve) for cells within three links of the
  outline, a shortest path through the cells deeper (where only "deep" matters); UV is the
  outward direction (toward the nearest point of the skin; the curve's normal on it).
- Vertices are shared within a face or a fan (one triple), not across: about 1.9 times the
  flat mesh's (30 × 150: 38 760 against 20 400). Links are split only on the rim now (a mixed
  face is no longer cut into quads); still no T-junction (the same cargo test).
- The silhouette is antialiased by the shader over a pixel of the outline distance (the
  triangles have none).

- **Corners are rounded** (`corner_radius`, px at unit 1): of a fragment's two walls (among
  its triangle's three cells) the distance is that to the cell shrunk by the radius and grown
  again: in the shrunk cell's corner's normal cone, the radius less the distance to that
  corner (from the two wall distances and the angle between the walls), elsewhere the nearer
  wall's. So the walls keep their width away from a corner and widen into a small fillet
  where three cells meet. The corner where three walls meet lies inside the triangle naming
  those three cells (about 8 px from its edges for 14 px cells), so a radius well under that
  never reaches a neighbouring triangle, which names another third cell: no seams
  (`debug_view` 5 shows each cell's surface, smooth across triangle edges at 6 px).

Two stages in one pass: `base()` is the goo (lifted by its own tint, `brightness`, so a
creature over dark water does not read dark nor an orange type brown), `lit()` the light
(thickness: darker and denser toward the middle, lit from the light's side; the surface's
specular and fresnel on the rim's normal, as the rings'; a broad sheen). **Each cell is a small
lit volume of its own**: its surface rolls off from flat in its middle to edge-on at its rounded
walls over `cell_rim` of its radius (sloping out from its centre, so its highlight is a spot,
not a dash along a wall), and the body's light terms are evaluated again on it × `cell_light`
(0.2: a fifth of what the body gets) × its type's `dome`: the side light and the sheen on a
normal as soft as the body's, a quarter of the fresnel (at the full share every wall glows
and reads as a light line), and the specular with a broader lobe (`cell_specular_power`)
whose peak is lowered by (n + 2) / (n_body + 2), so it reflects what the body's would, spread
wider; the type's `gloss` × that. Not the body's density toward the rim: with the walls it
rings every cell and reads as beads. The cell's light fades within the rim and under the
membrane, as the walls do. One pass, not a second draw, because the light needs only the per-fragment
fields the pass already has; a second draw would hand the mesh over twice and need a back-buffer
copy for nothing. Everything is fixed in the material: the walls and cells' light come from the cells'
positions, the bubbles from each cell's seed in its own turned frame, so they ride the cells as
they bend and swim, and a topology change or an added cell changes no fragment's cells but
those near it (the power diagram is the same whichever triangles name it).

**The look.** World-level uniforms on the material (lengths in px at `GooTuning.unit` 1; the
world sets `length_unit`), with GooCellLook's presets as uniform sets of them
(`skin_preset`: MEMBRANE, the default, FAINT, CELLULAR, or CUSTOM to leave the material
alone; `GooCellLook.apply(material, preset, overrides)`); per type, `GooCellType`'s look
fields reach a 16-row look table (`type_color`, `type_wall`, `type_look` = wall_strength,
dome, gloss, opacity), sent when a type is registered or `update_type()`d, so one draw keeps
serving the whole world:

| uniform | default = MEMBRANE | FAINT | CELLULAR | MEMBRANE+ (`cells_look.gd`) | what |
|---|---|---|---|---|---|
| `goo_opacity` | 0.4 | 0.3 | 0.32 | | the goo's own colour over what shows through |
| `brightness` | 0.15 | 0 | 0 | 0.22 | the goo's tint added over what shows through (a lift) |
| `rim_width` (px) | 24 | 16 | 14 | | the rim's roll-off to edge-on |
| `rim_strength`, `fresnel_power` | 1.0, 2.2 | 0.85 | 0.8 | | its fresnel glow |
| `rim_density` | 0.3 | 0.35 | 0.3 | | darker, denser toward the rim |
| `refraction_px` (px) | 22 | 18 | 16 | | the background displaced at the rim |
| `cell_refraction_px` (px) | 1 | 1.5 | 4 | | each cell a small lens |
| `wall_width`, `wall_softness` (px) | 1.5, 1.5 | 1.5, 1 | 2, 1.2 | | the walls |
| `wall_strength` | 0.2 | 0.16 | 0.3 | 0.26 | how dark (× a type's `wall_strength`) |
| `corner_radius` (px) | 4 | 0 | 0 | 3 | each cell's corners rounded |
| `wall_highlight` | 0 | 0 | 0.2 | | a thin light line beside each wall's lit side |
| `wall_rim_fade` | 1 | 0.6 | 0.4 | | walls (and the cells' light) fading within the rim |
| `border_sharpness` | 2.5 | 3 | 4 | | the types' blend: 1 a gradient across a triangle |
| `membrane_width` (px), `membrane_strength` | 9, 0.85 | 0, 0 | 0, 0 | 9, 1.0 | a clearer band inside the skin closed by a line |
| `cloud` | 0.4 | 0 | 0 | 0.4 | milky with depth, each cell its own |
| `bubble_density`, `bubble_strength` | 0.15, 0.7 | 0.12, 0.6 | 0.1, 0.5 | | a bubble in that share of cells |
| `light_dir` | (−0.55, −0.7, 0.75) | | | | the rings' light |
| `shade_depth` (px), `shade_strength` | 50, 0.12 | 40, 0.18 | 40, 0.15 | | thickness |
| `side_light` | 0.25 | 0.18 | 0.15 | | the thickness lit from the light's side |
| `specular_power`, `specular_strength` | 70, 1.6 | 90, 1.4 | 90, 1.2 | | the surface's highlight |
| `sheen_strength` | 0.3 | 0.22 | 0.15 | | a broad sheen |
| `cell_light` | 0.2 | 0.12 | 0.35 | 0.3 | each cell's share of the body's light (× a type's `dome`) |
| `cell_rim` | 0.6 | 0.6 | 0.7 | | the share of a cell's radius its surface rolls off over |
| `cell_specular_power` | 16 | 24 | 24 | 20 | a cell's broader highlight (its peak lowered to match) |
| `debug_view` | 0 | | | | 1 outline distance, 2 wall distance, 3 cells and blend, 4 outward, 5 each cell's surface |

(Round 2 of the look, 2026-11-13, replaced each cell's faint dome, `dome_strength`,
`dome_highlight` and `dome_power`, with `cell_light`, `cell_rim` and `cell_specular_power`;
round 1's MEMBRANE had `goo_opacity` 0.34, `wall_strength` 0.12, `membrane_strength` 0.7 and
no `brightness` or rounding, and FAINT was the default.)

`tools/cells_look.gd` renders the presets (examples/cells after 3 s, a strip beside a ring body
at 14 and 7 px cells on a dotted pattern and again on a stand-in for the fluid game's water,
4× crops, a swimming worm twice) with `--set=uniform=value,...` on top; `--preset=membrane+`
is MEMBRANE with the column above on top.

**Its cost** (`tools/cell_world_bench.gd --draw --skin=goo|flat`, swimming, 4 threads; the
build is the kernel's mesh and table, the hand-over the triangle array and the table texture;
two runs each, the first before the outline distances were limited to three links, on a noisy
4-core machine):

| | vertices | build (ms) | hand-over (ms) |
|---|---|---|---|
| 30 × 150 flat, headless | 20 400 | 0.39-0.40 | 0.14 |
| 30 × 150 goo, headless | 38 760 | 0.68-0.85 | 0.31 |
| 30 × 150 flat, xvfb | 20 400 | 0.41-0.42 | 0.34-0.35 |
| 30 × 150 goo, xvfb | 38 760 | 0.70-1.39 | 0.75-1.41 |
| 100 × 150 flat, headless | 68 000 | 2.25-2.38 | 0.44-0.45 |
| 100 × 150 goo, headless | 129 200 | 4.5-4.7 | 0.94-0.97 |
| 100 × 150 flat, xvfb | 68 000 | 1.15-1.17 | 1.43-2.35 |
| 100 × 150 goo, xvfb | 129 200 | 2.3-2.4 | 3.4-5.7 |

About twice the flat skin's: 1.9 times the vertices, the outline distances (the cargo bench
`mesh_cost`, a 169-cell blob single-threaded: flat 7-12 µs, goo 20 µs of which 10 µs the
distances) and a 128 kB table upload at 100 × 150. Under xvfb llvmpipe renders on the same 4
cores, so the costlier fragment shader slows the step there too; on a GPU it would not. Not yet
done: the per-creature parts are copied once more when concatenated, and the table is a fresh
Image each frame.

**The skin over walls at concave corners: bounded, not fixed.** Every drawn point lies
within 0.43 of a radius of some cell's disc (measured 5.8 px for 14 px cells; the notch
between two touching outline discs is bridged), and the cells themselves stay out of the
walls (0.00 px measured), so the skin can cover a wall by at most about 0.43 radius, at a
concave corner where the outline cuts across it. Clipping the skin to the walls was not
built.


## Cost

`tools/cell_world_bench.gd`: N creatures of 150 cells in a walled arena (`StaticBody2D`
walls through GooStatics), colliding (hex blobs pushed at 300 px/s² toward a point changing
every 2 s) or swimming (hex worms 30 × 5, pose wave 0.8-1.2 Hz steered toward their point),
the world's defaults (shape matching, 6 substeps, `SelfCollision.FAR`, drag ratio 20, no
water feed), 300 frames after 60; `world.step()` including GDScript (walls, events) but not
drawing; 4 cores. Commands:

```
godot --headless --path . -s tools/cell_world_bench.gd -- --creatures=30 --cells=150 --mode=collide --threads=4
godot --headless --path . -s tools/cell_world_bench.gd -- --creatures=30 --cells=150 --mode=swim --threads=1
xvfb-run -a -s "-screen 0 1920x1080x24" godot --path . --rendering-driver opengl3 --audio-driver Dummy -s tools/cell_world_bench.gd -- --cells=150 --creatures=30 --mode=swim --draw
```

| creatures × cells | mode | 1 thread median / p95 (ms) | 4 threads median / p95 (ms) | worst soundness (every 20th frame) |
|---|---|---|---|---|
| 30 × 150 | colliding | 3.56 / 3.73 | **1.84** / 2.09 | 0.2 px between creatures, 0 cells inside another |
| 30 × 150 | swimming | 7.03 / 7.50 | **2.88** / 3.54 | 23.6 px, 1 inside |
| 60 × 150 | colliding | 7.38 / 7.68 | **3.00** / 3.59 | 0.2 px, 1 |
| 60 × 150 | swimming | 14.25 / 17.88 | **4.85** / 5.64 | 12.5 px, 0 |
| 100 × 150 | colliding | 12.37 / 15.01 | **4.65** / 6.54 | 0.1 px, 1 |
| 100 × 150 | swimming | 22.98 / 24.58 | **7.73** / 8.91 | 28.8 px, 7 |

One run each. The exploration's raw `GooCells` bench (oriented links) at 30 × 150 on 4
threads: 2.55-2.59 colliding, 3.27-3.45 swimming; the world adds 0.04-0.26 ms of GDScript
over the kernel. Variants at 30 × 150, 4 threads: oriented links 2.33 colliding / 2.96
swimming (1 thread 4.92 / 7.61); 6 shape-matched segments 2.01 / 2.75; water per cell from a
GDScript closure 3.18 swimming. 100 × 150 swimming fits a 10 ms frame on 4 threads with its
p95 under it; with drawing (about 1-3 ms more at that size) it does not leave much.


## Rings and cells

`GooCellWorld2D.couple(world)` (or `GooWorld2D.couple(cells)`, or the cell world's
`ring_world` export, resolved at ready) makes a ring world's bodies and the creatures collide,
coupled directly between the two solvers (`addons/goo2d/native/src/couple.rs`), not through
Godot's physics. `uncouple()` undoes it (a freed ring world uncouples on its own);
`coupled_world()`, `coupling_stats()` (rings gathered, near a creature, touched, candidate pairs,
contacts solved, centres found inside, the deepest overlap found, the momentum handed over, the
microseconds it took).

**One solver resolves every ring-cell contact: the cells'.** It steps after the ring world:
`couple()` raises the cell world's `process_physics_priority` above the ring world's (a scene
may list them in either order; stepping by hand, step the ring world first). Each frame:

1. before the cells' step, every ring's beads as the kernel's step left them (position and
   velocity), its bead radius, mass and whether it is settled (`couple_gather()`);
2. after the cells' broad phase, the rings near a creature and the candidate pairs: outline
   cells near a ring's bead chain or inside its loop, beads near a creature's outline or inside
   it (found through the creature's colliders' grid); rings near nothing take no further part;
3. in each of the cells' substeps, after their own contacts: the touched rings' beads move as
   **ghost particles** along the path the kernel gave them (from p − v·dt to p, so they are
   time-aligned with the cells), then
   - a cell against a ring: the nearest edge of the ring's bead loop as a capsule of the bead
     radius, the whole loop searched with its winding, so a cell whose centre got inside is
     pushed out across the nearest edge (a reach beyond it), not further in;
   - a bead against a creature: the outline (its outline cells' centres) as capsules of the
     cells' contact radii, seven edges round the nearest one searched each substep (the
     whole outline for a bead that started inside), the side from the edge's normal (at a
     corner the two edges' pseudo-normal);
   - both solved as position corrections split by inverse mass (both sides move: the cell and
     the edge's two beads, or the bead and the edge's two cells, as the cells' own edge
     contacts do), so the pair's momentum is kept;
   - the ghosts kept out of the walls (a bead pressed between a cell and a wall stays out of it
     within the frame, not just at the kernel's next step: without it a ring resting under a
     blob buzzed at 60 px/s);
   - a touched ring's change of velocity drawn toward its rigid part (`ring_rigidity`, 0.3 a
     substep: its mean and its turn about its centre, momentum and angular momentum kept),
     so within one frame a ring answers a push as a whole, as its constraints would, and its
     dent stays for the kernel's own elasticity to undo;
4. after the step, each touched ring's beads get their ghosts' change of position (position
   and previous position, so no velocity comes of it) and velocity (`couple_apply()`).

Nothing is counted twice: the kernel never sees the creatures, and the cells resolve each
contact once, with both masses. The cost is about one frame of lag for the ring's own
constraints: they answer a push at the kernel's next step (the rigidity stands in for them
within the frame).

**Masses.** The two solvers' masses are in different units (a ring's are `GooTuning`'s, small;
a cell's its area × the cells' density, 1 per px²), so a coupled ring weighs its target area ×
`ring_density` (1: a ring weighs what cells of its area weigh; the bead mass is that / its
bead count). The momentum the tests measure is in these units.

**Settled rings.** A settled ring's ghosts are immovable (the cell takes the whole push), and a
contact deeper than the kernel's wake depth or closing faster than its wake speed wakes it
(`GooKernel.wake()`, so the world's `woke` handling runs). A ring that touched a creature this
frame has its calm time restarted: it never settles while resting on or under a creature (the
kernel cannot see what holds it up).

**Determinism.** Gather, the coupling's broad phase, its substeps and apply are serial and in
a fixed order: a replay is identical and the cells' threaded step equals their serial one
(tested from GDScript and in cargo). Without a partner nothing of it runs: the golden trace
(`tools/trace.gd`) is unchanged and both worlds behave as before (`ghosts.on` gates every hook).

`GooTuning.unit`: every length the coupling uses comes from the solvers (bead radii, cell radii,
the cells' margin), so it scales with them; the tests run at unit 0.5 and 1.

### Measured (`tests/integration/test_goo_ring_cells.gd`, simulated time, no water drag)

Thrown at each other at the given speed each, zero gravity, the rings undamped for the
momentum (a ring's own linear damping, 0.1-0.5 /s, loses a third of its momentum in 1.5 s
otherwise):

| case | worst overlap found in a substep / measured after a frame | centres in a ring, beads in a creature (any frame / end) | momentum error | after |
|---|---|---|---|---|
| unit 0.5, ring 40 px, 37 cells of 14 px, 300 px/s | 2.08 / 0.65 px | 0 / 0 | 0.02 % | apart (ring −331, blob −161 px/s) |
| unit 0.5, same, 600 px/s | 3.68 / 1.17 px | 0 / 0 | 0.01 % | apart (−616, −332) |
| unit 1, ring 80 px, cells of 28 px, 300 px/s | 1.73 / 0.63 px | 0 / 0 | 0.02 % | apart |
| unit 1, same, 600 px/s | 4.15 / 1.29 px | 0 / 0 | 0.04 % | apart |
| ring 14 px (the smallest at 0.5) against 7 cells of 36 px, 400 px/s | 3.38 / 0.46 px | 0 / 0 | 0.04 % | apart |
| ring 80 px against 61 cells of 8 px, 400 px/s | 4.23 / 0.78 px | 0 / 0 | 0.04 % | apart |
| a triangle ring / a square ring of 40 px, 400 px/s | 3.11 / 0.56, 2.12 / 0.62 px | 0 / 0 | 0.09 %, 0.01 % | apart |
| 1 and 7 cells of 6 px shot at 1200 and 2400 px/s into a 60 px ring | 2.4-7.6 px found | 0 centres inside | | deflected |

At rest under gravity (5 s after 1 s of settling; drift of the centres over the last 3 s,
fastest particle in the last second):

| case | drift | fastest bead / cell | overlap |
|---|---|---|---|
| a 40 px ring on a 14 × 3 worm on the floor | ring 0.04, worm 0.58 px/s | 1.6 px/s | 0.01 px |
| a 19-cell blob in the dip between two 40 px rings held by low walls | rings 0.23, blob 0.17 px/s | 9.2 / 5.9 px/s | 0.02 px |
| the same ring and blob alone on the floor, uncoupled (reference) | 0.00, 0.15 px/s | 0.0 / 0.3 px/s | |

No jitter grows (the fastest particle falls from the second second to the fifth). A blob on a
ring under gravity buzzes slightly where alone it would be still: the frame of lag. The
rigidity was swept for it (fastest bead in the dip case: 51.6 px/s at 0, 9.2 at 0.3, 15.6 at
0.6, 28.9 at 1; deeper in-frame overlaps above 0.6); an earlier rigidity, a pull toward a rigid
fit of the ring's unperturbed path, sprang dented beads back into the cells (a bead moving
121 px/s into the blob that had just pushed it) and was replaced.

A 24 × 2 worm (lengths only) thrown broadside at 350 px/s onto a 36 px ring 40 times as heavy
as its area wraps round it, its ends 136 px past the ring's centre, then springs back: worst
overlap 0.93 px, never a centre or bead inside. A settled ring hit by a falling blob wakes 12
frames later. Uncoupled worlds pass through each other as before.

**Cost** (`tools/cell_world_bench.gd -- --rings=40 [--couple=0]`: 30 creatures of 150 cells and
40 rings of 18-26 px thrown about every 2 s in the gaps between them, unit 0.5, both worlds
stepped by hand; one machine shared with other work, load 2-5 on 4 cores, so ±0.3 ms):

| mode, threads | both worlds' steps median / p95, uncoupled | coupled | the coupling inside the cells' step (median, of it the broad phase) | rings touched a frame, candidate pairs |
|---|---|---|---|---|
| colliding, 4 | 2.14-2.44 / 2.74-3.69 ms | 2.38-2.71 / 2.84-3.53 ms | 0.18-0.20 ms (0.09-0.11) | 5.5-5.8, 94-97 |
| colliding, 1 | 4.10-4.11 / 5.44-5.74 ms | 4.01-4.26 / 4.69-5.97 ms | 0.18-0.19 ms (0.10) | 5.5, 94 |
| swimming, 4 | 3.46-3.63 / 4.49-4.86 ms | 4.22-4.41 / 5.88-6.53 ms | 0.36-0.43 ms (0.15-0.17) | 6.9-8.1, 278-317 |
| swimming, 1 | 6.91-7.23 / 7.69-9.86 ms | 7.91-8.08 / 8.51-8.62 ms | 0.42 ms (0.16) | 8.1, 317 |

The coupling itself costs 0.2 ms colliding and 0.4 ms swimming (the worms' long outlines give
three times the candidate pairs); the rest of the difference is the ring world's own step
growing (0.45 to 0.65 ms swimming), because the rings are now shoved about and collide with
each other more, which a game would pay for any interaction.

### Quirks to design around

1. **The cell world must step after the ring world.** `couple()` arranges it through the
   priority; a game that sets `process_physics_priority` itself, or steps worlds by hand, keeps
   the ring world first (else the cells meet the rings a frame late, 10 px at 600 px/s).
2. **Rings resting on or under creatures never settle**, so they keep costing the kernel's step,
   and buzz slightly (under 10 px/s at unit 0.5 measured).
3. **Masses are a choice**: `ring_density` 1 makes a ring as heavy as cells of its area, far
   heavier than its own (GooTuning's) mass; ring-ring collisions inside the kernel keep using
   GooTuning's masses, so momentum is only kept in the cells' units for ring-cell contacts.
4. **No friction and no restitution** between rings and cells (the cells have neither): a ring
   slides off a creature, a creature off a round ring; a blob rests on rings only in a dip.
5. **A ring's bead chain is a capsule chain**: a cell meets a ring's beads plus their radius,
   which is where the ring's skin is drawn; a creature is its outline cells' discs and the
   capsules between them, which is about where its skin is drawn (the skin's B-spline lies up
   to 0.43 radius off).
6. **Overlap within a frame** reaches 2-4 px at unit 0.5 in a 600 px/s crash before the
   substeps resolve it, and about 1 px remains after the frame (the rigidity moves the beads after
   the contacts); a game drawing both skins sees them touch, not cross.
7. **Ring-ring contacts are the kernel's, cell-cell the cells'**: a ring squeezed between two
   creatures gets both pushes from the cells in one frame, but a ring pressed between a creature
   and another ring meets the other ring only at the kernel's next step.
8. **With Godot's physics as well** (`physics_proxies`, `push_bodies` on both worlds,
   docs/godot-physics.md; `tests/integration/test_goo_coupled_godot_physics.gd`): a moving
   obstacle (a crate, a paddle) is mirrored into both worlds, each pushing its own goo and
   handing its own reaction to the body; the ghosts of the coupling ignore moving obstacles
   (the ring world has already met them with their reaction). The two mass systems meet at
   the crate: the coupling weighs a ring by `ring_density` × its area; the ring world, by
   default, by its kernel's bead masses. Set the ring world's `body_mass_density` to the cell
   world's `ring_density` and its `body_mass_scale` to the cell world's: it then weighs every
   ring as its area × that against moving obstacles, and the momentum of a ring, a creature and
   a crate is kept (0.19 % measured) for rings of any size. (Before, a `body_mass_scale` matched
   by hand to one ring, `body_mass() / (target_area × ring_density)` × the cells', kept it to
   0.30 % for that size only: 0.0023-0.033 at unit 0.5 for radii 44-5 px. At its bead masses
   and scale 1 a crate barely notices a 24 px ring: 109 % momentum change.) The ring world's
   proxies are moved in its own step, before the coupling's push of that frame reaches its
   beads (a frame's push behind).

## Limits

- Rings (`GooWorld2D`) and cell creatures collide only when coupled; one ring world per cell
  world (a cell world couples to one `GooWorld2D`).
- No friction: creatures slide off each other and along walls.
- No editor plugin: designs are made in code or as parallel arrays in the inspector (a
  creature editor is a later stage).
- 16 cell types per world (the kernel's slots).
- The skin is not clipped to the walls (bounded above) and has no per-cell detail (a cell
  never squashes; only the aggregate bends).
- Water is sampled at cell centres once a frame; drag acts on the outline only.
- One machine (4 cores); timings are wall clock, one run each, not averaged (the threads table
  shows about ±0.15 ms of noise between runs).
- Damping is an exponential decay: one rate cannot stop a creature both short and soon (see
  "Braking"); a game shapes the stop by changing the rate over time.
- The spin servo turns the creature as a rigid body: a bent worm turns about its centre of mass,
  not along its curve; it holds the world-frame spin, not the spin relative to a vortex.
- The yield reads the last substep's contacts: the first substep of a contact is at full power,
  and what a turning creature already carries (its angular momentum) hits at full power
  whatever the yield (only `max_tip_speed` limits that).


## Quirks to design around

1. **Spawned overlapping, tangled for good**: only outline cells collide with other
   creatures, so cells that start inside another creature stay there. `spawn()` warns when a
   cell lands inside one; spawn apart.
2. **Swimming crowds interpenetrate a little**: a stiff stroke pressing into a neighbour wins
   now and then: 12-29 px deep, up to 7 cells left inside another creature in 100 swimming
   worms over 5 s. Colliding blobs stay at 0.1-0.2 px.
3. **No friction, very inelastic**: nothing grips; two creatures meeting at 600 px/s each
   leave at about a tenth of it.
4. **Gaps jam**: stiff creatures jam at 0.8 of their width (exploration); soft types
   (lower `stretch` / `bend`) pass 0.6.
5. **Breaking learns the muscles' share**: the envelope is what the link carried over the
   last 2 s untouched; a sudden harder stroke can break links a gentler one never did.
6. **Ids move**: creature slots die on merges, splits get new ones; cell indices change at
   every topology change: keep uids and the handle's `data`.
7. **Topology changes rebuild the creature touched** (about 4 µs a cell): ask for
   retopologies, don't run one every frame.
8. **Swimming has a sweet spot**: speed per cycle falls with frequency (a 30 × 5 worm in the
   exploration: 0.270 at 0.5 Hz, 0.126 at 1 Hz, 0.077 at 2 Hz),
   falls for two-row bodies and is poor for irregular mixed-size bodies (0.016 bl/cycle in the
   exploration); blobs swim by thrust, not undulation. The swim drive (`set_swim()`) sidesteps
   all of this: it is as fast at any stroke, and the stroke can stay a gentle show of it.
9. **Commanded curls are clamped**: the pose wave never squeezes a side below half its length.
10. **The skin may cover a wall by up to about 0.43 radius** at a concave corner.
11. **A type edited after first use** needs `update_type()`; the 17th type is refused.
12. **Shape-matched regions bend only at joints**: a long region is stiff; give a part
    several groups to make it bendable, or use LINKS.
13. **The spin servo owns the spin**: while it is on, `set_damping()`'s angular part is ignored and
    `twist()` / `twist_once()` add to what it holds against (it takes them back within its
    acceleration). Stop it (`stop_spin_servo()`) to let a creature spin freely.
14. **Contact ids follow the mirror**: a wall's or an obstacle's id is GooStatics' kernel id,
    renumbered when a body comes or goes (the mirror is rebuilt); resolve it in the frame it is
    read (`contacts()` does).
