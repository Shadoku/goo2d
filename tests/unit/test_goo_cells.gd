extends TestCase
## GooCells, the one-particle-per-cell prototype (addons/goo2d/native/src/cells.rs,
## docs/explore-cells.md), through GooCellsSim at the game's unit (cells 14 px): links and
## the outline of a hex creature, threaded == serial with collisions and topology changes,
## a link breaking into a split with its events, joining at a retopology through the type
## table and the script's veto, a cell added without a kick and one removed, radius
## muscles, surface tension pulling without a net force, and a worm swimming by
## undulation alone. Prints what it measures.

const DELTA: float = 1.0 / 60.0
const D := preload("res://tools/cells_design.gd")

func before_each() -> void:
	GooTuning.unit = 0.5

func after_each() -> void:
	GooTuning.unit = 1.0

func _moving_world(threads: int) -> GooCellsSim:
	var sim := GooCellsSim.new({"threads": threads, "break_force": 4.0e6})
	for k: int in 4:
		var c := sim.add_creature(D.blob(3))
		sim.cells.translate(c, Vector2((k % 2) * 300.0, (k / 2) * 300.0))
		sim.cells.set_velocity(c, Vector2(300.0 if k % 2 == 0 else -300.0, 60.0 * k - 90.0))
	return sim

func test_hex_creature_links_and_outline() -> void:
	var sim := GooCellsSim.new()
	var c := sim.add_creature(D.blob(2))
	assert_eq(sim.cells.cell_count(c), 19)
	assert_eq(sim.cells.links(c).size() / 2, 42)
	assert_eq(sim.cells.outline(c).size(), 12)

func test_rest_stays_put() -> void:
	var sim := GooCellsSim.new()
	var c := sim.add_creature(D.packed("blob", 60, 3, 14.0, 40.0))
	var before := sim.cells.centers(c)
	for f: int in 120:
		sim.step(DELTA)
	var after := sim.cells.centers(c)
	var moved := 0.0
	for i: int in before.size():
		moved = maxf(moved, before[i].distance_to(after[i]))
	print("    a mixed 14..40 px creature of 60 cells at rest: no cell moved more than %.4f px in 2 s" % moved)
	assert_lt(moved, 0.05)

func test_threaded_equals_serial() -> void:
	var hashes: Array[int] = []
	for threads: int in [1, 4, 1]:
		var sim := _moving_world(threads)
		for f: int in 150:
			sim.step(DELTA)
			if f == 50:
				sim.retopology(4.0)
				sim.add_cell(0, sim.cells.centers(0)[0] + Vector2(-14, 0), 14.0, 1)
		hashes.append(sim.cells.state_hash())
	assert_eq(hashes[0], hashes[1])
	assert_eq(hashes[0], hashes[2])

func test_a_link_breaks_into_a_split() -> void:
	var sim := GooCellsSim.new({"break_force": 2.0e5, "drag": false})
	var c := sim.add_creature(D.worm(12, 1))
	var n := sim.cells.cell_count(c)
	var forces := PackedVector2Array()
	forces.resize(n)
	forces[0] = Vector2(-4.0e6, 0)
	forces[n - 1] = Vector2(4.0e6, 0)
	sim.cells.set_cell_forces(c, forces)
	var parted: Array = []
	var splits: Array = []
	sim.cells_parted.connect(func(cr: int, a: int, b: int) -> void: parted.append([cr, a, b]))
	sim.creature_split.connect(func(p: int, ch: int, count: int) -> void: splits.append([p, ch, count]))
	for f: int in 30:
		sim.step(DELTA)
	print("    a single file of 12 pulled apart: %d links parted, %d splits" % [parted.size(), splits.size()])
	assert_gt(parted.size(), 0)
	assert_gt(splits.size(), 0)
	var total := 0
	for k: int in sim.cells.creature_count():
		if sim.cells.alive(k):
			total += sim.cells.cell_count(k)
	assert_eq(total, n)

func test_join_at_a_retopology_through_filters() -> void:
	var sim := GooCellsSim.new({"drag": false})
	# Type 1 never joins type 2; the script vetoes joins touching cell 0 of creature 0.
	sim.cells.set_type(1, {"join_mask": 0xffff & ~(1 << 2)})
	sim.cells.set_type(2, {"join_mask": 0xffff & ~(1 << 1)})
	var a := sim.add_creature(D.worm(6, 2), PackedInt32Array([1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0]))
	var b := sim.add_creature(D.worm(6, 2), PackedInt32Array([0, 0, 0, 0, 0, 0, 2, 2, 2, 2, 2, 2]))
	# Rows of a worm two wide: row 0 at −y, row 1 at +y. b above a: a's row 0 (type 1)
	# faces b's row 1 (type 2), which the type table forbids.
	var pitch := 2.0 * 14.0 * 0.8660254
	sim.cells.translate(b, Vector2(0, -2.0 * pitch - 1.0))
	assert_eq(sim.retopology(4.0), 0, "type 1 against type 2")
	# b below a: a's row 1 (type 0) faces b's row 0 (type 0).
	sim.cells.translate(b, Vector2(0, 4.0 * pitch + 2.0))
	var joined: Array = []
	sim.cells_joined.connect(func(cr: int, x: int, y: int) -> void: joined.append([cr, x, y]))
	sim.join_filter = func(ca: int, ia: int, cb: int, ib: int) -> bool: return not (ca == a and ia == 0)
	var made := sim.retopology(4.0)
	print("    two worms side by side joined at a retopology: %d links (vetoes and type filters applied)" % made)
	assert_gt(made, 0)
	assert_eq(joined.size(), made)
	assert_false(sim.cells.alive(b), "b merged into a")
	assert_eq(sim.cells.cell_count(a), 24)

func test_type_table_blocks_a_join() -> void:
	var sim := GooCellsSim.new({"drag": false})
	sim.cells.set_type(1, {"join_mask": 1 << 1})
	var a := sim.add_creature(D.blob(1), PackedInt32Array([1, 1, 1, 1, 1, 1, 1]))
	var b := sim.add_creature(D.blob(1))
	sim.cells.translate(b, Vector2(85.0, 0))
	assert_eq(sim.retopology(4.0), 0)
	assert_true(sim.cells.alive(b))
	sim.cells.set_type(1, {"join_mask": 0xffff})
	assert_gt(sim.retopology(4.0), 0)
	assert_false(sim.cells.alive(b))

func test_a_cell_added_eases_in_without_a_kick() -> void:
	var sim := GooCellsSim.new({"drag": false})
	var c := sim.add_creature(D.blob(2))
	var edge := sim.cells.centers(c)[0]
	var at := edge + (edge - sim.cells.creature_center(c)).normalized() * 28.0
	var k := sim.add_cell(c, at, 14.0, 1)
	var r0: float = sim.cells.radii(c)[k]
	var fastest := 0.0
	for f: int in 90:
		sim.step(DELTA)
		for v: Vector2 in sim.cells.velocities(c):
			fastest = maxf(fastest, v.length())
	var r1: float = sim.cells.radii(c)[k]
	print("    a cell added at the rim: radius %.1f -> %.1f px, fastest cell %.2f px/s, drift %.2f px/s" % [r0, r1, fastest, sim.cells.creature_velocity(c).length()])
	assert_lt(r0, 8.0)
	assert_almost_eq(r1, 14.0, 0.01)
	assert_lt(fastest, 20.0)
	assert_lt(sim.cells.creature_velocity(c).length(), 0.5)

func test_removing_a_cell_splits_a_chain() -> void:
	var sim := GooCellsSim.new({"drag": false})
	var c := sim.add_creature(D.worm(9, 1))
	var parted: Array = []
	sim.cells_parted.connect(func(_c: int, a: int, b: int) -> void: parted.append([a, b]))
	sim.remove_cell(c, 4)
	assert_eq(parted.size(), 2)
	assert_eq(sim.cells.cell_count(c), 4)
	assert_eq(sim.cells.creature_count(), 2)
	assert_eq(sim.cells.cell_count(1), 4)

func test_radius_muscles() -> void:
	var sim := GooCellsSim.new({"drag": false})
	var c := sim.add_creature(D.worm(5, 1))
	var scales := PackedFloat32Array([1.0, 1.0, 1.4, 1.0, 1.0])
	sim.cells.set_cell_scales(c, scales)
	var w0 := D.length_x(D.worm(5, 1))
	for f: int in 60:
		sim.step(DELTA)
	var p := sim.cells.centers(c)
	var r := sim.cells.radii(c)
	var span := p[4].x - p[0].x + r[0] + r[4]
	print("    a file of 5 with its middle cell at 1.4: radius %.1f px, length %.1f -> %.1f px" % [r[2], w0, span])
	assert_almost_eq(r[2], 19.6, 0.01)
	assert_almost_eq(span, w0 + 2.0 * 0.4 * 14.0, 1.0)

func test_tension_rounds_without_net_force() -> void:
	var sim := GooCellsSim.new({"drag": false, "tension": 3.0e6, "stretch_hz": 20.0, "plastic_yield": 0.0, "plastic_rate": 2.0, "bend_mode": GooCells.BEND_NONE, "self_mode": GooCells.SELF_NONE})
	var c := sim.add_creature(D.packed("ragged", 120, 5, 14.0, 14.0))
	var r0 := _roundness(sim, c)
	for f: int in 300:
		sim.step(DELTA)
	var r1 := _roundness(sim, c)
	var m := sim.cells.momentum()
	var mass := 0.0
	for r: float in sim.cells.radii(c):
		mass += PI * r * r
	print("    a ragged cluster under tension with flowing links: perimeter²/4πA %.2f -> %.2f; mean velocity %.4f px/s" % [r0, r1, Vector2(m[0], m[1]).length() / mass])
	assert_lt(r1, r0 * 0.95)
	assert_lt(Vector2(m[0], m[1]).length() / mass, 0.05)

func _roundness(sim: GooCellsSim, c: int) -> float:
	var p := sim.cells.centers(c)
	var loop := PackedVector2Array()
	for k: int in sim.cells.outline(c):
		loop.append(p[k])
	var per := 0.0
	var area := 0.0
	for i: int in loop.size():
		var a := loop[i]
		var b := loop[(i + 1) % loop.size()]
		per += a.distance_to(b)
		area += a.cross(b) * 0.5
	return per * per / (4.0 * PI * absf(area))

func test_a_worm_swims_by_undulation_alone() -> void:
	var sim := GooCellsSim.new()
	var d := D.worm(24, 5)
	var c := sim.add_creature(d)
	var length := D.length_x(d)
	sim.cells.set_wave(c, GooCells.WAVE_POSE, 1.0, length, 1.0, Vector2.RIGHT, 0.0, 0.0, 0.6)
	for f: int in 120:
		sim.step(DELTA)
	var x0 := sim.cells.creature_center(c).x
	for f: int in 240:
		sim.step(DELTA)
	var speed := (sim.cells.creature_center(c).x - x0) / 4.0
	print("    a 24 × 5 worm, pose wave of slope 1 at 1 Hz, the recommended drag: %.0f px/s, %.3f body lengths per cycle" % [speed, speed / length])
	assert_gt(speed / length, 0.15)
