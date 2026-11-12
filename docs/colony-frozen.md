# The colony's frozen topology

The colony plan's creatures (docs/colony-spike.md, docs/colony-adhesion.md,
docs/colony-exposure.md, docs/colony-tension.md) re-decide their topology every frame:
which beads capture which skin, which walls break and settle (with their events), which
beads are exposed, what the outline is, which cells are cores. The user's priorities are
propulsion and semi-solid collisions; creatures need not be mutable at every moment, and
joining or leaving may happen only now and then or when the game asks. The frozen topology
makes that the model: a creature's topology changes only at its **retopologies**, and
between them it is a fixed structure of rings, cores and sticks that moves, bends, swims and
collides at full rate.

It was prototyped on the `explore-frozen` branch (95bc383..f529a39) and is built here on
milestone 3. Everything in it is an option, off by default; `GooColonySim.frozen_options()`
turns on what the fluid game should use.

## The model

### When the topology changes

A creature retopologises in a step when

- the game asked for it: `GooColonySim.request_retopology(creature)` (or
  `GooColony.request_retopology()`), and `add_cell()` / `remove_cell()` ask by themselves;
- its timer is due: every `retopo_every` frames (the preset: `RETOPO_EVERY`, 30, half a
  second), staggered by creature (creature `c` on frames where `frame + c` is a multiple of
  it), so 30 creatures spread one retopology a frame;
- it never has (its first step);
- `urgent_retopo` is on (off in the preset) and a stick passed the break force since the
  last frame (at most once in `URGENT_REST`, 10 frames).

A retopology frame runs, for that creature, everything the full model runs every frame:

1. at the **start** of the frame, the exposure pass and the switches it calls for (rings
   wholly enclosed long enough become cores, exposed cores rings), at most
   `retopo_switches` of them (the preset: 8; the others stay candidates for the next), then
   the pass once more if anything switched;
2. its own contact search with the capture gap, and capture (free beads within the gap of
   another cell's skin stick, filters and asks as in the full model);
3. after the substeps, the full break and settle pass: loads, breaks with the pair's rest,
   anchors creeping, joined and parted events.

The exposure pass moved to the start of the frame (it was at the end of every frame in the
full model): there it was one creature's long tail in the last parallel phase while the
others waited (0.87 ms of the frame's after phase at 30 swimming worms of 150 cells, 0.37
after the move), at the start it runs beside the other creatures' contact search, on the
same positions.

### Between retopologies

- **Nothing captures** and no pair joins: a joined event only ever comes out of a
  retopology.
- **A wall past the break force breaks at once** (`frozen_breaks`, on in the preset): the
  frame's break pass is the full model's (loads, the break, the pair's rest of
  `break_rest`, the parted event). The pair can join again at a retopology after its rest.
  The opened wall's beads are not exposed to the drag and the tension until the next
  retopology recomputes the outline. With `frozen_breaks` off a loaded stick holds until the
  next retopology (the tests show both); with `urgent_retopo` it also asks for one.
- **Muscles** (`set_cell_muscle()`, `set_cell_muscles()`) scale a cell's size every frame
  (rest shape, bead radii, target area, a core's radius) without asking for an exposure pass
  or a retopology. `resize_cell()` still asks for both (it is a growth).
- **The surface tension and the drag** act along the outline and exposure of the last
  retopology: the edges are bead indices, valid while the topology stands; a switch at a
  retopology reruns the pass, so they never point at a renumbered bead.
- **Anchors creep** (`frozen_creep`), switched sticks' gaps ease to zero, as every frame.
- **A creature's own contacts** come from lists kept per pair of cells (below).

### Own contacts kept per pair of cells

The explore branch kept one Verlet list per creature, valid while no particle moved more
than its skin against the creature's best-fit rigid motion. A creature that bends breaks
that at once: a swimming worm's tail moves tens of pixels against any rigid fit, so the list
was built again on 157 of 180 swimming frames (test_goo_colony_frozen.gd), at the cost of a
full search each time.

`frozen_self` 4 (`FROZEN_SELF_CELLS`, colony/cellpairs.rs, the preset's) keeps one list per
pair of neighbouring cells (and one per ring for its own non-adjacent beads), each judged
from its two cells alone:

- Each cell keeps a snapshot of its beads' places about its centre and every frame fits its
  beads as a similarity of it: `p_i = C + z q_i + e_i` (C the beads' mean, z a complex number,
  its turn and scale since the snapshot, e_i its deformation; a core is its centre).
- A list built at time t remembers both cells' C, z and largest |e|. For any of their
  particles i and j and any common turn w, distances being turn-invariant,
  `|p_i − p_j|(now) ≥ |p_i − p_j|(t) − B` with
  `B = |w̄ (C_a − C_b)(now) − (C_a − C_b)(t)| + |w̄ z_a(now) − z_a(t)| ρ_a + |w̄ z_b(now) − z_b(t)| ρ_b + |e|_a(now) + |e|_a(t) + |e|_b(now) + |e|_b(t)`
  (ρ the cell's largest |q|; w the two cells' turns since t, summed). Two cells turned
  together by a bend keep B near zero.
- The list is kept while B, its cells' bead radii growth (a muscle) and this frame's motion
  margin stay under the margin it was built with; otherwise that one list is built again
  (all pairs of its two cells: a few dozen distances). The motion margin is the full
  search's, per pair: `PAIR_SLACK × ((|V_a − V_b| + the cells' largest bead speeds about their
  means) dt + |A_a − A_b| dt²/2) + 2 PAIR_PAD`, less the beads' own accelerations about their
  cell's mean (its pressure and damping, which its skin holds within the substep: counting
  them made the margin 15–30 px in a swimming crowd against the 2–4 px its cells move; the
  crash, the crowd and the cargo test below are sound without them).
- Which cells neighbour each other comes from a scan of their centres in a small grid, kept
  with a margin of its own (the margin needed plus the largest cell's reach) while no cell
  strays from a rigid motion of the scan by more than the rest of it allows: a swimming worm
  scans every 10 frames or so, a creature keeping its shape almost never.
- A cell deformed by a quarter of the margin takes a new snapshot; every list goes at a
  change of topology. Everything is the creature's own data in a fixed order: threaded is
  bit-identical to serial.

The cargo test `cell_pair_lists_miss_no_touching_pair` checks every frame of a violent
scene (creatures squeezed by hard pushes, bent by 30 % muscle waves at 1.9 Hz, thrown into
each other) that every own pair touching at the frame's start is among the frame's contacts:
43 000 touching pairs, none missed, though 77 % of the lists were rebuilt every frame there.
A swimming worm (the worm-bend gait) rebuilds 11.5 % of its lists a frame.

### The step

- **The spinning step** (`spin`, the preset's): one rayon broadcast a frame, the phases
  handed out by atomic counters with spin barriers between them, the serial parts on thread
  0. A creature in no overlapping pair this frame (usually most, while swimming all) runs
  its whole frame in one go (no barrier between its substeps, its data warm in cache);
  creatures retopologising are handed out first. The barrier spins 1000 times, then yields
  its core: with every core in the pool, a long spin keeps a preempted thread off its core
  (20 000 spins, the explore's, made the 95th percentile of a swimming crowd 11–14 ms
  against a median of 5; 200–2000 kept it at 6–6.5).
- **The forked step** (spin off) is kept, bit-identical to the spinning one: with fewer cores
  than threads, or a game busy on other threads, rayon's work stealing degrades gracefully
  where spin barriers wait on a preempted thread. With 1 thread both are the serial step.
- In a real frame loop (60 fps under Xvfb with a drawn scene, 30 worms of 150 swimming)
  the process used 2.97 cores with spin and 2.95 without, its steps taking 50 % and 64 % of
  the wall clock: the spinning threads do not burn cores between frames (the pool's workers
  sleep after a broadcast as after any rayon job).
- Small savings on every path: bead contacts stuck to the other's ring are dropped once a
  frame instead of being checked in every substep, `edge_at()` lost its modulo (the
  substeps' contacts and sticks −35 % and −18 % CPU in a swimming crowd); the per-part CPU
  timers (a system call per reading, some 2000 a frame) only with `cpu_timers`; `libc` only
  on unix (the explore's build did not compile for Windows).
- Removed: `stick_every` (sticks every other substep: unsound in the explore's crash).

## The API

`GooColonySim` (goo_colony_sim.gd):

| | |
|---|---|
| `frozen_options(strength = TENSION)` | `everything_options()` plus `frozen`, `frozen_self` 4, `pair_skin` `FROZEN_SKIN` × unit, `retopo_every` `RETOPO_EVERY`, `frozen_breaks`, `retopo_switches` `RETOPO_SWITCHES`, `fast_search`, `spin`, `fast_rings`, `cell_beads` `FROZEN_BEADS` |
| `request_retopology(creature)` | the creature retopologises in its next step |
| `add_cell(creature, cell)` | a cell (a Dictionary as `add_creature()` takes) appended; asks for a retopology, where it joins its neighbours |
| `remove_cell(creature, cell)` | its particles and sticks go, later cells renumbered down; each pair it was joined in reported parted at once (old numbering); asks for a retopology |
| `cell_beads` | the smallest cell's bead count for `add_creature()` and `add_cell()` (the option `cell_beads` given to `new()`) |
| `cells_joined`, `cells_parted` | as before: joins at retopologies, parts at retopologies or (frozen_breaks) when a wall breaks |
| `cell_floats(…, beads)` | the floats of a cell with `beads` beads for the smallest size |

`GooColony` adds `set_cell_muscle(c, cell, scale)`, `set_cell_muscles(c, scales)` (one call a
creature a frame: the cheap path for a gait), `cell_muscle()`, `add_cell()`, `remove_cell()`,
`cell_bead_radius()`, and the options in its `set_options()` comment; `stats()` adds
`retopos`, `retopo_cpu_us`, `urgent`, `cp_rebuilt`, `cp_lists`, `cp_snaps`, `cp_cpu_us`.

### What a game must do

- Build creatures with `GooColonySim.new(GooColonySim.frozen_options())` and a pool of at
  most the machine's cores (`threads`).
- Drive muscles with `set_cell_muscles()` once per creature per frame, not `resize_cell()`.
- Ask for a retopology when the creature should re-knit: after a cell joins or leaves
  (automatic), after a hard hit if it should heal sooner than the timer, when a creature
  is told to merge two of its parts. Joins arrive only then; parts arrive when walls break.
- Expect the outline, the cores and the drag's and tension's surface to lag a fresh break
  by up to `retopo_every` frames.
- Read events after each step (GooColonySim does).

## Knobs and why

| Knob | Value | Why |
|---|---|---|
| `RETOPO_EVERY` | 30 frames | one retopology a frame at 30 creatures; each costs 0.56 ms CPU in the colliding bench (150 cells) and 1.5 ms swimming hard (two exposure passes in most of them, 0.4 ms each, and 4.5 switches), run at the frame's start beside the others' search; a join or a fresh core waits at most half a second. 15 and 60 were within noise of it in the swimming crowd (p95 11.2, 10.2, 9.5 ms in one unquiet session); a game whose creatures rarely change can use 0 and requests |
| `FROZEN_SKIN` | 16 px at unit 1 (8 at 0.5) | the cell-pair lists' margin: 4 to 12 px at unit 0.5 cost the same within noise in the swimming crowd (rebuilds 25 % → 12 % of the lists a frame, longer lists to filter); 8 is in the flat middle |
| `RETOPO_SWITCHES` | 8 | caps a retopology's switches (a worm swimming hard switched 4.5 cells a retopology on average; a cluster settling at its start many more, whose cores now form over a few retopologies) |
| `frozen_breaks` | on | a broken wall breaks when it breaks, with its event, for the cost of the full break pass on that frame only (the urgent retopology instead tripled the retopology cost: 2.8 a frame in a crowd swimming hard, 14 breaks a frame) |
| `urgent_retopo` | off | as above; kept for a game that wants a broken creature re-knit at once |
| `FROZEN_BEADS` | 12 | propulsion first: at 10 the bend gait swims 23–27 % slower and the tension no longer zips a wall from 3 to 4 sticks; 10 is the option when the strict swimming gate matters (below) |
| `spin` | on | 30 × 150 colliding, full model: 7.6 ms forked, 6.0 spinning with the dense own search; in a frame loop it uses no more CPU than the forked step |
| `substeps` | 6 | 5 was measured (the crash: own particles inside own cells 3 at 600 px/s against 1 at 6); 4, the explore's, was unsound |

## Beads per cell

How the count is chosen today: `GooTuning.bead_count(radius)` gives 12 beads to the
smallest cell (radius 28 px at unit 1, 14 at 0.5) and grows to 22 at the largest (176 px),
by `size_t()`, a log scale between them; the bead radius is 0.6 of the spacing, so the beads
close the ring. "8 beads" (`GooColonySim.cell_floats(…, beads = 8)`, `cell_beads`, the tools'
`--beads`) means 8 for the smallest cell and every other cell its own count minus 4 (18 at
the largest): the bead radius of the smallest goes from 4.4 to 6.6 px at unit 0.5, the
masses, ring radius and springs recomputed for the count as `tuning()` would. At 10: 5.3 px.

| | 12 | 10 | 8 |
|---|---|---|---|
| bench 30 × 150 colliding, median / p95 ms | 4.8–5.1 / 6.3–7.0 | 3.7–3.8 / 4.9–7.6 | 3.3–3.4 / 4.4–5.2 |
| swimming crowd 30 × 150, median / p95 ms | 7.5–7.8 / 10.0–10.4 | 6.9–7.1 / 8.3–8.9 | 6.4–6.6 / 8.0–8.7 |
| crash 37 and 91 cells at 300 / 600 px/s | sound (0 inside out, 0 in the other, own inside 0) | sound (own inside 1 at 37 / 600) | sound (own inside 1 at 37 / 600) |
| ring area min in the crash (37 / 91, 600 px/s) | 0.58 / 0.58 | 0.65 / 0.64 | 0.84 / 0.79 |
| worm squeeze / worm bend / worm bend at half amplitude / blob squeeze, px/s | 26.2 / 22.1 / 7.8 / 19.1 | 23.4 / 17.2 / 7.1 / 18.6 | 19.7 / 8.8 / 3.5 / 11.9 |
| swimming crowd's speed (bend), px/s | 16.3 | 11.9 | 7.0 |
| two equal cells' wall, no tension / tension: sticks, centres apart (× diameter) | 3, 0.93 / 4, 0.80 | 3, 0.91 / 3, 0.88 | 1, 1.02 / 2, 0.95 |
| a cell beside one 1.6 × its size | 3 / 4 | 3 / 3 | 3 / 3 |
| ragged cluster's sticks per wall (tension) | 2.4 | 2.2 | 1.9 |
| ragged cluster rounding after 3 s (perimeter² / 4π area, none / tension) | 5.8 / 2.5 | 6.2 / 3.0 | 2.0 / 3.7 |

(Single crowd runs are the gate's, three each; the rest one run each, unit 0.5.)

The pictures (tools/colony_shot.gd `--frozen --beads=K`, every scene): at 10 the smallest
cells read as decagons and walls as short flat segments; at 8 they are octagons and two
equal cells meet at a corner, one or two sticks, the wall hardly reads, and the swimming
worm (the bend gait at 0.3) tore across near its tail in 4 s. Without tension at 8 the
ragged cluster's single-stick joints let it fold up (hence its low number: it is not
rounder, it collapsed).

Recommendation: 12 for the preset (`FROZEN_BEADS`), because propulsion is the user's first
priority and 10 loses a quarter of a bending worm's speed; 10 when the time matters more
(25 % cheaper colliding, 8–15 % swimming, and it meets the swimming gate's p95 with room);
not 8: sound, but its walls are one or two sticks, worms tear and swim at 40–60 %.

## Propulsion

Creatures swim by a travelling wave of muscles (`set_cell_muscles()`, one call per creature
per frame) against the water drag on their exposed edges, the tension on, frozen preset
(tools/colony_swim.gd; worms 24 × 5 cells, 686 px long, their inside cells cores; a blob of
37). The wave runs tail-ward; speeds along +x after 1 s to settle, over 6 s, 12 beads:

| gait | amplitude, waves, Hz | px/s | body lengths per cycle | full model |
|---|---|---|---|---|
| worm, squeeze (columns) | 0.3, 1.5, 1 | 26.2 | 0.038 | 24.3 |
| worm, bend (one side against the other) | 0.3, 1.5, 0.5 | 22.1 | 0.065 | 17.3 |
| worm, bend | 0.15, 1.5, 0.5 | 7.8 | 0.023 | |
| worm, bend | 0.25, 1, 1 | 10.1 | 0.015 | 8.3 |
| blob, squeeze | 0.3, 0.5, 1 | 19.1 | 0.097 | 20.8 |

Frozen swims as fast or faster than the full model: fewer walls break and re-knit under the
muscles. Slow, as soft bodies in this drag go (a few hundredths of a body length per cycle):
the hard bend breaks some 30 walls a frame across 30 worms, re-knit at retopologies.

The cost of driving muscles every frame: set_cell_muscles() of 150 scales for 30 creatures,
0.65–0.8 ms of GDScript a frame median (building the arrays), nothing in the step beyond
the rest shapes; resize_cell() also asked for an exposure pass every frame (120 passes in
120 frames for a worm of 30, against 5 with muscles).

All 30 worms of 120–150 cells swimming at once: the gate's swimming rows.

## Soundness against the full model

Measured with `soundness()` (own particles inside another own cell, particles inside
another creature, rings inside out, the smallest ring area over its rest, the deepest core
overlap), every frame unless said.

The crash (tools/colony_crash.gd; two hex clusters thrown into each other, worst over the
90 frames after the throw), 12 beads, 4 threads:

| cells, impact each | model | ring area min | inside out | inside the other | own inside own | core overlap own px | sticks broken |
|---|---|---|---|---|---|---|---|
| 37, 300 px/s | full | 0.67 | 0 | 0 | 0 | 6.6 | 20 |
| 37, 300 px/s | frozen | 0.69 | 0 | 0 | 0 | 4.0 | 9 |
| 37, 600 px/s | full | 0.56 | 0 | 0 | 1 | 9.9 | 59 |
| 37, 600 px/s | frozen | 0.58 | 0 | 0 | 0 | 8.7 | 30 |
| 91, 300 px/s | full | 0.63 | 0 | 0 | 0 | 7.6 | 85 |
| 91, 300 px/s | frozen | 0.69 | 0 | 0 | 0 | 2.9 | 31 |
| 91, 600 px/s | full | 0.58 | 0 | 0 | 3 | 19.2 | 199 |
| 91, 600 px/s | frozen | 0.58 | 0 | 0 | 0 | 7.7 | 101 |
| 91, 600 px/s | frozen, no own contacts | 0.15 | 119 | 52 | 1754 | 27.8 | 577 |

The last row is why own contacts between retopologies are not optional (the explore's
`frozen_self` 0). The Verlet own list gave the same numbers as the cell-pair lists within
one particle. Fewer walls break frozen: between retopologies a broken pair is not captured
again at once to break again.

The crowd (test_goo_colony_frozen.gd: 8 clusters of 19 pushed hard into the middle and out,
4 s, three turns of the ring): own particles inside own cells 12 / 15 / 12 full, 19 / 16 / 12
frozen; the full model turned one ring inside out in one run, frozen none. These are
compliant cores squeezed deep (core overlap 12–21 px at 14 px radius, both models): one
run's worst is chaotic (variants that change nothing physical gave the full model 9 to 14,
frozen 18 to 22), so the test compares sums with a margin. The seeded random game (pushes,
pokes, muscles, requests, cells added and removed): full 8 own inside, frozen 6, no ring
inside out, no particle in the other creature in either. The swimming crowds of the gate:
none of either in any run (ring area min 0.65–0.72 full, 0.72–0.92 frozen at 30 × 150).

## Retopology cost and cadence

A retopology costs 0.56 ms CPU (the colliding bench, 150 cells) to 1.5 ms (a worm of 150
swimming hard: about two exposure passes of 0.4 ms, 4.5 switches, the capture search and
the full break pass). The explore's 3.6 ms came from a cascade: every switch made the next
frame a retopology again (the kept list was invalid), so a deforming creature
retopologised several frames running; now a switch needs none (the cell-pair lists rebuild
themselves), one retopology makes at most `retopo_switches` switches and at most one pass
after them, and its search covers only that frame's candidates (it built the Verlet list's
8 px skin before). Recommended cadence: 30 frames (the preset) with requests on game
events; at 30 creatures that is one retopology a frame, its pass hidden beside the others'
contact search.

## The gate

`tools/colony_bench.gd` (creatures colliding: pushed to random targets) and
`tools/colony_swim.gd` (all swimming: worms of 5 cells across, the bend gait at 0.3, 1.5
waves, 0.5 Hz, 4 s), 3 runs each on a quiet 4-core machine (other processes' CPU checked,
under 0.2 cores, no run retried), ms per physics frame, median / p95 ranges over the runs.
Bench: the physics frame (the step and its GDScript); swim: the colony's step (the muscles'
GDScript, 0.65–0.8 ms at 30 creatures, apart). Full: `everything_options()`; + spin + dense:
the same physics on the spinning step with the dense own search; frozen: `frozen_options()`.

| size | model | colliding median | p95 | swimming median | p95 |
|---|---|---|---|---|---|
| 30 × 150 | full | 7.58–7.68 | 9.47–10.11 | 14.91–15.08 | 17.88–18.52 |
| 30 × 150 | full + spin + dense | 5.98–6.00 | 7.19–8.93 | 12.77–13.28 | 15.57–16.33 |
| 30 × 150 | frozen, 12 beads | 4.80–5.06 | 6.27–6.98 | 7.49–7.84 | 9.95–10.43 |
| 30 × 150 | frozen, 10 | 3.69–3.79 | 4.92–7.61 | 6.88–7.09 | 8.25–8.86 |
| 30 × 150 | frozen, 8 | 3.25–3.39 | 4.37–5.23 | 6.41–6.55 | 8.04–8.67 |
| 30 × 100 | full | 5.60–5.87 | 6.64–7.16 | 7.45–7.76 | 9.49–9.98 |
| 30 × 100 | full + spin + dense | 4.46–4.57 | 5.70–6.01 | 6.02–6.40 | 8.02–8.51 |
| 30 × 100 | frozen, 12 | 3.60–3.66 | 4.75–5.10 | 4.22–4.27 | 5.72–6.13 |
| 30 × 100 | frozen, 10 | 2.95–3.03 | 4.17–4.57 | 3.68–3.87 | 5.09–5.61 |
| 30 × 100 | frozen, 8 | 2.44–2.59 | 3.60–4.39 | 3.14–3.22 | 4.08–4.95 |
| 60 × 60 | full | 6.46–6.69 | 7.81–9.26 | 9.56–9.69 | 12.13–12.19 |
| 60 × 60 | full + spin + dense | 5.41–5.64 | 6.94–7.13 | 7.57–7.73 | 9.25–9.51 |
| 60 × 60 | frozen, 12 | 4.56–4.80 | 5.84–7.09 | 5.29–5.40 | 7.11–7.34 |
| 60 × 60 | frozen, 10 | 4.07–4.08 | 5.45–5.86 | 4.64–4.68 | 5.98–6.59 |
| 60 × 60 | frozen, 8 | 3.53–3.80 | 5.07–5.27 | 4.01–4.25 | 5.40–5.83 |
| 60 × 150 | full | 12.02–12.08 | 14.36–15.47 | 27.25–27.79 | 31.76–33.25 |
| 60 × 150 | full + spin + dense | 9.80–10.32 | 12.00–12.80 | 24.57–25.62 | 28.64–33.41 |
| 60 × 150 | frozen, 12 | 8.54–8.86 | 10.56–11.26 | 14.45–15.16 | 17.47–18.57 |
| 60 × 150 | frozen, 10 | 7.17–7.24 | 8.50–9.30 | 12.80–13.28 | 15.59–16.19 |
| 60 × 150 | frozen, 8 | 5.96–6.06 | 7.23–8.07 | 12.39–12.54 | 14.61–16.00 |
| 30 × 150, 1 thread | full | 18.92–19.38 | 22.27–23.46 | 47.07–50.53 | 55.02–63.99 |
| 30 × 150, 1 thread | frozen, 12 | 15.11–15.34 | 17.90–18.93 | 26.70–27.62 | 30.62–31.80 |
| 30 × 150, 1 thread | frozen, 10 | 12.28–12.44 | 13.69–15.64 | 23.43–24.05 | 26.90–31.58 |

The target, 30 × 150 well under 10 ms with p95 while swimming: met colliding at every bead
count; swimming hard at 12 beads the p95 sits at 10 (10.0–10.4), at 10 beads 8.3–8.9.
60 × 150 is out of reach at 4 threads (8.5 colliding, 14.5 swimming at 12).

Where the time goes (swimming crowd 30 × 150, 12 beads, CPU ms per frame summed over the
threads, about 25 in all): sticks 7.7, rings 7.3, own contacts 5.6 (of it the cell-pair
lists 4.5: 13 000 lists judged, 14 % rebuilt, 265 cells re-snapshot a frame), intra contacts
1.5, retopology 1.5, tension 1.0, drag 0.3. In wall time: the contact search phase 2.1 ms,
the substeps 3.6 ms, the after phase 1.9 (both include the spinning step's wait at the
barriers). The colliding bench: sticks and rings 9 ms CPU, own contacts 2.1, tension 0.7.
What is left is mostly the physics itself: sticks and rings solved 6 times a frame.

## Departures from the brief

- Own contacts kept per pair of cells (`frozen_self` 4) instead of the explore's Verlet list:
  the brief offered per-cell displacement against the neighbourhood or per-pair margins;
  this is both (each pair judged from its own two cells' similarity fits).
- The motion margin of the cell-pair lists leaves out the beads' accelerations about their
  cell's mean (see above); measured sound, and it is the one place the frozen path's
  margins are tighter than the full search's.
- Breaks between retopologies happen at once by default (`frozen_breaks`), with their events;
  the explore deferred them, the brief asked whether an urgent retopology was worth having:
  built (`urgent_retopo`), measured worse (2.8 a frame in a crowd swimming hard), left off. An
  impact trigger was not built: collisions with other creatures never change a creature's
  own topology (cells of different creatures never stick), an impact shows as breaks.
- The exposure pass of a retopology moved to the start of its frame.
- `stick_every` was removed rather than kept as an option (unsound at 2).
- Swimming in the gate is the bend gait at 0.3 amplitude, harder than any gait a game is
  likely to keep up; a gentler one costs less (fewer breaks and re-knits).
- `remove_cell()` and `add_cell()` did not exist and were built.

## Limits and defects

- Joins, cores and the outline lag by up to `retopo_every` frames; a broken wall's beads feel
  no drag or tension as surface until then.
- `soundness()`'s "own particles inside own cells" is not zero in violent scenes for either
  model: compliant cores (`core_contact` 1) are squeezed 12–21 px into each other at 14 px
  radius in the crowd test. Both models; the frozen one no worse in the sums.
- The spinning step wants a pool of at most the machine's cores: on 4 cores, 4 spinning
  threads beat 3 (p95 9.8 against 11.4) but a game loading other threads during the step
  should measure, or turn `spin` off (forked, bit-identical).
- Single-run maxima are noisy (p95 / median about 1.3 on this machine for the same work).
- The pictures are the debug view of colony_shot (bead outlines, sticks, loops), not a game
  skin.
- Manual promote() / demote() leave the outline's loops naming old indices until the next
  pass (as before this work); remove_cell() clears them.
