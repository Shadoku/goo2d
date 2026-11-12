# One particle per cell: an exploration

Branch `explore-cells` (from `colony-spike` 0935e9d), 2026-11-12. An exploration, not a
feature: nothing in the addon uses it; the ring-per-cell colony (`colony.rs`,
docs/colony-frozen.md) is untouched and is the baseline to beat. The user's words: "explore
one particle per cell a little more deeply now. Aggregate behavior and performance are more
important than preserving per cell collisions, the game I'm planning can be built around any
quirks that arise", and earlier "Creature propulsion and semi-solid collisions are the most
important things, creatures don't need to be infinitely mutable at all times."

What was built:

| | |
|---|---|
| `addons/goo2d/native/src/cells.rs` | `Cells`: the model below, its step, topology changes, designs, health, cargo tests |
| `GooCells` (lib.rs) | its Godot class |
| `addons/goo2d/goo_cells_sim.gd` | `GooCellsSim`: recommended options, events as signals, retopologies with a script veto |
| `tools/cells_design.gd` | designs: hex worms, blobs, tadpoles; free-form packings of mixed radii |
| `tools/cells_bench.gd` | cost: N × M creatures colliding or swimming in an arena |
| `tools/cells_swim.gd` | propulsion: gaits, drag ratios, turning, station keeping, crowds |
| `tools/cells_crash.gd` | collisions: crashes, tunnelling, snagging, walls, gaps, curls, impacts |
| `tools/cells_lab.gd` | link loads, topology costs, mixed sizes, bending models, tension, steering |
| `tools/cells_shot.gd` | pictures |
| `tests/unit/test_goo_cells.gd` | GDScript tests |

It reuses the earlier, shallower prototypes: `explore-simple`'s `GooCluster` (cluster.rs:
the planar link graph, its outer-face outline, the drag on the outline, shape matching, the
threaded step's layout, the drawing's outline surface) and `explore-lattice`'s notes (gap
jamming below 0.8 of the width; swimming weak). Measured on this machine (4 cores), each
timing three times, ranges given.

## The model

A **cell** is one disc particle: position, angle, velocity, spin, mass (density × π r0²,
fixed), moment (½ m r0²), radius r = r0 × scale (scale: muscles and the ease of a new cell),
type, a persistent uid.

A **creature** is a set of cells joined by **links**, built at touch distance (two cells
closer than 1.08 × the sum of their radii) from any design, crossing links dropped (longest
first) so the graph is planar. From the graph: neighbour lists sorted by angle, the
**outline** (the outer face, walked around; its cells are the **boundary**), each cell's
cells within two links. Nothing is a lattice: radii are free, from 14 to 44 px in the tests.

A link is three XPBD constraints, solved once per substep in link order:

- **stretch**: |xj − xi| = rest, compliance from `stretch_hz` over the pair's reduced mass,
  XPBD damping `link_damp`;
- **bend at each end** (oriented particles, as Primordialis): the link's direction measured
  in the end cell's own frame equals the angle it had when the link was made. The constraint
  moves both cells and turns the end cell; compliance from `bend_hz` over the effective
  inverse mass ((wi + wj)/l² + Iw), damping `bend_damp`. The shape's memory is entirely in
  these anchors: no rest shape is matched.

The alternative bending model, **shape matching** (`BEND_SHAPE`, from cluster.rs): each cell
and its linked neighbours pulled a share `shape_k` toward the best rigid fit of their design
offsets; a cell's angle then follows its neighbourhood's fit (so thrust and types still have a
heading).

Per frame (in parallel per creature):

1. **muscles**: radius muscles (`set_cell_scales()`, or the built-in wave `WAVE_RADIUS` /
   `WAVE_SQUEEZE`: radii change, links' rest lengths follow), or the **pose wave**
   (`WAVE_POSE`): the design bent along a travelling curvature wave
   κ(u, t) = bias + A·k·env(u)·sin(k u + ω t) (A·k the slope, env growing from head to tail),
   integrated along the body axis; every link's rest length and both anchors are set from the
   bent design, every cell's radius scaled by its stretch along the axis. Curvature is
   clamped so no side squeezes below half (an undrawable pose explodes). Waves ease in over
   0.5 s.
2. **plasticity** (optional): a link strained past `plastic_yield` creeps its rest length and
   anchors toward now at `plastic_rate`; `plastic_recover` creeps them back to the design.
3. **forces**: script forces per cell, **thrust** per cell along its heading, a **twist**
   (forces of a rigid turn about the centre of mass: torque, no net force), **surface
   tension** (along every outline edge a pull, equal and opposite on its two cells), the
   **drag** (below), a uniform push.
4. candidates: walls for every cell; the creature's own contacts (a Verlet list rebuilt every
   `self_every` = 4 frames, staggered by creature).

Then the broad phase between creatures (box pairs, then each collider against the other's
grid, in parallel per pair) and `substeps` substeps: per creature in parallel (predict,
links, shape matching, walls, own contacts), then the contacts between creatures serially in
a fixed order. Then velocities, link loads (each link's mean force over the frame, from the
constraints' multipliers, smoothed over `break_smooth`), and serially the topology changes.
Every creature's work touches only its own data: **threaded == serial bit for bit** (cargo
test and GDScript test, with collisions, joins, added and removed cells, breaks).

**Contacts between creatures**: disc against disc between **boundary** cells (default),
every cell (`collide_all`), or a boundary disc against the other's **outline capsules**
(`capsules`); optionally a contact pad on boundary cells (`contact_pad`) and a compliance
(`contact_hz`). **Walls**: convex polygons (up to 8 points), against every cell.

**The creature's own contacts**: none, every unlinked pair (`SELF_UNLINKED`), unlinked pairs
not sharing a neighbour (`SELF_FAR`), or cells of self-colliding types against every
unlinked cell (`SELF_TYPES`).

**Drag**: the fluid game's law (`FluidDrag`, GameSettings' DRAG_* style) on the outline's
surface edges (the boundary cells pushed out by their radius): per edge, the velocity
relative to the water split across and along it, −(c_n |v_n| + l_n) v_n − (c_t |v_t| + l_t) v_t,
× length × density, half to each cell, clamped per cell so it never takes more than half the
relative velocity in a frame. Interior cells feel none. `drag_facing` (Primordialis: only
faces turned into the flow) is an option. Per frame (as the game) or per substep.

**Topology** (between steps, serial):

- **breaking**: a link whose smoothed load passes `break_force` (× its types' factor; a
  torque term optional) is removed with an `EVENT_PARTED` (creature, uid, uid); a creature
  that falls apart is split into its connected parts, the part holding cell 0 keeps the slot,
  each other part gets a new slot and an `EVENT_SPLIT`;
- **joining at a retopology** (when the game asks): `find_captures(capture, same)` lists
  pairs of boundary cells within `capture` px of touching, across creatures (and within one,
  sharing no neighbour, when `same`), filtered by the type table (`join_mask` both ways);
  the script vetoes any (`GooCellsSim.may_join()`); `join()` links the rest at their current
  geometry, merges creatures (the second into the first), re-planarises, `EVENT_JOINED`;
- **adding a cell**: `add_cell(creature, at, radius, type)` links it to the cells it would
  touch at full size; it grows from 0.3 of its radius over 0.5 s (smoothstep), its links'
  rest lengths with it; it starts with its neighbours' mean velocity;
- **removing a cell**: its links' `EVENT_PARTED`, then a split if it falls apart.

Creature ids are slots (a merged creature's slot stays, dead); cells are named by uid in
events.

## Primordialis: what was taken, what was not

The reference (reconstructed from patch notes and the community wiki, so inspiration only):

| Primordialis | here | why |
|---|---|---|
| a cell is a point with position, rotation, velocity, spin; mass and radius per type; radius changes at run time | taken | the whole model |
| 120 Hz × 4 substeps, forces, "compliance" | XPBD at 60 Hz × 6 substeps (360 Hz) | XPBD's compliance is the same idea in one solve; low compliance in one solve was their lesson |
| a link = radial spring + angular spring to the build-pose angle in each cell's frame | taken as XPBD constraints (`BEND_LINK`) | shape memory without shape matching; per-link joints possible |
| link forces capped; break past a force; components split off | break taken (smoothed multiplier force), cap not | a cap would need force-based links |
| own cells do not collide; a self-colliding cell type opts in | measured: none, `SELF_FAR`, unlinked, opt-in types (`SELF_TYPES`) | none folds a curling worm through itself (below); `SELF_FAR` is cheap and sound |
| other creatures collide as discs with a penalty force, scalable per cell ("phasing") | discs as hard XPBD contacts; per-type pad; compliance optional | soft (penalty-like) contacts let boundary-only creatures interpenetrate (below) |
| walls as an SDF with the stream's flow | convex polygons; a uniform current | the SDF and flow field are a game-side swap; the drag already takes a water velocity |
| swim force per cell along its heading | taken (thrust) | the cheat baseline and thrusters |
| turning by tangential forces about the centre of mass; "seeker" pair | taken (`twist()`, script forces) | both measured |
| drag per exposed hex face, normal / tangential, linear, faces into the flow only | the outline's edges, the fluid game's law, both faces by default (`drag_facing` option) | facing-only swam slower (0.157 against 0.255 body lengths per cycle) |
| jets: a force field ahead of the cell | not built | game-side |
| rigid cells (hard groups) clipped and launched; regrown cells spawned inside others launched | no rigid groups; new cells ease in | the lesson taken; spawning creatures inside each other still launches them (quirks) |
| editor on a hex grid; neighbour graph carries electricity/heat/biomass | free-form designs; neighbour lists exist | the graph is there for a game to use |

## Propulsion

`tools/cells_swim.gd`, one creature, unit 0.5 (cells 14 px), 2 s warm-up then 6 s measured.
Body lengths per cycle = speed / (length × frequency). Worm 24 × 5 is 686 px long, 30 × 5
854 px.

Recommended settings unless a row says otherwise: 6 substeps, links 60 Hz, bending 40 Hz,
own contacts `SELF_FAR`, the game's normal drag (0.1 quadratic, 60 linear) with the
tangential terms a twentieth of it ("ratio 20": 0.005, 3).

**Undulation alone (no thrust).** The pose wave: slope A·k = 1, one wavelength per body,
amplitude growing to the tail (envelope 0.6), 1 Hz.

| creature, change | speed px/s | body lengths / cycle |
|---|---|---|
| worm 24 × 5 (686 px) | 155 | **0.226** |
| ... drag ratio 7.5 / 10 / 20 / 50 / 100 (tangential = normal / ratio) | 122 / 134 / 155 / 169 / 174 | 0.177 / 0.195 / 0.226 / 0.246 / 0.253 |
| ... the fluid game's drag exactly (10 quadratic, 7.5 linear) | 127 | 0.185 |
| ... all drag × 0.5 / × 2 / × 4 | 139 / 162 / 164 | 0.203 / 0.236 / 0.238 |
| ... drag on faces into the flow only (Primordialis) | 90 | 0.132 |
| ... shape matching instead of oriented links | 146 | 0.212 |
| ... radius muscles (Primordialis' way: one side ± 30 % / 50 %) | 135 / 144 | 0.196 / 0.210 |
| ... squeeze wave (all cells across ± 30 %) | 18 backwards | −0.026 |
| ... 4 / 8 substeps | 117 / 158 | 0.171 / 0.231 |
| ... soft links and bending (20 / 4 Hz, the first guess) | 61 | 0.089 |
| worm 30 × 5 (854 px) at 1 Hz / 0.5 Hz / 2 Hz | 107 / 115 / 132 | 0.126 / **0.270** / 0.077 |
| worm 30 × 5, drag × 4, ratio 50 | 201 | 0.235 |
| worm 30 × 3 / 40 × 2 / 24 × 7 | 169 / 75 / 108 | 0.198 / 0.067 / 0.157 |
| tadpole (61-cell hex head, 24 × 3 tail; slope 1.5, envelope 0.9), 1 Hz / 0.6 Hz | 124 / 72 | 0.132 / 0.128 |
| free-form worm of radii 14..30 px (150 cells, 1354 px) | 22 | 0.016 |
| hex blob of 127 (pose wave) | 4.5 backwards | −0.012 |

Best seen, with stiffer links and bending (80 / 80 Hz) and drag × 4: worm 24 × 5 at ratio
50, 0.288; worm 30 × 5 at 0.5 Hz, ratio 20, **0.316**. The colony's rings: 0.02-0.07.

So **undulation alone reaches 0.2-0.3 body lengths per cycle**: the 0.3 aimed at is reached
at a low frequency (0.5 Hz) or with a drag ratio of 50 and drag × 4; ratio 20 gives 0.23-0.27.
What it takes, in order of effect: stiff enough bending that the body holds the commanded
pose against the water (bending 4 Hz: 0.09; 40 Hz: 0.23; 80 Hz: a little more), a drag ratio
of 20 or more (7.5: 0.18), a frequency low enough for the body's length (the water's linear
drag gives a 5-wide body a time constant near 1 s: at 2 Hz it is inertial and slips), a
slender, regular body (2 rows barely bend, 7 rows push less; the free-form worm of mixed
sizes swims at 0.016 because its bent pose is far from what its irregular links can follow),
and the curvature wave over the radius wave (Primordialis' radius muscles reach 0.20-0.21,
close). The blob cannot undulate: it needs thrust.

**Thrust (the cheat).** Every cell pushing 200 px/s² × its mass along its heading: a 127
blob 299 px/s, a 24 × 5 worm 443 px/s (straight, no deformation).

**Turning.** A curvature bias added to the wave: 0.0005 / 0.001 / 0.002 per px turn a
swimming 24 × 5 worm at 0.09 / 0.20 / 0.44 rad/s, keeping 98 / 93 / 70 % of its speed. A
twist (forces of a rigid turn, no net force): a 127 blob at 1 / 2 / 4 rad/s² settles at
2.1 / 4.5 / 6.6 rad/s against the drag, a 24 × 5 worm at 1 / 4 rad/s² 0.7 / 2.0 rad/s, the
centre drifting under 10 px. A seeker pair on the 127 blob (its front half pulled toward a
point at 100 px/s² × the creature's mass in total, its back half pushed away by the same,
no net force) turned it 1.93 rad in 5 s toward a target 1.57 rad away (an overshoot: the
script's law has no damping), the centre still.

**Station keeping in a current.** A worm 24 × 5 facing a uniform current; a script controller
(frequency = feed-forward current / (0.2 body lengths) + 0.004 × error along − 0.006 ×
velocity; curvature bias toward the target's line): held within 23 px (0.03 body lengths, worst
25) in 60 px/s at a mean 0.34 Hz; 18 px in 30 px/s; 33 px in 90 px/s (0.53 Hz); a 30 × 5 worm
34 px in 60 px/s. (A frequency changed every frame needs the wave's phase integrated, not
ω t: before that fix the same controller held only to 64-174 px.)


## Collisions between creatures

`tools/cells_crash.gd`, recommended settings, 1 thread. A cell is 28 px across.

**Two clusters** (hex, 91 + 91 and 91 + 37 cells), thrown into each other at 300 and
600 px/s each:

| contact model | 91+91 at 300: deepest overlap / inside | at 600 | 91+37 at 600 | rebound at 600 (91+91) |
|---|---|---|---|---|
| boundary discs (default) | 0.0 px / 0 | 4.5 px / 0 | 0.0 / 0 | 57 px/s |
| every disc | 0.0 / 0 | 4.5 / 0 | 0.0 / 0 | 57 |
| outline capsules | 0.0 / 0 | 0.0 / 0 | 0.0 / 0 | 41 |
| boundary discs padded 0.3 r | 0.0 / 0 | 0.0 / 0 | 0.0 / 0 | 47 |
| soft contacts (30 Hz) | 8.5 / 0 | **27.8 / 66 cells stuck inside** | 11.2 / 0 | |

Shape error at the impact 0.35 (600 px/s; 0.16 at 300), back to 0.000 3 s later in every
rigid model: the creatures **visibly squash as a whole and recover** (cells_crash_3.png: the
two hexagons flattened along their contact face). Collisions are very inelastic: 2 × 600
px/s in, 2 × 57 out.

**Tunnelling**: a 7-cell creature fired into a 127-cell blob at 600, 1200, 2000 and 3000 px/s
(the speed cap): never inside, deepest overlap 0.0 px, every model. The candidates are found
per frame with the frame's travel as margin, then solved six times; the boundary ring of
discs touches its neighbours, so there is no gap to slip through at rest.

**Snagging**: a 30 × 5 worm pulled 300 px/s² along another while pressed 150 px/s² into it
slides 0.92 of its free speed with discs, 1.03 with capsules, 1.00 with padded discs: the
bumpy outlines do not interlock (nothing has friction; the bumps only cost 8 %).

**Walls**: a 91 blob thrown at a wall at 300 / 600 / 1200 px/s: no wall overlap, shape error
0.12 / 0.29 / 0.80 at the impact, back within 0.05 after 0.73 / 0.43 / 0.27 s, rebound 26 /
41 / 58 px/s.

**Crowds**: in the bench (30-100 creatures jostling in an arena, below) the colliding blobs
never went deeper than 0.4 px, with at most one cell counted inside another creature's
outline (a notch). Swimming worms (pose wave at full stiffness) occasionally go 12-25 px deep
into each other (worst over 6 s, sampled every 20th frame) and 0-2 cells end inside;
capsules removed it in two runs of three. The muscles are as stiff as the contacts, so a pose
that presses into a neighbour wins half the time.

**A creature through a gap** (91-cell blob, 270 px wide, pushed 800 px/s² at a slit in a
flat wall):

| link model | gap 0.8 | 0.6 | 0.45 | shape 10 s after |
|---|---|---|---|---|
| stiff (60 / 40 Hz) | jammed | jammed | jammed | |
| medium (20 / 6 Hz) | jammed | jammed | jammed | |
| soft (10 / 3 Hz) | through 1.4 s | through 3.2 s | jammed | stays deformed (1.0-1.2) |
| softer (6 / 2 Hz) | through 1.4 s | through 1.7 s | jammed | **recovered (0.02-0.03)** |
| plastic (yield 0.05 or 0.01, 3/s), ± recovery, ± no bending | jammed | jammed | jammed | |
| soft 10 / 3 + plastic | through 1.4 s | jammed | jammed | 0.02 |
| breaks at 1.5e5 + rejoin every 10 frames | jammed | through 1.5 s, **in 23 pieces** | jammed | |

Squeezing works only with soft links: compliance, not plasticity (stiff links never strain
past any useful yield: a plastic creature jams like a stiff one), and break-and-rejoin
shatters the creature. Nothing passes 0.45 of its width: the topology is fixed, and 10 cells
across cannot become 4 without rearranging. A game would make squeezers soft (per type:
`set_type(t, {stretch, bend})`) or treat gaps below 0.6 as walls.


## The creature's own contacts

Primordialis skips them. Measured (cells_crash.gd `curl`, `impact`; cells_bench.gd):

| own contacts | a 30 × 3 worm bent into 1.5 turns: deepest own overlap | a 127 blob into a wall at 1200 px/s | cost |
|---|---|---|---|
| none | **34.8 px** (it folds through itself) | 0.0 px (links and bending hold it) | 0 |
| `SELF_FAR` (unlinked and not sharing a neighbour) | 0.0 | 0.0 | 30 × 150: +0.65 ms a frame on 1 thread, +0.2 ms on 4 |
| `SELF_UNLINKED` | 0.0 | 0.0 | a little more |
| `SELF_TYPES` (head and tail cells opt in) | 0.0 | — | only those cells' pairs |

What goes wrong with none: a creature that bends far (a curling worm, a tail swung into the
body) passes through itself; impacts do not collapse interiors (the links hold), and with no
bending at all the interior overlaps 2.1 px. The cheapest sound choice is `SELF_FAR` on a
Verlet list rebuilt every 4 frames (staggered by creature), its margin twice the frame's
fastest travel (1.2 × was measured to miss a curl: 29 px). Pairs two links apart are left out
because a bent pose squeezes them together on purpose; with mixed sizes such pairs overlap up
to 10-12 px at an impact (a small cell between two large ones).


## Topology changes

All between steps, serial, deterministic (threaded == serial with them in the cargo and
GDScript tests).

- **Breaking**: a single file of 12 pulled apart parts links and splits (test); a 24 × 3 worm
  torn by forces on its ends with a break force 3e6 parted 67 links into 5 creatures. The
  load is each link's mean constraint force over the frame, smoothed over 0.05 s. **Loads**
  (cells_lab.gd `loads`, largest smoothed link load): blob pushed 800 px/s² 1.2e6; two blobs
  crashing at 300 / 600 px/s each 6.6e7 / 1.1e8; a blob into a wall at 600 px/s 2.2e8; a worm
  30 × 5 swimming 2.9e8. The swimmer's own muscles load its links more than a 600 px/s crash
  (stiff links fighting a stiff pose): one break force cannot tell "hit hard" from "swims
  hard" (quirks).
- **Joining at a retopology**: two worms side by side, a type table refusing type 1 against
  type 2 (no link), then rows of type 0 facing each other joined, a script veto applied,
  joined events, the second creature merged (test). Cost (30 creatures of 169 cells): finding
  candidates 0.07-0.19 ms; joining 25 pairs that chain them into large creatures 15 ms (each
  merge rebuilds the merged creature's lists and outline: about 4 µs per cell, as a build:
  0.63-0.67 ms per 169-cell creature).
- **Adding a cell**: 0.55 ms on a 150-cell creature; it grows from 0.3 of its radius over
  0.5 s, its links' rest lengths easing from their length when made, so no kick: fastest cell
  under 20 px/s, drift under 0.5 px/s (test). (The first version scaled the rest lengths with
  the radius: the new cell snapped in at 297 px/s.)
- **Removing a cell**: 0.13-0.18 ms; its links' parted events; a single file cut in the middle
  becomes two creatures (test).
- **Muscles**: radius scales per cell every frame (a file of 5 lengthens by 2 × 0.4 r for a
  middle cell at 1.4, test), or the waves.
- **Surface tension**: pairs of equal and opposite pulls along outline edges: no net force by
  construction (the mean velocity stays under 0.05 px/s: f32 noise, quirks). Rounding a ragged
  150-cell cluster (perimeter² / 4πA from 2.78), 5 s:

| links | tension 3e5 | tension 3e6 |
|---|---|---|
| stiff (60 / 40 Hz), no flow | 2.78 | 2.78 |
| stiff, flowing (plastic, no yield, 2/s) | 2.77 | 2.73 |
| no bending, flowing | 2.77 | 2.71 |
| no bending, flowing, recovering 0.5/s | 2.78 | 2.75 |
| 20 Hz links, no bending, flowing | 2.72 | **2.27** |

  With fixed links a pull "like bubbles" only rounds what can flow: it needs soft links that
  creep (and then the creature has little shape memory), and a pull of a few % of the links'
  stiffness. With the recommended stiff links it is a cosmetic squeeze of a few hundredths
  of a pixel. Rounding is better done at a retopology (new links at the current geometry)
  or by a rest-shape change than by a force.


## Mixed sizes and free-form designs

Designs come from a packing generator (the colony bench's: cells placed tangent to two
touching cells, scored by the shape; radii 14 + 30 u³ px, so mostly small): links at touch
distance, planarised. cells_lab.gd `mixed` (6 creatures of 150, 1 thread):

| design | links per cell | rest drift 2 s | solve µs per cell a frame | crash at 600 px/s: overlap / inside / own overlap / shape err after 3 s |
|---|---|---|---|---|
| hex, 14 px | 2.70 | 0.0000 px | 1.22 | 0.4 px / 0 / 0.0 / 0.000 |
| packed, 14 px | 2.70 | 0.0000 | 1.26 | 0.0 / 0 / 0.0 / 0.000 |
| packed, 14..30 px | 2.09 | 0.0000 | 0.96 | 0.2 / 0 / 11.8 / 0.047 |
| packed, 14..44 px | 2.14 | 0.0000 | 0.96 | 0.4 / 0 / 9.9 / 0.037 |

A free-form design is as stable as a lattice at rest (exact: the links are built at the
geometry they hold) and costs the same per link; a fixed hex grid of one size would be
**no faster** (2.70 links per cell either way: the solve is per link) and only simpler in the
builder (implicit neighbours, no planarisation, an outline from the grid). Mixed sizes have
fewer links per cell (big cells have room for more neighbours but the packing leaves gaps),
impacts squeeze small cells between big ones (own overlap 10-12 px with `SELF_FAR`), they
recover more slowly, and mixed worms swim badly (0.016). The bench's 30 × 150 mixed creatures
cost 2.2-2.5 ms (4 threads) against the hex blobs' 2.4.


## Oriented links against shape matching

| | oriented links (40 Hz) | oriented links (15 Hz) | shape matching k 0.3 | k 0.6 | none |
|---|---|---|---|---|---|
| worm 24 × 5 swims (bl/cycle) | 0.222 | 0.203 | 0.209 | 0.192 | 0.174 |
| solve, that worm alone (ms a frame) | 0.153 | 0.166 | 0.114 | 0.114 | 0.059 |
| tail pushed sideways 2 s: shape err / 2 s after release | 0.28 / 0.018 | 0.29 / 0.041 | 0.09 / 0.003 | 0.04 / 0.000 | 0.30 / 0.044 |
| blob into a wall at 600 px/s: peak / back under 0.05 at | 0.29 / 0.43 s | 0.34 / 0.45 s | 0.15 / 0.37 s | 0.12 / 0.35 s | 0.36 / 0.45 s |
| 1200 px/s impact: strain / shape err | 0.42 / 0.89 | | 0.63 / 0.40 | | 0.39 / 1.01 |
| 30 × 150 colliding, solve 1 thread / step 4 threads | 5.38-5.54 / 2.55-2.59 ms | | 2.93-3.01 / 1.70-1.82 ms | | |

**Shape matching wins on cost (about 0.55 of the oriented links' solve when colliding, 0.8
when swimming) and on shape memory** (it holds a shape 3-7 × better under a load and comes
back faster); swimming is a tie. **Oriented links win on locality**: a joint's rest angle is a
number per link end, so hinges, per-link bending muscles, a soft joint between two stiff
parts, a torque term in the break test and per-type bendiness come free, as in Primordialis;
shape matching can only bend through the whole neighbourhood's goal. Both are in the code;
a cell's heading under shape matching follows its neighbourhood's fit, so thrust and types
work with either.


## Cost

`tools/cells_bench.gd`: N creatures in a walled arena (placed on a non-overlapping grid,
the arena 1.25 × it), every creature pushed at 300 px/s² toward a random point that changes
every 2 s (**colliding**, hex blobs) or all swimming (**swimming**, hex worms 30 × 5 for 150
cells and 60 × 5 for 300, a pose wave at 1 Hz steered toward their point by a curvature
bias); recommended settings (links 60 Hz, bending 40 Hz oriented links, 6 substeps,
`SELF_FAR`, drag on); 300 frames after 60 of warm-up; each run three times, the ranges of the
three runs' medians and 95th percentiles; the physics step only (`GooCells.step()`), measured
around the call. The machine (4 cores) was otherwise idle (load average 2.2 at most, from the
bench's own threads).

| creatures × cells | mode | 1 thread median / p95 (ms) | 4 threads median / p95 (ms) | contacts | worst soundness (4 threads) |
|---|---|---|---|---|---|
| 30 × 150 | colliding | 6.52-6.62 / 7.08-7.98 | **2.55-2.59** / 3.17-3.47 | 127 | 0.2 px overlap, 0 inside |
| 30 × 150 | swimming | 8.73-9.00 / 10.21-10.78 | **3.27-3.45** / 4.04-4.50 | 679 | 25.5 px overlap, 0 inside |
| 60 × 150 | colliding | 13.46-13.72 / 15.44-16.35 | **4.44-4.64** / 5.48-6.40 | 329 | 0.3 px, 0 |
| 60 × 150 | swimming | 18.04-18.51 / 20.72-23.21 | **5.66-5.98** / 6.59-7.40 | 1532 | 11.7 px, 0 |
| 100 × 150 | colliding | 22.65-22.81 / 25.11-25.96 | **7.06-7.18** / 8.57-9.12 | 616 | 0.4 px, 1 |
| 100 × 150 | swimming | 29.89-30.36 / 33.49-38.08 | **8.93-9.46** / 10.99-11.28 | 2828 | 21.1 px, 1 |
| 30 × 300 | colliding | 13.49-13.72 / 14.56-16.92 | **4.49-4.58** / 5.47-6.37 | 166 | 0.2 px, 0 |
| 30 × 300 | swimming | 16.94-17.52 / 19.11-21.06 | **5.59-5.91** / 7.04-7.39 | 1722 | 0.0 px, 1 |

The ring colony (frozen topology, docs/colony-frozen.md) at 30 × 150 on 4 threads: 4.8 ms
colliding, 7.4 ms swimming. **One particle per cell is 1.9 × cheaper colliding and 2.2 ×
swimming at 30 × 150, and 60 × 150 costs less than the rings' 30 × 150.** 100 × 150 fits the
10 ms gate on 4 threads (7.1 / 9.2 ms median) but its p95 swimming crosses it (11.0-11.3).

Where the time goes (30 × 150 colliding, 1 thread, per frame): the per-creature solve
5.4 ms (links: three constraints × about 405 links per creature × 6 substeps: about 25 ns a
constraint), the frame's preparation 1.1 ms (rest values, forces, drag, walls, the own-contact
Verlet list: 0.65 of it), the broad phase 0.08, the contacts between creatures 0.01 (serial;
they stay cheap because only boundary cells collide), velocities and breaks 0.03. Swimming
adds the pose wave (0.04 ms per creature a frame) and more own candidates. The solve
dominates and is what threads divide; serial parts are under 0.3 ms even at 100 creatures.

Options:

| 30 × 150 colliding, 4 threads | median / p95 (ms) |
|---|---|
| 4 / 6 / 8 / 10 substeps | 1.83-1.94 / 2.45-2.57 / 3.06-3.17 / 3.78-3.82 (p95 2.40-2.79 / 3.07-3.65 / 3.75-4.28 / 4.75-5.30) |
| shape matching instead of oriented links | 1.70-1.82 / 2.19-2.85 (1 thread 3.98-4.05) |
| shape matching, swimming | 3.01-3.04 / 3.80-4.23 (1 thread 8.05-8.33) |
| own contacts off | 2.2 median (an earlier build; the Verlet list costs about 0.2 ms on 4 threads) |
| free-form 14 px / mixed 14..44 px designs (an earlier build, ±0.1 ms) | 2.37-2.49 / 2.23-2.54 |

**Substeps**: 4 are enough for collisions (crashes at 600 px/s and the tunnel test at
3000 px/s stay sound, the crowd too) and cost 25 % less; swimming loses 25 % of its speed at 4
(the pose is held less firmly), 8 gain 2 %. 6 is the recommendation; 4 for a game that swims
mostly by thrust.

**Drawing set-up**: every creature's skin (outline surface, two Chaikin passes) for 30 ×
150: 0.04 ms (1 thread), 100 × 150: 0.16 ms. The per-cell discs and type capsules of the
pictures are drawn with `draw_circle` / `draw_line` in GDScript, not measured (a game would use
one mesh or a MultiMesh per creature).


## The look

`tools/cells_shot.gd` (pictures listed at the end). A creature's **skin** is its outline
surface (each boundary cell pushed out by its radius along the outline's normal), smoothed by
two Chaikin passes and filled; inside it every cell is a disc of its type's colour at 0.82 of
its radius, and every link between two cells of one type a capsule of that colour 1.4 × the
smaller radius wide, so **a run of one type reads as one piece** (cells_types.png: a blue spine,
a yellow core and a red rim region read as three shapes, not 30 discs). Building every skin
of 30 × 150 creatures costs 0.04 ms on 1 thread (0.2 ms on 4: the thread hand-off costs more
than the work).

What it looks like, honestly: a worm mid-swim (cells_worm.png) is one smooth sausage with a
travelling bend, the cells invisible under the skin; its ends are a little lumpy (the hex
ends). A crash (cells_crash_3.png) shows two hexagons each flattened along the contact face;
nothing squashes per cell: the aggregate bends instead, and with stiff links it is subtle
(0.35 radius of RMS change). The ragged cluster after tension (cells_ragged_0/5.png) has its
hex steps smoothed and its lobes a little rounder; its shape is the same shape. The squeeze
(cells_squeeze_soft.png) reads well as goo pushing through a slit, but the skin is drawn over
the wall by up to two radii at the sharp concave corners (the outline normal there averages
two edges: an artefact of offsetting the outline). The mixed creature (cells_mixed.png) shows
the packing's holes as dark pockets inside the skin and big cells as blobs joined by
capsules: busy; a metaball or SDF pass over the cells would read better and is the obvious
next step (not built). Thirty worms swimming in an arena (cells_crowd.png) read clearly as
thirty animals.


## Quirks

Everything a game built on this would meet (measured above unless marked):

1. **Spawned overlapping, tangled for good.** Only boundary cells collide with other
   creatures, so cells that start inside another creature are never pushed out (a bench bug
   placed long worms overlapping: 666 cells stayed inside for the whole run). Spawn apart, or
   ease new creatures in from a small size; `collide_all` halves it but does not fix it.
2. **Soft contacts let cells in.** A contact compliance (Primordialis' penalty force) lets
   boundary cells pass between the other's boundary cells at speed and stay inside (600 px/s:
   66 cells). Keep contacts rigid, or collide every cell.
3. **Muscles beat contacts.** A stiff pose pressing into a neighbour wins half the time:
   swimming crowds go 12-25 px deep into each other now and then (cells rarely end inside).
4. **Gaps jam.** Stiff creatures jam even at 0.8 of their width; soft ones (6 / 2 Hz) pass 0.6
   and recover; nothing passes 0.45 (fixed topology). Plasticity does not help (stiff links
   never strain enough), break-and-rejoin shatters the creature.
5. **Surface tension only rounds what flows.** With stiff links it is a squeeze too small to
   see; rounding needs soft, creeping links (and then the creature forgets its shape).
6. **Swimming loads exceed crash loads.** The pose muscles load links more (2.9e8) than a
   600 px/s crash (1.1e8): one break force cannot separate the two; break forces need per-type
   factors or a load that leaves out the muscles' share (not built).
7. **No friction.** Creatures slide off each other freely (snag 0.92-1.03 of free sliding);
   nothing grips or interlocks; a game wanting grip needs a friction term or anchor cells.
8. **Very inelastic.** Two 91-cell creatures meeting at 2 × 600 px/s leave at 2 × 57 px/s; walls
   return 5-9 %. No energy gain was seen anywhere (no explosion in any run; not finite 0).
9. **Swimming has a sweet spot.** Speed per cycle falls with frequency above the body's drag
   time constant (30 × 5: 0.270 at 0.5 Hz, 0.126 at 1 Hz, 0.077 at 2 Hz), with body length at a
   fixed frequency, for two-row bodies (0.067) and irregular mixed-size bodies (0.016); blobs
   cannot undulate. Drag on faces into the flow only (Primordialis) swims 40 % slower.
10. **Commanded curls are clamped.** The pose wave never squeezes a side below half its length
    (a tighter command is silently limited; an undrawable pose would explode).
11. **Own contacts leave out pairs two links apart**, so a bent pose may overlap those (by
    design); with mixed sizes a small cell between two large ones overlaps 10-12 px on impact.
    The Verlet list's margin assumes the frame's speeds; an impulse far above them between
    rebuilds could miss (a 1.2 × margin missed a curl; 2 × did not).
12. **Floating point drift.** Linear momentum is conserved to f32 rounding: under a standing
    load (tension) a creature creeps at 0.01-0.17 px/s; angular momentum drifts O(h) (0.6 %
    in 4 s in the cargo test) as in any position-based solver. The speed cap (3000 px/s) breaks
    momentum when hit.
13. **Stiffness costs substeps for swimming only**: 4 substeps lose 25 % swim speed.
14. **Shape matching** has no spin of its own (headings come from the neighbourhood's fit),
    held a swimming crowd less well (37 cells inside, 4.9 px into a wall, one run) and cannot
    bend one joint.
15. **Ids move.** Creature ids are slots (a merged creature's slot dies, a split part gets a new
    one); cell indices change at every topology change: track cells by uid.
16. **Topology changes cost a rebuild of the creature touched**: about 4 µs per cell (a join
    that chains creatures into a big one: 15 ms for 25 links over 30 creatures).
17. **The skin overshoots at sharp concave corners** (drawn over a wall by up to two radii in
    the squeeze); individual cells never squash, only the aggregate bends.
18. **Spawning inside other creatures launches** (the overlap is solved in one substep;
    reconstructed from Primordialis' notes and seen in the first, overlapping bench runs; not
    measured further).


## Recommendation

**Switch the creatures to one particle per cell.** On what the user ranks first it is
better on every count measured: undulation alone swims 0.2-0.3 body lengths per cycle against
the rings' 0.02-0.07 (3-10 ×), a worm holds station in a 60 px/s current within 0.03 body
lengths, turning by gait, twist and seeker pairs all work; collisions between creatures are
semi-solid and sound (no tunnelling at 3000 px/s, no interpenetration of colliding crowds, the
aggregate squashes and recovers in under half a second); and it costs about half as much
(30 × 150: 2.6 ms colliding / 3.4 swimming on 4 threads against 4.8 / 7.4), leaving room for
60 × 150 (4.5 / 5.8 ms) and, at the gate's edge, 100 × 150 (7.1 / 9.2 ms median). What it gives
up is the individual cell's squash and its round skin, which the ring model does for real and
this one can only draw; the user's words put aggregate behaviour above that.

Keep rings where a single cell's deformation is the point (the existing Goo2D bodies, a
creature of one to a few cells). A mixed model (a ring skin only on the outline) is **not**
recommended: the outline skin is a drawing problem solved by drawing (the outline surface,
smoothed, and per-type regions), not physics, and a ring outline would bring back the rings'
cost and their weak swimming.

Within the model:

- **Bending**: shape matching as the default body (half the solve, better shape memory);
  oriented links where a game wants joints (hinges, per-joint muscles, soft joints, per-type
  bendiness). Both share the links, the outline and everything else; a per-link or per-type
  switch between them is the natural finished form (not built: today it is global).
- **Propulsion**: the pose wave (a curvature wave over the design) is the swimmer's muscle;
  radius muscles (Primordialis') work nearly as well and are the right tool for single-cell
  muscles; thrust cells for blobs. Use a drag ratio of 20 (the fluid game's 7.5-10 swims
  20-30 % slower).
- **Collisions**: boundary discs, rigid; outline capsules for crowds of swimmers (a little
  dearer); `SELF_FAR` own contacts on a 4-frame Verlet list.
- **Squeezing**: soft types (6 / 2 Hz) or gaps no narrower than 0.6.
- **Topology**: breaks with per-type factors and a load that excludes muscles; joins only at
  retopologies the game asks for (finding is cheap, merging costs a rebuild); new cells eased.

**What the port to a finished feature would cost** (an estimate, not measured): the solver is
most of the work and exists (about 2400 lines of Rust here). A finished feature needs, in
roughly this order: (1) walls from GooStatics' convex pieces and tile layers instead of the
prototype's 8-point polygons, and a water velocity field (the fluid game's FlowField) per
cell instead of one current: a few days; (2) a node API (a GooCreature2D or a world node owning
a GooCells, creatures from designs or scenes, signals, uids) and an editor-friendly design
format: about a week; (3) drawing: one mesh per creature from the skin and the type regions,
or a metaball / SDF shader over the cells (the pictures here are GDScript `draw_*` calls): about
a week, more to look good; (4) per-type bending model and break loads without the muscles'
share, friction or anchors if wanted, rounding by retopology: days each; (5) tests and docs at
the colony's standard. Several weeks of the kind of sessions that built the colony milestones,
and none of it blocked on a research question.


## Pictures

Under `/tmp/claude-0/-home-user/2286a381-de4b-5b28-80dc-08ea5f8bb39d/scratchpad/cells/` (not committed;
`tools/cells_shot.gd OUT_DIR` makes them again): `cells_worm.png` (a 24 × 5 worm and a tadpole
swimming), `cells_crowd.png` (30 worms), `cells_crash_3.png` and `_90` (91 + 91 at 600 px/s
each, 0.05 s and 1.5 s after contact; `_debug` variants with links, outline and cell rims),
`cells_ragged_0.png` / `_5` (tension), `cells_squeeze_stiff.png` / `_soft`, `cells_mixed.png`,
`cells_types.png`.

## Limits of this exploration

- One machine, one core count (4); timings are wall clock around `step()`.
- The station-keeping and seeker controllers are scripts in the tools, simple and untuned.
- The pose wave's design frame is the world's at the build: a creature added turned must be
  given its axis turned (the tools do).
- Not built: jets, per-cell water velocities, link force caps, friction, per-type choice of
  bending model, a load without the muscles' share, rounding by retopology, a metaball or SDF
  look, GooStatics walls, jointed links between creatures (two creatures can be joined into
  one; a hinge between them would be oriented links with a soft bend, untested).
