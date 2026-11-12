extends TestCase
## The colony's surface tension (milestone 3 of the colony plan, docs/colony-tension.md),
## through GooColonySim at unit 0.5 (and one test at unit 1): strength 0 and a slack type
## change nothing; the tension adds no net force or torque; a ragged cluster rounds off and
## stays so; two cells settle to a wider wall and stay still; a resting creature comes to
## rest; what the tension costs a worm's designed shape and at what strength it balls up;
## walls after an impact; pockets kept or closed; a seeded random game stays sound; the
## threaded step equals the serial one. Each test prints what it measures.

const DELTA: float = 1.0 / 60.0

func before_each() -> void:
	GooTuning.unit = 0.5

func after_each() -> void:
	GooTuning.unit = 1.0

# ---- Fixtures ----

## GooColonySim with exposure (and automatic, compliant, anchored cores) and the tension at
## `strength` (unit 1; 0: off), merged with `extra`.
static func _sim(strength: float, extra: Dictionary = {}) -> GooColonySim:
	var options := GooColonySim.EXPOSURE_OPTIONS.duplicate()
	if strength > 0.0:
		options.merge(GooColonySim.tension_options(strength))
	options.merge(extra, true)
	return GooColonySim.new(options)

static func _steps(sim: GooColonySim, frames: int) -> void:
	for f: int in frames:
		sim.step(DELTA)

## A ragged cluster of `count` cells of the smallest size: each new cell touches one picked
## at random, in a random direction, where it overlaps none (branches, bays, arms one cell
## wide); centred. (tools/colony_shot.gd's ragged scene draws the same.)
static func _ragged(count: int, seed_value: int, at: Vector2 = Vector2.ZERO) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var r := GooTuning.min_radius()
	var points: Array[Vector2] = [Vector2.ZERO]
	while points.size() < count:
		var p := points[rng.randi() % points.size()] + Vector2.from_angle(rng.randf() * TAU) * 2.0 * r
		var free := true
		for q: Vector2 in points:
			if q.distance_to(p) < 2.0 * r - 0.01:
				free = false
				break
		if free:
			points.append(p)
	var mean := Vector2.ZERO
	for p: Vector2 in points:
		mean += p
	mean /= points.size()
	var cells: Array = []
	for p: Vector2 in points:
		cells.append({ "position": at + p - mean, "radius": r })
	return cells

## A worm `length` cells long and `wide` wide (rows offset by half a cell), each cell
## jittered by up to 0.3 px (seeded), from `at` along +x.
static func _worm(length: int, wide: int, at: Vector2 = Vector2.ZERO) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = 1
	var r := GooTuning.min_radius()
	var cells: Array = []
	for i: int in length:
		for j: int in wide:
			var p := at + Vector2(i * 2.0 * r + (r if j % 2 == 1 else 0.0), j * sqrt(3.0) * r)
			cells.append({ "position": p + Vector2(rng.randf_range(-0.3, 0.3), rng.randf_range(-0.3, 0.3)), "radius": r })
	return cells

static func _hex(rings: int, at: Vector2 = Vector2.ZERO) -> Array:
	var r := GooTuning.min_radius()
	var cells: Array = []
	for q: int in range(-rings, rings + 1):
		for p: int in range(-rings, rings + 1):
			if absi(p + q) <= rings:
				cells.append({ "position": at + Vector2(p * 2.0 * r + q * r, q * sqrt(3.0) * r), "radius": r })
	return cells

## The creature's outline (its largest outside loop, from the last exposure pass): its
## perimeter, its area, and its perimeter² over 4π × its area (1 for a disc).
static func _roundness(sim: GooColonySim, c: int) -> Vector3:
	var outline := sim.colony.creature_outline(c)
	var perimeter := 0.0
	for i: int in outline.size():
		perimeter += outline[i].distance_to(outline[(i + 1) % outline.size()])
	var area := absf(GooLoop.signed_area(outline))
	return Vector3(perimeter, area, perimeter * perimeter / (4.0 * PI * maxf(area, 1.0)))

## The kinetic energy (unit masses: Σ v² / 2) of creature `c`'s particles with its rigid
## motion (mean velocity and best-fit spin) taken out, and that spin (rad/s).
static func _internal_motion(sim: GooColonySim, c: int) -> Vector2:
	var points := sim.colony.creature_points(c)
	var velocities := sim.colony.creature_velocities(c)
	var n := points.size()
	var centre := Vector2.ZERO
	var mean := Vector2.ZERO
	for i: int in n:
		centre += points[i]
		mean += velocities[i]
	centre /= n
	mean /= n
	var spin := 0.0
	var inertia := 0.0
	for i: int in n:
		var r := points[i] - centre
		spin += r.cross(velocities[i] - mean)
		inertia += r.length_squared()
	var omega := spin / maxf(inertia, 1e-6)
	var energy := 0.0
	for i: int in n:
		var r := points[i] - centre
		var rigid := mean + Vector2(-r.y, r.x) * omega
		energy += 0.5 * (velocities[i] - rigid).length_squared()
	return Vector2(energy, omega)

static func _kinetic(sim: GooColonySim, c: int) -> float:
	var energy := 0.0
	for v: Vector2 in sim.colony.creature_velocities(c):
		energy += 0.5 * v.length_squared()
	return energy

## Sticks per wall: for each pair of cells with sticks between them, how many; their mean.
static func _sticks_per_wall(sim: GooColonySim, c: int) -> float:
	var st := sim.colony.creature_sticks(c)
	var walls := {}
	for q: int in range(0, st.size(), GooColony.STICK_FLOATS):
		var a := int(st[q + 5])
		var b := int(st[q + 6])
		var key := Vector2i(mini(a, b), maxi(a, b))
		walls[key] = walls.get(key, 0) + 1
	if walls.is_empty():
		return 0.0
	var total := 0
	for k: Vector2i in walls:
		total += walls[k]
	return float(total) / walls.size()

## The rings' bead polygons' areas over their rest polygons' (a regular polygon on the
## ring radius): the smallest and the mean.
static func _ring_areas(sim: GooColonySim, c: int) -> Vector2:
	var lo := INF
	var total := 0.0
	var n := 0
	for cell: int in sim.colony.cell_count(c):
		var points := sim.colony.cell_points(c, cell)
		if points.size() == 1:
			continue
		var ring: float = GooTuning.tuning(sim.colony.cell_radius(c, cell))["ring_radius"]
		var rest := 0.5 * points.size() * ring * ring * sin(TAU / points.size())
		var ratio := absf(GooLoop.signed_area(points)) / rest
		lo = minf(lo, ratio)
		total += ratio
		n += 1
	return Vector2(lo, total / maxi(n, 1))

static func _sound(h: Dictionary) -> String:
	return "area %.2f..%.2f, %d inside out, %d not finite" % [h["area_min"], h["area_max"], int(h["inverted"]), int(h["not_finite"])]

static func _same(a: PackedVector2Array, b: PackedVector2Array) -> bool:
	if a.size() != b.size():
		return false
	for i: int in a.size():
		if a[i] != b[i]:
			return false
	return true

# ---- Strength 0, a slack type ----

func test_strength_zero_and_a_slack_type_are_exactly_todays_behaviour() -> void:
	# The same thrown, pushed and dragged creature in four colonies: one never told about the
	# tension, one with strength 0, one with the tension on but this creature's factor 0,
	# and one whose cells are all of a type whose tension factor is 0.
	var runs: Array[PackedVector2Array] = []
	for variant: int in 4:
		var extra := GooColonySim.DRAG_OPTIONS.duplicate()
		if variant == 1:
			extra.merge({ "tension": 0.0, "tension_pockets": 1.0 })
		var sim := _sim(GooColonySim.TENSION if variant >= 2 else 0.0, extra)
		var cells := _ragged(24, 9)
		if variant == 3:
			for cell: Dictionary in cells:
				cell["type"] = 2
			sim.colony.set_type_tension(2, 0.0)
		var k := sim.add_creature(cells)
		if variant == 2:
			sim.colony.set_creature_tension(k, 0.0)
		sim.colony.set_creature_velocity(k, Vector2(120, -40))
		for f: int in 120:
			if f == 30:
				sim.colony.push_cell(k, 3, Vector2(4000, 0))
			if f == 40:
				sim.colony.push_cell(k, 3, Vector2.ZERO)
			sim.step(DELTA)
		runs.append(sim.colony.creature_points(k))
	var on := _sim(GooColonySim.TENSION, GooColonySim.DRAG_OPTIONS)
	var k := on.add_creature(_ragged(24, 9))
	on.colony.set_creature_velocity(k, Vector2(120, -40))
	_steps(on, 120)
	print("    %d particles: strength 0, the creature's factor 0 and a slack type equal to no tension bit for bit: %s, %s, %s; tension on differs: %s" % [
		runs[0].size(), _same(runs[0], runs[1]), _same(runs[0], runs[2]), _same(runs[0], runs[3]), not _same(runs[0], on.colony.creature_points(k))])
	assert_true(_same(runs[0], runs[1]), "strength 0 is exactly the run without the option")
	assert_true(_same(runs[0], runs[2]), "a creature's factor 0 is too")
	assert_true(_same(runs[0], runs[3]), "and so is a slack type")
	assert_false(_same(runs[0], on.colony.creature_points(k)), "the tension does change something")

# ---- No net force or torque ----

func test_the_tension_adds_no_net_force_or_torque_and_a_free_creature_keeps_still() -> void:
	# A ragged cluster with its cores, free and at rest: every substep's tension forces sum to
	# nothing and turn nothing about any point, and the creature as a whole does not start
	# moving (its mass-weighted mean velocity) while it rounds off, no more than without it.
	var drifts := {}
	for strength: float in [0.0, 2.0 * GooColonySim.TENSION]:
		var sim := _sim(strength)
		var k := sim.add_creature(_ragged(30, 3, Vector2(400, -250)))
		var worst_force := 0.0
		var worst_torque := 0.0
		var scale := 0.0
		var drift := 0.0
		for f: int in 240:
			sim.step(DELTA)
			var forces := sim.colony.creature_tension_forces(k)
			var points := sim.colony.creature_tension_points(k)
			var total := Vector2.ZERO
			var torque := 0.0
			var size := 0.0
			var reach := 0.0
			for i: int in forces.size():
				total += forces[i]
				torque += points[i].cross(forces[i])
				size += forces[i].length()
				reach = maxf(reach, points[i].length())
			if size > 0.0:
				worst_force = maxf(worst_force, total.length() / size)
				worst_torque = maxf(worst_torque, absf(torque) / (size * reach))
				scale = maxf(scale, size)
			drift = maxf(drift, sim.colony.creature_velocity(k).length())
		drifts[strength] = drift
		print("    strength %4.0f, 4 s, %d tension forces a substep (their sizes summed up to %.0f): net force up to %s of that, net torque up to %s of it × the reach; the creature's mean velocity at most %.3f px/s" % [
			strength, sim.colony.creature_tension_forces(k).size(), scale, String.num_scientific(worst_force), String.num_scientific(worst_torque), drift])
		if strength > 0.0:
			assert_gt(scale, 0.0)
			assert_lt(worst_force, 1e-5, "no net force")
			assert_lt(worst_torque, 1e-5, "no net torque")
			assert_lt(drift, drifts[0.0] + 0.05, "a free creature does not set off by itself, no more than without the tension")

# ---- Rounding off ----

func test_a_ragged_cluster_rounds_off_and_stays_round() -> void:
	# The same ragged cluster without and with the tension (and with it twice as strong):
	# its outline's perimeter² over its area (over a disc's 4π) after 1, 3 and 6 s.
	var results := {}
	for strength: float in [0.0, GooColonySim.TENSION, 2.0 * GooColonySim.TENSION]:
		var sim := _sim(strength)
		var k := sim.add_creature(_ragged(30, 3))
		var line := ""
		var at := []
		var elapsed := 0
		for second: int in [1, 3, 6]:
			_steps(sim, 60 * second - elapsed)
			elapsed = 60 * second
			var r := _roundness(sim, k)
			at.append(r.z)
			line += " %d s %.2f (outline %.0f px around %.0f px²)," % [second, r.z, r.x, r.y]
		var h := sim.colony.health()
		var s := sim.colony.stats()
		print("    strength %4.0f:%s %d beads exposed, %d cores, %d sticks; %s" % [strength, line, s["exposed"], s["cores"], s["sticks"], _sound(h)])
		results[strength] = at
		assert_eq(h["inverted"], 0.0)
	var none: Array = results[0.0]
	var on: Array = results[GooColonySim.TENSION]
	var strong: Array = results[2.0 * GooColonySim.TENSION]
	assert_lt(on[2], 0.8 * none[2], "the tension rounds it off well beyond what adhesion alone does")
	assert_lt(strong[2], on[2] + 0.05, "a stronger tension rounds it at least as much")
	assert_lt(absf(on[2] - on[1]), 0.1 * on[1], "and it stays so")

# ---- A wall ----

func _wall(unit: float) -> void:
	GooTuning.unit = unit
	var r := GooTuning.min_radius()
	for r2: float in [r, 1.6 * r]:
		var line := ""
		for strength: float in [0.0, GooColonySim.TENSION]:
			var sim := _sim(strength)
			var k := sim.add_creature([{ "position": Vector2(-r, 0), "radius": r }, { "position": Vector2(r2, 0), "radius": r2 }])
			# The centres' distance every 3 s over 21 s, the internal motion and spin in the last 3.
			var seps := PackedFloat32Array()
			var internal := 0.0
			var spin := 0.0
			for f: int in 21 * 60 + 1:
				if f % 180 == 0:
					seps.append(sim.colony.cell_center(k, 0).distance_to(sim.colony.cell_center(k, 1)))
				if f >= 18 * 60:
					var m := _internal_motion(sim, k)
					internal = maxf(internal, m.x)
					spin = maxf(spin, absf(m.y))
				if f < 21 * 60:
					sim.step(DELTA)
			var early := absf(seps[2] - seps[1])
			var late := absf(seps[7] - seps[6])
			var sticks := sim.colony.creature_sticks(k).size() / GooColony.STICK_FLOATS
			var h := sim.colony.health()
			line += " strength %.0f: %d sticks, centres %.3f of (r1 + r2) apart, moving %.3f px in 3-6 s and %.3f px in 18-21 s, internal motion up to %.4f (Σ v²/2), spin %.3f rad/s, area %.2f..%.2f;" % [
				strength, sticks, seps[7] / (r + r2), early, late, internal, spin, h["area_min"], h["area_max"]]
			assert_lt(late, maxf(0.7 * early, 0.02 * unit), "the wall settles (its creep slows down)")
			assert_lt(internal, 1.0 * unit * unit, "nothing oscillates")
			if strength > 0.0:
				assert_gt(sticks, 3, "the wall zipped wider than the 3 sticks adhesion alone makes")
				assert_gt(h["area_min"], 0.85, "without crushing the cells")
		print("    unit %.1f, cells of %.0f and %.0f px:%s" % [unit, r, r2, line])

func test_two_cells_settle_to_a_wider_stable_wall() -> void:
	_wall(0.5)

func test_two_cells_settle_to_a_wider_stable_wall_at_unit_one() -> void:
	_wall(1.0)

# ---- At rest ----

func test_a_resting_creature_comes_to_rest() -> void:
	# A hex cluster of 37 (its middle becoming cores) left alone, without and with the
	# tension, without and with the water's drag: over 4 to 16 s the kinetic energy (Σ v²/2,
	# unit masses) frame by frame: its median, and the frames above 500 (without the tension
	# too a resting cluster kicks a few beads to 20-30 px/s now and then, for a frame or a few).
	var medians := {}
	var kicks := {}
	for variant: String in ["none", "tension", "drag", "tension, drag"]:
		var sim := _sim(GooColonySim.TENSION if variant.begins_with("tension") else 0.0, GooColonySim.DRAG_OPTIONS if variant.ends_with("drag") else {})
		var k := sim.add_creature(_hex(3))
		_steps(sim, 240)
		var energies: Array[float] = []
		var over := 0
		for f: int in 720:
			sim.step(DELTA)
			var e := _kinetic(sim, k)
			energies.append(e)
			if e > 500.0:
				over += 1
		energies.sort()
		medians[variant] = energies[energies.size() / 2]
		kicks[variant] = over
		print("    %s: kinetic energy over 4-16 s median %.1f, 90th percentile %.1f, largest %.1f; %d frames above 500; spin %.4f rad/s at the end" % [
			variant, medians[variant], energies[energies.size() * 9 / 10], energies[-1], over, _internal_motion(sim, k).y])
	assert_lt(medians["tension"], 2.0 * medians["none"] + 10.0, "the tension leaves a resting creature as still as adhesion alone does")
	assert_lt(medians["tension, drag"], 2.0 * medians["drag"] + 10.0)
	assert_lt(medians["tension"], 150.0, "at rest: under 1 px/s on average")
	assert_lt(kicks["tension"], 3 * kicks["none"] + 12, "and kicks it no more often")
	assert_lt(kicks["tension, drag"], 3 * kicks["drag"] + 12)

# ---- Designed shapes ----

## End to end over its length as placed, and the cells' path (centre to centre along the
## first row) over the same.
static func _worm_shape(sim: GooColonySim, k: int, length: int, wide: int) -> Vector2:
	var a := Vector2.ZERO
	var b := Vector2.ZERO
	for j: int in wide:
		a += sim.colony.cell_center(k, j)
		b += sim.colony.cell_center(k, (length - 1) * wide + j)
	var path := 0.0
	for i: int in length - 1:
		path += sim.colony.cell_center(k, i * wide).distance_to(sim.colony.cell_center(k, (i + 1) * wide))
	var design := (length - 1) * 2.0 * GooTuning.min_radius()
	return Vector2(a.distance_to(b) / wide / design, path / design)

func test_a_long_worm_keeps_its_shape_and_balls_up_only_when_the_strength_is_raised() -> void:
	# A worm 3 cells wide and 24 long (72 cells) and a single file of 20, after 6 s at 0,
	# 1, 2, 4, 8 and 16 times the default strength: end to end over the length as placed
	# (1 straight, about 0.3 a ball), and the single file's path along its cells.
	var balled := { 3: -1.0, 1: -1.0 }
	for strength_x: float in [0.0, 1.0, 2.0, 4.0, 8.0, 16.0]:
		var sim := _sim(GooColonySim.TENSION * strength_x)
		var thick := sim.add_creature(_worm(24, 3, Vector2(0, -150)))
		var thin := sim.add_creature(_worm(20, 1, Vector2(0, 150)))
		_steps(sim, 360)
		var a := _worm_shape(sim, thick, 24, 3)
		var b := _worm_shape(sim, thin, 20, 1)
		var h := sim.colony.health()
		print("    %4.1f × the default: worm 3 wide end to end %.2f of its length; single file %.2f end to end, %.2f along its cells; %s" % [strength_x, a.x, b.x, b.y, _sound(h)])
		if a.x < 0.6 and balled[3] < 0.0:
			balled[3] = strength_x
		if b.x < 0.6 and balled[1] < 0.0:
			balled[1] = strength_x
		if strength_x == 1.0:
			assert_gt(a.x, 0.95, "at the default a worm three cells wide keeps its designed length")
			assert_gt(b.x, 0.6, "and a single file does not ball up")
		if strength_x == 0.0:
			assert_gt(a.x, 0.95)
	print("    end to end below 0.6 first at: 3 wide %s, single file %s (× the default; -1: never)" % [balled[3], balled[1]])

# ---- After an impact ----

func test_after_an_impact_walls_are_wider_and_the_cells_not_crushed() -> void:
	# Two hex clusters of 37 thrown into each other at 300 px/s each, then left 3 s: the
	# sticks per wall and the rings' areas (over the cell's disc, beads' centres), without
	# and with the tension.
	for strength: float in [0.0, GooColonySim.TENSION]:
		var sim := _sim(strength)
		var a := sim.add_creature(_hex(3, Vector2(-120, 0)))
		var b := sim.add_creature(_hex(3, Vector2(120, 14)))
		_steps(sim, 30)
		sim.colony.set_creature_velocity(a, Vector2(300, 0))
		sim.colony.set_creature_velocity(b, Vector2(-300, 0))
		var worst := INF
		for f: int in 240:
			sim.step(DELTA)
			worst = minf(worst, sim.colony.health()["area_min"])
		var areas := _ring_areas(sim, a)
		var h := sim.colony.health()
		print("    strength %4.0f: %.2f sticks per wall, rings' areas %.2f (smallest) %.2f (mean) of their discs at rest, worst during the impact %.2f of target; %s" % [
			strength, _sticks_per_wall(sim, a), areas.x, areas.y, worst, _sound(h)])
		assert_eq(h["inverted"], 0.0)
		assert_gt(worst, 0.5)

# ---- Pockets ----

func test_pockets_keep_their_size_unless_asked() -> void:
	# A closed ring of 14 cells round a pocket: its pocket's area after 6 s without the
	# tension, with it (pockets pulling 0, the preset) and with tension_pockets 1.
	var r := GooTuning.min_radius()
	var n := 14
	var big := r / sin(PI / n)
	var areas := {}
	for variant: String in ["none", "preset", "pockets 1"]:
		var sim := _sim(0.0 if variant == "none" else GooColonySim.TENSION, { "tension_pockets": 1.0 } if variant == "pockets 1" else {})
		var cells: Array = []
		for i: int in n:
			cells.append({ "position": Vector2.from_angle(TAU * i / n) * big, "radius": r })
		var k := sim.add_creature(cells)
		_steps(sim, 360)
		var kinds := sim.colony.creature_loop_kinds(k)
		var pocket := 0.0
		for li: int in kinds.size():
			if kinds[li] == GooColony.LOOP_POCKET:
				pocket += absf(GooLoop.signed_area(sim.colony.creature_loop(k, li)))
		var radius := 0.0
		for c: int in n:
			radius += sim.colony.cell_center(k, c).length()
		areas[variant] = pocket
		print("    %s: pocket %.0f px² (placed %.0f), ring of cells %.1f px across the middle (placed %.1f); %s" % [variant, pocket, PI * pow(big - r, 2.0), radius / n, big, _sound(sim.colony.health())])
	assert_gt(areas["preset"], 0.3 * areas["none"], "the preset's pocket stays open")
	assert_lt(areas["pockets 1"], areas["preset"], "pulling the pocket's skin shrinks it")

# ---- Soundness, threads ----

func _game(threads: int, strength: float) -> GooColonySim:
	var options := GooColonySim.everything_options(strength)
	options["threads"] = threads
	var sim := GooColonySim.new(options)
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261112
	for c: int in 6:
		var cells := _ragged(22, 11 + c, Vector2((c % 3) * 260.0, (c / 3) * 260.0))
		var k := sim.add_creature(cells)
		sim.colony.push_creature(k, Vector2.from_angle(rng.randf() * TAU) * 900.0)
	return sim

func test_a_seeded_random_game_with_tension_stays_sound() -> void:
	var sim := _game(1, GooColonySim.TENSION)
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	var worst := { "area_min": INF, "area_max": 0.0, "inverted": 0.0, "not_finite": 0.0, "fastest": 0.0 }
	var switches := 0
	var patched := 0
	for f: int in 300:
		if f % 30 == 0:
			for c: int in sim.colony.creature_count():
				sim.colony.push_creature(c, Vector2.from_angle(rng.randf() * TAU) * rng.randf_range(300.0, 1500.0))
				sim.colony.push_cell(c, rng.randi_range(0, 9), Vector2.from_angle(rng.randf() * TAU) * rng.randf_range(0.0, 8000.0))
		sim.step(DELTA)
		var h := sim.colony.health()
		var s := sim.colony.stats()
		switches += s["to_core"] + s["to_ring"]
		patched = maxi(patched, s["patched_runs"])
		for key: String in worst:
			worst[key] = minf(worst[key], h[key]) if key == "area_min" else maxf(worst[key], h[key])
	print("    300 frames of 6 ragged creatures thrown about, everything on: fastest %.0f px/s, area %.2f..%.2f, %d inside out, %d not finite; %d switches; beads on guessed loops at most %d" % [
		worst["fastest"], worst["area_min"], worst["area_max"], int(worst["inverted"]), int(worst["not_finite"]), switches, patched])
	assert_eq(worst["not_finite"], 0.0, "no NaN")
	assert_eq(worst["inverted"], 0.0, "no cell inside out")
	assert_gt(worst["area_min"], 0.5)
	assert_lt(worst["area_max"], 1.5)

func test_threaded_step_equals_serial_with_tension() -> void:
	var serial := _game(1, GooColonySim.TENSION)
	var threaded := _game(4, GooColonySim.TENSION)
	var events_a := PackedInt64Array()
	var events_b := PackedInt64Array()
	for f: int in 200:
		if f % 40 == 39:
			for c: int in serial.colony.creature_count():
				var push := Vector2.from_angle(f * 0.7 + c) * 900.0
				serial.colony.push_creature(c, push)
				threaded.colony.push_creature(c, push)
		serial.colony.step(DELTA)
		threaded.colony.step(DELTA)
		events_a.append_array(serial.colony.take_events())
		events_b.append_array(threaded.colony.take_events())
	print("    200 frames, 6 ragged creatures, everything on: %d events, %d tension forces in the last substep" % [events_a.size() / 4, serial.colony.creature_tension_forces(0).size()])
	assert_eq(events_a, events_b, "the same events in the same order")
	for c: int in serial.colony.creature_count():
		assert_eq(serial.colony.creature_points(c), threaded.colony.creature_points(c), "creature %d's particles are bit for bit the serial ones" % c)
		assert_eq(serial.colony.creature_velocities(c), threaded.colony.creature_velocities(c))
		assert_eq(serial.colony.creature_tension_forces(c), threaded.colony.creature_tension_forces(c))
