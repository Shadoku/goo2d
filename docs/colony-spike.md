# Colony spike: can 30 creatures of 150 cells run in a frame?

Milestone 0 of the colony plan (`fluid_physics_game/docs/colony-plan.md`): a measured
feasibility spike, run on 2026-11-12 on the development machine (4 cores, nothing else
running), Godot 4.7.2, the kernel built with `cargo build --release`. Branch
`colony-spike`.

## Verdict

**The gate is met, measured, with all three changes together.** 30 creatures × 150
cells (blob shape, smallest cell size, 12 beads a ring, moving and colliding):

| | physics per frame (median / p95) | drawing set-up per frame |
|---|---|---|
| Today: 4 500 `Goo2D` nodes in a `GooWorld2D` | 174 / 240 ms (kernel 105, script 68) | 75 ms of `_process` + 10 ms renderer set-up |
| A + B + C, the creature's own contacts off | **4.0 / 4.7 ms** | **0.28 ms** + 0.01 ms renderer set-up |
| A + B + C, own contacts on (needed, see "Risks") | **6.5 / 7.3 ms** | the same |

Gate: under 10 ms of physics and under 3 ms of drawing set-up. Met by 3.5 ms (with
the contacts a real creature needs) and by a factor of 10 on drawing. About 38 times
faster than today's path for the same cells.

What the measurement does not contain, because it does not exist yet, is listed under
"What is not in the numbers". The extrapolated cost once adhesion, surface tension and
exposure are real is **7 to 10 ms** at 4 threads: inside the gate, with little margin.
Plan for that, not for 6.5.

Without threads (a web build, a 2-core machine) the gate is reached only at **30 × 100
or 60 × 60 with the creature's own contacts off** (6.7 and 9.5 ms); with them on, about
30 × 60. Without core cells (threads, own contacts off) the limit is about **30 × 60 to
60 × 60** (5.3 and 7.8 ms); 30 × 150 rings-only is 10.9 ms median, 17 ms p95: missed.

## Method

### What was built

- `addons/goo2d/native/src/colony.rs`: a `Colony` of `Creature`s, behind a new
  GDExtension class `GooColony` (lib.rs). Nothing in the existing addon uses it; the
  `Kernel` is untouched apart from wall-clock timing of its phases (`solver()`'s
  `last_step_usec`, `last_phase_usec`) and `distances()` made `pub(crate)` so the colony
  reuses it. Each creature owns its data as struct-of-arrays: its ring beads (ring after
  ring), its cores, its bonds, its contact candidates. Ring cells run the kernel's ring
  math unchanged (skin and bending distances with `kernel::distances`, shape matching,
  stretch limit, pressure and internal damping as frame forces). Left out: static
  shapes, restitution and friction (water: e = 0), settling, splits, skins, links.
- **A, core cells**: one particle with the cell's radius and mass, colliding with beads
  and cores (other creatures' always; its own creature's when own contacts are on).
  `promote()` / `demote()` swap a core and a ring.
- **The hold-together stand-in for adhesion: bonds.** At spawn every ring bead within
  1.5 px (gap between outlines) of a neighbouring cell gets one XPBD distance constraint
  to the nearest point on that cell's edge (bead to edge, the point at `t` between two
  beads), rest length the two bead radii (zero gap); a bead near a core is bonded to its
  rim; touching cores to each other. Compliance 1 / the cells' skin stiffness. Solved
  every substep, like adhesion will be. This is exactly the constraint adhesion solves
  each substep (bead to edge, pulling and pushing), so its solve cost is representative;
  capture, anchors, creep and breaking are not in it (estimated below).
- **B, cells that are not nodes**: per creature one triangle-fan mesh (ring cell: its
  centroid and each bead pushed out a bead radius along its normal; core: centre and 12
  around). Attributes once (colour, UV = the vertex's place in its cell's rest frame /
  radius, CUSTOM0 = cell radius, exposed weight, cell index), positions every frame from
  Rust as the raw bytes of Godot's 2D vertex buffer, handed to
  `RenderingServer.mesh_surface_update_vertex_region()`. A canvas_item shader uses all
  three attributes (fill, a per-cell bubble field in the rest frame, rims where the
  exposed weight is 1, walls elsewhere). Variants measured: one mesh for the whole world,
  re-sending the attributes every frame, rebuilding the surface every frame, cores as
  MultiMesh instances.
- **C, threads**: rayon (1.12). Per substep: every creature's own work in parallel
  (prediction, rings, bonds, its own contacts), then the contacts between creatures
  serially in a fixed order, then every creature's velocities in parallel. Contact
  candidates once per frame: within a creature from its own grid in parallel, with each
  particle's reach measured against the creature's mean motion; between creatures only
  for pairs whose boxes overlap, only their particles inside the overlap, found in
  parallel and concatenated in pair order. Sleep (`set_asleep`: not stepped, immovable
  to others) and coarse stepping (`set_every`: every k frames with k frames of time).
- `tools/colony_bench.gd`: builds the creatures (packed cell designs, the classifier),
  keeps them moving and runs the table. See its header for every option.

### The fake creatures

Cells are packed edge to edge by placing each new cell touching two others where the
shape's score is lowest: `blob` (distance from the centre), `worm` (5 cells wide, grown
along x), `ragged` (a lobed outline). Sizes: `uniform` (all 14 px, the smallest at
`GooTuning.unit` 0.5, 12 beads) or `mixed` (14 to 26 px, most small). The design is
built once and every creature is a turned copy. Creatures start 3.2 bounding radii apart
on a grid (about a third of the arena covered), each pushed at 250 px/s² toward a random
target, retargeted every 5 s or on arrival; a linear damping of 1.5 /s stands in for
water drag (terminal speed about 170 px/s). Zero gravity. They run into each other: in
30 × 150, 150 to 600 bead contacts between creatures in the median frame (the PNG shows
several pairs pressed together).

Cores are chosen by `_classify()`: the cells rasterised at 1 px, each grown by the
capture distance (1.5 px), the outside flooded from the border; a cell is a ring when a
point just outside its outline is reached by the flood. Pockets between cells are not
the outside.

### What is measured

Per physics frame, min / median / p95 over 200 to 300 frames after 40 to 60 frames of
warm-up (30 × 150 nodes: 60 frames after 20). **physics** = the wall clock from the first
to the last physics callback of the frame: the kernel's or colony's step plus all
GDScript (the bench's per-creature push included). **kernel** = the step's own clock
inside Rust. **holds** = the bonds' solve, CPU time summed over threads. **drawing
set-up** = for the colony, the bench's `_process` work: building the arrays in Rust,
crossing into Godot, the RenderingServer calls; for nodes, the span of every `_process`
callback (the `Goo2D` skins). Drawing is measured under `xvfb-run` with the real GL
renderer (`--rendering-driver opengl3`, llvmpipe, `LP_NUM_THREADS=0`), physics headless.
"Renderer set-up" is `RenderingServer.get_frame_setup_time_cpu()`. GPU frame times under
llvmpipe are software rasterising and say nothing about a GPU, so they are not reported;
vertex, triangle and draw-call counts are.

A configuration replays the same paths every run (seeded targets, deterministic steps);
the same configuration measured twice still differs by about ±10 % in its medians
(machine noise), more in its p95. Configurations differ in where and when creatures
collide.

## The headline table

Median / p95 ms per frame. Today: nodes. "Rings" = no core cells. Own contacts off
unless noted (the bonds alone hold a creature's cells apart). Drawing set-up for the
colony rows is from the `region` variant (one mesh per creature, positions only).

| Creatures × cells | Today: nodes, physics (kernel + script) | today: nodes, `_process` | today's kernel alone | +B rings, 1 thread | +A+B cores, 1 thread | +B+C rings, 4 threads | **+A+B+C**, 4 threads | A+B+C with own contacts | drawing set-up rings / cores |
|---|---|---|---|---|---|---|---|---|---|
| 4 × 150 | 18.6 / 30.3 (10.5 + 7.9) | 9.3 | 13.4 / 16.5 | 4.2 / 5.2 | 1.0 / 1.3 | 3.4 / 5.1 | 1.2 / 1.9 | 1.5 / 1.9 | 0.09 / 0.06 |
| 10 × 150 | 49.1 / 64.4 (28.9 + 19.7) | 24.1 | 28.7 / 37.6 | 8.9 / 12.5 | 2.7 / 3.3 | 4.9 / 10.3 | 2.3 / 2.9 | 2.6 / 3.0 | 0.19 / 0.11 |
| **30 × 150** | 173.9 / 239.7 (105.0 + 67.8) | 75.0 (+10 renderer) | 109.8 / 146.9 | 28.1 / 36.0 | 8.5 / 10.4 | 10.9 / 17.3 | **4.0 / 4.7** | **6.5 / 7.3** | 0.47 / 0.28 |
| 30 × 100 | 107.6 / 148.7 (64.0 + 43.2) | 49.4 | 65.2 / 91.0 | 18.0 / 22.8 | 6.8 / 7.1 | 9.0 / 11.6 | 3.7 / 4.7 | 5.6 / 7.3 | 0.35 / 0.23 |
| 30 × 60 | 60.3 / 87.3 (35.5 + 24.7) | 29.9 | 34.4 / 46.5 | 10.7 / 13.9 | 5.6 / 6.1 | 5.3 / 6.8 | 2.5 / 3.6 | 3.6 / 4.3 | 0.25 / 0.17 |
| 60 × 60 | 127.3 / 181.3 (77.6 + 49.4) | 61.1 | 76.7 / 102.3 | 22.1 / 28.0 | 9.5 / 11.3 | 7.8 / 9.9 | 4.3 / 5.5 | 6.5 / 8.3 | 0.44 / 0.32 |

Also measured at 30 × 150: rings with own contacts on, 1 thread: 46.4 ms; cores with own
contacts on, 1 thread: 16.9 ms. The renderer set-up of the colony's 30 canvas items is
0.01 ms in every row; today's 4 500 `Goo2D` skins cost 10.0 ms of it (30 × 150; 1.5 ms
at 4 × 150), on top of `_process`.

B is a prerequisite of A and C here: they are measured on the colony solver, which only
exists because cells are no longer nodes. "+B rings, 1 thread" is therefore what B alone
buys (no per-cell GDScript, no per-cell skins, no O(rings²) pair passes, adhesion's bonds
in place of the overlap push), and the other columns add A, C or both to it.

## What dominates

**Today, 30 × 150** (headless): the kernel 105 ms = solver 57-64 (6 substeps over 54 000
beads, contact pairs included), the pair passes 21 (every pair of 4 500 ring boxes is
tested, O(rings²), then the overlap push on every touching pair), skins 11-12 (a
`Geometry2D` outline per moving ring); GDScript in the physics frame 68 ms (the events
dispatched per touching pair, the world's bookkeeping, the bench's per-cell push 8 ms);
`_process` 75 ms (4 500 skins: polygon and shader uniforms each); renderer set-up 10 ms.
Even the kernel alone (no nodes, no script) is 110 ms.

**After, 30 × 150, cores, 4 threads**: the step 4.0 ms = the parallel substep region 2.5
(rings 4.5 ms CPU, bonds 2.2-2.6 ms CPU, summed over threads), contact candidates 0.7,
contacts between creatures 0.1-0.3 (serial), the rest under 0.3. With own contacts on,
candidates within creatures become the biggest single item: 8.1 ms serial, about 2.5 ms
wall at 4 threads, plus 1.3 ms CPU of solving them.

**At small scale** (4 × 150) threads do not pay: 1.0 ms serial against 1.2 ms on 4
threads (12 fork/joins a frame for 4 creatures).

Rings are the unit of cost: 30 × 60 costs 66 % of 30 × 150 with cores although it has 40
% of the cells, because a 60-cell creature is 40 % rings and a 150-cell one 27 %.

## Ring and core cells (A)

From `colony_bench.gd --ratios` (cells sealed when within 1.5 px):

| shape | mix | 60 cells | 100 | 150 | 200 |
|---|---|---|---|---|---|
| blob | uniform | 60 % cores | 65 % | **73 %** (40 rings) | 76 % |
| blob | mixed | 37 % | 49 % | 52 % (72 rings) | 55 % |
| worm, 5 wide | uniform | 52 % | 55 % | 57 % (65 rings) | 58 % |
| worm, 5 wide | mixed | 22 % | 23 % | 27 % (109 rings) | 30 % |
| ragged | uniform | 37 % | 53 % | 61 % (59 rings) | 66 % |
| ragged | mixed | 13 % | 32 % | 34 % (99 rings) | 36 % |

Mixed sizes leave gaps wider than the capture distance between cells that touch only two
neighbours, so more cells see the outside through a channel. Counted with 4 px sealing
(a bead diameter, roughly what surface tension will close): blob mixed 65 %, worm mixed
37 %, ragged mixed 45 %. The plan's "40 to 60 cells on the outside of 150" holds for
uniform blobs (40), worms (65) and ragged shapes (59); mixed sizes give 72 to 109.

What that costs, 30 × 150, cores on, 4 threads, own contacts off:

| design | beads + cores | physics median / p95 |
|---|---|---|
| blob uniform | 14 400 + 3 300 | 4.0 / 4.7 |
| worm uniform | 23 400 + 2 550 | 4.3 / 5.1 |
| ragged uniform | 21 240 + 2 730 | 4.2 / 5.3 |
| blob mixed | 28 770 + 2 340 | 5.2 / 6.8 |
| ragged mixed | 38 760 + 1 530 | 6.0 / 7.1 |
| worm mixed | 42 660 + 1 230 | 6.1 / 7.5 |
| ragged mixed, no cores | 59 070 | 9.6 / 11.0 |

Add about 2.5 ms for own contacts. The worst designs still fit; the ratio matters as
much as the per-cell cost, as expected: a core costs about a tenth of a 12-bead ring.

### Promotion and demotion (measured, `--promote-test`)

A creature at rest for 1.5 s; one cell changed; a twin left alone (both rebuild their
bonds at that moment); every other cell's centre compared with its twin's.

| | cost | overlap at once | worst other cell off its twin after 1 / 5 / 30 frames |
|---|---|---|---|
| promote, uniform (4 cells) | 0.18-0.20 ms | 0 | 0.01-0.03 / 0.03-0.15 / 0.03-0.11 px |
| promote, mixed (4 cells) | 0.36-0.41 ms | 0 | 0.08-0.16 / 0.14-0.42 / 0.36-1.56 px |
| demote, uniform (3 cells) | 0.16-0.18 ms | 0 | 0.05-0.13 / 0.03-0.17 / 0.02-0.29 px |
| demote, mixed (3 cells) | 0.36-0.41 ms | 0.44-1.07 px | 0.15-0.92 / 0.57-1.68 / 0.39-1.58 px |

Promotion places the beads on the cell's rest circle, each pulled in along its ray until
it clears every neighbouring bead and core, moving with the core: nothing overlaps and
nothing jumps (0.16 px in the first frame at most; then the softer cell lets its
neighbours settle into it by up to 1.6 px over half a second). Demotion of a squashed
mixed-size ring puts a rigid disc of the cell's radius where the ring was narrower: up to
1.07 px of overlap, pushed out in a frame (0.92 px): a visible 1 px pop on a 14-26 px
cell. Easing the core's radius from the ring's inscribed size would remove it. The cost
is almost all the rebuild of every bond of the creature; a rebuild of the cell's and its
neighbours' bonds would be tens of µs. Either way it is once per change, not per frame.

### Knobs (30 × 150, cores, 4 threads, own contacts off, unless noted)

| knob | physics median / p95 | health (worst) |
|---|---|---|
| 12 beads (default) | 4.1 / 5.5 | 0-1 rings inside out, area 0.62-1.07 |
| 10 beads | 3.4 / 4.2 | 1 inside out, area 0.68-1.07 |
| 8 beads | 2.9 / 3.8 | **13 inside out** in collisions, area 0.76-1.08 |
| rings only, 1 thread: 12 / 10 / 8 beads | 28.0 / 23.6 / 18.6 | 0 inside out each |
| 6 substeps (default) | 4.1 | |
| 4 substeps | 3.2 / 4.0 | fastest bead 775 px/s, area 0.67-1.08 |
| 3 substeps | 2.3 / 3.1 | area 0.70-1.09 |
| 2 substeps | 2.2 / 3.0 | fastest 975 px/s, area up to 1.21 |
| own contacts on, grid cell × 0.75 / 1 / 1.5 / 2 | 7.2 / 6.5 / 6.2 / 6.2 | the same |

An 8-bead ring is an octagon on screen (`zoom_beads8.png`) and turns inside out when two
creatures collide; 10 beads behaves like 12 here and saves 18 %. Fewer substeps help less
than they promise below 4 (the per-frame work stays) and the crude health numbers start
to drift at 2; the ring springs (200 rad/s for the smallest cell) were tuned at 6. The
grid's cell size barely matters once candidates are found per creature against its own
mean motion (it mattered a lot before that change: the first, global version of the
candidate search took 33 ms of 62 at 30 × 150 rings, because one fast bead set the cell
size for everyone).

### The cost of adhesion (estimated from measured parts)

Bonds per cell: 9.2 for all-ring creatures (41 310 bonds for 54 000 beads: 77 % of the
beads are bonded, the rest are exposed), 3.7 with cores (16 710: bead to core rims and
core to core). Measured solve cost: 19-22 ns per bond per substep, 4.8 ms CPU per frame
for all rings, 2.2-2.6 ms with cores (6 substeps). Real adhesion adds per bond an anchor
spring along the edge (a second constraint on the same particles: about the same again)
and per frame the capture search, which needs the creature's own contact candidates
(about 2.5 ms wall at 4 threads, already in the "own contacts" column) plus bookkeeping
for creep and breaking (small, per bond, no sqrt). Estimate: 2-3 × the bonds' cost, so
+2.5 to 5 ms CPU, +0.8 to 1.5 ms wall at 4 threads over the "own contacts on" column.

## Drawing (B)

30 × 150 with cores: 58 500 vertices, 54 000 triangles, 30 draw calls (the all-ring
version has the same counts, since a 12-bead ring and a 12-sided core are both 13
vertices). The surface's strides checked by reading it back: 8 bytes a vertex (two
floats), 28 bytes of attributes (colour RGBA8, UV, CUSTOM0 RGBA float).

| variant (30 × 150, cores) | drawing set-up median / p95 | of which Rust | draw calls |
|---|---|---|---|
| `region`: one mesh per creature, positions only each frame | **0.29 / 0.43 ms** | 0.16 | 30 |
| `world`: one mesh for all creatures, one call | 0.29 / 0.36 | 0.22 | 1 |
| `attrs`: positions and every attribute each frame | 2.55 / 3.58 | 2.14 | 30 |
| `rebuild`: the surface rebuilt from arrays each frame | 3.40 / 4.61 | - | 30 |
| `multimesh`: ring fans as meshes, cores as instances | 0.44 / 0.63 | 0.16 | 60 (15 600 vertices + 3 300 instances) |

The cheapest correct path is positions only: the attributes do not change from frame to
frame (the UV is a material coordinate in the cell's rest frame, so the bubble field rides
the cell without being re-sent), and re-sending them costs 9 times as much (the
unoptimised attribute writer allocates; even a tight one would move 3.5 times the bytes).
Rebuilding surfaces is the worst. MultiMesh for cores buys nothing over fans. One world
mesh is as cheap as 30 and gives one draw call, but loses per-creature culling and
materials; a mesh per creature and cell type is what the plan wants and costs the same.

Before: 75 ms of `_process` and 10 ms of renderer set-up for 4 500 polygons, each its own
material and uniform set, 4 500 draw calls. After: 0.3 ms and 0.01 ms, 30 draw calls.

GPU: 58 500 vertices and 54 000 triangles in 30 calls is nothing for any GPU made in the
last decade (an integrated GPU transforms tens of millions of vertices a second; this is
well under 0.1 ms of vertex work); the fill is the creatures' area once (about a third of
the screen at this zoom) with a cheap fragment shader. The upload is 468 KB a frame into
dynamic buffers. llvmpipe's 49 ms frame here is software rasterising and is not a
measurement of anything a player would see. The look in the spike is crude (cores are
rigid discs, small triangular gaps between three cells, rims per vertex rather than per
edge). The pictures named in this report (`colony_30x150_*.png`, `zoom_*.png`) come from
the drawing commands under "Reproducing" (`--png`, `--zoom=3`) and are not committed.

## Threads (C)

Thread scaling, 30 × 150, cores, own contacts off (same run, same paths):

| threads | 1 | 2 | 3 | 4 |
|---|---|---|---|---|
| physics median / p95 | 8.2 / 8.5 | 6.6 / 8.0 | 5.3 / 6.5 | 4.1 / 5.5 |
| parallel substep region | 6.8 | 4.6 | 3.6 | 2.5 |

The parallel region scales 2.8 × on 4 cores; the whole step 2.0 × (all rings: 28.0 → 10.9
ms, 2.6 ×). What stays serial: the contacts between creatures (0.1-0.3 ms, solved in
order), the list of overlapping creature pairs (O(creatures²) box tests, negligible at
60), gathering per-step setup, the GDScript call and statistics; the per-substep
fork/joins (12 a frame) cost more than they save below about 10 creatures. Load balance:
30 creatures on 4 threads leaves up to 1/8 idle; very unequal creatures would leave more.

**Determinism.** A threaded step is bit-identical to a serial one, by construction: every
creature's work touches only that creature's arrays and runs the same instructions in the
same order whichever thread runs it; there is no reduction across creatures or threads;
contacts between creatures are solved serially in an order fixed by creature indices
(found per overlapping pair in parallel, then concatenated in pair order); the serial path
calls the very same per-creature functions in creature order. Tested twice: `cargo test`
(`threaded_step_is_bit_identical_to_serial`, 6 colliding creatures, 90 frames, compared
with `to_bits()`) and `tests/unit/test_goo_colony.gd`
(`test_threaded_step_equals_serial_step`, 4 creatures that collide, 90 frames, every
particle compared exactly). The golden trace (`tools/trace.gd`) is byte-identical to
before the spike (md5 7f26b075334263e1f447ee8104806252 before and after): the `Kernel`'s
arithmetic was not touched. Note: this is determinism per build; the colony's order of
operations differs from the `Kernel`'s (rings, then bonds, then contacts per creature,
instead of all rings then all contacts), so it is a different simulation, not a faster
copy of today's.

**Sleep and coarse stepping** (30 × 150, cores, 4 threads): 15 of 30 asleep 2.4 ms (4.1
with none), 27 of 30 asleep 1.6 ms: an asleep creature costs a few µs (its reach and box).
15 of 30 stepped every other frame (each with two frames of time, alternating halves):
3.05 ms, −25 %, and less stable (ring area up to 1.28 of target in collisions: double the
substep).

## What is not in the numbers

- Real adhesion: capture, anchors, creep, breaking (estimated above: +0.8 to 1.5 ms at 4
  threads).
- Surface tension along the outer outline (per exposed edge: cheap), exposure and pocket
  detection (on contact changes only), drag on exposed edges in the kernel (per exposed
  bead: cheap), statics (walls), restitution and friction.
- The game's per-creature GDScript (swimmer, pilot): per creature, not per cell; today's
  creatures cost well under 0.1 ms each. Muscle strokes as per-cell rest deformation are
  per ring per frame in Rust.
- Other systems competing for the 4 cores (Godot's own threads, the game, audio).

Extrapolated total, 30 × 150 with everything: 7 to 10 ms at 4 threads (6.5 measured +
1 to 3 estimated). Inside the gate, thin margin.

## Risks

1. **Cores against rings under impact.** Cores are rigid and heavy, so a collision between
   creatures concentrates in the outer ring layer: ring area falls to 0.53-0.62 of target
   (0.77 for all-ring creatures), bonds stretch up to 0.4-0.7 of their rest length, and
   a ring turns inside out now and then (0-1 per 300 frames at 12 beads, 13 at 8 beads).
   With the creature's own contacts off, cores slip through the outer rings at an impact
   (`zoom_beads12.png`, bottom); with only core contacts, outer rings fold over each
   other (`zoom_intra_cores.png`); with all own contacts the creature holds
   (`zoom_intra_on.png`). That costs 2.4 ms at 4 threads and is in the gate figure.
   Adhesion with anchors may supply part of it; until shown, budget it.
2. **The margin is thin once milestones 1-3 land**, and the thread speedup assumes 4 free
   cores. On a 2-core machine or a web build (rayon needs wasm threads and
   SharedArrayBuffer there; the serial path would need a cargo feature) the reachable
   size is 30 × 100 or 60 × 60, own contacts off. Mixed-size designs cost up to 1.5 ×
   the uniform blob.
3. **Two solvers.** The colony is a second solver beside the `Kernel`, sharing only the
   ring math. Links, statics, grabs, cuts, merges, skins and settling exist only in the
   `Kernel`; creatures and loose bodies do not collide with each other. Folding the
   per-creature storage into the `Kernel` (or the reverse) is real work and changes
   the golden trace if the existing world moves to it.

Also seen: a demotion pop of up to 1 px (mixed sizes); promotion costing a whole
creature's bond rebuild (0.2-0.4 ms, fine once, not for many cells a frame); memory is
not a concern (30 × 150 with cores: about 1.4 MB of particle and bond arrays, 2.1 MB of
vertex buffers); the library grows from 4.4 to 5.0 MB; the three platforms: `cargo check
--release --target` passes for x86_64-pc-windows-msvc, aarch64-apple-darwin and
x86_64-apple-darwin (type-checked only: there is no MSVC linker or macOS SDK here, so
`kernel.yml` would be the first real link; rayon and its dependencies, rayon-core,
crossbeam-deque/epoch/utils and either, are pure Rust with no C toolchain).

## Keep, rewrite

Keep as designed:
- Per-creature struct-of-arrays storage and the threading pattern: creatures in parallel,
  contacts between them serially in a fixed order, bit-identical to serial.
- Contact candidates per creature against its mean motion; between creatures only where
  boxes overlap.
- The drawing pipeline: attributes once, positions as raw vertex bytes each frame through
  `mesh_surface_update_vertex_region()`, one mesh per creature (and per cell type).
- Bead-to-edge XPBD constraints as the core of adhesion's solve.
- Core cells, and promotion that fits the new ring to the pocket.

Rewrite for the milestones:
- Make it one solver: the `Kernel` gains groups (creatures) with per-group storage, or the
  colony gains statics, links, grabs and loose bodies; decide before milestone 1.
- Bonds become adhesion (capture each frame from contacts, anchors, creep, break, filters,
  signals), and the bond rebuild after a promotion becomes local.
- Exposure computed in the kernel from the adhesion topology (`_classify()` is a
  design-time raster in GDScript: fine for the spike, not for run time).
- Own contact candidates: reuse them across frames (they barely change inside a creature)
  or derive them from the adhesion topology; they are 40 % of the step when on.
- Demotion eases the core's radius in; cores keep a rotation so their bubble field turns.
- Drawing: smoothed outlines, the gaps between three cells filled, per-type batches,
  rims and walls per edge rather than per vertex.

## Recommendation

1. Keep the target: 30 × 150 is reachable with core cells, cells that are not nodes and
   threads together; none of the three alone reaches it (rings-only with threads misses
   at 10.9 ms median, 17 p95; cores without threads sits at the limit, 8.5 / 10.4, and
   fails once own contacts are on).
2. Build milestone 1 (adhesion) on per-creature storage from the start and bring the
   threaded step in with it: the determinism design dictates the data layout, and
   retrofitting it later is the expensive way round. Decide first whether the `Kernel`
   absorbs the colony's storage or the colony grows the `Kernel`'s features (risk 3).
3. Fold core cells into milestone 2 as planned; implement sleep with it (an asleep
   creature costs nearly nothing).
4. Re-run this bench at the end of milestone 3 with adhesion, tension and exposure real,
   against the same gate. If it misses, the cheap knobs in order: 10 beads for the
   smallest cell (−18 %, behaves like 12 here), 4 substeps (−22 %, check the feel),
   coarse stepping for far creatures (−25 % with half of them), then fewer cells per
   creature (decision 6).
5. Batch drawing (milestone 4) is not a cost risk: 0.3 ms for 4 500 cells. Its risk is the
   look (same-type cells contiguous), not the frame time.

## Reproducing

```
# rings and cores per design
godot --headless --path . -s tools/colony_bench.gd -- --ratios [--seal=4]
# physics (headless); add --threads=4, --cores=off, --intra=on, --mode=nodes|kernel ...
godot --headless --fixed-fps 60 --path . -s tools/colony_bench.gd -- --creatures=30 --cells=150 --threads=4
# drawing set-up (needs a renderer), and a picture
LP_NUM_THREADS=0 xvfb-run -a -s "-screen 0 1920x1080x24" godot --path . --rendering-driver opengl3 \
  --audio-driver Dummy --fixed-fps 60 -s tools/colony_bench.gd -- --creatures=30 --draw=region --png=out.png
# promotion and demotion
godot --headless --path . -s tools/colony_bench.gd -- --promote-test [--mix=mixed]
```

Each run prints one `RESULT` line with the medians and p95s, after the per-phase lines.
