# Colony exposure, core cells and drag (milestone 2)

Milestone 2 of the colony plan (`fluid_physics_game/docs/colony-plan.md`): which beads of a
creature in a `GooColony` face the water and which are enclosed, the pockets between cells,
rings that become cores and cores that become rings again by themselves, cores that give
under an impact and turn, and the fluid game's water drag inside the colony's step, on
exposed edges only. Built and measured on 2026-11-12, branch `colony-spike`, on the same
machine as milestones 0 and 1 (4 cores).

The colony stays a second solver beside `GooKernel`; nothing in `GooKernel`, `GooWorld2D` or
`Goo2D` changed (the golden trace is still `7f26b075334263e1f447ee8104806252`). Every part is
off by default, so milestone 1's tests and bench run as before.

## Where it is

| What | Where |
|---|---|
| Exposure, pockets, the outline, the automatic switches | `addons/goo2d/native/src/colony/exposure.rs` (`Exposure`, `compute_exposure()`, `post_step()`, `auto_switch()`, `restick()`) |
| The drag | `addons/goo2d/native/src/colony/drag.rs` (`Drag`, `loop_forces()`, `apply_drag()`) |
| Cores that turn and give, the switches' smoothing, kept candidates | `addons/goo2d/native/src/colony.rs` (`Cores`, `core_frame()`, `predict()`, the anchored core stick in `solve_sticks()`, `demote()` / `promote()`, `reuse_own_pairs()`) |
| The API | `GooColony` in `native/src/lib.rs` (the block "Exposure, cores, drag" at its end, and the options) |
| Presets | `GooColonySim.EXPOSURE_OPTIONS`, `GooColonySim.DRAG_OPTIONS`, `GooColonySim.SKIP_SPEED` (`addons/goo2d/goo_colony_sim.gd`) |
| Tests | `tests/unit/test_goo_colony_exposure.gd` (14 tests); `cargo test` in `native/` (16, 6 of them new: the hex cluster's exposure, a pocket and a bay, automatic cores in a hex cluster, the drag law on a square, the cost of one pass, threaded == serial with all of it on) |
| Bench | `tools/colony_bench.gd`: `--exposure`, `--auto-cores`, `--skip`, `--core-contact`, `--core-anchors`, `--m2` (the preset), `--water-drag`, `--water=uniform|cells`, `--exposure-every`, `--exposure-hot`, `--reuse`, `--skin` |
| Pictures | `tools/colony_shot.gd`: exposed beads white, enclosed dark, the outside loop cyan, pockets blue, each core's turn as a tick; scenes `exposure` and `crash` added |

## The model

### Exposure

Each ring bead is exposed (1) or enclosed (0), in `Creature::exposed`. A bead is enclosed
when:

1. it is stuck (end a of a stick), or it is a bead of the edge a stuck bead holds onto and
   within the gap of that bead (the far side of a one-sided wall);
2. it lies within `gap` (default: the capture gap, 2.5 px at unit 0.5) of another cell's
   skin of the same creature, whether the two are joined or not (two cells pressed together
   without a wall still face no water there);
3. it faces a pocket: see below.

Rule 1 is read off the sticks without a search; rule 2 searches a grid of the creature's
points for the beads rule 1 left (the search over every bead cost 1.2 ms a pass for a
169-cell creature, reading the sticks first 0.14 ms).

### Pockets and the outline

Each cell's runs of beads not enclosed by contact are chained into loops: the end of a run
is joined to the start of the run that continues the outline where the bead after the end
meets another cell X. In order: a run of X coming out of a contact with this cell; a run of
any cell nearby coming out of a contact with X (the outline passes along X, which has no run
there: a small cell in a crevice, a core); a run nearby coming out of this cell; any run of X;
any run nearby but its own. A walk that closes on itself is a loop. Every ring is
counter-clockwise on screen (negative signed area), and the boundary of a union of such
shapes keeps that winding on its outside and has the other on its holes, so a loop with
negative area is an outside and one with positive area a pocket; the largest loop is an
outside whatever its winding. A pocket's beads are enclosed. A run whose walk ends on
another loop or nowhere stays exposed (counted in `stats()["broken_runs"]`).

A creature in several pieces has several outsides. `creature_outline(c)` is the largest
outside's points (beads, and a core's virtual beads where it runs along a core);
`creature_loop(c, k)` and `creature_loop_kinds(c)` give them all.

### Cores take part as the ring they would be

A core is given its cell's bead count of virtual beads on its rim (the ring's rest
outline, turned with the core, scaled by its radius now), tested like beads but with a
wider gap, `core_gap` × `gap` (2 ×). A core with a virtual bead on an outside is exposed
(`cexposed`). The wider gap is the hysteresis between the two switches: a ring becomes a
core when every bead is within 2.5 px of a neighbour (or faces a pocket), and goes back only
when the core's rim is 5 px clear of one somewhere on the outside.

### When the pass runs

Exposure changes when cells part, so the pass runs after a pair parts (and on the following
`hot` = 6 frames: parted cells take a few frames to move apart), after a switch, a resize or a
join or part by hand, and every `every` = 30 frames as a safety net, staggered by creature. A
join only encloses beads, which the next regular pass finds. A cell waiting to switch is
looked at again when its time is up, not every frame. Running it on every stick made or
broken (milestone 1's capture makes and breaks a few every frame in a crowd) ran it for half
the creatures every frame.

### Automatic cores (`auto_cores`)

- A ring with every bead enclosed for `to_core_time` (0.25 s) becomes a core
  (`demote()`); a core exposed for `to_ring_time` (0: at once) becomes a ring (`promote()`).
  A switched cell does not switch again for `switch_rest` (1 s). Manual `promote()` /
  `demote()` stay and use the same smoothing.
- No jump: the core sits at the ring's bead centroid, moving with its mean velocity and
  spinning with its beads' angular momentum about it (over the core's moment of inertia, a
  ring's: mass × ring radius²); its turn is the ring's best-fit rotation. Its disc starts no
  larger than the room its neighbours leave and grows to the cell's radius over `core_ease`
  (0.25 s). Back to a ring, the beads go where the core's turned rest outline puts them,
  pulled in to clear every neighbour, moving with v + ω × r.
- Walls kept: the switched cell is stuck straight back (`restick()`) to every neighbour it
  was joined to at the last settle, within the capture gap, in the mode its pair allows; each
  new stick holds the gap it found (`Stick::gap0`), easing to zero over `core_ease`, so the
  switch moves nothing at once. Nothing is reported: the pair never showed as parted.

### Cores turn (`core_anchors`)

A core has a turn, an angular velocity and a moment of inertia (`crot`, `comega`, its cell's
mass × ring radius²), integrated with the rest. Contacts are central and turn nothing; an
anchored stick on a core's rim does: C = (bead − centre) · t − offset, t the rim's tangent at
the anchor's angle in the core's frame, with dC/dθ = −(bead − centre) · u in its gradient, so
it conserves angular momentum. The anchor creeps like an edge's. With `core_anchors` on, a
bead captured onto a core is anchored when the type table says so; off, sticky as in
milestone 1. Core-to-core sticks stay gap only (a rolling contact between two turning discs
needs both turns in one constraint: not needed yet). The cost was a cosine and a sine per
anchored core stick per substep (+0.7 ms of CPU at 30 × 150); each core's (cos, sin) once a
substep and the anchor kept as a direction brought it to a rotation by multiplication.

### Softer cores (`core_contact`, `soft_cores`)

The spike found rigid cores concentrate an impact in the outer cells. Two ways were built and
measured (`test_compliant_cores_...`, two clusters of 37 thrown at each other, their 19
enclosed cells cores each):

| impact, each cluster | no cores | rigid cores (before) | soft radius | compliant contacts (the preset) |
|---|---|---|---|---|
| 300 px/s | area 0.71 | 0.59 | 0.59 | **0.66** |
| 600 px/s | area 0.58 | 0.45, 2 inside out, 6 particles through | 0.55 | **0.62**, none |

- **Compliant contacts** (`core_contact` = 1, the preset's): a core's contacts with its own
  creature's beads and cores are XPBD contacts with compliance 1 / (`core_contact` × the core
  cell's skin stiffness): the impulse spreads over a few substeps as through a ring. At rest
  beads sink 0.2-0.3 px into cores; in the bench's collisions up to 4-6 px (rigid: 1.3-2.1).
  0.3, 1 and 3 were tried: 0.3 and 1 are as good, 3 is no better than rigid.
- **A soft radius** (`soft_cores`): the radius is a degree of freedom squeezed by every
  contact and stick, pulled back by a spring of `core_stiffness` × 4π × pressure_k (what a
  ring's pressure gives for a change of its radius), the cell's mass as its inertia, clamped
  to 0.6-1.25 of its rest. It shrinks (to 0.60) but the outer cells squash as much as with
  rigid cores: they flow into the room it leaves. Kept as an option; not in the preset.

### Skipping the enclosed in collisions (`skip_enclosed`): built, measured, off

Requirement 4 of the plan says enclosed beads take no part in collisions. Measured, it is
unsound: an outer ring is soft, and the other creature's bead that dents it meets nothing
behind it and passes in.

| two blobs of 127 pressed together at 250 px/s² for 3 s | cross candidates a frame | skipped a frame | particles inside the other |
|---|---|---|---|
| every particle collides (`SKIP_NONE`, the default) | 209 | 0 | 0 |
| cells with no exposed bead skipped (`SKIP_CELLS`) | 205 | 21 | 0 |
| every enclosed bead skipped (`SKIP_BEADS`) | 96 | 518 | 317 |

`SKIP_BEADS` lets the other creature in through every wall's seam. `SKIP_CELLS` (cores and
rings with no exposed bead) saves nothing worth having (the overlap of two creatures' boxes
holds their outer layers) and in the 30 × 150 bench it let rings be crushed and pierced
(ring area up to 2.5 of target, 5 inside out); creatures meeting faster than `skip_speed`
(1600 px/s at unit 1) collide whole for a second (`FAST_REST`), which fixed a 600 px/s
impact but not the bench. So the default is `SKIP_NONE`: exposure is for the drag, the
switches, the outline and the look, not collisions. Walls (not built) will face the same
question.

### Drag (`drag`)

The law of the fluid game's `FluidDrag.bead_forces()`, ported (`drag.rs`), applied once a
frame before the substeps to every ring's skin edges (as the game applies its forces through
`apply_bead_forces()` before the kernel steps): per edge, the mean of its two beads'
velocities relative to the water split across and along the edge; force
−(normal |v_n| + linear_normal) v_n n − (tangent |v_t| + linear_tangent) v_t t × edge length ×
density, the whole of it added to both beads (as the game does); each bead's total clamped to
`max_step` of its relative speed × bead mass / frame. Density per cell as the game's
`FluidWorld`: `drag_density` × the cell's mass / (π radius²). Exposure weighs each edge by the
mean of its two beads' (1, ½, 0): a wholly enclosed cell and every core get none. Without
exposure every edge counts.

The water: `set_water(c, v)` for a whole creature, or `set_cell_water(c, velocities)` one per
cell (sampled where `creature_cell_centers(c)` says). Feeding 4 500 cells from a stand-in
vortex in GDScript costs 0.57 ms a frame (`--water=cells`); the game's `FlowField` with
several regions would cost more, per creature (`set_water()`) next to nothing. Per bead was
not built: a per-cell value is what a cell-sized creature needs and a 54 000-entry array a
frame is not cheap to fill in GDScript.

### Kept candidates (`reuse_pairs`)

A creature's own contact candidates (2.2-2.5 ms of the 30 × 150 frame at 4 threads) can be
kept across frames: searched with `pair_skin` px of margin and filtered every frame by that
frame's reaches. The list is searched again when a particle's motion margin plus how far it
moved against the creature's rigid motion (its mean's shift and best-fit turn since the
search) could exceed the skin, after a switch, or when it no longer covers the capture gap.
With it, motion is measured against the creature's mean and spin (plus what the spin moves
two neighbours apart), so a turning creature keeps its list: one pushed along a circle is
searched 29 times in 180 frames. Deterministic (rebuilt and filtered on the creature's own
data in a fixed order); off by default.

### Determinism

Every part runs on the creature's own data in the per-creature passes (the exposure pass in
the settle pass's parallel region); the per-pair "met fast" record is kept serially. The
threaded step stays bit-identical to the serial one: `cargo test
threaded_exposure_cores_and_drag_are_bit_identical_to_serial` (6 clusters with exposure,
automatic, compliant, soft and anchored cores, per-cell water and kept candidates, 200
frames; positions, velocities, core radii and turns, exposure, sticks' loads, anchors and
gaps, drag forces compared by bits) and `test_threaded_step_equals_serial_with_exposure_cores_and_drag`
(240 frames, 105 switches, 423 events, equal).

## The API

`GooColony` options (`set_options()`; every one off or at its default unless set):

| Option | Default | What |
|---|---|---|
| `exposure` | false | the exposure pass |
| `exposure_gap` | −1 (the capture gap) | px |
| `core_gap` | 2 | × the gap, for a core's virtual beads |
| `exposure_every`, `exposure_hot` | 30, 6 | frames |
| `skip_enclosed` | `SKIP_NONE` | `SKIP_CELLS` or `true`, `SKIP_BEADS` (both unsound) |
| `skip_speed` | 1600 (GooColonySim: × unit) | px/s |
| `auto_cores` | false | |
| `to_core_time`, `to_ring_time`, `switch_rest`, `core_ease` | 0.25, 0, 1, 0.25 | s |
| `core_anchors` | false | beads anchored on cores' rims |
| `core_contact` | 0 (rigid) | × the core cell's skin stiffness |
| `soft_cores`, `core_stiffness`, `core_damping`, `core_min_radius`, `core_max_radius` | false, 1, 1, 0.6, 1.25 | |
| `drag`, `drag_density`, `drag_normal`, `drag_tangent`, `drag_linear_normal`, `drag_linear_tangent`, `drag_max_step` | false, 1, 0.1, 0.01, 60, 8, 0.5 | the game's GameSettings numbers |
| `reuse_pairs`, `pair_skin` | false, 3 | px |

Calls: `set_creature_velocity(c, v)`, `creature_velocities(c)`, `set_water(c, v)`,
`set_cell_water(c, velocities)`, `creature_cell_centers(c)`, `creature_drag_forces(c)`,
`update_exposure(c)` (the pass now), `creature_exposure(c)` (per bead), `cell_exposed(c, cell)`
(per bead, or [1]/[0] for a core), `cell_exposed_count(c, cell)`, `cell_outward(c, cell)` (the
mean direction of its exposed beads: thrusters and spikes), `cell_rotation(c, cell)` (a core's
turn), `creature_loop_kinds(c)` (`LOOP_OUTSIDE`, `LOOP_POCKET`), `creature_loop(c, k)`,
`creature_outline(c)`. `stats()` adds `drag_cpu_us`, `exposure_us` (CPU), `exposure_runs`,
`exposed`, `enclosed`, `pockets`, `broken_runs`, `to_core`, `to_ring`, `cross_skipped`,
`own_pairs_us`, `pair_builds`; `health()` adds `core_min`, `core_max` (radius over rest).

`GooColonySim.EXPOSURE_OPTIONS` = exposure, automatic cores, compliant contacts (1), core
anchors; `DRAG_OPTIONS` = the game's drag. Pass them (merged) to `GooColonySim.new()`.

## Measured

### The tests (`tests/unit/test_goo_colony_exposure.gd`, unit 0.5)

| Test | Result |
|---|---|
| hex cluster of 19 | the 7 inner cells 0 exposed beads; the 12 rim cells 48 exposed beads, none facing in; one loop (the outside, 48 points); with automatic cores the 7 become cores 25 frames later, no parted event, the middle core stuck to all 6 |
| a pocket and a bay | a closed ring of 10 cells round a hole: a pocket of 3 010 px², the 20 beads facing it enclosed, the 20 facing out exposed; an open ring of 9: no pocket, all 17 beads facing the bay exposed |
| a loose mixed cluster of 40 (3 seeds) | one outside each; of 139-185 exposed beads 1-3 on no loop |
| switching without a jump or flicker | 40 cells, twins with and without the switch: 20 rings (uniform) / 4 (mixed) became cores at once; the switched cells' centres 0.000 px off their twins' at the switch; the other cells' 0.07 / 0.56 / 2.7 px (uniform) and 0.03 / 0.25 / 1.7 px (mixed) after 1 / 5 / 30 frames (a disc settles a little differently from a ring: the spike's 0.4-1.6 px after 30 frames); velocities 0.000 px/s off at the switch; over 5 s no core went back, each cell switched once, no parting |
| a core whose neighbour leaves | the neighbour parted by hand and pushed away: the core behind it a ring after 5 frames, 0.012 px off where it was heading; its other 5 walls kept, no parted event of it |
| compliant cores | the table above |
| skipping the enclosed | the table above |
| the drag law | a free 20 px cell wobbling in a current: the kernel's forces equal the ported GDScript law within 6.1e-5 (1e-7 of the largest force); with linear_normal 4 000 all 14 beads clamped, equal within 2e-7 relative |
| enclosed cells and the outline | hex clusters of 7, 19, 37 at 100 px/s: the middle cell's drag 0; drag per px of outline 11.5 / 10.7 / 10.1 (37 against 7: × 0.88), per cell 364 / 216 / 149 (× 0.41) |
| a thrown cell | a 30 px cell thrown at 400 px/s (no damping of its own, internal damping × 0.25, as the game's bodies): 176 px, stopped (2 % of the throw) after 1.97 s, never sped up (the game's test bounds: 60-400 px within 2.5 s) |
| core anchors | a ring pushed round a core: sticky, the core turns 0.00 rad; anchored, 4.36 rad while the ring goes 1.95 rad round it |
| kept candidates | a 37-cell creature pushed along a circle: searched 29 times in 180 frames, as sound (area 0.91) and as fast (99 px/s) as searching every frame |
| threaded == serial | see "Determinism" |

### The bench

30 × 150, 30 × 100 and 60 × 60; blob, uniform, 12 beads, designed cores, own contacts and
adhesion on, 4 threads; three runs each, median / p95 ms of physics per frame. "M2" is
`--m2` (exposure, automatic cores, compliant contacts, core anchors), "+ drag" adds
`--water-drag=on` (with the bench's linear damping still on: drag slows the creatures, so
they collide less, which is why it can come out cheaper), "+ kept" adds `--reuse=on
--skin=4`.

| | milestone 1 | M2 | M2 + drag | M2 + drag + kept |
|---|---|---|---|---|
| 30 × 150 | 7.03-7.38 / 8.40-9.22 | 8.08-8.32 / 9.73-10.76 | 7.69-8.23 / 9.15-10.45 | 7.63-7.96 / 8.95-9.96 |
| 30 × 100 | 5.89-6.26 / 7.18-7.50 | 6.62-6.69 / 7.71-8.22 | 6.18-6.89 / 7.17-8.32 | 5.91-6.33 / 7.22-7.94 |
| 60 × 60 | 7.52-7.67 / 8.97-9.94 | 7.76-7.95 / 9.07-10.27 | 7.38-7.75 / 9.45-9.62 | 6.38-6.96 / 7.80-8.65 |

Where it goes at 30 × 150 with M2 (wall unless CPU): own candidates 2.2-2.35, the substeps'
parallel region 3.4-3.5 (rings 4.5 CPU, sticks 4.7-4.8 CPU against milestone 1's 3.5-3.7:
the anchors on cores' rims, compliant contacts don't cost), the settle pass with the exposure
pass inside it 0.94-0.97 (milestone 1: 0.13-0.14; exposure 1.9-2.1 ms CPU, 8 passes a frame of
30 creatures, about 0.25 ms each with its switches), velocities 0.38, capture 0.30, contacts
between creatures 0.17, drag 0.18 CPU. Health over the measured frames: none inside out, ring
area 0.67-1.11 (milestone 1: 0.64-1.07), beads up to 4.4-6.0 px into cores (1.3-2.1), 213-269
rings became cores and 156-228 cores rings in 360 frames of colliding blobs, 25-34 beads
exposed for want of a loop of about 14 000 (30 × 100 without drag: 224).

Kept candidates save 0.4-0.5 ms of own candidates at 30 × 150 (1.84-1.98 against 2.19-2.28)
and 1 ms at 60 × 60: the bench's creatures collide and deform all the time and 15-20 of 30 are
searched again in the median frame; a calm or swimming creature keeps its list.

**What is left under the 10 ms gate**: with everything (M2, drag, kept candidates) the medians
are 7.6-8.0 at 30 × 150 and the p95s 9.0-10.0: about 2 ms of median and nothing of p95 for
surface tension. The cheapest savings, measured or estimated:

1. Kept candidates on (measured above: −0.4 to −1 ms); a larger skin keeps more (skin 6:
   13 of 30 searched again a frame, own candidates 1.6 ms) at the cost of longer lists.
2. Searching a creature's candidates again only around the cells that moved, not the whole
   creature (not built; the bench's rebuilds are mostly one cell's wobble).
3. The exposure pass on fewer occasions: `exposure_hot` 0 measured 3 passes a frame instead
   of 5-8 (−0.1 to −0.4 ms; a core whose neighbour drifts off slowly then waits up to
   `exposure_every` frames to come back as a ring).
4. Core anchors off (estimated from the sticks' CPU, 4.7 against 3.6 ms: −0.3 ms wall; walls
   onto cores sticky again).
5. The spike's knobs: 10 beads for the smallest cell (−18 %), 4 substeps (−22 %).

## Departures from the brief and the plan

- **Enclosed beads still collide with other creatures** (`skip_enclosed` = `SKIP_NONE` by
  default): skipping them is unsound (measured above). The plan's requirement 4 ("no
  collisions") does not hold for collisions; it holds for drag.
- **The softening is compliant contacts**, not a compliant radius: the radius was built and
  measured and does not help (above).
- **Core-to-core sticks stay gap only** (anchors only for beads on cores' rims).
- **Exposure is not recomputed on every contact change** but on partings, switches, resizes,
  joins and parts by hand and every 30 frames: joins only enclose, and single sticks made or
  broken along a wall do not change the outline.
- **No outward drag on cores**: a core gets no drag, even while exposed waiting to switch (at
  most `to_ring_time`, 0 by default).
- **Kept candidates** (the brief's optional saving) are built but off by default, so the
  milestone 1 numbers replay.

## Limits and defects

- A run whose successor is wrong leaves its beads exposed (`broken_runs`): 1-3 beads in a
  loose mixed cluster of 40, 25-34 of 14 000 in the bench, 224 in one bench (30 × 100 without
  drag, crushed collisions). Exposed is the safe side (more drag, never a missed contact). A
  tiny gap between three cells one of which is a core can send its run onto the outline.
- Cells switch often in a crowd (200-270 each way in 6 s of colliding blobs at 30 × 150):
  squeezed rings become cores and the cores ring again when released. Each switch is smooth
  and `switch_rest` stops a cell flickering, but a rest of 1 s is long when a creature is hit
  again at once.
- Compliant contacts let beads sink up to 4-6 px into a core in an impact (rigid: 1.3-2.1).
  The look (milestone 4) will show it unless it draws cores from their neighbours.
- A switch's twin divergence after 30 frames (1.7-2.7 px) is the core's disc settling
  differently from the ring it replaced; nothing jumps (0.07 px in the first frame).
- Pockets are found from contacts within the gap: a gap between mixed cells wider than 2.5 px
  that leads to the outside is outside (a channel a bead could not pass through still counts
  as open). Milestone 3's surface tension should close such channels.
- The drag is per frame (as the game's), not per substep; per-cell water only.

## Notes for milestone 3 (surface tension)

- The outside loop is the line the tension runs along: `Creature::loops` (kind `Outside`)
  lists its points in order, beads and cores' virtual beads, across junctions. A loop's
  points are rebuilt by every exposure pass; between passes the indices stay valid until a
  switch (which reruns the pass). Tension acts on beads; where the loop runs along a core,
  push the core (its virtual beads are not particles).
- Tension per exposed edge on its two beads, inward along the outline's curvature: the same
  edge loop the drag walks, weighted by exposure as the drag is.
- Hops between runs (the outline crossing a junction) need the tension too, or the junctions
  stay notched: apply it between a run's end and its successor's start.
- Surface tension will press rim cells together: more beads within the gap, more enclosed,
  more cores. Re-measure the switch counts and `broken_runs`.

## Notes for milestone 4 (the look)

- Rims belong on exposed edges: `creature_exposure(c)` per bead (the mesh's exposed weight
  already reads it once a pass has run), pockets are the drawn holes inside a creature,
  `cell_outward()` gives a rim's direction.
- Cores have a turn now (`cell_rotation()`), so their bubble field can turn with them and a
  switch keeps the field's place (the ring's best-fit rotation becomes the core's turn and
  back).
- A switch changes the mesh's topology (`creature_info()`'s version): the attributes must be
  rebuilt for that creature (rarely per creature, often in a crowd: see the switch counts).
