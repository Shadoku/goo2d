extends SceneTree
## Stability repros: plays the situations the goo is known to get wrong, headless,
## and prints what happened, so a fix can be measured.
##
##   godot --headless --fixed-fps 60 --path . -s tools/stability.gd -- [scenario ...] [--seed=N] [--unit=U]
##
## --unit=U plays everything at GooTuning.unit U (1 by default): the arena is
## scaled by U in the scene, and every size, distance and speed of the
## scenarios below with it, so at 0.5 each scenario is the same game at half
## size. Sizes, speeds and offsets are named in px at unit 1 in what is printed;
## measured lengths and speeds are printed back in px at unit 1 too, so runs at
## two units compare line by line.
##
## Scenarios (default: all):
## - passthrough: a launch-size body (round or square) thrown at a big resting ring
##   at 1200 … 2500 px/s, and dropped onto it from above. Prints how many of its
##   beads ended up inside the big ring's bead loop (at worst and at the end), the
##   widest gap the impact opened between two neighbouring beads of the big ring,
##   and the final centre distance as a fraction of the two radii.
## - inside: two bodies spawned overlapping (round/round, small/big, square/square,
##   round/square).
##   Prints how long the world took to get them apart, or that it never did, and
##   whether they settled (fell asleep) while still inside each other.
## - skin: a packed column of round bodies and shapes. Every process frame checks
##   every body's Skin polygon the way the renderer does (Geometry2D.triangulate_polygon):
##   a polygon that does not triangulate is not drawn, so the body is invisible that
##   frame. Prints the invisible body-frames and why (loop inside out, outline
##   self-intersecting, or neither).
## - impale: bodies dropped and thrown onto the wedge's apex and both blades' tips,
##   centred and off-centre. Prints, per case, whether the body split, whether the
##   tip ended up inside a body's bead loop (impaled), and whether an impaled body
##   settled (fell asleep, so nothing will ever cut it) or sits stuck on the tip;
##   the summary also counts the trims (GooWorld2D.trimmed: a cut that would have
##   left a crumb, made into one body off the tip instead) and the most in one case.
## - impale_pile: eight bodies dropped one after another onto the wedge's apex and
##   onto the floor blade, so the ones underneath are pressed onto the tip by the
##   pile. Prints how many bodies ended with the tip inside their bead loop, how
##   many of those are settled or stuck, and the splits and trims.
## - births: a 5000-frame random game (launches at player speeds, drops, squares
##   and triangles; seeded by --seed=N, 1 by default) watched after every physics
##   step. Counts explosions (a bead over EXPLODE_SPEED px/s, or a body's fastest
##   bead jumping by more than EXPLODE_JUMP px/s in one frame), bodies tangled at
##   some point (a bead loop crossing itself at least twice), merges, and births
##   gone wrong (a body at most BIRTH_AGE steps old that is faster than
##   BIRTH_FAST_SPEED, crossing itself, or far from its target area) by what made
##   them (the world's split / merged / trimmed signals of that frame, or a
##   spawn), and dumps the first few of those births with their parents' loops;
##   also counts the frames in which the kernel's speed cap clamped a bead
##   (GooTuning.MAX_BEAD_SPEED), near a birth or not.
##   The game is chaotic: starting it one physics frame later plays a different
##   game (seed 1: 165 merges and 29 explosions, or 96 and none), so compare
##   `births` run alone (it then starts on the same frame as the old
##   tools/births.gd did), over several seeds.
## - scale (only when named): the length unit's gate (docs/tiled-boards-plan.md,
##   step 1): the smallest blob's rebound from a 500 px drop, the time blobs take
##   to settle on the floor after it, and whether launch-size blobs dropped on
##   the wedge's apex, or thrown onto it from the launch point, split. Run at --unit=1 and --unit=0.5 and compare: the
##   rebound halves (printed back at unit 1, it is the same), the times match,
##   the wedge still splits.
## All runs are deterministic for a fixed build of the goo's kernel.

const MAIN_SCENE := "res://scenes/main.tscn"

var _main: Node
var _game: Game
var _arena: Arena
var _splits: int = 0
var _merges: int = 0
var _trims: int = 0
# The goo's length unit the scenarios play at (--unit=U).
var _unit: float = 1.0

func _initialize() -> void:
	var scenarios: Array[String] = []
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--seed="):
			_birth_seed = int(arg.substr(7))
		elif arg.begins_with("--unit="):
			_unit = float(arg.substr(7))
		elif not arg.begins_with("--"):
			scenarios.append(arg)
	if scenarios.is_empty():
		scenarios = ["passthrough", "inside", "skin", "impale", "impale_pile", "births"]
	# Before the world exists: its kernel takes the solver's settings when made.
	GooTuning.unit = _unit
	_main = (load(MAIN_SCENE) as PackedScene).instantiate()
	(_main.get_node("Arena") as Node2D).scale = Vector2(_unit, _unit)
	root.add_child(_main)
	_game = _main.get_node("Game") as Game
	_arena = _main.get_node("Arena") as Arena
	_game.split.connect(func(_a: float, _b: float, _p: Vector2) -> void: _splits += 1)
	_game.merged.connect(func(_r: float, _p: Vector2) -> void: _merges += 1)
	_game.trimmed.connect(func(_r: float, _p: Vector2) -> void: _trims += 1)
	# From a node processed after every body (a higher process_priority), so
	# each body's _process() has put this frame's skin on its Skin, as the
	# renderer will draw it (a deferred call runs before the nodes' _process()).
	var watcher := SkinWatcher.new()
	watcher.check = _check_skins
	watcher.process_priority = 1000
	root.add_child(watcher)
	_watching_skins = true
	_run(scenarios)

func _run(scenarios: Array[String]) -> void:
	await physics_frame
	if _unit != 1.0:
		print("at GooTuning.unit %s: the arena scaled by it, sizes and speeds named in px at unit 1" % _unit)
	for scenario: String in scenarios:
		print("\n==== %s" % scenario)
		_reset_skin_counts()
		match scenario:
			"passthrough": await _passthrough()
			"inside": await _inside()
			"skin": await _skin()
			"impale": await _impale()
			"impale_pile": await _impale_pile()
			"births": await _births()
			"scale": await _scale()
			_: push_error("stability: unknown scenario %s" % scenario)
		_print_skin_counts()
	quit(0)

func _frames(count: int) -> void:
	for _i: int in count:
		await physics_frame

func _reset() -> void:
	_game.reset()
	_splits = 0
	_merges = 0
	_trims = 0
	await physics_frame

func _floor_centre() -> Vector2:
	return _arena.to_global(Vector2(Arena.INNER_LEFT + Arena.INNER_WIDTH / 2.0, Arena.FLOOR_Y))

# `length` (a size, distance or speed in px at unit 1) at the unit played.
func _u(length: float) -> float:
	return length * _unit

# The global point of `local`, a point in the arena's space (px at unit 1).
func _at(local: Vector2) -> Vector2:
	return _arena.to_global(local)

static func _shape_of(sides: int, radius: float) -> GooShape:
	return null if sides == 0 else GooShape.regular(sides, radius)

static func _name_of(sides: int, radius: float) -> String:
	return "%s %.0f" % [["round", "", "", "triangle", "square"][sides], radius]

# Widest gap, px, between two neighbouring beads' collision circles of `body`
# (negative while they overlap, as they do at rest).
static func _widest_gap(body: Goo2D) -> float:
	var points := body.bead_points()
	var widest := -INF
	for i: int in points.size():
		var gap := points[i].distance_to(points[(i + 1) % points.size()]) - 2.0 * body.bead_radius()
		widest = maxf(widest, gap)
	return widest

static func _live(body: Variant) -> bool:
	return is_instance_valid(body) and not (body as Node).is_queued_for_deletion()

# ---- passthrough ----

func _passthrough() -> void:
	var big_radius := _u(140.0)
	var cases: Array[Dictionary] = []
	for sides: int in [0, 4]:
		for speed: float in [1200.0, 1600.0, 2000.0, 2500.0]:
			cases.append({ "sides": sides, "radius": 36.0, "from": "side", "speed": speed })
		for speed: float in [1500.0, 2500.0]:
			cases.append({ "sides": sides, "radius": 36.0, "from": "above", "speed": speed })
	cases.append({ "sides": 0, "radius": 60.0, "from": "side", "speed": 2000.0 })
	cases.append({ "sides": 0, "radius": 90.0, "from": "side", "speed": 2000.0 })
	for speed: float in [1600.0, 2500.0]:
		cases.append({ "sides": 0, "radius": 36.0, "from": "side", "speed": speed, "target_sides": 4 })
		cases.append({ "sides": 4, "radius": 36.0, "from": "side", "speed": speed, "target_sides": 4 })
	print("case                                | inside worst/end | big gap | distance/radii | untangled | splits")
	for c: Dictionary in cases:
		await _reset()
		var target_sides: int = c.get("target_sides", 0)
		var big := _game.spawn(big_radius, _floor_centre() - Vector2(0.0, big_radius), _shape_of(target_sides, big_radius))
		await _frames(90)
		var centre := big.center()
		var start := centre + (Vector2(-_u(520.0), 0.0) if c["from"] == "side" else Vector2(0.0, -_u(520.0)))
		var speed := _u(c["speed"])
		var velocity := Vector2(speed, 0.0) if c["from"] == "side" else Vector2(0.0, speed)
		var radius := _u(c["radius"])
		var small := _game.spawn(radius, start, _shape_of(c["sides"], radius))
		small.set_velocity(velocity)
		var worst_inside := 0
		var worst_gap := -INF
		var ever_inside := false
		for _f: int in 150:
			await physics_frame
			if not _live(small) or not _live(big):
				break
			var inside := small.beads_inside(big, 0.0) + big.beads_inside(small, 0.0)
			worst_inside = maxi(worst_inside, inside)
			ever_inside = ever_inside or inside > 0
			worst_gap = maxf(worst_gap, _widest_gap(big))
		var end_inside := -1
		var ratio := -1.0
		if _live(small) and _live(big):
			end_inside = small.beads_inside(big, 0.0) + big.beads_inside(small, 0.0)
			ratio = small.center().distance_to(big.center()) / (small.radius + big.radius)
		print("%-35s | %4d / %4d      | %6.1f  | %6.2f         | %-9s | %d" % [
			"%s from %s at %.0f%s" % [_name_of(c["sides"], c["radius"]), c["from"], c["speed"], " into square" if target_sides != 0 else ""],
			worst_inside, end_inside, worst_gap / _unit, ratio,
			"yes" if ever_inside and end_inside == 0 else ("still in" if end_inside > 0 else "n/a"), _splits])

# ---- inside ----

func _inside() -> void:
	var cases: Array[Dictionary] = [
		{ "name": "round 60 half inside round 60", "a": [0, 60.0], "b": [0, 60.0], "overlap": 0.5 },
		{ "name": "round 40 half inside round 120", "a": [0, 40.0], "b": [0, 120.0], "overlap": 0.5 },
		{ "name": "round 40 deep inside round 120", "a": [0, 40.0], "b": [0, 120.0], "overlap": 0.85 },
		{ "name": "square 40 half inside square 60", "a": [4, 40.0], "b": [4, 60.0], "overlap": 0.5 },
		{ "name": "round 40 half inside square 60", "a": [0, 40.0], "b": [4, 60.0], "overlap": 0.5 },
	]
	print("case                                 | apart after | settled overlapping | end inside | end distance/radii")
	for c: Dictionary in cases:
		await _reset()
		var ra := _u(c["a"][1])
		var rb := _u(c["b"][1])
		var at := _floor_centre() - Vector2(0.0, rb)
		if c.get("pile", false):
			at = _at(Vector2(Arena.INNER_LEFT, Arena.FLOOR_Y)) + Vector2(rb, -rb)
		var b := _game.spawn(rb, at, _shape_of(c["b"][0], rb))
		if c.get("pile", false):
			for k: int in 4:
				_game.spawn(rb, at + Vector2(0.0, -2.0 * rb * (k + 1)))
			_game.spawn(rb, at + Vector2(2.0 * rb, 0.0))
		await _frames(90)
		var centre := b.center()
		var a := _game.spawn(ra, centre + Vector2((1.0 - float(c["overlap"])) * (ra + rb), 0.0), _shape_of(c["a"][0], ra))
		var apart_frame := -1
		var settled_overlapping := false
		for f: int in 300:
			await physics_frame
			if not _live(a) or not _live(b):
				break
			var inside := a.beads_inside(b, 0.0) + b.beads_inside(a, 0.0)
			var ratio := a.center().distance_to(b.center()) / (ra + rb)
			if apart_frame < 0 and inside == 0 and ratio >= 0.7:
				apart_frame = f
			if inside > 0 and a.settled and b.settled:
				settled_overlapping = true
		var end_inside := -1
		var ratio := -1.0
		if _live(a) and _live(b):
			end_inside = a.beads_inside(b, 0.0) + b.beads_inside(a, 0.0)
			ratio = a.center().distance_to(b.center()) / (ra + rb)
		print("%-36s | %-11s | %-19s | %5d      | %.2f" % [c["name"],
			("%.2f s" % (apart_frame / 60.0)) if apart_frame >= 0 else "never", "yes" if settled_overlapping else "no",
			end_inside, ratio])

# ---- skin ----

# Calls `check` every process frame, after the bodies' _process() (see _initialize()).
class SkinWatcher extends Node:
	var check: Callable
	func _process(_delta: float) -> void:
		check.call()

var _invisible_frames: int = 0
var _invisible_inside_out: int = 0
var _invisible_self_intersecting: int = 0
var _invisible_other: int = 0
var _invisible_empty: int = 0
var _stale_frames: int = 0
var _stale_repair_failed: int = 0
var _stale_part_dropped: int = 0
# Per body (instance id): its current run of consecutive wrong frames, and the longest.
var _wrong_run: Dictionary = {}
var _wrong_longest: Dictionary = {}
var _wrong_last_frame: Dictionary = {}
var _stale_examples: Array[String] = []
var _invisible_examples: Array[String] = []
var _skin_frame: int = 0
var _body_frames: int = 0
var _watching_skins: bool = false

func _reset_skin_counts() -> void:
	_invisible_frames = 0
	_invisible_inside_out = 0
	_invisible_self_intersecting = 0
	_invisible_other = 0
	_invisible_empty = 0
	_stale_frames = 0
	_stale_repair_failed = 0
	_stale_part_dropped = 0
	_wrong_run.clear()
	_wrong_longest.clear()
	_wrong_last_frame.clear()
	_stale_examples.clear()
	_invisible_examples.clear()
	_skin_frame = 0
	_body_frames = 0

func _print_skin_counts() -> void:
	print("skins: %d body-frames, %d invisible (skin polygon does not triangulate): %d with the bead loop inside out, %d with a self-intersecting outline, %d other, %d with no polygon at all"
		% [_body_frames, _invisible_frames, _invisible_inside_out, _invisible_self_intersecting, _invisible_other, _invisible_empty])
	for example: String in _invisible_examples:
		print("  " + example)
	print("skins: %d body-frames drawn wrong (a bead more than %.1f bead radii outside the drawn skin polygon): %d while the skin could not be repaired, %d with the repaired skin leaving part of the body out, %d stale (the skin of an earlier frame)"
		% [_stale_frames, STALE_BEAD_RADII, _stale_repair_failed, _stale_part_dropped, _stale_frames - _stale_repair_failed - _stale_part_dropped])
	var runs: Array = _wrong_longest.values()
	runs.sort()
	var long_runs := runs.filter(func(r: int) -> bool: return r >= 6).size()
	print("skins: %d bodies drawn wrong at some point; longest runs of consecutive frames %s; %d bodies wrong for 6 or more frames in a row"
		% [runs.size(), runs.slice(maxi(runs.size() - 8, 0)), long_runs])
	for example: String in _stale_examples:
		print("  " + example)

func _skin() -> void:
	await _reset()
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var centre := _floor_centre().x
	var body_frames := 0
	for i: int in 40:
		var radius := _u([30.0, 42.0, 60.0, 36.0][i % 4])
		var sides: int = [0, 4, 0, 3][i % 4]
		_game.spawn(radius, Vector2(rng.randf_range(centre - _u(180.0), centre + _u(180.0)), _at(Vector2(0.0, Arena.DROP_Y)).y),
			_shape_of(sides, radius))
		for _f: int in 6:
			await physics_frame
			body_frames += _game.bodies().size()
	for _f: int in 300:
		await physics_frame
		body_frames += _game.bodies().size()
	print("packed column: %d body-frames, %d merges, %d splits" % [body_frames, _merges, _splits])

func _check_skins() -> void:
	if not _watching_skins:
		return
	_skin_frame += 1
	for body: Goo2D in _game.bodies():
		_body_frames += 1
		var skin := body.get_node("Skin") as Polygon2D
		var points := body.bead_points()
		var drawn := _drawn_pieces(skin)
		var drawable := not drawn.is_empty()
		for piece: PackedVector2Array in drawn:
			if Geometry2D.triangulate_polygon(piece).is_empty():
				drawable = false
		if drawable:
			_check_stale(body, drawn, points)
			continue
		_invisible_frames += 1
		var why := "other"
		if skin.polygon.size() < 3:
			_invisible_empty += 1
			why = "no polygon (%d points)" % skin.polygon.size()
		elif not GooLoop.is_ccw(points):
			_invisible_inside_out += 1
			why = "inside out"
		elif GooLoop.self_intersects(skin.polygon):
			_invisible_self_intersecting += 1
			why = "self-intersecting outline"
		else:
			_invisible_other += 1
		if _invisible_examples.size() < 8:
			_invisible_examples.append("frame %d: %s radius %.0f, %d beads, area %.0f%% of target, settled %s, merging %s: %s"
				% [_skin_frame, "round" if body.shape.is_round() else "%d-point shape" % body.shape.outline.size(),
					body.radius, body.particle_count(), 100.0 * body.area() / body.target_area, body.settled, body.merging, why])
			if _invisible_examples.size() <= 3:
				_invisible_examples.append("    bead radius %s, corners %s, beads %s, %d polygons drawn" % [body.bead_radius(), body.corner_flags(), points, drawn.size()])

## Bead radii a bead centre may lie outside the drawn skin polygon before the
## skin counts as stale: the skin is the beads pushed out one radius, so a bead
## this far outside it is drawn nowhere near where it is.
const STALE_BEAD_RADII: float = 2.0

# The drawn polygon triangulates; is it the skin of where the beads are now? The
# kernel keeps a ring's previous polygon while its new outline cannot be
# repaired into one Polygon2D can draw (and for SKIN_REPAIR_WAIT steps after a
# repair), so a ring that stays folded is drawn where it was, not where it is.
func _check_stale(body: Goo2D, drawn: Array[PackedVector2Array], points: PackedVector2Array) -> void:
	var limit := STALE_BEAD_RADII * body.bead_radius()
	var worst := _outside(points, drawn)
	if worst <= limit:
		return
	_stale_frames += 1
	var key := body.get_instance_id()
	_wrong_run[key] = (_wrong_run.get(key, 0) + 1) if _wrong_last_frame.get(key, -1) == _skin_frame - 1 else 1
	_wrong_last_frame[key] = _skin_frame
	_wrong_longest[key] = maxi(_wrong_longest.get(key, 0), _wrong_run[key])
	var reference := Goo2D.skin_pieces(points, body.bead_radius(), body.corner_flags())
	var why := "the kernel is waiting after a repair, or has not rebuilt yet"
	if reference.is_empty():
		_stale_repair_failed += 1
		why = "the skin of the beads now cannot be repaired (reference empty)"
	elif _outside(points, reference) > limit:
		_stale_part_dropped += 1
		why = "the skin of the beads now leaves part of the body out (a bead %.1f px outside its %d polygons)" % [_outside(points, reference), reference.size()]
	elif not GooLoop.self_intersects(points):
		why = "the bead loop is simple now; reference skin has %d points" % reference.size()
	if _stale_examples.size() < 8:
		_stale_examples.append("frame %d: %s radius %.0f, %d beads, area %.0f%% of target, settled %s, merging %s, a bead %.1f px outside the drawn skin: %s"
			% [_skin_frame, "round" if body.shape.is_round() else "%d-point shape" % body.shape.outline.size(),
				body.radius, body.particle_count(), 100.0 * body.area() / body.target_area, body.settled, body.merging, worst, why])
		if _stale_examples.size() <= 3:
			_stale_examples.append("    bead radius %s, corners %s, beads %s" % [body.bead_radius(), body.corner_flags(), points])

# How far the farthest of `points` outside every one of `polygons` lies from
# the nearest of them (0 if each is inside one).
func _outside(points: PackedVector2Array, polygons: Array[PackedVector2Array]) -> float:
	var worst := 0.0
	for p: Vector2 in points:
		var nearest := INF
		for polygon: PackedVector2Array in polygons:
			if Geometry2D.is_point_in_polygon(p, polygon):
				nearest = 0.0
				break
			for i: int in polygon.size():
				var q := Geometry2D.get_closest_point_to_segment(p, polygon[i], polygon[(i + 1) % polygon.size()])
				nearest = minf(nearest, p.distance_to(q))
		worst = maxf(worst, nearest)
	return worst

# The polygons a Skin draws, in global space: its sub-polygons
# (Polygon2D.polygons, index lists into `polygon`) or the polygon itself;
# empty when it has fewer than 3 points (nothing drawn).
func _drawn_pieces(skin: Polygon2D) -> Array[PackedVector2Array]:
	var all := skin.get_global_transform() * skin.polygon
	var pieces: Array[PackedVector2Array] = []
	if skin.polygons.is_empty():
		if all.size() >= 3:
			pieces.append(all)
		return pieces
	for indices: PackedInt32Array in skin.polygons:
		var piece := PackedVector2Array()
		for i: int in indices:
			piece.append(all[i])
		pieces.append(piece)
	return pieces

# ---- impale ----

func _impale() -> void:
	var targets: Array[Dictionary] = [
		{ "name": "wedge apex", "tip": _arena.wedge_apex(), "axis": Vector2.UP, "approach": Vector2.UP },
		{ "name": "floor blade", "tip": (_arena.get_node("FloorBlade") as Blade).tip(), "axis": Vector2.UP, "approach": Vector2.UP },
		{ "name": "wall blade", "tip": (_arena.get_node("WallBlade") as Blade).tip(), "axis": Vector2.RIGHT, "approach": Vector2.RIGHT },
	]
	var bodies: Array[Array] = [[0, 18.0], [0, 22.0], [0, 28.0], [0, 40.0], [4, 36.0], [3, 36.0], [0, 80.0]]
	var totals := { "cases": 0, "split": 0, "impaled": 0, "settled_impaled": 0, "stuck": 0, "trims": 0, "most_trims": 0 }
	print("case                                              | split | tip in loop | settled impaled | stuck at tip")
	for target: Dictionary in targets:
		var tip: Vector2 = target["tip"]
		var approach: Vector2 = target["approach"]
		var sideways := approach.orthogonal()
		for body_spec: Array in bodies:
			var sides: int = body_spec[0]
			var radius := _u(body_spec[1])
			for offset: float in [0.0, 12.0, 24.0]:
				for speed: float in [0.0, 900.0, 1600.0]:
					await _reset()
					var start := tip + approach * (radius + _u(240.0)) + sideways * _u(offset)
					var body := _game.spawn(radius, start, _shape_of(sides, radius))
					if speed > 0.0:
						body.set_velocity(-approach * _u(speed))
					await _frames(180)
					var impaled := false
					var settled_impaled := false
					var stuck := false
					for live: Goo2D in _game.bodies():
						var in_loop := GooLoop.point_in_loop(tip, live.bead_points())
						impaled = impaled or in_loop
						settled_impaled = settled_impaled or (in_loop and live.settled)
						if in_loop and live.average_velocity().length() < _u(10.0) and _splits == 0:
							stuck = true
					totals["cases"] += 1
					totals["split"] += 1 if _splits > 0 else 0
					totals["impaled"] += 1 if impaled else 0
					totals["settled_impaled"] += 1 if settled_impaled else 0
					totals["stuck"] += 1 if stuck else 0
					totals["trims"] += _trims
					totals["most_trims"] = maxi(totals["most_trims"], _trims)
					if impaled or stuck:
						print("%-49s | %5d | %-11s | %-15s | %s" % [
							"%s on %s, %.0f px off, %s" % [_name_of(sides, body_spec[1]), target["name"], offset, "dropped" if speed == 0.0 else "thrown"],
							_splits, "yes" if impaled else "no", "yes" if settled_impaled else "no", "yes" if stuck else "no"])
	print("%d cases: %d split, %d ended with the tip inside a bead loop, %d of those settled impaled, %d stuck on the tip without a split; %d trims (at most %d in one case)"
		% [totals["cases"], totals["split"], totals["impaled"], totals["settled_impaled"], totals["stuck"],
			totals["trims"], totals["most_trims"]])

func _impale_pile() -> void:
	var targets: Array[Dictionary] = [
		{ "name": "wedge apex", "tip": _arena.wedge_apex() },
		{ "name": "floor blade", "tip": (_arena.get_node("FloorBlade") as Blade).tip() },
	]
	for target: Dictionary in targets:
		for mix: String in ["round", "shapes"]:
			await _reset()
			var tip: Vector2 = target["tip"]
			var rng := RandomNumberGenerator.new()
			rng.seed = 11
			for i: int in 8:
				var radius := _u([40.0, 32.0, 48.0, 36.0][i % 4])
				var sides: int = 0 if mix == "round" else [0, 4, 3, 4][i % 4]
				_game.spawn(radius, Vector2(tip.x + _u(rng.randf_range(-30.0, 30.0)), _at(Vector2(0.0, Arena.DROP_Y)).y),
					_shape_of(sides, radius))
				await _frames(20)
			await _frames(300)
			var impaled := 0
			var settled_impaled := 0
			var stuck := 0
			for live: Goo2D in _game.bodies():
				if not GooLoop.point_in_loop(tip, live.bead_points()):
					continue
				impaled += 1
				if live.settled:
					settled_impaled += 1
				if live.average_velocity().length() < _u(10.0):
					stuck += 1
			print("8 %s bodies piled on the %s: %d bodies, %d splits, %d trims, %d merges; %d with the tip inside their loop (%d settled, %d at rest on it)"
				% [mix, target["name"], _game.bodies().size(), _splits, _trims, _merges, impaled, settled_impaled, stuck])

# ---- births ----

## A bead faster than this, px/s, in a frame counts as an explosion.
const EXPLODE_SPEED: float = 4000.0
## A body's fastest bead getting faster by more than this, px/s, in one frame
## counts as an explosion too (GooTuning.MAX_BEAD_SPEED keeps every bead under
## EXPLODE_SPEED; a jump up to the cap is still a jolt).
const EXPLODE_JUMP: float = 2500.0
## Physics frames the random game of `births` plays.
const BIRTH_FRAMES: int = 5000
## A body at most BIRTH_AGE steps old that is faster than BIRTH_FAST_SPEED px/s,
## crossing itself, or with area() outside BIRTH_AREA_RANGE times its
## target_area was born wrong.
const BIRTH_AGE: int = 1
const BIRTH_FAST_SPEED: float = 2000.0
const BIRTH_AREA_RANGE := Vector2(0.5, 2.0)
## How many reports (tangled, explosions, merges born tangled) and full dumps of
## births gone wrong `births` prints.
const BIRTH_REPORTS: int = 12
const BIRTH_DUMPS: int = 6

# Calls `check` every physics frame, after the world's step (see _births()).
class StepWatcher extends Node:
	var check: Callable
	func _physics_process(_delta: float) -> void:
		check.call()

var _birth_seed: int = 1
var _watching_births: bool = false
var _birth_frame: int = 0
# id -> { "crossings", "speed", "born", "loop", "radius", "shape", "cause" } at the last check.
var _birth_last: Dictionary = {}
var _tangled_runs: Dictionary = {}
var _birth_reports: int = 0
var _tangled_bodies: int = 0
var _explosions: int = 0
var _explosions_speed: int = 0
var _explosions_jump: int = 0
var _merges_tangled_at_birth: int = 0
var _merges_from_folded_parent: int = 0
# The world's split / merged / trimmed signals since the last check: their
# descriptions, and their kinds ("split", "merge", "trim") as keys.
var _birth_events: Array[String] = []
var _birth_event_kinds: Dictionary = {}
# Ids of the bodies born wrong, and how many of them each cause made.
var _births_wrong: Dictionary = {}
var _births_wrong_by_cause: Dictionary = {}
var _births_dumped: int = 0
# Frames in which the kernel's speed cap (GooTuning.MAX_BEAD_SPEED) clamped a
# velocity, those with a body at most CAP_NEAR_BIRTH steps old, the velocities
# clamped (summed over substeps), and how many of the others were reported.
var _capped_frames: int = 0
var _capped_near_birth: int = 0
var _capped_velocities: int = 0
var _capped_reports: int = 0
## A frame whose speed cap acted counts as near a birth when a body this many
## steps old or younger is in play.
const CAP_NEAR_BIRTH: int = 3

# A random game, seeded by --seed=N (1 by default): launches at player speeds
# from the launch point and drops across the arena, a fifth of them squares and
# a seventh triangles, one every 24 frames while fewer than 45 bodies are in
# play. After each step every body is checked (_check_births()).
func _births() -> void:
	await _reset()
	var watcher := StepWatcher.new()
	watcher.check = _check_births
	# After the world's _physics_process: sees each step's result.
	watcher.process_physics_priority = 1000
	root.add_child(watcher)
	var on_merged := func(r: float, p: Vector2) -> void: _on_birth_event("merge", "merged radius %.0f at %s" % [r, p])
	var on_split := func(a: float, b: float, p: Vector2) -> void: _on_birth_event("split", "split into %.0f and %.0f at %s" % [a, b, p])
	var on_trimmed := func(r: float, p: Vector2) -> void: _on_birth_event("trim", "trimmed to %.0f at %s" % [r, p])
	_game.merged.connect(on_merged)
	_game.split.connect(on_split)
	_game.trimmed.connect(on_trimmed)
	_reset_birth_counts()
	_watching_births = true
	var rng := RandomNumberGenerator.new()
	rng.seed = _birth_seed
	for f: int in BIRTH_FRAMES:
		await physics_frame
		if f % 24 == 0 and _game.bodies().size() < 45:
			var roll := rng.randf()
			var radius := rng.randf_range(DropController.drop_min_radius(), DropController.drop_max_radius())
			var shape: GooShape = null
			if roll < 0.2:
				shape = GooShape.regular(4, radius)
			elif roll < 0.35:
				shape = GooShape.regular(3, radius)
			if rng.randf() < 0.7:
				var blob := _game.spawn(radius, _arena.launch_point(), shape)
				var speed := _u(rng.randf_range(300.0, DropController.MAX_LAUNCH_SPEED))
				var angle := rng.randf_range(PI * 0.55, PI * 1.05)
				blob.set_velocity(Vector2(cos(angle), -sin(angle)) * speed * Vector2(1.0, -1.0))
			else:
				_game.spawn(radius, _at(Vector2(rng.randf_range(Arena.INNER_LEFT + 100.0, Arena.INNER_RIGHT - 100.0), Arena.DROP_Y)), shape)
	_watching_births = false
	_game.merged.disconnect(on_merged)
	_game.split.disconnect(on_split)
	_game.trimmed.disconnect(on_trimmed)
	watcher.queue_free()
	var causes: Array[String] = []
	for cause: String in ["split", "merge", "trim", "spawn"]:
		causes.append("%d %s" % [_births_wrong_by_cause.get(cause, 0), cause])
	for cause: String in _births_wrong_by_cause:
		if not cause in ["split", "merge", "trim", "spawn"]:
			causes.append("%d %s" % [_births_wrong_by_cause[cause], cause])
	print("births: seed %d, %d frames, %d bodies at the end, %d merges (%d born tangled, %d with a parent folded at the merge), %d splits, %d trims; %d bodies tangled at some point; %d explosions (%d with a bead over %.0f px/s, %d with a jump over %.0f px/s in a frame); %d births gone wrong (%s); speed cap acted in %d frames (%d within %d steps of a birth), %d velocities clamped"
		% [_birth_seed, BIRTH_FRAMES, _game.bodies().size(), _merges, _merges_tangled_at_birth, _merges_from_folded_parent,
			_splits, _trims, _tangled_bodies, _explosions, _explosions_speed, _u(EXPLODE_SPEED), _explosions_jump, _u(EXPLODE_JUMP),
			_births_wrong.size(), ", ".join(causes), _capped_frames, _capped_near_birth, CAP_NEAR_BIRTH, _capped_velocities])

func _reset_birth_counts() -> void:
	_birth_frame = 0
	_birth_last.clear()
	_tangled_runs.clear()
	_birth_reports = 0
	_tangled_bodies = 0
	_explosions = 0
	_explosions_speed = 0
	_explosions_jump = 0
	_merges_tangled_at_birth = 0
	_merges_from_folded_parent = 0
	_birth_events.clear()
	_birth_event_kinds.clear()
	_births_wrong.clear()
	_births_wrong_by_cause.clear()
	_births_dumped = 0
	_capped_frames = 0
	_capped_near_birth = 0
	_capped_velocities = 0
	_capped_reports = 0

func _on_birth_event(kind: String, description: String) -> void:
	_birth_events.append(description)
	_birth_event_kinds[kind] = true
	if kind == "merge":
		_on_birth_merge()

# How many times the bead loop crosses itself (at least).
static func _crossings(points: PackedVector2Array) -> int:
	return GooLoop.split_at_crossings(points, 32).size() - 1

static func _shape_name(body: Goo2D) -> String:
	return "round" if body.shape == null or body.shape.is_round() else "%d-point shape" % body.shape.outline.size()

func _describe_birth(body: Goo2D, info: Dictionary) -> String:
	return "%s radius %.0f (id %d, age %d frames, made by %s), %d crossings, fastest bead %.0f px/s, area %.0f%% of target, merging %s, settled %s" % [
		info["shape"], body.radius, body.id, _birth_frame - int(info["born"]), info["cause"], info["crossings"], info["speed"],
		100.0 * body.area() / maxf(body.target_area, 1.0), body.merging, body.settled]

# After each step: counts explosions and tangled bodies, and reports the births
# gone wrong (bodies at most BIRTH_AGE steps old) with what made them: the
# world's signals since the last check, or a spawn when there were none.
func _check_births() -> void:
	if not _watching_births:
		return
	_birth_frame += 1
	var now: Dictionary = {}
	var kinds: Array = _birth_event_kinds.keys()
	kinds.sort()
	var cause := "spawn" if kinds.is_empty() else "+".join(PackedStringArray(kinds))
	for body: Goo2D in _game.bodies():
		var points := body.bead_points()
		var fastest := 0.0
		for i: int in body.particle_count():
			fastest = maxf(fastest, body.bead_velocity(i).length())
		var crossings := _crossings(points)
		var previous: Dictionary = _birth_last.get(body.id, {})
		var info := {
			"crossings": crossings, "speed": fastest, "born": previous.get("born", _birth_frame), "loop": points,
			"radius": body.radius, "shape": _shape_name(body), "cause": previous.get("cause", cause),
		}
		now[body.id] = info
		if crossings >= 2:
			_tangled_runs[body.id] = _tangled_runs.get(body.id, 0) + 1
			if _tangled_runs[body.id] == 1:
				_tangled_bodies += 1
				if _birth_reports < BIRTH_REPORTS:
					_birth_reports += 1
					print("frame %d TANGLED: %s" % [_birth_frame, _describe_birth(body, info)])
					print("    bead radius %s, corners %s, beads %s" % [body.bead_radius(), body.corner_flags(), points])
			elif _tangled_runs[body.id] == 30 and _birth_reports < BIRTH_REPORTS:
				print("frame %d still tangled after 30 frames: %s" % [_birth_frame, _describe_birth(body, info)])
		else:
			_tangled_runs.erase(body.id)
		var jump := fastest - float(previous.get("speed", fastest))
		if fastest > _u(EXPLODE_SPEED) or jump > _u(EXPLODE_JUMP):
			_explosions += 1
			_explosions_speed += 1 if fastest > _u(EXPLODE_SPEED) else 0
			_explosions_jump += 1 if jump > _u(EXPLODE_JUMP) else 0
			if _explosions <= BIRTH_REPORTS:
				print("frame %d EXPLOSION: %s (jump %.0f px/s; %d crossings last frame)" % [
					_birth_frame, _describe_birth(body, info), jump, previous.get("crossings", -1)])
		var age := _birth_frame - int(info["born"])
		var area := body.area()
		var wrong := fastest > _u(BIRTH_FAST_SPEED) or crossings >= 1 \
			or area > BIRTH_AREA_RANGE.y * body.target_area or area < BIRTH_AREA_RANGE.x * body.target_area
		if age > BIRTH_AGE or not wrong or _births_wrong.has(body.id):
			continue
		_births_wrong[body.id] = true
		_births_wrong_by_cause[info["cause"]] = _births_wrong_by_cause.get(info["cause"], 0) + 1
		if _births_dumped >= BIRTH_DUMPS:
			continue
		_births_dumped += 1
		print("frame %d BIRTH GONE WRONG (age %d): %s; events since the last frame: %s" % [
			_birth_frame, age, _describe_birth(body, info), _birth_events])
		print("    outline %d points, %d beads, bead radius %.2f, area %.0f, target_area %.0f, rest area %.0f" % [
			body.shape.outline.size() if body.shape != null else 0, body.particle_count(), body.bead_radius(), area,
			body.target_area, GooLoop.area(body.rest_shape)])
		print("    beads %s" % [points])
		print("    rest_shape %s" % [body.rest_shape])
		var velocities := PackedVector2Array()
		for i: int in body.particle_count():
			velocities.append(body.bead_velocity(i))
		print("    velocities %s" % [velocities])
		for id: int in _birth_last:
			if not now.has(id) and not _game.bodies().any(func(b: Goo2D) -> bool: return b.id == id):
				print("    gone (a parent): %s radius %.0f, %d crossings, beads %s" % [
					_birth_last[id]["shape"], _birth_last[id]["radius"], _birth_last[id]["crossings"], _birth_last[id]["loop"]])
	_check_cap(now)
	_birth_last = now
	_birth_events.clear()
	_birth_event_kinds.clear()

# Counts the frames in which the kernel clamped a velocity to the speed cap, and
# reports the first few with no body near its birth (the cap felt in play).
func _check_cap(now: Dictionary) -> void:
	var capped := int(_game.kernel().solver().get("last_capped", 0))
	if capped == 0:
		return
	_capped_frames += 1
	_capped_velocities += capped
	var fastest_id := -1
	for id: int in now:
		if _birth_frame - int(now[id]["born"]) <= CAP_NEAR_BIRTH:
			_capped_near_birth += 1
			return
		if fastest_id < 0 or float(now[id]["speed"]) > float(now[fastest_id]["speed"]):
			fastest_id = id
	if _capped_reports < BIRTH_REPORTS and fastest_id >= 0:
		_capped_reports += 1
		var info: Dictionary = now[fastest_id]
		print("frame %d CAPPED with no body near its birth: %d velocities clamped; fastest %s radius %.0f (id %d, age %d frames), %.0f px/s"
			% [_birth_frame, capped, info["shape"], info["radius"], fastest_id, _birth_frame - int(info["born"]), info["speed"]])

# A merge during `births`: its parents are the bodies of the last check that are
# gone now, its child the body that is new.
func _on_birth_merge() -> void:
	var alive: Dictionary = {}
	for body: Goo2D in _game.bodies():
		alive[body.id] = body
	var parents: Array[Dictionary] = []
	for id: int in _birth_last:
		if not alive.has(id):
			parents.append(_birth_last[id])
	if parents.any(func(p: Dictionary) -> bool: return int(p["crossings"]) >= 1):
		_merges_from_folded_parent += 1
	for id: int in alive:
		if _birth_last.has(id):
			continue
		var child: Goo2D = alive[id]
		var crossings := _crossings(child.bead_points())
		if crossings < 1:
			continue
		_merges_tangled_at_birth += 1
		if _birth_reports < BIRTH_REPORTS:
			_birth_reports += 1
			print("frame %d MERGE BORN TANGLED: child radius %.0f (id %d) %d crossings; parents: %s" % [_birth_frame, child.radius, id, crossings,
				parents.map(func(p: Dictionary) -> String: return "%s radius %.0f with %d crossings" % [p["shape"], p["radius"], p["crossings"]])])
			print("    child beads %s" % [child.bead_points()])
			for parent: Dictionary in parents:
				print("    parent beads %s" % [parent["loop"]])

# ---- scale ----

## Height, px at unit 1, the smallest blob is dropped from in `scale`, measured
## from where its bottom rests to where it starts.
const SCALE_DROP: float = 500.0
## Seconds `scale` watches a rebound after the first touch, and waits at most
## for a blob to settle.
const SCALE_WATCH: float = 1.5
const SCALE_SETTLE_LIMIT: float = 10.0

# The length unit's gate: the smallest blob's rebound from SCALE_DROP, the time
# blobs of three sizes take to settle on the floor after that drop, and whether
# launch-size blobs let go above the wedge's apex split on it. Lengths are
# printed in px at unit 1 (divided by the unit) and in px as played.
func _scale() -> void:
	var step := 1.0 / Engine.physics_ticks_per_second
	print("blob (px at unit 1) | rebound, unit-1 px (played px) | first touch to settled")
	for size: float in [GooTuning.MIN_RADIUS, 40.0, 90.0]:
		await _reset()
		var radius := _u(size)
		var floor_y := _floor_centre().y
		var blob := _game.spawn(radius, _floor_centre() - Vector2(0.0, radius + _u(SCALE_DROP)))
		var contact_y := NAN
		var highest := INF
		var touched_at := -1.0
		var settled_at := -1.0
		var elapsed := 0.0
		while elapsed < SCALE_SETTLE_LIMIT and _live(blob):
			await physics_frame
			elapsed += step
			if is_nan(contact_y):
				if _lowest_bead(blob) >= floor_y - _u(2.0):
					contact_y = blob.center().y
					highest = contact_y
					touched_at = elapsed
				continue
			if elapsed - touched_at <= SCALE_WATCH:
				highest = minf(highest, blob.center().y)
			if blob.settled:
				settled_at = elapsed
				break
		var rebound := contact_y - highest if not is_nan(contact_y) else NAN
		print("round %-13.0f | %6.2f (%6.2f)              | %s" % [size, rebound / _unit, rebound,
			("%.2f s" % (settled_at - touched_at)) if settled_at >= 0.0 else "never (%d splits)" % _splits])
	print("blob (px at unit 1) | let go above the wedge's apex: splits, trims, bodies after 3 s")
	for size: float in [28.0, 36.0, 48.0]:
		for sides: int in [0, 4]:
			await _reset()
			var radius := _u(size)
			var apex := _arena.wedge_apex()
			_game.spawn(radius, Vector2(apex.x, _at(Vector2(0.0, Arena.DROP_Y)).y), _shape_of(sides, radius))
			await _frames(180)
			print("%-19s | %d splits, %d trims, %d bodies" % [_name_of(sides, size), _splits, _trims, _game.bodies().size()])
	print("blob (px at unit 1) | thrown from the launch point at 370 px/s, onto the apex (tools/trace.gd's first launch)")
	for size: float in [28.0, 36.0, 48.0]:
		await _reset()
		var blob := _game.spawn(_u(size), _arena.launch_point())
		blob.set_velocity(Vector2(-_u(370.0), 0.0))
		await _frames(180)
		print("%-19s | %d splits, %d trims, %d bodies" % [_name_of(0, size), _splits, _trims, _game.bodies().size()])

# Lowest point of any bead's collision circle of `body`.
static func _lowest_bead(body: Goo2D) -> float:
	var lowest := -INF
	for point: Vector2 in body.bead_points():
		lowest = maxf(lowest, point.y + body.bead_radius())
	return lowest
