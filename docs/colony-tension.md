# Colony surface tension (milestone 3)

Milestone 3 of the colony plan (`fluid_physics_game/docs/colony-plan.md`): a creature in a
`GooColony` pulls itself inward a little, as a cluster of bubbles does, so it rounds off and
its cells are drawn into each other until their pressure balances it; then the performance
gate re-run with everything on. Built and measured on 2026-11-12, branch `colony-spike`, on
the same 4-core machine as milestones 0 to 2 (shared with other jobs this time: see "The
gate re-run").

The colony stays a second solver beside `GooKernel`; nothing in `GooKernel`, `GooWorld2D` or
`Goo2D` changed (the golden trace is still `7f26b075334263e1f447ee8104806252`). The tension
is off by default (strength 0, and then none of it runs).

## Where it is

| What | Where |
|---|---|
| The tension | `addons/goo2d/native/src/colony/tension.rs` (`Tension`, `TEdge`, `build_tension_edges()`, `apply_tension()`), called at the start of each substep in `Creature::substep_own()` (`colony.rs`) |
| What it needed of the exposure pass | `colony/exposure.rs`: successors given one to one, open paths joined, degenerate loops dropped, `Creature::surface` per bead |
| The API | `GooColony` in `native/src/lib.rs`: options `tension`, `tension_pockets`, `tension_min_edge`, `tension_hop`, `tension_hop_max`; `set_type_tension()`, `set_creature_tension()`, `creature_tension_forces()`, `creature_tension_points()`; `stats()` `tension_cpu_us`, `patched_runs` |
| Presets | `GooColonySim.TENSION`, `tension_options()`, `everything_options()` (`addons/goo2d/goo_colony_sim.gd`) |
| Tests | `tests/unit/test_goo_colony_tension.gd` (11 tests); `cargo test` in `native/` (18, 2 of them new: no net force or torque through cores; threaded == serial and strength 0 unchanged) |
| Bench | `tools/colony_bench.gd --tension=T`, `--everything` |
| Pictures | `tools/colony_shot.gd --scene=ragged|wall|worm [--tension=T]` |

## The model

### What pulls

The surface is where the exposure pass says the cells face water:

- **every skin edge of a ring whose two beads both face the water**: the outside, a crevice
  between cells, and (with `tension_pockets` above 0) a pocket's skin;
- **the hops of the outline's loops between cells**: a run's last bead to the first bead of
  the run that continues the outline on the cell it meets (a junction between two rings, or
  a ring and an exposed core's virtual bead). A hop pulls in full up to `hop` (2.5) × its two
  beads' radii summed and fades linearly to nothing at `hop_max` (3.5) × them. Junction hops
  measured 15.7-19.7 px between two 14 px cells at unit 0.5 (beads of 4.4 px: 1.8-2.2 × the
  radii); hops across a crevice or a bay were 20-54 px. Tension across those would be a
  rubber band drawing the far side of a bay in from a distance, which surface tension is not.

Every such edge pulls its two ends toward each other with its tension T_e: +T_e u on the
first, −T_e u on the second, u the unit vector between them. On a point of a smooth stretch
that sums to T (u_next − u_prev): the tension times the outline's turn there, inward on a
convex stretch and out of a notch between two cells, which zips the wall wider.

T_e = strength × the creature's factor × the mean of its ends' surface factors (1 outside,
`pockets` facing a pocket) × the mean of its ends' cells' type factors × min(1, L /
`min_edge`) × the hop's fade.

### No net force or torque, and why there is no per-point clamp

The forces come in equal and opposite pairs along the line joining their points, so they
add no net force and no torque to a free creature whatever each edge's T_e is. Every
adjustment (a type's factor, a hop's fade, a short edge's) is therefore made per edge. A
per-point clamp (the brief's "clamp at junction kinks") would break the pairs, so there is
none; it is not needed either: the force on a point is at most 2 T by construction (the sum
of two unit vectors), whatever the kink, and the short-edge factor keeps an edge's
transverse stiffness, T / L, below T / `min_edge` (0.5 px), so two points that meet do not
pull along a direction that flips every substep.

### When and how it acts

Every substep, from the positions the substep starts at, as an impulse (force × the substep)
on the velocities before the prediction. Once a frame would have been the cheap choice, but
it is explicit: T dt² / (m min_edge) at a frame's step is about 2 for the default on the
smallest beads (unstable), at a substep's about 0.05.

### Cores

An edge between two points of one core is left out (forces inside a rigid body cancel). A
hop's end on a core's virtual bead pushes the core: the force on its centre, and its moment
about the centre on the core's turn (cores turn since milestone 2), so angular momentum,
orbital plus the cores' spin, is conserved too (`cargo test
tension_adds_no_net_force_or_torque_even_through_cores`: momentum change 0, angular 8e-9 of
the impulse × reach, with 5 loop points on 2 cores).

### Pockets

A pocket's skin pulls only with `tension_pockets` (0 by default, in the preset too): pockets
keep their size. With 1 the skin round a pocket shrinks it (a closed ring of 14 cells: 4 604
px² of pocket left with 0, 3 653 with 1, against 6 885 without tension). It never blows a
pocket up: tension only ever shortens. A creature designed with a hole keeps it more with 0.

### Per creature, per type

`set_creature_tension(c, factor)` (1 when added) and `set_type_tension(type, factor)` (1
each; an edge takes the mean of its ends' cells'): 0 slack, above 1 taut. A creature whose
factor is 0, or whose cells are all of a slack type, steps bit for bit as without tension.

### What the exposure pass had to change

The tension pulls along what the exposure pass finds, and on a ragged cluster it found
almost nothing: of 134 exposed beads 6 lay on a loop. Each run took the best successor it
was offered, two runs often took the same one, and every run behind such a fork was left off
any loop. Now (all of it inside `compute_exposure()`, run whether or not the tension is on):

- **successors one to one**: every run's offers (the same tiers as before) are given out
  best first (tier, then distance, then index), a run already continued into not offered
  again. Tier 0 offers come first whatever else is offered, so they are given out before the
  wider search, which is made only for the runs they leave without a successor (the pass
  costs 141-144 µs on the 169-cell hex creature against 125-138 before);
- **open paths joined**: what is left is paths from a run nothing continues into to a run
  with no successor within reach; each path's end is joined to the nearest free path start
  (its own included). Their beads are counted in `stats()["patched_runs"]`; a loop with such
  a join is never a pocket (exposed is the safe side);
- **degenerate loops dropped**: fewer than 3 points or less area than a bead's radius² (a run
  closed on itself, two runs each other's successor): their beads stay exposed, on no loop.

The ragged cluster now has 131 points on its loops for 117 exposed beads. Milestone 2's
tests pass unchanged; its printed numbers move a little (the loose mixed clusters of 40:
0 beads on no loop where there were 1-3).

## The API

Options (`GooColony.set_options()`):

| Option | Default | What |
|---|---|---|
| `tension` | 0 (off) | the force each surface edge pulls with (mass × px/s²; scales with `GooTuning.unit` as forces do) |
| `tension_pockets` | 0 | × it on skin facing a pocket |
| `tension_min_edge` | 0.5 | px: a shorter edge pulls in proportion |
| `tension_hop`, `tension_hop_max` | 2.5, 3.5 | × a hop's two bead radii: full up to, nothing from |

Calls: `set_type_tension(type, factor)`, `type_tension(type)`, `set_creature_tension(c,
factor)`, `creature_tension(c)`, `creature_tension_forces(c)` and `creature_tension_points(c)`
(the last substep's: two per edge, equal and opposite, and where their ends were).
`stats()` adds `tension_cpu_us` (CPU, summed over creatures and substeps) and `patched_runs`.
The tension runs the exposure pass even when `exposure` is off.

`GooColonySim`: `TENSION` = 1500 (at unit 1); `tension_options(strength = TENSION)` = {
`tension`: strength × unit, `tension_pockets`: 0 }; `everything_options(strength)` =
`EXPOSURE_OPTIONS` + `DRAG_OPTIONS` + `tension_options()` + kept candidates (`reuse_pairs`,
`pair_skin` 8 px at unit 1) + `exposure_hot` 0: what the fluid game will use.

### Why 1500

The strength is a force, so it scales with the unit (`tension_options()` multiplies): the
same strength at unit 0.5 and 1 gives the same picture (measured: two cells' wall, the file
of 12, to three digits). Two touching cells of the smallest size, after 5 s:

| strength (unit 1) | 0 | 600 | 800 | 1000 | 1200-1600 | 2000-3000 |
|---|---|---|---|---|---|---|
| sticks in the wall | 3 | 3 | 3 | 4 | 4 | 5 |
| centres apart, of a diameter | 0.924 | 0.896 | 0.886 | 0.811 | 0.803-0.808 | 0.713 |
| a single file of 12, end to end | 0.91 | 0.77 | 0.73 | 0.70 | 0.68 | 0.66-0.68 |
| smallest ring area of target | 0.99 | 0.93 | 0.92 | 0.91 | 0.91 | 0.89-0.90 |

The wall widens in steps of a bead. 1500 sits in the middle of the 4-stick plateau, so a
small change of numbers does not flip it; 2000 and up give 5 sticks and squeeze the cells a
little more for little more rounding (the ragged cluster: 1.58 at 1500 and at 3000).

## Measured

### The tests (`tests/unit/test_goo_colony_tension.gd`, unit 0.5 unless said)

| Test | Result |
|---|---|
| strength 0, a creature factor 0, a slack type | a ragged creature of 24 thrown, pushed and dragged for 2 s: the colony told nothing about the tension, told strength 0, with the tension on but this creature's factor 0, and with all its cells of a type of factor 0: the same 244 particles bit for bit; with the tension on they differ. (`cargo test`: 6 thrown hex clusters with everything on, strength 0 against a colony whose options never mention it, bit for bit.) |
| no net force or torque | a ragged cluster of 30 free for 4 s at twice the default: each substep's 132 forces sum to 0 (to the last bit) and their torque to 7e-9 of their sizes × the reach; the creature's mean velocity at most 0.052 px/s (0.183 without tension: the start's settling, not the tension) |
| a ragged cluster rounds off | 30 cells placed as branches: its outline's perimeter² over 4π its area (1 a disc) after 1 / 3 / 6 s: without tension 7.49 / 4.22 / 4.22; at the default 3.26 / 1.61 / 1.58, 68 beads exposed of 117 without, 11 cores of 4; at twice it 2.86 / 1.65 / 1.58. It stays (1.61 to 1.58 from 3 to 6 s). Twice the strength rounds it no more: anchored walls do not let cells slide past each other, so what is left is the shape the walls allow (pictures: `colony_shot --scene=ragged`). Cells 0.91-0.99 of their area, none inside out |
| two cells' wall | two cells of the smallest size (14 px at unit 0.5, 28 at 1) and one beside a 1.6 times larger one, 21 s: without tension 3 sticks, centres 0.920 (equal) / 0.960 (unequal) of r1 + r2 apart; at the default 4 sticks, 0.798 / 0.839, cells 0.97-0.99 of their area. The wall creeps as the anchors relax and slows: equal cells 0.032 px in 3-6 s, 0.017 px in 18-21 s; unequal 0.116 then 0.080 (without tension 0.013 then 0.007). Internal motion (rigid motion taken out) at most 0.003-0.007 (Σ v²/2, unit masses): no oscillation. The same numbers at unit 1 (lengths doubled) |
| at rest | a hex cluster of 37 (19 cores) from 4 to 16 s: kinetic energy median 53.4 without tension, 37.8 with, 15.0 with drag, 11.7 with drag and tension (Σ v²/2, unit masses, 444 particles: 0.2-0.5 px/s); frames above 500: 6, 7, 6, 9. Those are a few beads kicked to 20-30 px/s for a frame or a few, without tension as well (see "Limits") |
| a long worm | after 6 s, end to end over its length as placed: a worm 3 cells wide and 24 long 0.99 without, 0.98 at the default, 0.98 / 0.97 / 0.94 / 0.88 at 2 / 4 / 8 / 16 times; a single file of 20 0.87 without, 0.70 at the default (0.72 along its cells: it shortens, it hardly bends), 0.67 / 0.63 / 0.62 / 0.52 at 2 / 4 / 8 / 16 times |
| after an impact | two hex clusters of 37 thrown into each other at 300 px/s each, 4 s later: 1.78 sticks per wall without tension, 1.82 with; the rings' smallest area at rest 0.88 of their rest polygon without, 0.81 with (mean 0.94, 0.92); the worst during the impact 0.63 / 0.64 of target; none inside out |
| pockets | a closed ring of 14 cells round a pocket (7 517 px² as placed), 6 s: 6 885 px² without tension, 4 604 at the default (pockets pulling 0), 3 653 with `tension_pockets` 1; the ring across its middle 57.3, 51.0, 48.5 px (62.9 placed) |
| a seeded random game | 6 ragged creatures of 22 with everything on (`everything_options()`), thrown about for 5 s: fastest 1 105 px/s, area 0.73..1.10 of target, none inside out or not finite, 80 switches, at most 255 beads on guessed loops in a frame |
| threaded == serial | the same with 4 threads: the same 228 events in order, the same particles, velocities and tension forces bit for bit; `cargo test`: 6 hex clusters with everything on and two type and creature factors, positions, velocities, turns, tension forces and exposure bit for bit |

### What it costs a designed shape

The brief asked whether a long worm balls up. It does not, at any strength tried (up to 16
times the default): anchored walls hold the cells' order, and nothing lets them slide past
each other into a ball. A worm three cells wide keeps 0.98 of its length at the default and
0.88 at 16 times it.

What the tension costs a designed shape is in its **thin parts**: every wall between two
cells zips about one bead wider (3 sticks to 4 between the smallest cells) and their centres
close from 0.92 to 0.80 of a diameter. So:

- a single file of cells shortens to 0.70 of its length at the default (0.87 without
  tension: adhesion alone shortens it too), 0.62 at 8 times;
- a closed ring of cells round a hole shrinks: 14 cells, 51 px across instead of 57, its
  pocket two thirds of its size without tension (with pockets pulling, half);
- anything three or more cells thick keeps its shape within 2 %.

A designer who wants a thin part kept gives its cells a slack type (`set_type_tension(type,
0)`: the edges at those cells pull at the mean of their ends' factors), or lowers the
creature's factor. The default is a compromise: the lowest plateau where a wall between two
round cells widens at all (below 1000 it does not).

## The gate re-run

The gate: 30 creatures × 150 cells under 10 ms per physics frame at 4 threads (blob,
uniform cells, 12 beads, 6 substeps, designed cores, own contacts and adhesion on, as
milestones 1 and 2 measured). `tools/colony_bench.gd --hold=adhesion --threads=4`, 300 frames
after 60, median / p95 ms of physics. The machine was shared with other agents' builds this
time: each run waited until the machine was quiet (load under 1.5, other processes under
40 % of a core), and a run another job broke into anyway (median 9-14 ms, p95 12-22, one in
seven) is left out of the tables and said so.

"M2 + drag + kept" is milestone 2's best (`--m2 --water-drag=on --reuse=on --skin=4`).
"Everything" is `--everything`, `GooColonySim.everything_options()`: that plus the tension at
1500 and `exposure_hot` 0.

| | M2 + drag + kept | everything, exposure_hot 6 | **everything** (preset) | p95 under 10 ms? |
|---|---|---|---|---|
| 30 × 150 | 7.14-7.79 / 8.37-10.01; with exposure_hot 0 7.42-7.80 / 9.63-10.18 | 7.63, 8.40 / 9.93, 12.18 | **7.59-7.91 / 9.16-9.28** in a first batch of three, **7.73-8.48 / 9.69-12.58** in a second | in 4 runs of 6; not reliably |
| 30 × 100 | 5.86-6.49 / 7.75-8.81 | | **5.80-6.54 / 7.15-9.04** (and one run broken into) | yes |
| 60 × 60 | 6.44-6.90 / 7.92-8.70 | | **6.70-7.04 / 8.14-9.44** | yes, by 0.6 ms at worst |

Soundness, worst over the measured frames: none inside out in any of these; ring area
0.70..1.10 of target at 30 × 150 with everything (0.68..1.06 for M2 + drag + kept), 0.71..1.07
at 30 × 100, 0.74..1.01 at 60 × 60; beads up to 4.6-5.0 px into cores (milestone 2:
4.4-6.0). Switches in 360 frames at 30 × 150: 226 rings to cores and 137 back with everything
(185 and 119 without the tension: it presses rim cells together, so more become cores).

Where the time goes at 30 × 150 with everything (wall unless CPU, medians): the substeps'
parallel region 3.7 ms (rings, sticks, own contacts, and the tension, 0.8 ms CPU summed:
about 0.2 ms of wall), the creature's own candidates 1.8-1.9 (searched again for 18 of 30
creatures in the median frame), the settle pass with the exposure pass inside it 0.6 (the
pass 0.7 ms CPU, 3 passes a frame), capture 0.45, velocities 0.3, forces (drag included)
0.25, contacts between creatures 0.14.

The savings, measured (30 × 150, everything, two or three runs each):

| | median / p95 | sound? | taken |
|---|---|---|---|
| kept candidates off (`--reuse=off`) | 8.64-8.93 / 10.69-11.91 | yes | kept on: −1 ms median, −1.5 to −2.5 ms p95; deterministic and sound in the tests (the random game, threaded == serial, the bench's health), so on in the preset |
| `exposure_hot` 6 instead of 0 | 7.63-8.40 / 9.93-12.18 | yes | 0 in the preset: 3 passes a frame instead of 6, settle 0.60 against 0.80 ms; a core whose neighbour drifts off slowly comes back as a ring up to `exposure_every` (0.5 s) later |
| `pair_skin` 6 instead of 4 (unit 0.5) | 7.35 / 9.63 (and one run broken into) | yes | no: 11 creatures searched again a frame instead of 18, but the longer lists cost as much |
| 10 beads for the smallest cell (`--beads=10`) | 6.37-6.67 / 7.96-8.26 | yes: area 0.74..1.06, none inside out | an option, not a default: −1.1 ms median, −1 ms p95, a coarser ring |
| 4 substeps (`--substeps=4`) | 6.27-7.00 / 8.32-10.90 | **no**: area 0.62..1.18 and a ring inside out | not taken |

**The honest answer**: with everything on (adhesion, exposure, automatic compliant anchored
cores, drag, tension, kept candidates) the full preset costs 7.6-8.5 ms median at 30 × 150 and
9.2-12.6 ms at p95 over six runs: the median is under the gate with 1.5-2.4 ms to spare, the
p95 was under 10 ms in four runs of six (9.2-9.7) and over it in two (10.5, 12.6), on a
machine other jobs were using between and sometimes during runs. 30 × 100 and 60 × 60 stayed
under 10 ms at p95 in every clean run (at worst 9.0 and 9.4). The tension itself costs
about 0.2 ms of wall time (milestone 2's preset with `exposure_hot` 0 measures the same within
the noise: 7.4-7.8 / 9.6-10.2); what paid for it and for milestone 2's overrun is the kept
candidates (about −1 ms median, −1.5 to −2.5 ms p95) and half the exposure passes. If the p95
must hold with margin, 10 beads for the smallest cell is the next step (−1.1 ms median, −1 ms
p95, sound); 4 substeps is unsound.

## Departures from the brief

- **The surface is the exposed skin plus the outline's short hops, not the outside loop
  alone.** The brief (and milestone 2's notes) put the tension on the outside loop. On a
  ragged cluster the loops were mostly broken, and where they were whole their hops crossed
  crevices and bays, where a constant tension acts at a distance. Tension on every
  water-facing skin edge is local and needs no loop; the loops supply only the junction
  hops, and a hop longer than 3.5 bead radii pulls nothing.
- **The exposure pass changed** (successors one to one, open paths joined, degenerate loops
  dropped), whether or not the tension is on: milestone 2's outline was broken on ragged
  shapes. Its tests pass unchanged; its numbers moved a little.
- **No per-point clamp at junction kinks**: it would break the zero net force; the force on a
  point is bounded by 2 T anyway, and short edges pull in proportion (above).
- **Pockets do not pull by default** (`tension_pockets` 0): they keep their size, as a
  designed hole should.
- **The everything preset sets `exposure_hot` 0** as well as kept candidates.
- **"Strength 0 is exactly today's behaviour"** is proved against a run without the option
  (and with a creature or type factor 0); "today" includes the exposure pass's change, which
  is not part of the tension.
- **A long worm does not ball up** at any strength tried; the cost to designed shapes is
  thin parts shortening (above), not balling.
- Commits carry the session's attribution lines as this environment gave them.

## Limits and defects

- **Rounding stops at what the walls allow**: anchored walls keep the cells' order, so a ragged
  creature rounds to about 1.6 times a disc's P²/A and no further at any strength. Rounder
  would need walls that slide or rearrange (sticky walls, or breaking and remaking walls
  under tension), not built.
- **After an impact the tension does not unzip a compacted cluster**: walls are as narrow
  (1.8 sticks per wall) and the smallest rest area a little smaller (0.81 against 0.88). It
  pulls on the outside only; walls inside a creature see none of it.
- **Walls creep**: under the tension's standing load anchored walls keep relaxing for tens
  of seconds (two unequal cells: 0.12 px in 3-6 s, 0.08 in 18-21 s), slowing, not
  oscillating.
- **A resting creature spins slowly** (0.006-0.02 rad/s) after its walls form: the ring
  constraints, solved by position, do not conserve angular momentum exactly while walls zip
  (measured step by step in a pair zipping under tension: the rings' distance
  constraints add a steady torque, the tension exactly none). Conserved afterwards; the drag removes it.
- **Kicks at rest, not from the tension**: a resting cluster with cores kicks a few
  neighbouring beads to 20-30 px/s for a frame now and then (6 frames in 12 s without
  tension, 7 with; 6 and 9 in the drag), always at a stick whose place sits exactly on a
  vertex of the other ring (s = 4.000, 6.000). A guess at the cause (the place flipping
  between the two edges at a convex corner every substep) was tried and did not help; left
  for the adhesion's owner.
- Without cores a 37-cell hex cluster of rings never comes to rest (kinetic energy above 500
  in 619 of 720 frames, with or without the tension): milestone 1's anchored rings alone.
- Sticky walls (`JOIN_STICKY` for every pair) make thousands of sticks in a 30-cell cluster
  (5 960 at rest) where anchored ones make about 110: seen while measuring, not looked into.
- Loops closed by a guess (`patched_runs`): up to 255 beads a frame in the random game, 10-14
  in the bench's median frame. Their hops are ordinary hops (pulling only when short).
- The tension's edges are rebuilt from each exposure pass, which runs on partings, switches
  and every 30 frames: between passes a bead that became stuck still pulls along its old
  edges (harmless: still pairs), and a new junction pulls from the next pass on.

## Notes for milestone 4 (the look)

- The surface the tension pulls along is the drawn surface: `Creature::surface` (1 outside,
  2 pocket, 0 in contact) per bead, refreshed with every exposure pass; draw rims where it is
  non-zero. Hops are where the rim crosses from one cell to the next.
- Walls between cells are wider and flatter with tension (4 sticks instead of 3 between the
  smallest cells): the membrane line between two types is longer, and cells are a little
  squeezed (0.97 of their area in a pair, 0.91 at worst in a ragged cluster); draw from the
  beads, not from the rest radius.
- `patched_runs` > 0 means some of the outline is a guess: a rim drawn along a guessed hop
  may cut a corner.

## Notes for milestone 5 (the game side)

- `GooColonySim.everything_options()` is the preset; pass `TENSION` × a factor to change the
  strength for all, `set_creature_tension()` for one creature, `set_type_tension()` per cell
  type (a muscle or armour type taut, a soft one slack).
- Thin parts of a design (a single file of cells, a ring of cells round a hole) shorten under
  tension by about a fifth at the default; a designer should see the creature at its tension
  in the editor's "test in tank", or give those cells a slack type.
- A creature at rest spins slowly after its walls form (0.006-0.02 rad/s, conserved without
  drag): the water's drag takes it out.
