extends SceneTree
## Benchmark: plays a fixed pile headless and prints frame-time statistics, so
## a performance change can be measured before and after.
##
##   godot --headless --fixed-fps 60 --path . -s tools/bench.gd -- [scenario ...] [--frames=N] [--seed=S] [--unit=U]
##
## --unit=U plays the piles at GooTuning.unit U (1 by default): the arena scaled
## by U in the scene and every drop's radius and position with it, so at 0.5 each
## pile is the same pile at half size (the plan's sizes below are px at unit 1).
##
## Scenarios (default: all): round40 (40 launch-size round blobs spread over the
## arena), packed30 (30 launch-size squares and triangles dropped into a narrow
## column, so they pack and fuse into complex shapes), big12 (12 blobs of radius
## 90-176 in a column), mixed40 (40 of everything, half the arena wide), pile40 (40
## round blobs of three sizes too different to merge, in a column: a lasting packed
## pile) and shapepile40 (the same column, every other drop a square or a triangle
## between round ones, so few of them fuse) and mixed80 (80 of mixed40's mix over the
## whole arena width: the scaling check against mixed40). Each drops
## one body every 6 physics frames from Arena.DROP_Y, then runs --frames more (default
## 300). Per physics frame it measures the wall clock between consecutive physics
## frames: under --fixed-fps headless that is one whole iteration, the scripts'
## _physics_process (the goo's kernel steps in the world's) and _process (where the skins
## are updated), the physics server's step and the canvas updates, with nothing drawn. It prints the mean, median, 95th percentile and worst of that, the same for
## the last 120 frames (the pile at rest or nearly), the live body and bead counts,
## merges and splits, Godot's TIME_PHYSICS_PROCESS monitor's worst value (that
## monitor only reports the worst physics frame of each second), and the cost per
## bead-frame (frame time over live beads: the fairest number when two runs play out
## differently). It also counts, every
## 4th physics frame, the pairs of non-merging bodies with a bead centre inside the
## other's bead loop (bodies sunk into or threaded through each other) and reports
## the pair-samples found, the worst count of beads inside, the longest run of
## consecutive samples one pair stayed inside, and how many pairs first got inside each
## other while one of them was fresh from a merge or a split (still merge-locked) or
## was being pulled into a merge.
## If a GooProf class is present (a scratch profiler), its section totals are
## printed too; the tool runs without it.
##
## Headless frames run as fast as the machine allows, so absolute numbers are this
## machine's; compare runs on the same machine.

const MAIN_SCENE := "res://scenes/main.tscn"
const DROP_EVERY: int = 6
var _scenarios: Array[String] = []
var _settle_frames: int = 300
var _seed: int = 20261014
# The goo's length unit the piles play at (--unit=U).
var _unit: float = 1.0

var _main: Node
var _world: GooWorld2D
# The node whose space the plan's px are in (the arena).
var _space: Node2D
var _rng := RandomNumberGenerator.new()
var _plan: Array[Dictionary] = []
var _next_drop: int = 0
var _frame: int = 0
var _end_frame: int = 0
var _frame_ms := PackedFloat64Array()
var _monitor_worst: float = 0.0
var _last_tick_usec: int = 0
var _merges: int = 0
var _splits: int = 0
var _started_usec: int = 0
var _scenario: String = ""
var _bead_counts := PackedInt32Array()
var _inside_samples: int = 0
var _inside_worst: int = 0
var _inside_runs: Dictionary = {}
var _inside_longest: int = 0
var _inside_pairs: int = 0
var _inside_fresh: int = 0
var _inside_merging: int = 0
var _count_due: bool = false

func _initialize() -> void:
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--frames="):
			_settle_frames = int(arg.trim_prefix("--frames="))
		elif arg.begins_with("--seed="):
			_seed = int(arg.trim_prefix("--seed="))
		elif arg.begins_with("--unit="):
			_unit = float(arg.trim_prefix("--unit="))
		elif not arg.begins_with("--"):
			_scenarios.append(arg)
	if _scenarios.is_empty():
		_scenarios = ["round40", "packed30", "big12", "mixed40", "pile40", "shapepile40"]
	# Before any world exists: a world's kernel takes the solver's settings when made.
	GooTuning.unit = _unit
	if _unit != 1.0:
		print("at GooTuning.unit %s: the arena and every drop scaled by it" % _unit)
	_start_next()

func _start_next() -> void:
	if _main != null:
		_main.queue_free()
		_main = null
	if _scenarios.is_empty():
		quit(0)
		return
	_scenario = _scenarios.pop_front()
	_main = (load(MAIN_SCENE) as PackedScene).instantiate()
	(_main.get_node("Arena") as Node2D).scale = Vector2(_unit, _unit)
	root.add_child(_main)
	_world = _main.get_node("Game") as GooWorld2D
	_space = _main.get_node("Arena") as Node2D
	# Counted after the world's kernel step (connected after the world's own
	# handler), so the count reads this frame's snapshot of the beads.
	if physics_frame.is_connected(_after_step):
		physics_frame.disconnect(_after_step)
	physics_frame.connect(_after_step)
	_count_due = false
	_world.merged.connect(func(_r: float, _p: Vector2) -> void: _merges += 1)
	_world.split.connect(func(_a: float, _b: float, _p: Vector2) -> void: _splits += 1)
	_rng.seed = _seed
	_plan = _make_plan(_scenario)
	_next_drop = 0
	_frame = 0
	_end_frame = _plan.size() * DROP_EVERY + _settle_frames
	_frame_ms = PackedFloat64Array()
	_monitor_worst = 0.0
	_last_tick_usec = 0
	_bead_counts = PackedInt32Array()
	_inside_samples = 0
	_inside_worst = 0
	_inside_runs = {}
	_inside_longest = 0
	_inside_pairs = 0
	_inside_fresh = 0
	_inside_merging = 0
	_merges = 0
	_splits = 0
	_started_usec = Time.get_ticks_usec()
	_reset_profile()

func _make_plan(name: String) -> Array[Dictionary]:
	var plan: Array[Dictionary] = []
	var centre := Arena.INNER_LEFT + Arena.INNER_WIDTH / 2.0
	match name:
		"round40":
			for i: int in 40:
				var radius := _rng.randf_range(DropController.DROP_MIN_RADIUS, DropController.DROP_MAX_RADIUS)
				plan.append({ "radius": radius, "x": _rng.randf_range(Arena.INNER_LEFT + radius + 4.0, Arena.INNER_RIGHT - radius - 4.0), "sides": 0 })
		"packed30":
			for i: int in 30:
				var radius := _rng.randf_range(DropController.DROP_MIN_RADIUS, DropController.DROP_MAX_RADIUS)
				plan.append({ "radius": radius, "x": _rng.randf_range(centre - 180.0, centre + 180.0), "sides": 4 if _rng.randf() < 0.5 else 3 })
		"big12":
			for i: int in 12:
				var radius := _rng.randf_range(90.0, GooTuning.MAX_RADIUS)
				plan.append({ "radius": radius, "x": _rng.randf_range(centre - 300.0, centre + 300.0), "sides": 0 })
		"mixed40":
			for i: int in 40:
				var radius := _rng.randf_range(DropController.DROP_MIN_RADIUS, 90.0)
				var roll := _rng.randf()
				plan.append({ "radius": radius, "x": _rng.randf_range(centre - 400.0, centre + 400.0), "sides": 0 if roll < 0.5 else (4 if roll < 0.75 else 3) })
		"mixed80":
			for i: int in 80:
				var radius := _rng.randf_range(DropController.DROP_MIN_RADIUS, 90.0)
				var roll := _rng.randf()
				plan.append({ "radius": radius, "x": _rng.randf_range(Arena.INNER_LEFT + radius + 4.0, Arena.INNER_RIGHT - radius - 4.0), "sides": 0 if roll < 0.5 else (4 if roll < 0.75 else 3) })
		"pile40":
			for i: int in 40:
				plan.append({ "radius": [30.0, 42.0, 60.0][i % 3], "x": _rng.randf_range(centre - 180.0, centre + 180.0), "sides": 0 })
		"shapepile40":
			for i: int in 40:
				plan.append({ "radius": [30.0, 42.0, 60.0, 36.0][i % 4], "x": _rng.randf_range(centre - 180.0, centre + 180.0), "sides": [0, 4, 0, 3][i % 4] })
		_:
			push_error("bench: unknown scenario %s" % name)
	return plan

func _physics_process(_delta: float) -> bool:
	if _main == null:
		return false
	var now := Time.get_ticks_usec()
	if _last_tick_usec > 0:
		_frame_ms.append((now - _last_tick_usec) / 1000.0)
		_monitor_worst = maxf(_monitor_worst, Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0)
		_bead_counts.append(_live_beads())
	_last_tick_usec = now
	if _next_drop < _plan.size() and _frame % DROP_EVERY == 0:
		var drop := _plan[_next_drop]
		_next_drop += 1
		var sides: int = drop["sides"]
		var radius: float = drop["radius"] * _unit
		var shape: GooShape = null if sides == 0 else GooShape.regular(sides, radius)
		var drop_y := Arena.DROP_Y
		_world.spawn(radius, _space.to_global(Vector2(drop["x"], drop_y)), shape)
	_count_due = _frame % 4 == 0
	_frame += 1
	if _frame > _end_frame:
		_report()
		_start_next()
	return false

func _after_step() -> void:
	if _main != null and _count_due:
		_count_due = false
		_count_inside()

func _count_inside() -> void:
	var bodies := _world.bodies()
	var seen: Dictionary = {}
	var now := float(Engine.get_physics_frames()) / Engine.physics_ticks_per_second
	for i: int in bodies.size():
		var a := bodies[i]
		if a.particle_count() == 0:
			continue
		for j: int in range(i + 1, bodies.size()):
			var b := bodies[j]
			if b.particle_count() == 0:
				continue
			var reach := a.radius + b.radius
			if a.center().distance_squared_to(b.center()) > reach * reach:
				continue
			var inside := a.beads_inside(b, 0.0) + b.beads_inside(a, 0.0)
			if inside == 0:
				continue
			var key := Vector2i(mini(a.id, b.id), maxi(a.id, b.id))
			seen[key] = true
			if not _inside_runs.has(key):
				_inside_pairs += 1
				if a.merging or b.merging:
					_inside_merging += 1
				elif a.merge_lock_until > now or b.merge_lock_until > now:
					_inside_fresh += 1
			_inside_runs[key] = int(_inside_runs.get(key, 0)) + 1
			_inside_longest = maxi(_inside_longest, _inside_runs[key])
			_inside_samples += 1
			_inside_worst = maxi(_inside_worst, inside)
	for key: Vector2i in _inside_runs.keys():
		if not seen.has(key):
			_inside_runs.erase(key)

func _live_beads() -> int:
	var total := 0
	for body: Goo2D in _world.bodies():
		total += body.particle_count()
	return total

func _report() -> void:
	var wall_ms := (Time.get_ticks_usec() - _started_usec) / 1000.0
	var bodies := _world.bodies()
	var settled := 0
	var beads := 0
	for body: Goo2D in bodies:
		beads += body.particle_count()
		if body.settled:
			settled += 1
	var peak_beads := 0
	for count: int in _bead_counts:
		peak_beads = maxi(peak_beads, count)
	print("bench %s: %d frames, %d bodies (%d settled), %d beads (peak %d), %d merges, %d splits, %.0f ms wall"
		% [_scenario, _frame - 1, bodies.size(), settled, beads, peak_beads, _merges, _splits, wall_ms])
	print("  frame            %s" % _stats(_frame_ms))
	# The last 120 frames alone: the pile at rest or nearly, without the drops.
	var tail := 120
	if _frame_ms.size() > tail:
		print("  frame, last %d  %s" % [tail, _stats(_frame_ms.slice(_frame_ms.size() - tail))])
	print("  TIME_PHYSICS_PROCESS monitor, worst second: %.2f ms" % _monitor_worst)
	# Cost per bead-frame: compares runs that played out differently (other merges,
	# other bead counts) better than the frame alone does.
	var bead_frames := 0
	var frame_total := 0.0
	for i: int in mini(_bead_counts.size(), _frame_ms.size()):
		bead_frames += _bead_counts[i]
		frame_total += _frame_ms[i]
	if bead_frames > 0:
		print("  mean %.0f live beads; %.2f us per bead-frame" % [float(bead_frames) / _bead_counts.size(), 1000.0 * frame_total / bead_frames])
	print("  bodies inside each other: %d pair-samples (every 4th frame), worst %d beads inside, longest %d samples (%.1f s) for one pair; %d pairs got inside each other: %d with a body fresh from a merge or split, %d with one being pulled into a merge, %d other"
		% [_inside_samples, _inside_worst, _inside_longest, _inside_longest * 4.0 / 60.0, _inside_pairs, _inside_fresh, _inside_merging,
			_inside_pairs - _inside_fresh - _inside_merging])
	_print_profile(_frame - 1)

static func _stats(samples: PackedFloat64Array) -> String:
	if samples.is_empty():
		return "no samples"
	var sorted := samples.duplicate()
	sorted.sort()
	var total := 0.0
	for sample: float in sorted:
		total += sample
	return "mean %.2f ms, median %.2f, p95 %.2f, worst %.2f" % [total / sorted.size(),
		sorted[sorted.size() / 2], sorted[int(0.95 * (sorted.size() - 1))], sorted[sorted.size() - 1]]

# Optional scratch profiler (a class_name GooProf with a static `totals`
# Dictionary of section name -> usec and `counts` of section name -> calls).
func _reset_profile() -> void:
	var prof := _profiler()
	if prof != null:
		prof.call("reset")

func _print_profile(frames: int) -> void:
	var prof := _profiler()
	if prof == null:
		return
	var totals: Dictionary = prof.call("totals_dict")
	var counts: Dictionary = prof.call("counts_dict")
	var keys := totals.keys()
	keys.sort()
	print("  script sections (ms per frame over %d frames; calls per frame):" % frames)
	for key: String in keys:
		print("    %-28s %7.3f ms  %8.1f calls" % [key, float(totals[key]) / 1000.0 / frames, float(counts.get(key, 0)) / frames])

static func _profiler() -> Script:
	var path := "res://tools/goo_prof.gd"
	return load(path) as Script if ResourceLoader.exists(path) else null
