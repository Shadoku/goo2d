extends TestCase
## Thrusters (docs/cells.md, "Thrusters"): a thrust level per cell × its type's max_thrust
## (px/s² of the cell's own mass at GooTuning.unit 1) along its facing, set for a creature in
## one call (GooCellCreature.set_thrust_levels()), and the allocator's query (thrusters()).
## At the fluid game's sizes: unit 0.5, 7 px cells, the world's default drag, top-down,
## stepped by hand. Prints what it measures.

const DELTA: float = 1.0 / 60.0
const R: float = 7.0
## The thrusters' maximum (px/s² at unit 1: 300 at the game's 0.5).
const MAX_THRUST: float = 600.0

func before_each() -> void:
	GooTuning.unit = 0.5

func after_each() -> void:
	GooTuning.unit = 1.0

func _world(threads: int = 1) -> GooCellWorld2D:
	var w := GooCellWorld2D.new()
	w.gravity_scale = 0.0
	w.threads = threads
	w.draw_skins = false
	add_child(w)
	w.set_physics_process(false)
	return w

func _steps(w: GooCellWorld2D, frames: int) -> void:
	for f: int in frames:
		w.step(DELTA)

func _types(max_thrust: float = MAX_THRUST) -> Array[GooCellType]:
	var body := GooCellType.new()
	body.name = &"body"
	var thruster := GooCellType.new()
	thruster.name = &"thruster"
	thruster.max_thrust = max_thrust
	return [body, thruster]

## A 37-cell blob (hex, 3 rings of 7 px cells): `rear` its back third thrusters facing +x;
## else its rim all thrusters, each facing outward (an allocator fires those facing the way).
func _blob(rear: bool, max_thrust: float = MAX_THRUST) -> GooCellDesign:
	var d := GooCellDesign.hex_blob(3, R)
	d.types = _types(max_thrust)
	var reach := 0.0
	for p: Vector2 in d.positions:
		reach = maxf(reach, p.length())
	for i: int in d.cell_count():
		var p := d.positions[i]
		if rear and p.x < -0.5 * reach:
			d.cell_types[i] = 1
			d.angles[i] = 0.0
		elif not rear and p.length() > 0.8 * reach:
			d.cell_types[i] = 1
			# Facing inward: a thruster pushes its cell along its facing, so the rim's back
			# cells face forward (+x) and push the blob that way.
			d.angles[i] = (-p).angle()
	return d

## Levels for the thrusters by their facing against `way`: max(0, cos) (the simplest
## allocator), by index.
static func _levels_toward(cr: GooCellCreature, way: Vector2) -> PackedFloat32Array:
	var t := cr.thrusters()
	var levels := PackedFloat32Array()
	levels.resize(cr.cell_count())
	var idx: PackedInt32Array = t["indices"]
	var fac: PackedVector2Array = t["facings"]
	for k: int in idx.size():
		levels[idx[k]] = maxf(0.0, fac[k].dot(way))
	return levels

## [steady px/s over the last 2 s of 8, the thrusters' share of the mass, the blob's width,
## the thrust's acceleration of the whole blob (Σ max force / mass, px/s²)]
func _steady(rear: bool, max_thrust: float = MAX_THRUST) -> Array:
	var w := _world()
	var d := _blob(rear, max_thrust)
	var cr := w.spawn(d, Transform2D(0.0, Vector2(0, 0)))
	var share := 0.0
	var t := cr.thrusters()
	for f: float in t["max_forces"]:
		share += f
	var acc := share / cr.mass()
	share /= cr.mass() * max_thrust * GooTuning.unit
	var start := Vector2.ZERO
	for f: int in 480:
		if f % 6 == 0:
			assert_true(cr.set_thrust_levels(_levels_toward(cr, Vector2.RIGHT)))
		w.step(DELTA)
		if f == 359:
			start = cr.center()
	var speed := (cr.center() - start).length() / 2.0
	var out := [speed, share, d.bounds().size.x, acc]
	w.queue_free()
	return out

func test_a_blob_reaches_a_steady_speed_by_its_thrusters() -> void:
	var speeds := {}
	for max_thrust: float in [600.0, 2400.0, 6000.0]:
		var rear := _steady(true, max_thrust)
		var rim := _steady(false, max_thrust)
		speeds[max_thrust] = rear[0]
		for row: Array in [["back third, facing +x", rear], ["rim all round, facing inward, cos-allocated", rim]]:
			var m: Array = row[1]
			print("    37-cell blob (7 px, unit 0.5), thrusters %s: %.0f %% of its mass, max_thrust %.0f (%.0f px/s² at 0.5): the blob pushed at %.1f px/s², steady %.1f px/s = %.2f body lengths/s (%.0f px wide)" % [row[0], 100.0 * m[1], max_thrust, max_thrust * GooTuning.unit, m[3], m[0], m[0] / m[2], m[2]])
		assert_gt(rim[0], 0.5 * rear[0])
	assert_gt(speeds[600.0], 20.0)
	assert_gt(speeds[6000.0], 4.0 * speeds[600.0])

func test_full_thrust_accelerates_at_the_share_times_the_maximum() -> void:
	# No drag: the first half second's acceleration is the thrusters' share × the maximum.
	var w := _world()
	w.drag_enabled = false
	var cr := w.spawn(_blob(true))
	var t := cr.thrusters()
	var expect := 0.0
	for f: float in t["max_forces"]:
		expect += f
	expect /= cr.mass()
	var levels := PackedFloat32Array()
	levels.resize(cr.cell_count())
	for i: int in t["indices"]:
		levels[i] = 1.0
	cr.set_thrust_levels(levels)
	_steps(w, 30)
	var a := cr.velocity().x / 0.5
	print("    no drag: %.1f px/s² measured, %.1f expected (Σ max force / mass)" % [a, expect])
	assert_almost_eq(a, expect, 0.02 * expect)
	assert_almost_eq(cr.velocity().y, 0.0, 0.5)

func test_thrust_off_centre_turns_the_creature() -> void:
	# The back third's top half alone (y < 0): it turns clockwise (positive) as it goes.
	var w := _world()
	var d := _blob(true)
	var cr := w.spawn(d)
	var t := cr.thrusters()
	var levels := PackedFloat32Array()
	levels.resize(cr.cell_count())
	var offs: PackedVector2Array = t["offsets"]
	var fac: PackedVector2Array = t["facings"]
	var forces: PackedFloat32Array = t["max_forces"]
	var torque := 0.0
	var idx: PackedInt32Array = t["indices"]
	for k: int in idx.size():
		if offs[k].y < -1.0:
			levels[idx[k]] = 1.0
			torque += offs[k].cross(fac[k]) * forces[k]
	cr.set_thrust_levels(levels)
	_steps(w, 6)
	var early := cr.spin()
	_steps(w, 114)
	var spin := cr.spin()
	print("    the back third's upper thrusters: angular acceleration %.2f rad/s² predicted (Σ offset × facing × force / inertia), spin %.3f rad/s after 0.1 s, %.2f rad/s after 2 s, %.1f px/s" % [torque / t["inertia"], early, spin, cr.velocity().length()])
	assert_gt(torque, 0.0)
	assert_gt(spin, 0.3)
	assert_almost_eq(early / 0.1, torque / t["inertia"], 0.35 * torque / t["inertia"])

func test_link_strain_under_full_thrust_against_the_swim_drive() -> void:
	# The same push on the creature, from the back third's thrusters or from every cell (the
	# swim drive): the links' strain and load at a steady speed.
	var measure := func(by_thrust: bool) -> Array:
		var w := _world()
		w.break_force = 1e12
		var cr := w.spawn(_blob(true))
		var t := cr.thrusters()
		var total := 0.0
		for f: float in t["max_forces"]:
			total += f
		if by_thrust:
			var levels := PackedFloat32Array()
			levels.resize(cr.cell_count())
			for i: int in t["indices"]:
				levels[i] = 1.0
			cr.set_thrust_levels(levels)
		else:
			cr.set_swim(total / cr.mass(), 0.0)
		var strain := 0.0
		var load := 0.0
		for f: int in 240:
			w.step(DELTA)
			if f >= 120:
				for s: float in w.cells().link_strains(cr.id):
					strain = maxf(strain, absf(s))
				for l: float in w.cells().link_loads(cr.id):
					load = maxf(load, l)
		var env := 0.0
		for e: float in w.cells().link_envelopes(cr.id):
			env = maxf(env, e)
		var out := [strain, load, env, cr.velocity().length()]
		w.queue_free()
		return out
	var th: Array = measure.call(true)
	var sw: Array = measure.call(false)
	print("    the same push (back third's thrusters / the swim drive): steady %.1f / %.1f px/s; links' worst strain %.4f / %.4f, load %.0f / %.0f, envelope %.0f / %.0f (the own share the break test leaves out)" % [th[3], sw[3], th[0], sw[0], th[1], sw[1], th[2], sw[2]])
	assert_gt(th[1], sw[1])
	assert_lt(th[0], 0.1)
	# Thrust is the creature's own: its loads join the envelope.
	assert_gt(th[2], 0.5 * th[1])

func test_levels_are_refused_at_a_stale_size_and_set_by_uid() -> void:
	var w := _world()
	var cr := w.spawn(_blob(true))
	var n := cr.cell_count()
	var short := PackedFloat32Array()
	short.resize(n - 1)
	assert_false(cr.set_thrust_levels(short))
	var t := cr.thrusters()
	var uids: PackedInt32Array = t["uids"]
	var ones := PackedFloat32Array()
	ones.resize(uids.size())
	ones.fill(0.5)
	assert_eq(cr.set_thrust_levels_by_uid(uids, ones), uids.size())
	var lv := cr.thrust_levels()
	for i: int in t["indices"]:
		assert_almost_eq(lv[i], 0.5, 1e-6)
	# A level on a cell that is not a thruster pushes nothing.
	var w2 := _world()
	w2.drag_enabled = false
	var plain := w2.spawn(GooCellDesign.hex_blob(2, R))
	var all := PackedFloat32Array()
	all.resize(plain.cell_count())
	all.fill(1.0)
	plain.set_thrust_levels(all)
	_steps(w2, 30)
	assert_lt(plain.velocity().length(), 0.01)

func test_the_allocators_query_is_consistent() -> void:
	var w := _world()
	var cr := w.spawn(_blob(false), Transform2D(0.7, Vector2(100, 50)))
	_steps(w, 10)
	var t := cr.thrusters()
	var p := cr.positions()
	var c := cr.center()
	assert_true((t["center"] as Vector2).distance_to(c) < 0.01)
	assert_almost_eq(t["mass"], cr.mass(), 0.01 * cr.mass())
	var inertia := 0.0
	var masses := 0.0
	for i: int in p.size():
		var m := PI * R * R
		inertia += m * p[i].distance_squared_to(c)
		masses += m
	assert_almost_eq(t["inertia"], inertia, 0.001 * inertia)
	var idx: PackedInt32Array = t["indices"]
	var fac: PackedVector2Array = t["facings"]
	var offs: PackedVector2Array = t["offsets"]
	var forces: PackedFloat32Array = t["max_forces"]
	var all_facings := cr.facings()
	for k: int in idx.size():
		assert_almost_eq(fac[k].length(), 1.0, 1e-4)
		assert_true(fac[k].distance_to(all_facings[idx[k]]) < 1e-5)
		assert_true(offs[k].distance_to(p[idx[k]] - c) < 0.01)
		assert_almost_eq(forces[k], MAX_THRUST * GooTuning.unit * PI * R * R, 0.01)
		# A rim cell faces inward, turned with the creature (spawned at 0.7 rad).
		assert_almost_eq(fac[k].dot(-offs[k].normalized()), 1.0, 0.05)
	assert_almost_eq(cr.cell_angle(idx[0]), fac[0].angle(), 1e-4)

func test_threaded_equals_serial_and_a_replay_with_thrust() -> void:
	var run := func(threads: int) -> int:
		var w := _world(threads)
		var crs: Array[GooCellCreature] = []
		for k: int in 6:
			crs.append(w.spawn(_blob(k % 2 == 0), Transform2D(0.4 * k, Vector2(160 * (k % 3), 160 * (k / 3)))))
		for f: int in 120:
			for k: int in crs.size():
				if crs[k].is_alive():
					crs[k].set_thrust_levels(_levels_toward(crs[k], Vector2.from_angle(0.03 * f + k)))
			w.step(DELTA)
		var h := w.cells().state_hash()
		w.queue_free()
		return h
	var a: int = run.call(1)
	assert_eq(run.call(4), a)
	assert_eq(run.call(0), a)
	assert_eq(run.call(1), a, "a replay")
