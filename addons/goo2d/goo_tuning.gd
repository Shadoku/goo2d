class_name GooTuning
extends RefCounted
## Every size-dependent number of the goo: how it feels, how big it gets and
## what colour it is. A body is described by its nominal radius in px, anywhere
## from min_radius() to max_radius(), and most functions here take that radius
## and lerp between a small and a large value over size_t(), a log scale of it.
## Every number is tuned in screen pixels at `unit` 1; `unit` scales each
## absolute length, speed and acceleration of the goo, so a game drawn at
## another scale gets the same goo at that scale (see `unit`).
## Three sections, top to bottom:
## - Sizes: the length unit, the size range, size_t() and radius_at(), colour
##   by size and the merge-by-size rule (can_merge(), merged_radius()).
## - Bead physics by size: each bead's mass, joint frequency and damping
##   ratio, linear damping, bounce, friction and wall grip, the wall layer
##   and the merge flash; the solver's knobs (substeps, contact
##   slop, waking, the bead speed cap) and the GooKernel made with them (make_kernel()).
## - The pressure ring: bead count and size, spring constants, pressure,
##   shape matching, internal damping, settling and split thresholds;
##   tuning() bundles everything a round body's setup needs, and tuning_for()
##   the same for a body of any GooShape.

# ---- Sizes ----
# Sizes are continuous: size-dependent tuning lerps over size_t(), a log scale
# of the radius, and colour runs from red (smallest) through orange, yellow,
# green and cyan to blue (largest). Two bodies merge when their radii are
# within MERGE_TOLERANCE of each other, into one that holds their combined area.

## Pixels per tuned pixel: the length unit of the goo. The goo is tuned in
## pixels at 1.0 (the default); at 0.5 every absolute length the goo uses is
## half (the size range, min_radius() … max_radius(), and so every bead, gap and
## threshold that follows a body's radius), and so is every absolute speed and
## acceleration (gravity(), settle_speed(), solver_settings()'s slop, waking,
## speed cap and UNTANGLE_SEPARATION_SPEED, GooWorld2D.MERGE_PULL and
## SPLIT_GAP, Goo2D.MERGE_GROW, GooSkin.MAX_SPEED), while masses, times,
## frequencies and ratios are kept: a body of half the radius then moves as
## the body of the full radius does at unit 1, the same picture at half the
## size (the addon README's "what `unit` scales" lists every value and the
## measured gate). Set it once, before any body or GooWorld2D exists: a
## GooKernel takes solver_settings() when it is made (make_kernel()), and a
## body its tuning when it is built.
static var unit: float = 1.0

## Radius, in px at unit 1, of the smallest blob: min_radius() is this × unit,
## and the size anchors are read through it.
const MIN_RADIUS := 28.0
## Radius, in px at unit 1, of the largest blob: max_radius() is this × unit.
const MAX_RADIUS := 176.0
## Two blobs merge when the smaller radius is at least (1 - this) times the larger.
const MERGE_TOLERANCE := 0.15

## Radius, in px, of the smallest blob: MIN_RADIUS × unit; size_t() is 0 here.
static func min_radius() -> float:
	return MIN_RADIUS * unit

## Radius, in px, of the largest blob: MAX_RADIUS × unit; size_t() is 1 here
## and nothing merges past it.
static func max_radius() -> float:
	return MAX_RADIUS * unit

## Where `radius` sits between min_radius() (0) and max_radius() (1) on a log
## scale, clamped to 0..1. The old fixed sizes were 28 × 1.3^n, n = 0..7, so
## size n of those maps to n / 7 (at unit 1).
static func size_t(radius: float) -> float:
	if radius <= 0.0:
		return 0.0
	var smallest := min_radius()
	return clampf(log(radius / smallest) / log(max_radius() / smallest), 0.0, 1.0)

## The radius, in px, whose size_t() is `t` (clamped to 0..1).
static func radius_at(t: float) -> float:
	var smallest := min_radius()
	return smallest * pow(max_radius() / smallest, clampf(t, 0.0, 1.0))

## Solid colour of a blob of `radius`: hue 0 (red) for the smallest, 2/3
## (blue) for the largest.
static func color(radius: float) -> Color:
	return Color.from_hsv(lerpf(0.0, 240.0 / 360.0, size_t(radius)), 0.85, 0.95)

## True if blobs of `radius_a` and `radius_b` merge: both real, within
## MERGE_TOLERANCE of each other, and the result no bigger than max_radius().
## The rule for two round blobs; GooWorld2D.can_merge() decides for any pair.
static func can_merge(radius_a: float, radius_b: float) -> bool:
	if radius_a <= 0.0 or radius_b <= 0.0:
		return false
	if minf(radius_a, radius_b) < (1.0 - MERGE_TOLERANCE) * maxf(radius_a, radius_b):
		return false
	return merged_radius(radius_a, radius_b) <= max_radius()

## Radius of the blob merged from blobs of `radius_a` and `radius_b`: their
## areas add up.
static func merged_radius(radius_a: float, radius_b: float) -> float:
	return sqrt(radius_a * radius_a + radius_b * radius_b)

# ---- Bead physics by size ----
# What each bead of a body of a given size is made of in the kernel's solver:
# its mass, the frequency and damping of the constraints between beads (as
# springs: the solver's compliance is 1 / stiffness), its damping, bounce and
# friction. A contact between a bead and another bead or a static shape uses
# the lower of the two frictions and the sum of the two bounces, clamped to
# 0..1 (the rules the tuning was first found with, kept by the solver).

## Natural frequency, in rad/s, of the joints of the smallest and of the
## largest blob. Big blobs are squishier. A pressure ring's skin springs run at
## SKIN_FREQUENCY_RATIO times this.
const JOINT_FREQUENCY_SMALL: float = 20.0
const JOINT_FREQUENCY_LARGE: float = 1.0
## Damping ratio of the joints of the smallest and of the largest blob. A blob's
## rebound comes from its joints springing back, not only from the particles'
## restitution, so low damping is what makes small blobs bouncy; big blobs are
## damped more so they land with a thud and do not wobble.
const JOINT_DAMPING_SMALL: float = 0.05
const JOINT_DAMPING_LARGE: float = 0.25
## Coulomb friction of each bead. A contact uses the lower of the two
## frictions, so this is also the friction blobs get against a wall with more
## (the demo's Arena has 0.4); what holds goo on a wall is WALL_GRIP_DAMP.
const BLOB_FRICTION: float = 0.2
## Wall grip: extra linear damping, per second, the solver gives a bead while
## it touches a static shape that grips (any on LAYER_WALLS not in
## NO_GRIP_GROUP; Goo2D.bead_gripping()). On top of the contact's friction it
## makes goo cling to walls and floors: a blob slides down a wall slowly
## instead of dropping, and a landing blob stops rather than skidding. 0 turns
## the grip off.
const WALL_GRIP_DAMP: float = 3.0
## Group of the StaticBody2D bodies the goo does not grip (no WALL_GRIP_DAMP
## while a bead touches one): sharp things a body should slide off rather than
## hang on, such as the demo's blades. A body grazing a gripping tip stopped
## on it and could stay there with the tip between its beads.
const NO_GRIP_GROUP: StringName = &"goo_no_grip"

## The physics layer bit of the static geometry the goo collides with: GooStatics
## mirrors every StaticBody2D whose collision_layer has it into the kernel. The
## goo has no physics bodies of its own, so this is the only layer it uses.
const LAYER_WALLS: int = 1

## Substeps of the kernel's solver per physics frame (60 Hz): each predicts,
## constrains and collides every awake bead once. More converge the contacts
## and stiff constraints better and cost about linearly.
const SUBSTEPS: int = 6
## Most substeps a frame takes while something moves fast: the solver adds
## substeps until no bead moves more than its radius in one (so it cannot step
## through another bead), up to this.
const MAX_SUBSTEPS: int = 12
## Pixels (at unit 1; solver_settings() scales it by unit) within which two
## beads, or a bead and a static shape, count as touching (`touched`, the wall
## grip) without being pushed apart.
const TOUCH_SLOP: float = 1.0
## A contact wakes a settled ring when a bead presses into it by more than
## WAKE_DEPTH px or closes on it faster than WAKE_SPEED px/s (both at unit 1,
## scaled by unit in solver_settings()); anything gentler (a calm neighbour's
## weight) leaves it asleep, as if it were static.
const WAKE_DEPTH: float = 0.5
const WAKE_SPEED: float = 30.0
## The Untangler's push on two rings deep inside each other
## (GooWorld2D.Untangler, run by the world's kernel): an acceleration, px/s²,
## per pixel of nominal overlap, up to UNTANGLE_SEPARATION_SPEED. Rings deep
## inside each other in a pile, or falling together, must part within a few
## frames or contacts and load drive them back in. Measured on bench.gd's
## pile40 and mixed40 over three seeds (pair-samples inside each other per
## run): 100 left 41-47 and 57-59, 200 left 24-28 and 40-45, 400 left 16-19 and
## 23-39, and 19-25 and 38-56 with UNTANGLE_SEPARATION_SPEED 800 (300 gave
## 35-52 and 66-102). 20, the old gentle push, let pairs sit inside each other
## for a second or more. Its unit is 1/s² (the overlap's pixels cancel the
## acceleration's), so `unit` leaves it alone.
const UNTANGLE_STRENGTH: float = 400.0
## Speed, px/s at unit 1 (solver_settings() scales it by unit), at which the
## Untangler stops adding to the pair's parting along the centre line: without
## it a strong push on a deep overlap would fling the two apart at over 1000
## px/s.
const UNTANGLE_SEPARATION_SPEED: float = 1600.0
## The fastest any bead may move, px/s at unit 1 (solver_settings() scales it
## by unit): the kernel clamps every bead's velocity
## to this after each substep's velocity update, and every velocity set from
## GDScript (Goo2D.set_velocity(), set_bead_velocity(), apply_impulse()). It is
## above anything normal play produces (a thrown blob is at most
## DropController.MAX_LAUNCH_SPEED, 1600; impacts and bounces stay under about
## 2500) and below what a ring built wrong reaches (4000-8000, when its rest
## edges do not fit its loop): a cap on the energy such a ring can hand its
## neighbours, never felt in play. 0 turns it off.
const MAX_BEAD_SPEED: float = 3000.0
## The grab's spring (GooWorld2D.grab()): the acceleration, px/s², per px a
## held bead of weight 1 is off its place by the grab point. Its unit is 1/s²
## (the pixels cancel), so `unit` leaves it alone. Solved implicitly once a
## frame, so any stiffness is stable; 3600 (60 rad/s): a 40 px body held by
## its top bead and dragged 160 px over 15 frames is within a bead radius
## (11 px) of the point when it stops and, held there, its grab point within
## 2 px of it (tests/integration/test_goo_grab.gd); dragged at 600 px/s its
## grab point trails the point by 7-18 px.
const GRAB_STIFFNESS: float = 3600.0
## The grab's damping, 1/s, for a held bead of weight 1: 2 × √GRAB_STIFFNESS,
## critically damped (no overshoot when the point stops). A bead of weight w
## gets GRAB_STIFFNESS × w and GRAB_DAMPING × √w, critical too.
const GRAB_DAMPING: float = 120.0
## How far beyond the bead nearest the grab point, as a fraction of the body's
## radius, the grab still holds beads, with a weight falling from 1 (that bead)
## to 0 (this far beyond it): a grab at the rim holds the rim around it (about
## a third of the ring) and the rest of the body dangles from it; one at the
## centre holds every bead. Measured in the demo's arena dragging round bodies
## of 28-100 px by their top bead at 600 px/s along six paths (24 drags),
## before GRAB_CARRY: 0.3 tore 6 (bodies of 40 px and up: too few beads carry
## the rest, which necks below them) and trailed twice as far, 0.8 one.
const GRAB_REACH: float = 0.8
## How much of the velocity change the grab's spring gives its held beads as
## a whole the beads it does not hold get too (0..1): the rest of the ring
## carried a little with the hold, so a fast drag does not tear it off the
## held beads, while held still it hangs from them under gravity. Measured in
## the demo's arena dragging round bodies of 28-100 px by their top bead along
## six paths: at 1500 px/s, 0 tore 16 of 24, 0.15 tore 7, 0.3 tore 2 (both
## shaken from side to side); at 600 px/s 0.3 tore none of 24 round and 24
## square ones. On the title screen (unit 0.5), dragged by their top at 800
## canvas px/s, 0 tore its square, pentagon and triangle, 0.3 none of its
## blobs, which hang 1.05-1.4 × as tall as they rest.
const GRAB_CARRY: float = 0.3

# ---- Links (GooWorld2D.link(), GooLink) ----
# A link ties a patch of beads on one body to a patch on another, pair by pair,
# with compliant distance constraints and an angular term (the kernel's
# links.rs). Its stiffnesses are per reduced mass (1/s², like the grab's) and
# its sizes are fractions of the bodies' radii or bead radii, so `unit` leaves
# every one of them alone.

## The pairs' stiffness, px/s² per px a pair is off its rest length, per
## reduced bead mass (a frequency squared: 1/s²). XPBD, so any value is stable.
const LINK_STIFFNESS: float = 20000.0
## The pairs' damping, 1/s per reduced bead mass.
const LINK_DAMPING: float = 80.0
## The angular term's stiffness at strength 1, 1/s² per reduced moment of
## inertia: how hard the bodies' relative rotation is pulled toward the link's
## rest angle (scaled by the strength: a thread bends freely).
const LINK_BEND_STIFFNESS: float = 600.0
## The angular term's damping at strength 1, 1/s (× √strength).
const LINK_BEND_DAMPING: float = 30.0
## How wide the tied patch is at strength 1, as a fraction of the smaller
## body's radius (strength scales it: at 0.1 one pair, a thread).
const LINK_PATCH_RATIO: float = 1.0
## The gap between the tied beads' centres at rest, in sums of their bead
## radii: 1, the two collision outlines just touching at the neck (the bridge
## skin fills the waist), so the beads beside the patch, which still collide,
## do not push against the link at rest.
const LINK_GAP: float = 1.0
## The shortest a pair's rest length gets (a rest angle closing one side of
## the neck), in sums of the two bead radii.
const LINK_MIN_REST: float = 0.25
## Beads beyond each end of a tied patch that pass through the other body's
## patch too. 0: only the tied beads pass through each other (the neck does
## not fight itself); every other bead collides, which keeps the bodies from
## folding into each other (at 2, half of a strong link's ring passed through
## and a pulled pair could settle overlapping, its patches crossed).
const LINK_THROUGH_BEADS: int = 0
## Seconds a new link takes at least to ease from where its bodies are into
## its rest pose: bodies linked apart are drawn together, not snapped.
const LINK_EASE_TIME: float = 0.3
## The fastest, px/s at unit 1 (link_ease_speed() scales it), a new link draws
## bodies linked apart together: its ease takes longer for a longer way.
const LINK_EASE_SPEED: float = 300.0

## Seconds a merged blob takes to fade from its flash to its colour.
const MERGE_FLASH: float = 0.2
## How far toward white a merged ring starts its MERGE_FLASH: its inflating is
## the main merge cue, so the flash is a light one.
const MERGE_FLASH_BLEND: float = 0.4

## Mass of each particle of a blob of `radius`: bigger blobs are heavier per
## particle, so they push smaller ones around instead of being lifted by them.
## 0.2 for the smallest blob, 1.6 for the largest.
static func particle_mass(radius: float) -> float:
	return 0.2 * (1.0 + 7.0 * size_t(radius))

## Natural frequency, in rad/s, the joints of a blob of `radius` spring back with.
static func joint_frequency(radius: float) -> float:
	return lerpf(JOINT_FREQUENCY_SMALL, JOINT_FREQUENCY_LARGE, size_t(radius))

## Damping ratio of the joints of a blob of `radius` (1 is critically damped).
static func joint_damping_ratio(radius: float) -> float:
	return lerpf(JOINT_DAMPING_SMALL, JOINT_DAMPING_LARGE, size_t(radius))

## Linear damping of each particle of a blob of `radius`: settles small blobs'
## wobble while letting big ones fall without feeling floaty. 0.5 for the
## smallest, falling to a floor of 0.1.
static func linear_damp(radius: float) -> float:
	return maxf(0.1, 0.5 - 0.42 * size_t(radius))

## Restitution of each particle of a blob of `radius`: small blobs are bouncier.
## A contact adds the two bounces (clamped to 0..1), so the wall's bounce adds
## to this. It acts per particle, and a pressure ring lands on a few
## beads at a time, so its rebound leans on this as well as on its springs
## (joint_damping_ratio()): the smallest ring needs 0.45 (with the wall's 0.3)
## to rebound visibly, 0.3 left it near 33 px from a 500 px drop. Two of the
## smallest blobs together stay under 1.0, so blob-on-blob contacts still lose
## energy.
static func bounce(radius: float) -> float:
	return lerpf(0.45, 0.1, size_t(radius))

## The solver's knobs as GooKernel.set_solver() takes them: SUBSTEPS,
## MAX_SUBSTEPS, the gravity vector (gravity(), unit included, along the
## project's default gravity direction), the project's default linear damping
## (which every body had on top of its own under Godot's physics),
## WALL_GRIP_DAMP, TOUCH_SLOP, WAKE_DEPTH, WAKE_SPEED and MAX_BEAD_SPEED (the
## last four × unit), UNTANGLE_STRENGTH (kept: an acceleration per pixel of
## overlap, the overlap shrinks with the unit and the push with it) and
## UNTANGLE_SEPARATION_SPEED (× unit).
static func solver_settings() -> Dictionary:
	var direction: Vector2 = ProjectSettings.get_setting("physics/2d/default_gravity_vector", Vector2.DOWN)
	return {
		"substeps": SUBSTEPS,
		"max_substeps": MAX_SUBSTEPS,
		"gravity": direction.normalized() * gravity(),
		"base_damp": float(ProjectSettings.get_setting("physics/2d/default_linear_damp", 0.1)),
		"grip_damp": WALL_GRIP_DAMP,
		"touch_slop": TOUCH_SLOP * unit,
		"wake_depth": WAKE_DEPTH * unit,
		"wake_speed": WAKE_SPEED * unit,
		"max_bead_speed": MAX_BEAD_SPEED * unit,
		"untangle_strength": UNTANGLE_STRENGTH,
		"untangle_separation_speed": UNTANGLE_SEPARATION_SPEED * unit,
	}

## LINK_EASE_SPEED at the length unit, px/s.
static func link_ease_speed() -> float:
	return LINK_EASE_SPEED * unit

## A new GooKernel with solver_settings().
static func make_kernel() -> GooKernel:
	var kernel := GooKernel.new()
	kernel.set_solver(solver_settings())
	return kernel

# ---- The pressure ring ----
# A body is a hollow ring of beads held by neighbour (skin) and 2-hop (bending)
# constraints, inflated by a pressure constraint along each edge's outward
# normal, pulled toward its rest shape and damped internally. Its constraints
# are springs of joint_frequency() (scaled by SKIN_FREQUENCY_RATIO) and
# joint_damping_ratio(), so they grade from small to big like the rest of the
# tuning.

## Bead circle radius as a fraction of the spacing between neighbouring beads.
## Over 0.5 closes the ring, so nothing slips between two beads.
const BEAD_RADIUS_RATIO: float = 0.6
## Bending (2-hop) spring stiffness and damping as a fraction of the skin's.
const BENDING_RATIO: float = 0.3
## Pressure strength: at 100% area error the ring's total outward pressure force
## is PRESSURE_GAIN times the blob's weight. A resting ring's weight sits on a
## flat patch of length perimeter / (PRESSURE_GAIN × area error), so low gains
## pancake it (8 gave width/height 2 and a sloshing ring); 120 holds a resting
## ring at about 97% of its area. The force is explicit, so much more makes the
## smallest ring unstable (200 blew up on landing).
const PRESSURE_GAIN: float = 120.0
## Shape-matching force per px of goal error per unit bead mass, for the
## smallest ring (min_radius()). Pressure alone keeps the area but not the outline (area barely changes as a
## circle flattens), so this is what keeps a resting ring rounded.
const SHAPE_MATCH_K: float = 200.0
## How shape matching falls with size: shape_match_k() is SHAPE_MATCH_K ×
## (min_radius() / radius)^this. A flat gain would sag every size by the
## same number of pixels, leaving big blobs the roundest; 1.5 makes them squishier.
const SHAPE_MATCH_EXPONENT: float = 1.5
## Shape-matching gain of a polygon ring as a multiple of a round ring's of the
## same equivalent radius (tuning_for()). Measured on squares and triangles of
## radius 28 … 48 dropped from the launch point (thrown down at 0 … 1200 px/s),
## as the RMS distance of the settled beads from the rest shape fitted onto them
## (round blobs sit at 10-12% of their radius, flattened by design): at 1 a
## square sagged to 9-16% and the largest ones rocked without settling in 5 s;
## 2 left 4-6% (14-20% for the smallest square, which settled skewed); 3 gave
## 1-4%, with an odd skewed square at 12-15%; 4 gives 1-3% for every size and
## speed (one 48 px square thrown at 900 px/s settled at 9.6%); 5 and 6 only
## stiffen them further (1-2%), so 4 keeps them as jiggly as holds their shape.
const POLYGON_SHAPE_MATCH_RATIO: float = 4.0
## Skin and bending spring frequency as a multiple of joint_frequency(). A
## ring's skin is bead_count springs in series around the whole outline, so at
## joint_frequency() itself it stretched 4-5% under the blob's own weight and
## soaked up its bounce. 10 gives the smallest ring a
## 200 rad/s skin (and the largest 10 rad/s): with joint frequencies of
## 20 … 1 rad/s, 4 left the smallest ring rebounding 23 px from a 500 px drop
## and wedged on a gap 0.8 × its diameter wide, and 8 still 39 px and wedged; a
## softer skin stretches, so the pressure inflates it instead of springing it
## back.
const SKIN_FREQUENCY_RATIO: float = 10.0
## Damping, per second, of each bead's velocity relative to the ring's mean
## velocity, for the smallest and for the largest ring: settles wobble and the
## slow flatten-and-recover sloshing a pressure ring otherwise keeps up, without
## slowing the ring as a whole. Small rings keep more of their bounce; big ones
## land with a thud.
const INTERNAL_DAMP_SMALL: float = 5.0
const INTERNAL_DAMP_LARGE: float = 10.0
## Bead counts of the smallest and largest rings.
const MIN_BEADS: int = 12
const MAX_BEADS: int = 22
## Most beads a polygon ring gets (tuning_for()). A polygon is longer around
## than its equivalent circle and needs a bead on every corner, so its count
## follows its perimeter rather than its size; this caps a long thin one, whose
## beads then grow with their spacing.
const MAX_POLYGON_BEADS: int = 44
## Passes of the fixed-point search for a polygon ring's bead spacing in
## tuning_for(): the spacing is the inset loop's perimeter over the bead count,
## and the inset is one bead radius, itself BEAD_RADIUS_RATIO × the spacing.
## Each pass shrinks the error by about 2 × BEAD_RADIUS_RATIO × Σ tan(turn / 2)
## / bead count (0.3 for a launch-size triangle), so 6 leave under 0.1%.
const POLYGON_SPACING_PASSES: int = 6
## Mass of a whole blob as a multiple of particle_mass(): 13 keeps
## the smallest ring as heavy as the 13-particle body it replaced.
const MASS_PARTICLES: float = 13.0
## Bead speed, px/s at unit 1, under which a ring counts as at rest
## (settle_speed() scales it by unit).
const SETTLE_SPEED: float = 4.0
const SETTLE_TIME: float = 0.5
const INFLATE_TIME: float = 0.3
## Neck width, as a fraction of the rest ring's bead-circle diameter, under
## which a pinched ring splits (see split_neck()), for the smallest and for the
## largest ring. Big blobs are squishier and split at a much wider neck. At
## 0.10 the smallest ring had to be pinched to a 5 px gap, which a launch-size
## blob landing on the wedge's point never held long enough before sliding off.
const SPLIT_NECK_SMALL: float = 0.25
const SPLIT_NECK_LARGE: float = 0.35
## Fraction of its target area under which a ring squashed by an impact splits
## (its pressure is overcome), for the smallest and for the largest ring.
const SPLAT_AREA_SMALL: float = 0.64
const SPLAT_AREA_LARGE: float = 0.88
## Seconds a ring's neck must stay under split_neck() before it splits. The
## neck is scanned every Goo2D.PINCH_SCAN_FRAMES (2) frames, so 0.08 means
## three scans in a row (it was measured with 4-frame scans, two in a row).
## A launch-size blob on the wedge's point stays pinched for 0.08-0.13 s before
## it slides off (0.15 never split one); one falling ~800 px onto the flat floor
## dips under the neck for at most 0.03 s on the rebound.
const SPLIT_HOLD: float = 0.08
## Consecutive physics frames a ring must stay under splat_area_ratio() before
## it splits.
const SPLAT_HOLD_FRAMES: int = 2
## Seconds after a ring is built (spawned, merged or split off) during which it
## cannot split. (Merging is locked separately, for GooWorld2D.MERGE_LOCK.)
const SPLIT_LOCK: float = 0.5

## Gravity in px/s²: the project's default 2D gravity
## (physics/2d/default_gravity) × unit, which the solver pulls with
## (solver_settings()) and the pressure is scaled by (pressure_k()). The goo is
## tuned for 980, Godot's default, at unit 1: under another gravity the
## pressure keeps its proportion to the weight, but the springs, shape matching
## and split thresholds were measured at 980 and do not follow it. The unit
## scales it with every other length, so the project setting stays 980 at any
## unit.
static func gravity() -> float:
	return float(ProjectSettings.get_setting("physics/2d/default_gravity", 980.0)) * unit

## Number of beads in the ring of `radius`: 16 for the smallest, 30 for the
## largest, growing with size_t().
static func bead_count(radius: float) -> int:
	return clampi(MIN_BEADS + roundi((MAX_BEADS - MIN_BEADS) * size_t(radius)), MIN_BEADS, MAX_BEADS)

## Total mass of a blob of `radius`.
static func blob_mass(radius: float) -> float:
	return particle_mass(radius) * MASS_PARTICLES

## Mass of each bead of a ring of `radius`.
static func bead_mass(radius: float) -> float:
	return blob_mass(radius) / bead_count(radius)

## Distance between neighbouring bead centres around the rest circle, in px.
static func spacing(radius: float) -> float:
	return TAU * radius / bead_count(radius)

## Collision radius of each bead of a ring of `radius`, in px.
static func bead_radius(radius: float) -> float:
	return BEAD_RADIUS_RATIO * spacing(radius)

## Radius, in px, of the circle the bead centres sit on at rest: about one bead
## radius inside `radius`, so the beads' collision outline (and the skin drawn
## around them) is the blob's circle. Exactly, it is the radius at which the
## area inside that outline, outline_area() of the rest ring, equals
## target_area(), so a ring at rest feels no pressure.
static func ring_radius(radius: float) -> float:
	# outline_area of a regular n-gon of circumradius x with beads of radius b:
	# (n/2) sin(2π/n) x² + 2n sin(π/n) b x + π b², solved for target_area().
	var n := float(bead_count(radius))
	var b := bead_radius(radius)
	var qa := 0.5 * n * sin(TAU / n)
	var qb := 2.0 * n * sin(PI / n) * b
	var qc := PI * b * b - target_area(radius)
	return (-qb + sqrt(qb * qb - 4.0 * qa * qc)) / (2.0 * qa)

## Area, in px², inside the collision outline of a ring of bead centres
## `points` with beads of `bead_size` radius: the loop's area plus a band
## `bead_size` wide around it (Steiner's formula, exact for a convex loop).
static func outline_area(points: PackedVector2Array, bead_size: float) -> float:
	var perimeter := 0.0
	var count := points.size()
	for i: int in count:
		perimeter += points[i].distance_to(points[(i + 1) % count])
	return GooLoop.area(points) + perimeter * bead_size + PI * bead_size * bead_size

## Area, in px², the pressure force inflates a ring of `radius` toward: the
## drawn circle's.
static func target_area(radius: float) -> float:
	return PI * radius * radius

## Pressure force per px of edge length at 100% area error: the force on edge i
## is pressure_k × (target_area / area − 1) × its outward edge normal (whose
## length is the edge length). Summed over the rest perimeter that is
## PRESSURE_GAIN × the blob's weight, so it falls with size as 1/radius times
## the mass growth.
static func pressure_k(radius: float) -> float:
	var perimeter := TAU * radius
	return PRESSURE_GAIN * blob_mass(radius) * gravity() / perimeter

# Natural frequency, in rad/s, of the skin springs of a ring of `radius`:
# SKIN_FREQUENCY_RATIO × joint_frequency().
static func _skin_frequency(radius: float) -> float:
	return SKIN_FREQUENCY_RATIO * joint_frequency(radius)

## Stiffness of the neighbour springs of a ring of `radius`: bead_mass × ω², ω
## its _skin_frequency().
static func skin_stiffness(radius: float) -> float:
	var omega := _skin_frequency(radius)
	return bead_mass(radius) * omega * omega

## Damping of the neighbour springs of a ring of `radius`: 2 ζ bead_mass ω, ζ
## its joint_damping_ratio().
static func skin_damping(radius: float) -> float:
	return 2.0 * joint_damping_ratio(radius) * bead_mass(radius) * _skin_frequency(radius)

## Stiffness of the 2-hop bending springs of a ring of `radius`.
static func bending_stiffness(radius: float) -> float:
	return BENDING_RATIO * skin_stiffness(radius)

## Damping of the 2-hop bending springs of a ring of `radius`.
static func bending_damping(radius: float) -> float:
	return BENDING_RATIO * skin_damping(radius)

## Shape-matching gain of a ring of `radius`, see SHAPE_MATCH_K and
## SHAPE_MATCH_EXPONENT.
static func shape_match_k(radius: float) -> float:
	return SHAPE_MATCH_K * pow(min_radius() / radius, SHAPE_MATCH_EXPONENT)

## Internal damping of a ring of `radius`, see INTERNAL_DAMP_SMALL.
static func internal_damp(radius: float) -> float:
	return lerpf(INTERNAL_DAMP_SMALL, INTERNAL_DAMP_LARGE, size_t(radius))

## Bead speed, in px/s, under which a ring counts as at rest: SETTLE_SPEED ×
## unit.
static func settle_speed() -> float:
	return SETTLE_SPEED * unit

## Seconds a ring must stay under settle_speed() to count as settled.
static func settle_time() -> float:
	return SETTLE_TIME

## Seconds a new ring takes to inflate to its target area.
static func inflate_time() -> float:
	return INFLATE_TIME

## Narrowest gap, in px, between the collision circles of two beads far apart
## along a ring of `radius` (see Goo2D.pinch()) before the ring splits
## there: SPLIT_NECK_SMALL … SPLIT_NECK_LARGE of its bead circle's diameter.
static func split_neck(radius: float) -> float:
	return lerpf(SPLIT_NECK_SMALL, SPLIT_NECK_LARGE, size_t(radius)) * 2.0 * ring_radius(radius)

## Fraction of target_area() under which an impact splits a ring of `radius`.
static func splat_area_ratio(radius: float) -> float:
	return lerpf(SPLAT_AREA_SMALL, SPLAT_AREA_LARGE, size_t(radius))

## Every value above for a ring of `radius` by name, including the bead
## physics (linear_damp, bounce, friction).
static func tuning(radius: float) -> Dictionary:
	return {
		"radius": radius,
		"bead_count": bead_count(radius),
		"blob_mass": blob_mass(radius),
		"bead_mass": bead_mass(radius),
		"spacing": spacing(radius),
		"bead_radius": bead_radius(radius),
		"ring_radius": ring_radius(radius),
		"target_area": target_area(radius),
		"pressure_k": pressure_k(radius),
		"skin_stiffness": skin_stiffness(radius),
		"skin_damping": skin_damping(radius),
		"bending_stiffness": bending_stiffness(radius),
		"bending_damping": bending_damping(radius),
		"shape_match_k": shape_match_k(radius),
		"internal_damp": internal_damp(radius),
		"linear_damp": linear_damp(radius),
		"bounce": bounce(radius),
		"friction": BLOB_FRICTION,
		"settle_speed": settle_speed(),
		"settle_time": settle_time(),
		"inflate_time": inflate_time(),
		"split_neck": split_neck(radius),
		"splat_area_ratio": splat_area_ratio(radius),
	}

## tuning() for a body of `shape`, with the same keys, so Goo2D reads
## both alike. For a ROUND shape it is exactly tuning(shape.radius()). For a
## POLYGON, with r its equivalent radius (GooShape.radius()):
## - bead_count: the outline's perimeter over spacing(r), clamped to
##   MIN_BEADS … MAX_POLYGON_BEADS, so beads sit about as far apart as on a
##   round ring of the same size;
## - spacing: the rest loop's perimeter over bead_count, the rest loop being
##   GooShape.bead_loop(), the outline inset by bead_radius (found by
##   POLYGON_SPACING_PASSES of fixed-point search, since the inset depends on
##   the bead radius);
## - bead_radius: BEAD_RADIUS_RATIO × spacing, which closes the ring;
## - target_area: what that rest ring's collision outline encloses (the
##   outline less its corners rounded by one bead radius; outline_area()), so a
##   ring at rest feels no pressure, as ring_radius() arranges for round rings.
##   Inflating to the sharp outline's area would leave a resting ring pushing
##   its flat sides out;
## - bead_mass: blob_mass(r) shared by the beads, and the springs built from it
##   at the round ring's frequency and damping ratio of r;
## - pressure_k: spread over the outline's perimeter instead of 2π r;
## - shape_match_k: shape_match_k(r) × POLYGON_SHAPE_MATCH_RATIO;
## - everything else (damping, bounce, settling, split thresholds) by r.
## ring_radius is ring_radius(r), the circle a round ring of that size sits on:
## a polygon ring's beads and rest shape come from its bead loop
## (Goo2D.make() passes it to Goo2D.setup()), so nothing builds
## a circle from it. It stays the ring's size scale: split_neck() derives from
## it, and Goo2D measures how far apart two beads must be at rest to
## count as a neck against it.
static func tuning_for(shape: GooShape) -> Dictionary:
	var radius := shape.radius()
	var values := tuning(radius)
	if shape.is_round():
		return values
	var count := clampi(roundi(shape.perimeter() / spacing(radius)), MIN_BEADS, MAX_POLYGON_BEADS)
	var bead_size := bead_radius(radius)
	for _pass: int in POLYGON_SPACING_PASSES:
		var inset := shape.inset(bead_size)
		var rest_perimeter := GooLoop.perimeter(inset) if not inset.is_empty() else shape.perimeter()
		bead_size = BEAD_RADIUS_RATIO * rest_perimeter / count
	var rest := shape.bead_loop(count, bead_size)
	var mass := blob_mass(radius) / count
	var omega := _skin_frequency(radius)
	var stiffness := mass * omega * omega
	var damping := 2.0 * joint_damping_ratio(radius) * mass * omega
	values["bead_count"] = count
	values["bead_mass"] = mass
	values["spacing"] = bead_size / BEAD_RADIUS_RATIO
	values["bead_radius"] = bead_size
	values["target_area"] = outline_area(rest, bead_size) if not rest.is_empty() else shape.area()
	values["pressure_k"] = PRESSURE_GAIN * blob_mass(radius) * gravity() / shape.perimeter()
	values["skin_stiffness"] = stiffness
	values["skin_damping"] = damping
	values["bending_stiffness"] = BENDING_RATIO * stiffness
	values["bending_damping"] = BENDING_RATIO * damping
	values["shape_match_k"] = shape_match_k(radius) * POLYGON_SHAPE_MATCH_RATIO
	return values
