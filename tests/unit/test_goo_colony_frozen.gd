extends TestCase
## The colony's frozen topology (docs/colony-frozen.md), through GooColonySim at unit 0.5:
## as sound as the full model in a crash and a crowd; joins only at retopologies, at a
## request or on the timer; breaks at once or held until one; the events as signals; cells
## added and removed; muscles that ask for no exposure pass; worms and a blob swimming by
## muscle waves; a swimming worm keeping most of its own contact lists; the surface tension
## between retopologies; the threaded step equal to the serial one; a seeded random game
## staying sound. Each test prints what it measures.

const DELTA: float = 1.0 / 60.0

func before_each() -> void:
	GooTuning.unit = 0.5

func after_each() -> void:
	GooTuning.unit = 1.0

# ---- Fixtures ----

static func _frozen(extra: Dictionary = {}) -> GooColonySim:
	var options := GooColonySim.frozen_options()
	options.merge(extra, true)
	return GooColonySim.new(options)

static func _full(extra: Dictionary = {}) -> GooColonySim:
	var options := GooColonySim.everything_options()
	options.merge(extra, true)
	return GooColonySim.new(options)

static func _hex(rings: int, at: Vector2 = Vector2.ZERO) -> Array:
	var r := GooTuning.min_radius()
	var cells: Array = []
	for q: int in range(-rings, rings + 1):
		for p: int in range(-rings, rings + 1):
			if absi(p + q) <= rings:
				cells.append({ "position": at + Vector2(p * 2.0 * r + q * r, q * sqrt(3.0) * r), "radius": r })
	return cells

## A worm `long` × `wide` cells along +x from `at`, its inside cells cores, no damping of
## its own (the water drags it); `uv` gets each cell's (0..1 tail to head, -1..1 across).
static func _worm(long: int, wide: int, at: Vector2, uv: Array) -> Array:
	var r := GooTuning.min_radius()
	var cells: Array = []
	uv.clear()
	for c: int in long:
		for j: int in wide:
			cells.append({ "position": at + Vector2(c * 2.0 * r + (j % 2) * r, j * sqrt(3.0) * r), "radius": r,
				"core": j > 0 and j < wide - 1 and c > 0 and c < long - 1 })
			uv.append(Vector2(c / float(long - 1), (j - (wide - 1) * 0.5) / ((wide - 1) * 0.5)))
	return cells

## A hex blob of `rings` rings, its inside cells cores; `uv` as _worm()'s.
static func _blob(rings: int, uv: Array) -> Array:
	var cells := _hex(rings)
	uv.clear()
	for c: Dictionary in cells:
		var p: Vector2 = c["position"]
		var span := rings * 2.0 * GooTuning.min_radius()
		uv.append(Vector2((p.x + span) / (2.0 * span), p.y / maxf(span, 1.0)))
		c["core"] = p.length() < (rings - 0.5) * 2.0 * GooTuning.min_radius()
	return cells

## Adds `cells` to `sim` with no damping of their own and a quarter of the internal one (the
## fluid game's bodies'), as tools/colony_swim.gd does.
static func _add_swimmer(sim: GooColonySim, cells: Array) -> int:
	var floats := PackedFloat32Array()
	for c: Dictionary in cells:
		var f := GooColonySim.cell_floats(c["position"], c["radius"], c.get("core", false), Color.WHITE, 0.0, sim.cell_beads)
		f[14] *= 0.25
		floats.append_array(f)
	return sim.colony.add_creature(floats)

## One frame of a muscle wave running tail-ward: bend (one side against the other) or
## squeeze (whole columns), eased in over the first second.
static func _muscles(sim: GooColonySim, c: int, uv: Array, frame: int, gait: String, amp: float, waves: float, freq: float) -> void:
	var ramp := clampf((frame - 20) / 40.0, 0.0, 1.0)
	var scales := PackedFloat32Array()
	for p: Vector2 in uv:
		var s := sin(TAU * (waves * p.x + freq * frame * DELTA))
		scales.append(1.0 + amp * ramp * s * (p.y if gait == "bend" else 1.0))
	sim.colony.set_cell_muscles(c, scales)

static func _worst(into: Dictionary, sim: GooColonySim) -> void:
	var snd := sim.colony.soundness()
	for key: String in snd:
		if key == "area_min":
			into[key] = minf(into.get(key, INF), snd[key])
		else:
			into[key] = maxf(into.get(key, 0.0), snd[key])

static func _sound(w: Dictionary) -> String:
	return "own inside %d, cross inside %d, inside out %d, ring area min %.2f, core overlap own %.1f / cross %.1f px" % [
		int(w["own_inside"]), int(w["cross_inside"]), int(w["inverted"]), w["area_min"], w["own_core_overlap"], w["cross_core_overlap"]]

# ---- Soundness against the full model ----

func test_a_crash_is_as_sound_frozen_as_in_the_full_model() -> void:
	# Two clusters of 37 thrown into each other at 600 px/s each (docs/colony-exposure.md's
	# crash; tools/colony_crash.gd has 91 too), soundness every frame for 1.5 s.
	var results := {}
	for model: String in ["full", "frozen"]:
		var sim := _full({ "threads": 4 }) if model == "full" else _frozen({ "threads": 4 })
		var gap := 4 * 2.0 * GooTuning.min_radius() * 1.1
		var a := sim.add_creature(_hex(3, Vector2(-gap, 0)))
		var b := sim.add_creature(_hex(3, Vector2(gap, 14)))
		for f: int in 30:
			sim.step(DELTA)
		sim.colony.set_creature_velocity(a, Vector2(600, 0))
		sim.colony.set_creature_velocity(b, Vector2(-600, 0))
		var w := {}
		var hits := 0
		for f: int in 90:
			sim.step(DELTA)
			_worst(w, sim)
			hits = maxi(hits, sim.colony.stats()["cross_hits"])
		print("    %-6s: %s; up to %d contacts between them" % [model, _sound(w), hits])
		results[model] = w
		assert_gt(hits, 0, "they met")
	var full: Dictionary = results["full"]
	var frozen: Dictionary = results["frozen"]
	assert_eq(frozen["inverted"], 0.0, "no cell inside out")
	assert_eq(frozen["cross_inside"], 0.0, "no particle inside the other creature")
	assert_lt(frozen["own_inside"], full["own_inside"] + 3.0, "own particles inside own cells no more than the full model's")
	assert_gt(frozen["area_min"], full["area_min"] - 0.05, "rings squeezed no more than the full model's")

func test_a_crowd_thrown_together_is_as_sound_frozen_as_in_the_full_model() -> void:
	# Eight clusters of 19 pushed hard toward the middle and back out, 4 s, three times
	# (the ring of them turned differently each time): the worst of each run summed. One
	# run's worst is chaotic (the full model alone gave 9 to 14 own particles inside own
	# cells over variants that change nothing physical), so the sums are compared.
	var totals := {}
	for model: String in ["full", "frozen"]:
		var sum := { "own_inside": 0.0, "cross_inside": 0.0, "inverted": 0.0, "area_min": INF }
		var line := ""
		for turn: float in [0.0, 0.25, 0.5]:
			var sim := _full({ "threads": 4 }) if model == "full" else _frozen({ "threads": 4 })
			var n := 8
			for k: int in n:
				sim.add_creature(_hex(2, Vector2.from_angle(TAU * (k + turn) / n) * 230.0))
			var w := {}
			var hits := 0
			for f: int in 240:
				if f % 60 == 0:
					for k: int in n:
						sim.colony.push_creature(k, -Vector2.from_angle(TAU * (k + turn) / n) * (1500.0 if f % 120 == 0 else -600.0))
				sim.step(DELTA)
				hits = maxi(hits, sim.colony.stats()["cross_hits"])
				if f % 5 == 0:
					_worst(w, sim)
			assert_gt(hits, 0, "they met")
			line += " [%s]" % _sound(w)
			for key: String in ["own_inside", "cross_inside", "inverted"]:
				sum[key] += w[key]
			sum["area_min"] = minf(sum["area_min"], w["area_min"])
		print("    %-6s:%s" % [model, line])
		totals[model] = sum
	var full: Dictionary = totals["full"]
	var frozen: Dictionary = totals["frozen"]
	print("    summed over the three: full %d own inside, frozen %d" % [int(full["own_inside"]), int(frozen["own_inside"])])
	assert_eq(frozen["inverted"], 0.0)
	assert_eq(frozen["cross_inside"], 0.0)
	assert_lt(frozen["own_inside"], 1.5 * full["own_inside"] + 6.0)
	assert_gt(frozen["area_min"], full["area_min"] - 0.05)

# ---- When the topology changes ----

func test_joins_wait_for_a_retopology_and_come_with_its_events() -> void:
	# Two cells of one creature 12 px apart, the second pushed onto the first: with no timer
	# they touch for a second without joining; a request joins them in the next step, its
	# cells_joined signal emitted after that step. Frames with events are retopology frames.
	var sim := _frozen({ "retopo_every": 0 })
	var r := GooTuning.min_radius()
	var k := sim.add_creature([{ "position": Vector2(-r - 6, 0), "radius": r }, { "position": Vector2(r + 6, 0), "radius": r }])
	var joined: Array = []
	sim.cells_joined.connect(func(c: int, a: int, b: int) -> void: joined.append(Vector3i(c, a, b)))
	sim.colony.push_cell(k, 1, Vector2(-400, 0))
	var touching_at := -1
	for f: int in 90:
		sim.step(DELTA)
		var gap := sim.colony.cell_center(k, 0).distance_to(sim.colony.cell_center(k, 1)) - 2.0 * r
		if touching_at < 0 and gap < 0.0:
			touching_at = f
		assert_true(joined.is_empty(), "no join between retopologies (frame %d)" % f)
	sim.colony.push_cell(k, 1, Vector2.ZERO)
	print("    touching from frame %d, still apart at frame 90: %d sticks, %d joins" % [touching_at, sim.colony.creature_sticks(k).size() / GooColony.STICK_FLOATS, joined.size()])
	assert_gt(touching_at, -1, "they touch")
	sim.request_retopology(k)
	sim.step(DELTA)
	print("    after the request: %d retopology, %d sticks, joins %s" % [sim.colony.stats()["retopos"], sim.colony.creature_sticks(k).size() / GooColony.STICK_FLOATS, joined])
	assert_eq(sim.colony.stats()["retopos"], 1)
	assert_eq(joined, [Vector3i(k, 0, 1)], "joined in the request's step, its signal after it")

func test_the_timer_staggers_retopologies_and_only_they_join() -> void:
	# Six creatures of 19 cells, the default timer: one retopology a creature every
	# RETOPO_EVERY frames, staggered; every joined event arrives on a frame the creature
	# retopologised (the per-frame count of retopologies equals the creatures due).
	var sim := _frozen()
	var n := 6
	for c: int in n:
		sim.add_creature(_hex(2, Vector2(c * 200.0, 0)))
	var joined_frames := {}
	var now := { "frame": 0 }  # (a lambda captures a local's value, a Dictionary by reference)
	sim.cells_joined.connect(func(c: int, _a: int, _b: int) -> void: joined_frames[Vector2i(c, now["frame"])] = true)
	var retopos := 0
	var most := 0
	for f: int in 120:
		now["frame"] = f + 1
		sim.step(DELTA)
		var st := sim.colony.stats()
		retopos += st["retopos"]
		if f >= 1:
			most = maxi(most, st["retopos"])
	var every := GooColonySim.RETOPO_EVERY
	print("    %d retopologies over 120 frames (%d creatures, every %d frames), at most %d in a frame after the first; joins on %d creature-frames" % [
		retopos, n, every, most, joined_frames.size()])
	# The first frame retopologises every creature; then each once per RETOPO_EVERY frames.
	assert_lt(absi(retopos - (n + n * 119 / every)), n + 1)
	assert_lt(most, 2, "staggered: no two creatures in one frame (6 creatures, every 30)")
	for key: Vector2i in joined_frames:
		var due := key.y == 1 or (key.y + key.x) % every == 0
		assert_true(due, "creature %d joined on frame %d, not one of its retopologies" % [key.x, key.y])

func test_a_wall_past_the_break_force_breaks_at_once_or_at_the_next_retopology() -> void:
	# Two joined cells pulled apart hard. frozen_breaks (the preset): the wall breaks within
	# a few frames, cells_parted with it. Off: it holds until a retopology (requested here),
	# which breaks it; urgent_retopo asks for that one by itself.
	var r := GooTuning.min_radius()
	for mode: String in ["breaks at once", "held", "urgent"]:
		var extra := { "retopo_every": 0 }
		if mode != "breaks at once":
			extra["frozen_breaks"] = false
		if mode == "urgent":
			extra["urgent_retopo"] = true
		var sim := _frozen(extra)
		var k := sim.add_creature([{ "position": Vector2(-r, 0), "radius": r }, { "position": Vector2(r, 0), "radius": r }])
		var parted := []
		var now := { "frame": 0 }
		sim.cells_parted.connect(func(_c: int, _a: int, _b: int) -> void: parted.append(now["frame"]))
		for f: int in 20:
			now["frame"] = f
			sim.step(DELTA)
		var sticks := sim.colony.creature_sticks(k).size() / GooColony.STICK_FLOATS
		sim.colony.push_cell(k, 0, Vector2(-40000, 0))
		sim.colony.push_cell(k, 1, Vector2(40000, 0))
		var urgent := 0
		for f: int in 20:
			now["frame"] = 20 + f
			sim.step(DELTA)
			urgent += sim.colony.stats()["urgent"]
		var held := parted.is_empty()
		if mode == "held":
			sim.request_retopology(k)
			now["frame"] = 40
			sim.step(DELTA)
		print("    %-14s: %d sticks, pulled from frame 20: parted at frames %s%s" % [mode, sticks, parted, " (none before the request)" if mode == "held" and held else ""])
		assert_gt(sticks, 0, "joined at the first retopology")
		assert_eq(parted.size(), 1, "parted once")
		match mode:
			"breaks at once":
				assert_lt(parted[0], 30, "within a few frames of the pull")
			"held":
				assert_true(held, "no break between retopologies")
				assert_eq(parted[0], 40, "at the requested retopology")
			"urgent":
				assert_gt(urgent, 0, "an urgent retopology was asked for")
				assert_lt(parted[0], 36, "the frame after the load (smoothed over load_time) passed the force")

func test_adding_and_removing_cells() -> void:
	# A cell added beside a creature joins it at the retopology it asks for; removing a
	# joined cell reports its pairs parted (old numbering) at once and renumbers the rest.
	var sim := _frozen({ "retopo_every": 0 })
	var r := GooTuning.min_radius()
	var k := sim.add_creature(_hex(1))
	var joined := []
	var parted := []
	sim.cells_joined.connect(func(_c: int, a: int, b: int) -> void: joined.append(Vector2i(a, b)))
	sim.cells_parted.connect(func(_c: int, a: int, b: int) -> void: parted.append(Vector2i(a, b)))
	for f: int in 10:
		sim.step(DELTA)
	var before := joined.size()
	var added := sim.add_cell(k, { "position": Vector2(4.0 * r, 0), "radius": r })
	sim.step(DELTA)
	var with_new := joined.filter(func(p: Vector2i) -> bool: return p.y == added)
	print("    7 cells joined in %d pairs; cell %d added: retopology %d, joins with it %s" % [before, added, sim.colony.stats()["retopos"], with_new])
	assert_eq(added, 7)
	assert_eq(sim.colony.cell_count(k), 8)
	assert_false(with_new.is_empty(), "the new cell joined its neighbour at the retopology it asked for")
	for f: int in 10:
		sim.step(DELTA)
	parted.clear()
	var removed := sim.remove_cell(k, 3)  # the middle cell, joined to all six around it
	print("    cell 3 removed: %s; parted at once %s; %d cells left" % [removed, parted, sim.colony.cell_count(k)])
	assert_true(removed)
	assert_eq(sim.colony.cell_count(k), 7)
	assert_gt(parted.size(), 3, "the middle cell's pairs reported parted")
	for p: Vector2i in parted:
		assert_true(p.x == 3 or p.y == 3, "in the numbering before the removal")
	var w := {}
	for f: int in 60:
		sim.step(DELTA)
		_worst(w, sim)
	print("    a second after: %s" % _sound(w))
	assert_eq(w["inverted"], 0.0)
	assert_false(sim.remove_cell(k, 99), "no such cell")

func test_muscles_ask_for_no_exposure_pass() -> void:
	# The full model, every cell resized every frame: resize_cell() runs the exposure pass
	# every frame; set_cell_muscles() only on its regular frames.
	var runs := {}
	for how: String in ["resize_cell", "muscles"]:
		var sim := _full()
		var uv: Array = []
		var k := _add_swimmer(sim, _worm(10, 3, Vector2.ZERO, uv))
		var r := GooTuning.min_radius()
		var total := 0
		for f: int in 120:
			if how == "resize_cell":
				for i: int in uv.size():
					sim.colony.resize_cell(k, i, r * (1.0 + 0.1 * sin(TAU * (uv[i].x + f * DELTA))))
			else:
				var scales := PackedFloat32Array()
				for p: Vector2 in uv:
					scales.append(1.0 + 0.1 * sin(TAU * (p.x + f * DELTA)))
				sim.colony.set_cell_muscles(k, scales)
			sim.step(DELTA)
			total += sim.colony.stats()["exposure_runs"]
		runs[how] = total
		print("    %-11s: %d exposure passes in 120 frames; cell 0 at %.2f px (muscle %.2f)" % [how, total, sim.colony.cell_radius(k, 0), sim.colony.cell_muscle(k, 0)])
	assert_gt(runs["resize_cell"], 110)
	assert_lt(runs["muscles"], 20)

# ---- Propulsion ----

func test_worms_and_a_blob_swim_by_muscle_waves() -> void:
	# Frozen, drag and tension on, a wave of muscles running tail-ward; 3 s after 1 s to
	# settle. Speeds along +x (px/s, body lengths per cycle) above floors at about half of
	# what tools/colony_swim.gd measured.
	var gaits := [
		["worm squeeze", "worm", "squeeze", 0.3, 1.5, 1.0, 8.0],
		["worm bend", "worm", "bend", 0.3, 1.5, 0.5, 6.0],
		["blob squeeze", "blob", "squeeze", 0.3, 0.5, 1.0, 6.0],
	]
	for g: Array in gaits:
		var sim := _frozen({ "threads": 4 })
		var uv: Array = []
		var cells := _worm(24, 5, Vector2.ZERO, uv) if g[1] == "worm" else _blob(3, uv)
		var k := _add_swimmer(sim, cells)
		var length := 24 * 2.0 * GooTuning.min_radius() if g[1] == "worm" else 7 * 2.0 * GooTuning.min_radius()
		var start := Vector2.ZERO
		var w := {}
		for f: int in 240:
			_muscles(sim, k, uv, f, g[2], g[3], g[4], g[5])
			sim.step(DELTA)
			if f == 59:
				start = sim.colony.creature_center(k)
			if f % 10 == 0:
				_worst(w, sim)
		var moved := sim.colony.creature_center(k) - start
		var speed := moved.x / 3.0
		print("    %-12s: %.1f px/s along +x (%.1f across), %.3f body lengths per cycle; %s" % [g[0], speed, absf(moved.y) / 3.0, speed / g[5] / length, _sound(w)])
		assert_gt(speed, g[6], "%s swims forward" % g[0])
		assert_eq(w["inverted"], 0.0)

func test_a_swimming_worm_keeps_most_of_its_own_contact_lists() -> void:
	# A worm of 24 × 5 bending hard (the worm-bend gait): its own contacts come from the
	# cell-pair lists, most of which stay valid frame to frame (the Verlet list kept for
	# the whole creature was built again every frame: docs/colony-frozen.md).
	var results := {}
	for own: String in ["cells", "verlet"]:
		var sim := _frozen({ "frozen_self": 4 if own == "cells" else 3, "pair_skin": 8.0 if own == "cells" else 10.0 })
		var uv: Array = []
		var k := _add_swimmer(sim, _worm(24, 5, Vector2.ZERO, uv))
		var sums := { "cp_rebuilt": 0, "cp_lists": 0, "pair_builds": 0, "retopos": 0 }
		var frames := 0
		for f: int in 240:
			_muscles(sim, k, uv, f, "bend", 0.3, 1.5, 0.5)
			sim.step(DELTA)
			if f >= 60:
				frames += 1
				var st := sim.colony.stats()
				for key: String in sums:
					sums[key] += st[key]
		results[own] = sums
		print("    %-6s: over %d swimming frames, cell-pair lists built %d of %d judged (%.1f%%), whole-creature lists built %d times, %d retopologies" % [
			own, frames, sums["cp_rebuilt"], sums["cp_lists"], 100.0 * sums["cp_rebuilt"] / maxi(sums["cp_lists"], 1), sums["pair_builds"], sums["retopos"]])
	var cells: Dictionary = results["cells"]
	assert_eq(cells["pair_builds"], 0, "no whole-creature list")
	assert_lt(float(cells["cp_rebuilt"]), 0.35 * cells["cp_lists"], "most cell-pair lists kept from frame to frame")
	assert_gt(results["verlet"]["pair_builds"], 120, "the whole-creature Verlet list is built again on most swimming frames")

func test_the_tension_pulls_between_retopologies() -> void:
	# A ragged cluster with the frozen preset: the tension's forces act on frames with no
	# retopology too (along the outline of the last), and it rounds the cluster off.
	var rng := RandomNumberGenerator.new()
	rng.seed = 3
	var r := GooTuning.min_radius()
	var points: Array[Vector2] = [Vector2.ZERO]
	while points.size() < 30:
		var p := points[rng.randi() % points.size()] + Vector2.from_angle(rng.randf() * TAU) * 2.0 * r
		var free := true
		for q: Vector2 in points:
			if q.distance_to(p) < 2.0 * r - 0.01:
				free = false
		if free:
			points.append(p)
	var cells: Array = []
	for p: Vector2 in points:
		cells.append({ "position": p, "radius": r })
	var round := {}
	for strength: float in [0.0, GooColonySim.TENSION]:
		var sim := _frozen({ "tension": strength * GooTuning.unit })
		var k := sim.add_creature(cells)
		var pulled_between := 0
		for f: int in 180:
			sim.step(DELTA)
			if sim.colony.stats()["retopos"] == 0 and sim.colony.creature_tension_forces(k).size() > 0:
				pulled_between += 1
		var outline := sim.colony.creature_outline(k)
		var perimeter := 0.0
		for i: int in outline.size():
			perimeter += outline[i].distance_to(outline[(i + 1) % outline.size()])
		var area := absf(GooLoop.signed_area(outline))
		round[strength] = perimeter * perimeter / (4.0 * PI * maxf(area, 1.0))
		print("    strength %4.0f: perimeter² / 4π area %.2f after 3 s; tension forces on %d frames without a retopology" % [strength, round[strength], pulled_between])
		if strength > 0.0:
			assert_gt(pulled_between, 150, "the tension acts between retopologies")
	assert_lt(round[GooColonySim.TENSION], 0.85 * round[0.0], "and rounds the cluster off")

# ---- Determinism, a random game ----

## Six creatures of 19 cells, frozen, everything on, `threads`.
static func _game(threads: int) -> GooColonySim:
	var sim := _frozen({ "threads": threads })
	for c: int in 6:
		sim.add_creature(_hex(2, Vector2((c % 3) * 170.0, (c / 3) * 170.0 + (c % 2) * 20.0)))
	return sim

## One frame of the random game's driving: pushes, a hard poke, muscles, requests, a cell
## added or removed now and then.
static func _drive(sim: GooColonySim, rng: RandomNumberGenerator, f: int) -> void:
	var n := sim.colony.creature_count()
	if f % 30 == 0:
		for c: int in n:
			sim.colony.push_creature(c, Vector2.from_angle(rng.randf() * TAU) * rng.randf_range(300.0, 1500.0))
			sim.colony.push_cell(c, rng.randi_range(0, sim.colony.cell_count(c) - 1), Vector2.from_angle(rng.randf() * TAU) * rng.randf_range(0.0, 8000.0))
	if f % 45 == 20:
		sim.request_retopology(rng.randi_range(0, n - 1))
	if f % 70 == 35:
		var c := rng.randi_range(0, n - 1)
		var at := sim.colony.creature_center(c) + Vector2.from_angle(rng.randf() * TAU) * 70.0
		sim.add_cell(c, { "position": at, "radius": GooTuning.min_radius() })
	if f % 90 == 60:
		var c := rng.randi_range(0, n - 1)
		sim.remove_cell(c, rng.randi_range(0, sim.colony.cell_count(c) - 1))
	for c: int in n:
		var scales := PackedFloat32Array()
		for i: int in sim.colony.cell_count(c):
			scales.append(1.0 + 0.15 * sin(0.7 * i + f * 0.15))
		sim.colony.set_cell_muscles(c, scales)

func test_threaded_step_equals_serial_frozen() -> void:
	var serial := _game(1)
	var threaded := _game(4)
	var rng_a := RandomNumberGenerator.new()
	var rng_b := RandomNumberGenerator.new()
	rng_a.seed = 9
	rng_b.seed = 9
	var events_a := []
	var events_b := []
	serial.cells_joined.connect(func(c: int, a: int, b: int) -> void: events_a.append(Vector4i(1, c, a, b)))
	serial.cells_parted.connect(func(c: int, a: int, b: int) -> void: events_a.append(Vector4i(2, c, a, b)))
	threaded.cells_joined.connect(func(c: int, a: int, b: int) -> void: events_b.append(Vector4i(1, c, a, b)))
	threaded.cells_parted.connect(func(c: int, a: int, b: int) -> void: events_b.append(Vector4i(2, c, a, b)))
	for f: int in 200:
		_drive(serial, rng_a, f)
		_drive(threaded, rng_b, f)
		serial.step(DELTA)
		threaded.step(DELTA)
	print("    200 frames, 6 creatures (cells added and removed, muscles, requests), 1 thread against 4 spinning: %d events" % events_a.size())
	assert_gt(events_a.size(), 0)
	assert_eq(events_a, events_b, "the same events in the same order")
	for c: int in serial.colony.creature_count():
		assert_eq(serial.colony.creature_points(c), threaded.colony.creature_points(c), "creature %d's particles are bit for bit the serial ones" % c)
		assert_eq(serial.colony.creature_velocities(c), threaded.colony.creature_velocities(c))
		assert_eq(serial.colony.creature_tension_forces(c), threaded.colony.creature_tension_forces(c))

func test_a_seeded_random_game_with_retopologies_stays_sound() -> void:
	# The same driving for the full model and the frozen one (requests, cells added and
	# removed, muscles, pushes and pokes), 6 s.
	var results := {}
	for model: String in ["full", "frozen"]:
		var sim := _game(4) if model == "frozen" else _full({ "threads": 4 })
		if model == "full":
			for c: int in 6:
				sim.add_creature(_hex(2, Vector2((c % 3) * 170.0, (c / 3) * 170.0 + (c % 2) * 20.0)))
		var rng := RandomNumberGenerator.new()
		rng.seed = 5
		var w := {}
		var counts := { "retopos": 0, "to_core": 0, "to_ring": 0, "broken": 0, "made": 0 }
		var not_finite := 0.0
		for f: int in 360:
			_drive(sim, rng, f)
			sim.step(DELTA)
			var st := sim.colony.stats()
			for key: String in counts:
				counts[key] += st[key]
			if f % 5 == 0:
				_worst(w, sim)
				not_finite = maxf(not_finite, sim.colony.health()["not_finite"])
		print("    %-6s: %s; %d not finite; %s" % [model, _sound(w), int(not_finite), counts])
		assert_eq(not_finite, 0.0, "no NaN")
		results[model] = w
	var full: Dictionary = results["full"]
	var frozen: Dictionary = results["frozen"]
	assert_eq(frozen["inverted"], 0.0, "no cell inside out")
	assert_eq(frozen["cross_inside"], 0.0)
	assert_lt(frozen["own_inside"], 1.5 * full["own_inside"] + 6.0)
	assert_gt(frozen["area_min"], minf(0.5, full["area_min"] - 0.05))
