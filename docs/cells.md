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
| `tools/cell_world_bench.gd` | cost, draw and swimming through the world node |
| tests | `tests/integration/test_goo_cell_world.gd`, `tests/unit/test_goo_cell_design.gd`, `tests/integration/examples/test_cells.gd`, `tests/unit/test_goo_cells.gd` (the exploration's), cargo tests in `cells.rs` |

**Rings and cell creatures do not collide with each other** in this stage: a
`GooWorld2D`'s bodies and a `GooCellWorld2D`'s creatures pass through each other. Both read
the same walls. `GooColony` (the ring-per-cell colony) is untouched.


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
**radius muscles** (`set_muscles()`: a size scale per cell, the links following), **thrust**
per cell along its heading (`set_cell_thrust()`), and whole-creature **push** and **twist**.

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

**Stepping**: per frame, in parallel per creature (`threads`, 4): forces, drag, rest values
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
- Exports: `threads`, `substeps`, `stretch_hz`, `bend_hz`, `body_mode`, `shape_stiffness`,
  `self_collision`, `gravity_scale` (1: GooTuning's gravity; 0 top-down), `drag_enabled`,
  `drag_normal`, `drag_linear_normal`, `drag_ratio`, `drag_density`, `current`,
  `break_force`, `break_leaves_out_own_share`, `draw_skins`, `skin_material`,
  `draw_borders`, `border_color`, `border_width`, `default_type`.

`GooCellCreature` (a handle; creatures are not nodes): `is_alive()`, `center()`,
`velocity()`, `turn()`, `heading()`, `spin()`, `mass()`, `cell_count()`, `positions()`,
`velocities()`, `radii()`, `uids()`, `type_slots()`, `outline()`, `cell_index(uid)`,
`cell_position(i)`, `cell_angle(i)`, `cell_type(i)`, `is_boundary(i)`, `cell_at(point)`;
`push(acceleration)`, `twist(angular_acceleration)`, `set_cell_thrust(i, force)`,
`set_cell_force(i, force)`, `set_muscles(scales)`, `set_pose_wave(slope, wavelength,
frequency, bias, envelope)`, `stop_wave()`, `set_joint_angle(type_a, group_a, type_b,
group_b, angle)`, `set_water(velocities)`, `set_current(v)`, `translate()`,
`set_velocity()`, `add_cell()`, `remove_cell(uid)`; `design`, `axis` (its forward at
spawn), `data` (a dictionary for the game; copied to split parts). Forces set stay until
set again. Cell indices change at every topology change: keep uids.

`GooCellDesign` (a Resource, `.tres`, editable in the inspector): `types`
(`Array[GooCellType]`), parallel arrays `positions`, `radii`, `cell_types`, `groups`,
`angles`, plus `forward` and `link_tolerance`; `add_cell()`, `remove_cell()`, `clear()`,
`links()`, `bounds()`, `length()`, `centroid()`, `problems()` (arrays out of step, bad radii,
overlaps, unlinked cells), the builders `hex_worm(long, wide, radius)` and
`hex_blob(rings, radius)`.

`GooCellType` (a Resource): `name`, `color`, `mass_factor`, `radius_factor`, `stretch`,
`bend`, `break_factor`, `body`, `collides`, `collides_walls`, `self_collides`,
`contact_pad`, `join_layer`, `join_mask`, `behaviours` (a free dictionary for a game's
thrusters, spikes, sensors...). The kernel has 16 type slots; a world gives each distinct
type one the first time it is used (a 17th is an error and gets the default's).

A minimal use:

```gdscript
var world := GooCellWorld2D.new()
world.gravity_scale = 0.0
add_child(world)
var worm := world.spawn(GooCellDesign.hex_worm(24, 5, 14.0), Transform2D(0.0, Vector2(600, 400)))
worm.set_pose_wave(1.0, worm.design.length(), 1.0)   # swims along +x
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
| `break_force` | INF | games set it; with the own share left out, one value separates crashes from swimming (below) |
| `break_leaves_out_own_share` | on | without it, swimming loads links more than a 600 px/s crash (the exploration's quirk 6) |
| `CAPTURE` | 4 px at unit 1 | a retopology joins cells this close to touching |
| `MARGIN` / `MAX_SPEED` | 6 px / 6000 px/s at unit 1 | the solver's contact margin and speed cap (3 px, 3000 px/s at the game's 0.5); the swept wall test covers the cap |
| `GRAB_STIFFNESS` / `GRAB_DAMPING` / `GRAB_REACH` | 400 /s², 40 /s, 3 radii | critically damped; the cells within 3 radii of the grabbed one share the pull |


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


## Regions, joints and swimming

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

Two kernel bugs were found and fixed here (both cargo-tested): a shape-matched cell with
fewer than two neighbours of its region kept its angle forever and pinned the creature's
turn through its joint links (a blob with a rim of thruster cells could not be turned); and
under the pose wave a shape-matched cell's angle left out the bent pose's own turn, so joint
links fought the stroke (that three-region worm crabbed sideways, 1000 px/s along a wall).


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
  one contiguous piece** with a straight border (drawn as lines, `draw_borders`);
- around the outline, per outline cell a fan from its centre to its stretch of the skin, a
  quadratic B-spline through the midpoints of the outline pushed out by each cell's radius;
- a link is split at its midpoint only where a triangle on either side ends there (the rim, a
  mixed face), so neighbouring triangles share whole edges: **no T-junction, no pinholes**
  (a cargo test checks no vertex lies inside another triangle's edge);
- **gaps in mixed-size packings** (faces of four or more cells) are filled when the cells'
  discs nearly cover them (no point of the face farther than 0.6 of the mean radius from a
  disc); a real pocket stays open;
- the faces are walked once per topology change, not per frame.

Vertex colours are the types' colours; UV.x is 1 inside and 0 on the skin; UV.y is the
type's slot / 16. `goo_cells.gdshader` draws them flat with a darker edge band;
`skin_material` replaces it (the contract is in the shader's head).

Cost, 30 × 150 (`tools/cell_world_bench.gd --draw`): headless, building 0.24 ms and handing
over 0.10 ms a frame (4 threads; 20 400 vertices, about 4.5 per cell); under xvfb with the
real renderer (llvmpipe, which competes for the same 4 cores) 0.22-0.32 ms and 0.18-0.27 ms;
100 × 150 under xvfb 1.0 and 1.7 ms. Before this stage's rework the same skins cost 4.7 ms
and 2.8 ms (115 000 unindexed vertices).

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


## Limits

- Rings (`GooWorld2D`) and cell creatures do not collide with each other.
- No friction: creatures slide off each other and along walls.
- No editor plugin: designs are made in code or as parallel arrays in the inspector (a
  creature editor is a later stage).
- 16 cell types per world (the kernel's slots).
- The skin is not clipped to the walls (bounded above) and has no per-cell detail (a cell
  never squashes; only the aggregate bends).
- Water is sampled at cell centres once a frame; drag acts on the outline only.
- One machine (4 cores); timings are wall clock, one run each, not averaged.


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
   exploration); blobs swim by thrust, not undulation.
9. **Commanded curls are clamped**: the pose wave never squeezes a side below half its length.
10. **The skin may cover a wall by up to about 0.43 radius** at a concave corner.
11. **A type edited after first use** needs `update_type()`; the 17th type is refused.
12. **Shape-matched regions bend only at joints**: a long region is stiff; give a part
    several groups to make it bendable, or use LINKS.
