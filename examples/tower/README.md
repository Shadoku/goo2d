# tower: stack stiff goo blocks above a line

Run it with `godot --path . examples/tower/tower.tscn`.

A tower-building minigame. Square goo blocks drop from a hopper onto a narrow platform that
stands on a wide floor; stack them until the tower stands above the goal line. The goo is
the addon's, made stiff for this one world with `GooWorld2D.tuning_for()`: the blocks still
squash a little as they land and wobble when hit, but a stack of them stands.

## Rules

- Every block is a square, `GooShape.regular(4, block_radius)` (44 px: a square of about
  78 px a side), in the next colour of a five-colour palette (`TowerExample.PALETTE`,
  `Goo2D.color`).
- Blocks never merge (`TowerWorld.may_merge()` returns false). Tick `allow_merging` on the
  World to try the fused variant: squares then fuse flat face to flat face by the addon's
  default rule, and a stack becomes one tall body.
- A block whose centre is outside the platform's x range and more than 60 px
  (`TowerWorld.DESPAWN_DEPTH`) below its top has fallen off: it is despawned
  (`GooWorld2D.despawn()`, so `count_changed` reports it). So is anything below the screen
  (`OUT_Y`).
- The stack is the blocks resting (`Goo2D.settled`, or slower than 40 px/s) on the platform
  or on a block of the stack, found every physics frame from their bead bounds
  (`TowerWorld.stack()`); its height is its topmost bead's edge above the platform's top
  (`tower_height()`). The label shows it against the goal line's height.
- The game is won when the stack's top is above the goal line with every body settled, or
  has stayed above it for `WIN_HOLD` (1 s) while something still moves. `TowerWorld.won`
  fires once; the goal line turns green, a banner and the label say so, and the hopper stops
  until R.

## Controls

| Input | Does |
|---|---|
| Click | drop a block at the mouse's x (clamped into the hopper's range) |
| Space | drop a block at the hopper's centre |
| R | empty the world, clear the win, start the colours over |

A new block can drop 0.8 s after the last (`DROP_INTERVAL`). With `demo` on (the default),
the scene drops `demo_blocks` (4) blocks near the centre on its own at the start, each once
the last rests on the stack, so a screenshot or an idle player sees a tower one block short
of the goal; the first click or key stops it. `rng` (seeded in the tests) draws the demo's
few pixels of jitter.

## What a designer edits where

Everything is a node in `tower.tscn`; the `@tool` scripts draw it in the editor as in the
game.

| Node | Script | Edit |
|---|---|---|
| `Floor`, `Platform` | `slab.gd` (`TowerSlab`, a `StaticBody2D` on layer 1) | the size and position of the `Shape` child's `RectangleShape2D` (the drawing follows; GooStatics mirrors the same rectangle for the goo); `color`, `edge_color`. A narrower platform is harder |
| `GoalLine` | `goal_line.gd` (`TowerGoalLine`) | its y (move it up or down: the goal), `width`, `label` text, `color` |
| `Hopper` | `hopper.gd` (`TowerHopper`) | its position (blocks drop from its y), `width` (the range a click can drop in), `block_radius` (the size of every block; the outline it draws is the next block) |
| `World` | `tower_world.gd` (`TowerWorld`) | `stiffness`, `shape_hold`, `air_drag`, `friction`, `bounce` (below), `allow_merging`; `platform_path` and `goal_line_path`, the exported `NodePath`s through which it finds the platform and the goal line |
| `Tower` (root) | `tower.gd` (`TowerExample`) | `demo`, `demo_blocks` |

## Stiffness: what stands

`TowerWorld.tuning_for()` calls `super()` (GooTuning's tuning of the square) and changes:

| Key | Becomes | Default |
|---|---|---|
| `skin_stiffness`, `bending_stiffness` | × `stiffness` | 4 |
| `skin_damping`, `bending_damping` | × √`stiffness` (a spring's damping ratio is c / 2√(km), so it stays GooTuning's) | |
| `shape_match_k` | × `stiffness` × `shape_hold` (a gain in the kernel, not a fraction: a compliant pull, `k h² / (1 + k h²)` per substep, stable at any value) | 2.5 |
| `pressure_k` | × `stiffness`, at most × 5 (`MAX_PRESSURE_SCALE`) | |
| `linear_damp` | `air_drag` (GooTuning's is 0.39 for this size) | 2 |
| `friction` | `friction` (GooTuning's 0.2) | 1 |
| `bounce` | `bounce` (GooTuning's 0.36 for this size) | 0 |

`bead_count`, `bead_radius`, `spacing` and `target_area` stay GooTuning's.

Measured with `TowerWorld` in this scene's geometry (200 px platform, hopper 570 px above
it): blocks dropped from the hopper one at a time at the platform's centre ± 4 px (seeded),
each once every body had settled (at most 4 s), until the stack lost a block. The table
gives the most blocks that stood, for eight seeds; the friction, bounce and drag are the
defaults above unless the row says otherwise.

| `stiffness` | `shape_hold` | other | blocks that stood (8 seeds) | splits |
|---|---|---|---|---|
| 1 | 1 | GooTuning's friction, bounce and drag: the plain goo | 1 1 1 1 1 1 1 1 | 0 |
| 1 | 1 | | 2 2 2 2 4 2 2 4 | 7 |
| 2 | 1 | | 4 3 4 4 3 4 3 3 | 4 |
| 4 | 1 | | 3 3 3 4 4 3 4 3 | 0 |
| 6 | 1 | | 4 4 4 6 6 4 6 4 | 0 |
| 3 | 2 | | 4 4 4 5 6 4 6 4 | 0 |
| 4 | 2 | | 5 5 5 7 7 4 6 5 | 0 |
| **4** | **2.5** | **the defaults** | **5 6 5 7 7 5 7 6** | 0 |
| 4 | 3 | | 6 6 6 8 8 5 8 7 | 0 |
| 4 | 4 | | 7 8 8 7 8 7 5 8 | 0 |
| 4 | 2.5 | `friction` 0.2 | 5 5 6 2 6 5 6 5 | 0 |
| 4 | 2.5 | `bounce` 0.36 | 5 5 5 7 7 5 7 6 | 0 |
| 4 | 2.5 | `air_drag` 0 | 2 1 3 1 2 2 3 3 | 0 |
| 8 | 1 | (pressure × 8, before the cap) | a resting block blew apart within a second | |

What the numbers say:

- **Shape matching is what makes a stack stand.** A square's skin keeps its edge lengths, not
  its angles: under the blocks above it, it shears into a rhombus, the stack leans, and the lean
  grows over a second or two until the stack topples. Stiffening everything alike
  (`shape_hold` 1) stood 3-4 blocks at 4×, 4-6 at 6×; shape matching 10× (4 × 2.5) stands 5-7.
- **Air drag is what lets a block land from the hopper.** Without it a block falls the 530 px
  to the platform at about 1000 px/s and knocks the stack over; `air_drag` 2 holds a fall to
  about 470 px/s. Dropped from 30 px above the stack instead, the same blocks without drag
  stood 5 5 5 7 6 4 6 5: the drag is for the fall, not for the stack.
- Friction and bounce matter little once the blocks land slowly; friction 1 keeps a block from
  sliding off the one below while a stack sways.
- The pressure is an explicit force, so it is capped: at 8× a resting block blew apart.
- The plain goo never stood two blocks. At 1× with the tower's drag, friction and
  bounce, blocks split on landing (7 splits in 8 games); at 2× still now and then.

The goal line sits 350 px above the platform (4.5 block sides): five blocks. Dropped at the
centre (Space) with care, five stand in every seed above; the demo's four leave the last one to
the player. Aiming matters: a block landing a quarter of a side (19 px) off a stack of three
brings the stack's top block down with it (3 of 4 seeds); a third of a side (27 px) off, it slides
off alone (3 of 4) or takes the top block with it; half a side off, it always slides off. With
the drop point scattered ± 10 px the stacks stood 2-6 blocks, ± 20 px 2-4. Dropping before the
stack has settled is a gamble.

## Addon hooks used

- `GooWorld2D.tuning_for()` (stiffer, deader blocks in this world only),
  `GooWorld2D.may_merge()` (off) and `merged_color()` (for `allow_merging`).
- `GooWorld2D.spawn()` with `GooShape.regular(4, r)`, `Goo2D.color`, `GooWorld2D.despawn()`,
  `count_changed`, `clear()`.
- `Goo2D.settled`, `average_velocity()`, `bead_bounds()`, `bead_radius()` to find the stack
  and measure it.
- `GooTuning.LAYER_WALLS` for the slabs, `GooSkin.warm_up()` for the goo shader.

## Notes

- `Goo2D.settled` is reliable for a stack but slow: the kernel settles a whole contact group
  at once, so the drop of a third block onto two takes 5.0 s to a settled stack, against 2.9 s
  for the first block alone (the fall is about 1.2 s of each). The win therefore also counts after `WIN_HOLD` with the stack resting
  (each block under 40 px/s), not only when everything has settled.
- Despawning a block from the middle of a settled stack is clean: the blocks above wake and
  fall onto the ones below.
- A block falling past the goal line does not count: it is not resting and not part of the
  stack until it lands on it.

## Tests

`tests/integration/examples/test_tower.gd`: the scene boots with its parts and the demo; blocks
are squares tuned `stiffness` × GooTuning's; two stacked blocks do not merge in 3 s (and do with
`allow_merging`); a block dropped beside the platform is despawned and `count_changed` reports
it; a tower of three blocks dropped one at a time at the centre above a low goal line fires `won`
exactly once and the label says so; R (`reset()`) empties the world and clears the win, and the
game can be won again.
