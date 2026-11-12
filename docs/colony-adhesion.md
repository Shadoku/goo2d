# Colony adhesion (milestone 1)

Milestone 1 of the colony plan (`fluid_physics_game/docs/colony-plan.md`): the cells of a
creature in a `GooColony` hold together because they stick where they touch, and can join
and part at run time. It replaces the spike's spawn-time bonds (`docs/colony-spike.md`),
which stay available for comparison. Built and measured on 2026-11-12, branch
`colony-spike`, on the same machine as the spike (4 cores).

The colony stays a second solver beside `GooKernel`; nothing in `GooKernel`, `GooWorld2D`
or `Goo2D` changed (the golden trace is still `7f26b075334263e1f447ee8104806252`).

## Where it is

| What | Where |
|---|---|
| The model, in Rust | `addons/goo2d/native/src/colony.rs`: `Adhesion` (settings), `Stick`, `Pair`, and on `Creature`: `capture()`, `solve_sticks()` / `solve_sliding()`, `after_step()`, `settle()`, `join_cells()`, `part_cells()`, `answer()`, `neighbours()`, `resize_cell()` |
| The API | `GooColony` in `native/src/lib.rs` (the adhesion block at its end) |
| A thin GDScript layer | `addons/goo2d/goo_colony_sim.gd`: `GooColonySim` |
| Tests | `tests/unit/test_goo_colony_adhesion.gd` (17 tests); `cargo test` in `native/` (rotation, threaded == serial with sticky and anchored walls, promotion) |
| Bench | `tools/colony_bench.gd --hold=adhesion` (`--capture=`, `--break=`, `--sticky`) |
| Pictures | `tools/colony_shot.gd` (a cluster at rest, pulled apart, two after a collision) |

## The model

### Cells, creatures, types

A cell belongs to one creature (its group) and has a type id, 0 to `MAX_TYPES - 1` (16),
set with `set_cell_type()`. Only cells of the same creature stick; cells of different
creatures only collide, as before.

### A stick

A stick holds one bead of a ring cell (end a) to the skin of another cell (end b): a place
`s` along another ring (edge `floor(s)`, `frac(s)` of the way along it), or a core's rim.
Touching cores stick to each other. Each stick is an XPBD constraint solved every substep,
after the ring constraints and before the creature's own contacts.

- **The gap.** The bead's distance to the nearest point of the edge at `s` (clamped to the
  edge, so past an end it is the distance to the end bead), minus the two bead radii, is
  held at zero, pulling and pushing. If the bead is on the inner side of the edge the gap
  is measured along the edge's normal, so the stick pushes it out. Compliance: 1 / (the
  softer cell's skin stiffness × `stick_scale`). This is a true distance constraint (its
  gradient is exact), which matters: the first version measured the gap along a normal
  blended from the neighbouring beads, a force that depends on beads it does not move,
  and that pumped energy into resting clusters (beads at 100 to 400 px/s after 10 s).
- **One side only.** A wall between two rings is held by one side's beads: the side with
  the smaller beads, or for equal beads the lower cell index (`sticks_onto()`). Held from
  both sides, a curved wall is over-constrained (both sides' beads cannot all be at zero
  gap from the other's polyline) and every stick of it carried a standing load of about
  ±1 000 (half the break force then), which broke walls at rest. One-sided, the loads at
  rest are about zero.
- **Rest gap follows the radii**, read each substep, so a resized cell's walls follow it.

### Capture

Once a frame (every `capture_every` frames, each creature on its own frames), before the
substeps, from the creature's contact candidates: the candidate search is widened by the
capture gap on capture frames, and the extra pairs go to separate lists that only capture
reads. Each free bead takes the nearest skin within `capture` of its outline, among the
two edges at the candidate bead (seen from outside: a bead on the inner side of an edge is
not captured), if the wall's side rule lets it stick there and the pair allows it (below).
A bead holds at most one stick as its end a. A bead near a core sticks to the core's rim;
two cores within the gap stick to each other.

### Anchored and sticky

The type table gives each pair of types a mode: `JOIN_ANCHORED` (the default), `JOIN_STICKY`
or `JOIN_NONE`.

- **Anchored**: besides the gap, the bead is held at a fixed offset along the tangent of
  its anchor's edge: C = (bead − anchor point) · tangent − offset, softer than the gap
  (compliance / `anchor_scale`). The offset is what the bead had when it stuck, so a fresh
  stick has no tension wherever on its edge the bead sat. The gradient includes the
  edge's turning (the normal part of bead − anchor over the edge length); without that
  term a held shear is a net torque, and the first anchored clusters spun up from rest.
  With it the constraint is rotation-invariant and conserves angular momentum. Each frame
  the anchor moves to where the bead is now (its nearest place) keeping the tension, and
  the tension decays by `creep` per second: walls adjust when a cell resizes or the
  creature bends for a while, but resist a quick shear. An anchored wall acts like
  friction: a lone cell pushed along a neighbour rolls round it (`test_sticky_walls_...`:
  its own ring turns 1.7 times the angle it goes round, a coin rolled round a coin turns
  2).
- **Sticky**: no anchor, and both ends slide: end a is a place along its own ring too, and
  each substep both ends move to the places on their rings facing each other (the closest
  points of the two polylines near them), whose gap is held at zero
  (`solve_sliding()`). The wall carries no force along itself: pushed alike, the same cell
  goes 3.3 rad round its neighbour instead of 0.5 and turns 0.35 of that (rolling would be
  2). With only the target end sliding the cell still rolled: its own bead was held.
- **Cores have no orientation yet**, so a bead on a core's rim and two cores hold the gap
  only, whatever the table says (sticky).

### Break

Each stick's pull (λ / h², a force in the cells' mass units × px/s²) is averaged over the
frame's substeps and smoothed over `load_time`; past `break_force` the stick breaks. After a
break the pair captures nothing for `break_rest`: the broken beads sit within the capture
gap still (the stretch at the break force is about 1.4 px at unit 0.5, under the 2.5 px
gap), and without the rest a wall was captured again in the next frame and never parted.
Masses do not scale with `GooTuning.unit` and accelerations do, so forces scale with it:
`GooColonySim` multiplies the unit-1 defaults by the unit.

### Filters

1. The type table (`set_join_mode(a, b, mode)`, symmetric), read inside the step.
2. What is known of the pair (`Creature::pairs`, a `BTreeMap` per creature, so iteration
   order is fixed): allowed, forced (joined by hand), refused (answered no, or parted by
   hand), or pending (asked). With the `ask` option a pair found for the first time is
   recorded as pending and reported in `asks`; it sticks only after `answer(c, a, b,
   allow)`. Script is never called from the step: `GooColonySim.step()` steps the colony,
   then calls `may_adhere()` for each ask on the main thread and answers, so the pair can
   join in the next step (the frame after it touched). Whatever is known of a pair is kept
   while its cells are near each other (centres within 1.1 × the sum of their radii plus
   twice the capture gap) and forgotten after, so a refused pair is asked again only after
   it came apart.

### Events

After the substeps each creature compares every known pair's "has sticks" with what it
last reported and queues `EVENT_JOINED` or `EVENT_PARTED` (cell a < cell b), in cell-pair
order. `take_events()` returns them creature after creature; `join_cells()` and
`part_cells()` queue theirs at once. A pair that joins and parts within one frame reports
nothing. A promotion or demotion drops the changed cell's sticks without reporting: if
the next frame captures it again nothing is reported, otherwise a parted event.

### By hand

`join_cells(c, a, b)` forces the pair (it sticks whatever the filters say, now and whenever
it touches while remembered) and sticks every free bead within `join_reach` of the other
cell's skin (all edges searched); `part_cells()` removes the pair's sticks and refuses it
while the cells stay near; `set_capture_paused(c, paused)` (c = −1: the whole colony) stops
capture, existing sticks keep holding and breaking; `cell_neighbours(c, cell)` is the
adjacency (the cells stuck to it now, sorted).

### The creature's own contacts

Left on (all of a creature's beads and cores collide with each other), except between a
bead and the beads of the ring it is stuck to: that gap is the stick's. Measured with them
off at 30 × 150, adhesion is unsound (138 rings inside out, 22 px overlaps): a one-sided
wall leaves the other side's beads free to pass through. With bonds (two-sided, set at
spawn) they could be off; with adhesion they cannot, and their cost (about 2.5 ms at 4
threads in the spike) stays in the budget.

### Resize

`resize_cell(c, cell, radius)` is the smallest in-place resize: the ring's rest outline,
edge and bending rest lengths, bead radius and target area are scaled at once (a core's
radius set); bead count, masses and springs are kept. The ring's pressure and shape
matching move its beads over the next frames; sticks' rest gaps follow the bead radius.
Growing a cell surrounded by six from 14 to 19.6 px over 2 s keeps all six walls (none
parted, gap at most 1.7 px), and the anchors' tension relaxes from 2.1 px when it stops to
0.9 px 3 s later.

### Determinism

Everything above runs on the creature's own data inside the per-creature passes (capture,
the substep's stick solve, the break / creep / settle pass), in a fixed order; asks and
events are concatenated in creature order after the step. The threaded step stays
bit-identical to the serial one: `cargo test threaded_adhesion_is_bit_identical_to_serial`
(6 clusters with anchored and sticky walls thrown at each other and pulled, 150 frames,
8 166 sticks made, 1 245 broken, every particle, load and anchor compared by bits) and
`test_threaded_step_equals_serial_with_adhesion` (240 frames, 474 made, 199 broken, the
event streams equal).

### Room left for later milestones

`Cell` carries `exposure`, `outward` and `contacts` (data only: nothing reads or writes
them) and `push` (a per-cell acceleration, `push_cell()`: built, because the tests need to
pull single cells). `Stick::load` is per stick, so per-cell contact reports can sum it.

## The API

`GooColony` (Rust), adhesion part:

| Call | What |
|---|---|
| `set_options({...})` | `adhesion` (bool), `capture`, `capture_every`, `join_reach`, `stick_scale`, `anchor_scale`, `creep`, `break_force`, `load_time`, `break_rest`, `ask` (bool), `capture_paused` (bool) |
| `set_join_mode(a, b, mode)`, `join_mode(a, b)` | the type table; `JOIN_NONE`, `JOIN_ANCHORED`, `JOIN_STICKY` |
| `set_cell_type(c, cell, type)`, `cell_type()`, `cell_count(c)` | types 0..`MAX_TYPES` |
| `push_cell(c, cell, acceleration)` | a per-cell push |
| `resize_cell(c, cell, radius)`, `cell_radius()`, `cell_points()` | |
| `set_capture_paused(c, paused)`, `is_capture_paused(c)` | c = −1: the colony |
| `join_cells(c, a, b)`, `part_cells(c, a, b)` | sticks made / removed; event queued at once |
| `answer(c, a, b, allow)` | for an ask |
| `cell_neighbours(c, cell)` | PackedInt32Array, sorted |
| `take_events()` | PackedInt64Array, 4 per event: kind, creature, a, b |
| `take_asks()` | PackedInt64Array, 3 per ask: creature, a, b |
| `creature_sticks(c)` | `STICK_FLOATS` (12) each: a, a is core, b, b is core, s, cell a, cell b, mode, load, gap now, anchor, tension now |
| `stats()` | adds `sticks`, `made`, `broken`, `sticks_cpu_us`, `capture_us`, `settle_us` |
| `health()` | adds `stick_stretch`, `stick_squeeze` (px), `stick_load`, `sticks`, `not_finite` |

`GooColonySim` (GDScript, `RefCounted`): `colony` (the `GooColony`), `step(delta)`,
signals `cells_joined(creature, a, b)` and `cells_parted(creature, a, b)`, `may_adhere(c, a,
b)` to override (or `adhere_filter`, a Callable), `asks_script` (turns `ask` on),
`join_cells()` / `part_cells()` (emit at once), `add_creature([{position, radius, type,
core, color}])`, the static `cell_floats(at, radius, core, color, linear_damp)`; constants
`CAPTURE`, `JOIN_REACH`, `BREAK_FORCE` (unit 1).

## The knobs

| Knob | Value (unit 1; × unit in `GooColonySim`) | Why |
|---|---|---|
| `capture` | 5 px (2.5 at unit 0.5) | Two touching round cells get a wall about three beads wide. At 3 px (the spike's 1.5 at 0.5) it was one bead wide: a 14-cell mixed cluster tore under a 600 px/s² pull. At 8 px walls zip flatter, but the cells' elasticity then preloads the sticks with most of the break force (the middle of a flat wall pushes, its ends pull: ±5 400 at rest at unit 0.5). |
| `capture_every` | 2 frames | Capture and its widened candidate search cost 0.55 ms of wall time a frame at 30 × 150 when run every frame, 0.35 every other. A join comes at most a frame later. |
| `join_reach` | 8 px | Further than capture, so a pair a little apart can be joined by hand. |
| `stick_scale` | 1 | The bonds' stiffness (the softer cell's skin stiffness): a stick stretches about 0.17 px per 1 000 of load at unit 0.5. |
| `anchor_scale` | 0.3 | The anchor softer than the gap, so creep and sliding stay smooth. |
| `creep` | 1 /s | Walls settle within about a second after a resize or a held bend. |
| `break_force` | 24 000 (12 000 at 0.5) | Three times the standing loads seen at rest with the chosen capture (up to about 2 600 at 0.5) and above the pulls a creature makes swimming (p99 of the loads in the bench, creatures pushed at 250 px/s² and colliding: about 7 000). A 14 px cell pulled off its neighbour at 20 000 px/s² parts within 10 frames; a 14-cell cluster holds a 600 px/s² pull (at unit 0.5) between its thirds. |
| `load_time` | 0.1 s | A load must last to break a stick (single-frame spikes in impacts do not). |
| `break_rest` | 0.5 s | Long enough for a broken wall's cells to move apart. |
| table | anchored for every pair | Decision 1 of the plan. |

## Measured

### The tests (`tests/unit/test_goo_colony_adhesion.gd`, unit 0.5 unless named)

| Test | Result |
|---|---|
| capture and events | three cells in a row joined in the first step, events `(0,1)`, `(1,2)` once each; neighbours `[0, 2]` |
| six neighbours | the middle of a hexagonal cluster of 19 is stuck to all 6; every cell has 3 or more (102 sticks) |
| holds under pulls | 14 mixed cells (14 to 26 px), the left and right thirds pulled apart at 600 px/s² (1 200 at unit 1) for 1 s each way: span up to 1.12 of rest, 1.02 after letting go, no wall parted, identical at both units |
| thrown into each other | two clusters of 12 at 600 px/s each (1 200 at unit 1): area 0.69..1.07, none inside out, both one piece |
| break | a 800 px/s² pull each way holds (load 1 500); 20 000 px/s² parts them in 9 frames; events joined then parted, once each |
| filters | the type table refuses types 1 and 2; `may_adhere()` asked once per pair in order, the refused pair never joins; paused capture joins nothing until resumed |
| by hand | join across 3.5 px; part, rejoin a refused pair, part again; a parted pair pressed together for 0.5 s does not join |
| sticky / anchored | see "Anchored and sticky" above |
| resize | see "Resize" above |
| threaded == serial | see "Determinism" |
| a seeded random game | 6 mixed clusters thrown about with random pushes and cell pulls for 5 s: no NaN, none inside out, area 0.77..1.19; 143 joins, 64 parts |

### The bench

30 creatures × 150 cells and 30 × 100, 60 × 60; blob, uniform, 12 beads, cores on, the
creature's own contacts on, 4 threads; three runs each, median / p95 ms of physics per
frame (each configuration replays the same frames; the spread is this machine's noise):

| | bonds (the spike) | adhesion | adhesion's cost |
|---|---|---|---|
| 30 × 150 | 6.53-6.60 / 7.56-8.18 | 7.28-8.08 / 8.97-9.33 | +0.7 to 1.5 ms (+11 to 23 %) |
| 30 × 100 | 5.53-5.74 / 6.73-6.97 | 6.63-7.06 / 7.94-9.16 | +1.0 to 1.3 ms |
| 60 × 60 | 6.93-7.30 / 8.52-9.16 | 7.83-8.12 / 9.22-10.44 | +0.8 to 1.0 ms |

Where it goes at 30 × 150: the sticks' solve 3.4-3.7 ms of CPU summed over threads against
the bonds' 2.5 (16 734 sticks against 16 710 bonds: the anchor is a second constraint on
each), capture 0.32-0.37 ms of wall time, the break / creep / settle pass 0.14-0.16 ms,
the widened candidate search on capture frames about 0.1 ms. 1 to 3 sticks break in the
median frame (collisions), 20 at p95. The spike estimated +0.8 to 1.5 ms over the "own
contacts on" column: as measured. The gate later is 10 ms: the medians sit 2 ms under it
before surface tension and exposure; 60 × 60's p95 reached it in one run of three.

The bench's health over the measured frames, adhesion at 30 × 150: none inside out (bonds:
1), ring area 0.60..1.08, sticks stretched up to 7.8 px and squeezed 12.9 px in impacts,
the fastest bead at the 1 500 px/s cap (the bonds' run too: the impacts between cored
creatures are violent, the spike's risk 1).

### Pictures

`tools/colony_shot.gd` (not committed): a mixed cluster of 30 at rest shows walls of two to
three sticks between round, barely flattened cells and the packing's pockets; pulled apart
at 2 500 px/s² it tears between the pulled thirds, the walls under load zipped longer and
the cells stretched, sticks near the break drawn red; two clusters of 20 after an impact
at about 600 px/s are compacted: the impact pressed cells together, more beads came within
the gap, and the walls stayed zipped flat (polygonal cells, small triangular pockets).

## Limits and defects found

- **Walls between round cells are narrow** (two to three sticks): pressure keeps cells
  round and nothing presses them together. A wall loaded from one side peels from its end
  stick. Surface tension (milestone 3) is what should widen them.
- **Zipping is one-way**: cells pressed together (an impact) zip more beads and stay
  zipped; nothing unzips a wall but the break force. Clusters become more compact after
  every impact. Milestone 3 should decide what sets a wall's width at rest.
- **Break and recapture churn in crowds**: in the 30 × 150 bench 1 to 3 sticks break per
  median frame and are captured again after the rest; walls in collisions tear and heal.
- **Own contacts are required** with one-sided walls (see above), so their 2.5 ms stays in
  the budget; reusing their candidates across frames (the spike's suggestion) is still
  open.
- **Cores have no orientation**, so walls with cores are sticky whatever the table says.
- **Anchored is friction, not glue against rolling**: a lone round cell with a single
  wall rolls along its neighbour; rolling is resisted only where a cell has several walls.
- **Residual angular momentum**: a resting anchored cluster with no damping keeps the
  0.003 rad/s capture left it, and drifts about as much as the bonds do (Gauss-Seidel order
  under standing stress). Two defects were found and fixed on the way: the blended normal
  (energy) and the tangential constraint's missing gradient term (torque).
- **Resize is the smallest possible**: instant rest change, no easing or rate limit,
  masses and springs kept. Enough to show walls hold and anchors creep; not the
  `Goo2D.resize()` equivalent.
- **The ask hook costs a frame**: a pair joins the frame after it is answered.
- **A promotion drops the cell's sticks**; they are captured again in the next frame
  (cargo test: no event), but a promoted ring that does not touch within the gap parts.
- **Not built**: walls for the colony (not required), exposure, outward direction, contact
  reports (room only).

## For milestone 2

(Built: `docs/colony-exposure.md` says what came of each note.)

- Adjacency is `Creature::pairs` (pairs with sticks); `cell_neighbours()` reads it. A
  bead's stuck state is `stuck` (0, the ring it is stuck to + 1, or `STUCK_CORE`), its
  stick count for the drawing `bonded`. One-sided walls mean the other side's beads are
  not stuck though enclosed: exposure must treat a bead within the gap of a neighbour's
  skin (or a neighbour's stuck bead on it) as enclosed, not only stuck beads.
- Promotion and demotion work with adhesion (indices remapped, sticks of the changed cell
  dropped and captured again), but a promoted ring's beads must be within the capture gap
  of its neighbours or it parts: fit them to the pocket as the spike does.
- Cores need an orientation before their walls can be anchored.
- Drag on exposed edges will also load walls; the break force was chosen against pulls of
  600 px/s² between thirds of a 14-cell cluster.
