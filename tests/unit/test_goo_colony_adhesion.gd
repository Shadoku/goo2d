extends TestCase
## The colony's adhesion (milestone 1 of the colony plan, docs/colony-adhesion.md):
## cells of one creature stick where they touch (GooColony with "adhesion" on, driven
## through GooColonySim). Mixed-size clusters hold under pulls and when thrown into each
## other, at unit 0.5 and 1; cells join by capture at run time and part past the break
## force, the events arriving once each, in order; the type table, the script hook and
## paused capture refuse; joins and parts by hand; sticky walls slide where anchored ones
## resist; a growing cell keeps its walls and its anchors creep; the threaded step equals
## the serial one; a seeded random game stays sound. Each test prints what it measures.

const DELTA: float = 1.0 / 60.0

var _joined: Array = []
var _parted: Array = []
var _order: Array = []

func before_each() -> void:
	GooTuning.unit = 0.5
	_joined.clear()
	_parted.clear()
	_order.clear()

func after_each() -> void:
	GooTuning.unit = 1.0

# ---- Fixtures ----

func _sim(options: Dictionary = {}) -> GooColonySim:
	var sim := GooColonySim.new(options)
	sim.cells_joined.connect(func(c: int, a: int, b: int) -> void:
		_joined.append(Vector3i(c, a, b))
		_order.append(["joined", c, a, b]))
	sim.cells_parted.connect(func(c: int, a: int, b: int) -> void:
		_parted.append(Vector3i(c, a, b))
		_order.append(["parted", c, a, b]))
	return sim

## A cluster of `count` touching cells packed about the origin (each new one touching two
## others, nearest the centre), radii between the smallest and 1.85 × it when `mixed`:
## [x, y, radius] each.
static func _pack(count: int, seed_value: int, mixed: bool) -> Array[Vector3]:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var base := GooTuning.min_radius()
	var next := func() -> float:
		return base * (1.0 + 0.85 * rng.randf()) if mixed else base
	var cells: Array[Vector3] = []
	var r0: float = next.call()
	var r1: float = next.call()
	cells.append(Vector3(0, 0, r0))
	cells.append(Vector3(r0 + r1, 0, r1))
	while cells.size() < count:
		var r: float = next.call()
		var best := INF
		var best_at := Vector2.ZERO
		for i: int in cells.size():
			for j: int in range(i + 1, cells.size()):
				var a := cells[i]
				var b := cells[j]
				var ca := Vector2(a.x, a.y)
				var cb := Vector2(b.x, b.y)
				var d := ca.distance_to(cb)
				if d > a.z + b.z + 0.01:
					continue
				var r1s := a.z + r
				var r2s := b.z + r
				var x := (d * d + r1s * r1s - r2s * r2s) / (2.0 * d)
				var h := sqrt(maxf(r1s * r1s - x * x, 0.0))
				var dir := (cb - ca) / d
				for side: float in [-1.0, 1.0]:
					var at := ca + dir * x + dir.orthogonal() * h * side
					var free := true
					for c: Vector3 in cells:
						if Vector2(c.x, c.y).distance_to(at) < c.z + r - 0.01:
							free = false
							break
					if free and at.length() < best:
						best = at.length()
						best_at = at
		cells.append(Vector3(best_at.x, best_at.y, r))
	var mean := Vector2.ZERO
	for c: Vector3 in cells:
		mean += Vector2(c.x, c.y)
	mean /= cells.size()
	for i: int in cells.size():
		cells[i] = Vector3(cells[i].x - mean.x, cells[i].y - mean.y, cells[i].z)
	return cells

## Adds the cluster `cells` turned by `angle` about `at`; its creature index.
static func _add(sim: GooColonySim, cells: Array[Vector3], at: Vector2, angle: float = 0.0, cores: PackedInt32Array = PackedInt32Array()) -> int:
	var list: Array = []
	for i: int in cells.size():
		var c := cells[i]
		list.append({ "position": at + Vector2(c.x, c.y).rotated(angle), "radius": c.z, "core": cores.has(i) })
	return sim.add_creature(list)

static func _steps(sim: GooColonySim, frames: int) -> void:
	for f: int in frames:
		sim.step(DELTA)

## Whether every cell of creature `c` is reached from cell 0 through its neighbours.
static func _connected(sim: GooColonySim, c: int) -> bool:
	var n := sim.colony.cell_count(c)
	var seen := { 0: true }
	var stack := [0]
	while not stack.is_empty():
		var cell: int = stack.pop_back()
		for other: int in sim.colony.cell_neighbours(c, cell):
			if not seen.has(other):
				seen[other] = true
				stack.append(other)
	return seen.size() == n

## The largest distance between two cell centres of creature `c`.
static func _span(sim: GooColonySim, c: int) -> float:
	var n := sim.colony.cell_count(c)
	var best := 0.0
	for i: int in n:
		for j: int in range(i + 1, n):
			best = maxf(best, sim.colony.cell_center(c, i).distance_to(sim.colony.cell_center(c, j)))
	return best

static func _sound(h: Dictionary) -> String:
	return "area %.2f..%.2f, %d inside out, %d not finite, sticks stretched %.2f / squeezed %.2f px, load %.0f" % [
		h["area_min"], h["area_max"], int(h["inverted"]), int(h["not_finite"]), h["stick_stretch"], h["stick_squeeze"], h["stick_load"]]

# ---- Capture and events ----

func test_touching_cells_join_by_capture_and_the_events_come_once_in_order() -> void:
	var sim := _sim()
	var r := GooTuning.min_radius()
	# A row of three touching cells and a fourth well apart.
	var k := sim.add_creature([{ "position": Vector2(0, 0), "radius": r }, { "position": Vector2(2 * r, 0), "radius": r },
		{ "position": Vector2(4 * r, 0), "radius": r }, { "position": Vector2(0, 100), "radius": r }])
	sim.step(DELTA)
	print("    after one step: joined %s" % [_joined])
	assert_eq(_joined, [Vector3i(k, 0, 1), Vector3i(k, 1, 2)], "joined in the first step, in cell-pair order")
	_steps(sim, 60)
	assert_eq(_joined.size(), 2, "once each")
	assert_eq(_parted.size(), 0)
	assert_eq(sim.colony.cell_neighbours(k, 1), PackedInt32Array([0, 2]), "the middle cell's neighbours")
	assert_eq(sim.colony.cell_neighbours(k, 3), PackedInt32Array(), "the far cell touches nothing")
	assert_eq(sim.colony.take_events().size(), 0, "nothing left queued")

func test_cells_of_different_creatures_never_stick() -> void:
	var sim := _sim()
	var r := GooTuning.min_radius()
	var a := sim.add_creature([{ "position": Vector2(0, 0), "radius": r }])
	var b := sim.add_creature([{ "position": Vector2(2 * r, 0), "radius": r }])
	sim.colony.push_creature(a, Vector2(300, 0))
	_steps(sim, 60)
	assert_eq(_joined.size(), 0)
	assert_eq(sim.colony.stats()["sticks"], 0)
	assert_gt(sim.colony.creature_center(b).x, 2 * r + 5.0, "they still collide: b is pushed along")

func test_a_cell_brought_up_at_run_time_joins_by_capture() -> void:
	var sim := _sim()
	var r := GooTuning.min_radius()
	var k := sim.add_creature([{ "position": Vector2(0, 0), "radius": r }, { "position": Vector2(2 * r, 0), "radius": r },
		{ "position": Vector2(r, 6 * r), "radius": r }])
	sim.step(DELTA)
	assert_eq(_joined, [Vector3i(k, 0, 1)])
	sim.colony.push_cell(k, 2, Vector2(0, -400))
	var frame := 0
	while _joined.size() < 2 and frame < 180:
		sim.step(DELTA)
		frame += 1
	sim.colony.push_cell(k, 2, Vector2.ZERO)
	print("    the third cell joined after %d frames: %s, neighbours %s" % [frame, _joined, sim.colony.cell_neighbours(k, 2)])
	assert_lt(frame, 180, "it joined")
	assert_true(_joined.has(Vector3i(k, 0, 2)) or _joined.has(Vector3i(k, 1, 2)))
	_steps(sim, 60)
	assert_eq(_parted.size(), 0, "and stays")

func test_a_cell_with_six_neighbours_and_three_and_more_everywhere_inside() -> void:
	var sim := _sim()
	var r := GooTuning.min_radius()
	var cells: Array = []
	for q: int in range(-2, 3):
		for p: int in range(-2, 3):
			if absi(p + q) <= 2:
				cells.append({ "position": Vector2(p * 2.0 * r + q * r, q * sqrt(3.0) * r), "radius": r })
	var k := sim.add_creature(cells)
	_steps(sim, 60)
	var counts := PackedInt32Array()
	for i: int in cells.size():
		counts.append(sim.colony.cell_neighbours(k, i).size())
	print("    neighbours per cell: %s (%d sticks)" % [counts, sim.colony.stats()["sticks"]])
	assert_eq(counts[9], 6, "the middle cell is stuck to all six around it")
	var three := 0
	for n: int in counts:
		if n >= 3:
			three += 1
	assert_eq(three, cells.size(), "every cell has three or more neighbours")

# ---- Holding ----

func _pull_test(unit: float) -> void:
	GooTuning.unit = unit
	var sim := _sim()
	var cells := _pack(14, 7, true)
	var k := _add(sim, cells, Vector2.ZERO)
	_steps(sim, 30)
	assert_true(_connected(sim, k), "the packed cluster is one piece")
	var span0 := _span(sim, k)
	# The left third pulled left and the right third right, then up and down.
	var accel := 600.0 * unit / 0.5
	var worst := 0.0
	var health := {}
	for phase: int in 2:
		for i: int in cells.size():
			var c := cells[i]
			var side := 0.0
			var coordinate := c.x if phase == 0 else c.y
			if coordinate < -GooTuning.min_radius():
				side = -1.0
			elif coordinate > GooTuning.min_radius():
				side = 1.0
			sim.colony.push_cell(k, i, (Vector2.RIGHT if phase == 0 else Vector2.DOWN) * side * accel)
		for f: int in 60:
			sim.step(DELTA)
			worst = maxf(worst, _span(sim, k) / span0)
			health = sim.colony.health()
			assert_eq(health["inverted"], 0.0)
	for i: int in cells.size():
		sim.colony.push_cell(k, i, Vector2.ZERO)
	_steps(sim, 90)
	var after := _span(sim, k) / span0
	print("    unit %.1f, %d mixed cells pulled apart at %.0f px/s²: span up to %.2f of its rest, %.2f after letting go; %d parted; %s" % [
		unit, cells.size(), accel, worst, after, _parted.size(), _sound(sim.colony.health())])
	assert_eq(_parted.size(), 0, "no wall parted")
	assert_true(_connected(sim, k), "still one piece")
	assert_lt(worst, 1.35, "it stretches, but holds")
	assert_almost_eq(after, 1.0, 0.1, "and comes back")

func test_a_mixed_cluster_holds_under_pulls_at_unit_half() -> void:
	_pull_test(0.5)

func test_a_mixed_cluster_holds_under_pulls_at_unit_one() -> void:
	_pull_test(1.0)

func _throw_test(unit: float) -> void:
	GooTuning.unit = unit
	var sim := _sim()
	var cells := _pack(12, 3, true)
	var a := _add(sim, cells, Vector2(-70 * unit / 0.5, 0))
	var b := _add(sim, cells, Vector2(70 * unit / 0.5, 10 * unit / 0.5), 1.0)
	_steps(sim, 10)
	var speed := 600.0 * unit / 0.5
	var hits := 0
	var worst := { "area_min": INF, "area_max": 0.0, "inverted": 0.0 }
	# Thrown at each other: a push for a few frames, then coasting into the impact.
	sim.colony.push_creature(a, Vector2(speed * 6.0, 0))
	sim.colony.push_creature(b, Vector2(-speed * 6.0, 0))
	for f: int in 120:
		if f == 10:
			sim.colony.push_creature(a, Vector2.ZERO)
			sim.colony.push_creature(b, Vector2.ZERO)
		sim.step(DELTA)
		hits = maxi(hits, sim.colony.stats()["cross_hits"])
		var h := sim.colony.health()
		worst["area_min"] = minf(worst["area_min"], h["area_min"])
		worst["area_max"] = maxf(worst["area_max"], h["area_max"])
		worst["inverted"] = maxf(worst["inverted"], h["inverted"])
	print("    unit %.1f, two clusters of %d thrown together at %.0f px/s each: %d contacts at the impact, area %.2f..%.2f, %d inside out, %d walls parted, a and b one piece: %s %s" % [
		unit, cells.size(), speed, hits, worst["area_min"], worst["area_max"],
		int(worst["inverted"]), _parted.size(), _connected(sim, a), _connected(sim, b)])
	assert_gt(hits, 10, "they met")
	assert_true(_connected(sim, a), "a holds together")
	assert_true(_connected(sim, b), "b holds together")
	assert_eq(worst["inverted"], 0.0)
	assert_gt(worst["area_min"], 0.5)

func test_mixed_clusters_thrown_into_each_other_hold_at_unit_half() -> void:
	_throw_test(0.5)

func test_mixed_clusters_thrown_into_each_other_hold_at_unit_one() -> void:
	_throw_test(1.0)

# ---- Breaking ----

func test_cells_pulled_past_the_break_force_part_once() -> void:
	var sim := _sim()
	var r := GooTuning.min_radius()
	var k := sim.add_creature([{ "position": Vector2(0, 0), "radius": r }, { "position": Vector2(2 * r, 0), "radius": r }])
	_steps(sim, 20)
	assert_eq(_joined, [Vector3i(k, 0, 1)])
	# A gentle pull holds...
	sim.colony.push_cell(k, 0, Vector2(-800, 0))
	sim.colony.push_cell(k, 1, Vector2(800, 0))
	_steps(sim, 40)
	var gentle_load: float = sim.colony.health()["stick_load"]
	assert_eq(_parted.size(), 0, "a gentle pull holds")
	# ... a hard one parts them.
	sim.colony.push_cell(k, 0, Vector2(-20000, 0))
	sim.colony.push_cell(k, 1, Vector2(20000, 0))
	var frame := 0
	while _parted.is_empty() and frame < 60:
		sim.step(DELTA)
		frame += 1
	sim.colony.push_cell(k, 0, Vector2.ZERO)
	sim.colony.push_cell(k, 1, Vector2.ZERO)
	_steps(sim, 30)
	print("    load %.0f at 800 px/s² each way; parted %d frames into a 20000 px/s² pull (break %.0f); events %s" % [
		gentle_load, frame, GooColonySim.BREAK_FORCE * GooTuning.unit, _order])
	assert_lt(frame, 60, "they parted")
	assert_eq(_order, [["joined", k, 0, 1], ["parted", k, 0, 1]], "joined, then parted, once each")
	assert_eq(sim.colony.cell_neighbours(k, 0).size(), 0)
	assert_gt(sim.colony.cell_center(k, 0).distance_to(sim.colony.cell_center(k, 1)), 2 * r + 5.0, "and moved apart")

# ---- Filters ----

func test_the_type_table_refuses_a_pair() -> void:
	var sim := _sim()
	var r := GooTuning.min_radius()
	sim.colony.set_join_mode(1, 2, GooColony.JOIN_NONE)
	assert_eq(sim.colony.join_mode(2, 1), GooColony.JOIN_NONE, "symmetric")
	assert_eq(sim.colony.join_mode(1, 1), GooColony.JOIN_ANCHORED, "the default")
	var k := sim.add_creature([{ "position": Vector2(0, 0), "radius": r, "type": 1 }, { "position": Vector2(2 * r, 0), "radius": r, "type": 2 },
		{ "position": Vector2(r, 1.732 * r), "radius": r, "type": 1 }])
	assert_eq(sim.colony.cell_type(k, 1), 2)
	_steps(sim, 30)
	print("    joined %s" % [_joined])
	assert_false(_joined.has(Vector3i(k, 0, 1)), "types 1 and 2 never join")
	assert_true(_joined.has(Vector3i(k, 0, 2)), "types 1 and 1 do")
	assert_false(_joined.has(Vector3i(k, 1, 2)))

class RefusingSim extends GooColonySim:
	var asked: Array = []
	func may_adhere(creature: int, a: int, b: int) -> bool:
		asked.append(Vector3i(creature, a, b))
		return not (a == 0 and b == 1)

func test_the_script_hook_is_asked_once_per_pair_and_refuses() -> void:
	var sim := RefusingSim.new()
	sim.cells_joined.connect(func(c: int, a: int, b: int) -> void: _joined.append(Vector3i(c, a, b)))
	sim.asks_script = true
	var r := GooTuning.min_radius()
	var k := sim.add_creature([{ "position": Vector2(0, 0), "radius": r }, { "position": Vector2(2 * r, 0), "radius": r },
		{ "position": Vector2(r, 1.732 * r), "radius": r }])
	sim.step(DELTA)
	assert_eq(_joined.size(), 0, "nothing joins before the answer")
	_steps(sim, 60)
	print("    asked %s, joined %s" % [sim.asked, _joined])
	assert_eq(sim.asked, [Vector3i(k, 0, 1), Vector3i(k, 0, 2), Vector3i(k, 1, 2)], "each pair asked once, in order")
	assert_eq(_joined, [Vector3i(k, 0, 2), Vector3i(k, 1, 2)], "the refused pair never joins")

func test_paused_capture_joins_nothing_until_resumed() -> void:
	var sim := _sim()
	var r := GooTuning.min_radius()
	var a := sim.add_creature([{ "position": Vector2(0, 0), "radius": r }, { "position": Vector2(2 * r, 0), "radius": r }])
	var b := sim.add_creature([{ "position": Vector2(0, 100), "radius": r }, { "position": Vector2(2 * r, 100), "radius": r }])
	sim.colony.set_capture_paused(a, true)
	assert_true(sim.colony.is_capture_paused(a))
	_steps(sim, 20)
	assert_eq(_joined, [Vector3i(b, 0, 1)], "only the creature not paused joins")
	sim.colony.set_capture_paused(-1, true)
	sim.colony.set_capture_paused(a, false)
	assert_true(sim.colony.is_capture_paused(a), "the whole colony paused")
	sim.colony.push_cell(a, 0, Vector2(150, 0))
	sim.colony.push_cell(a, 1, Vector2(-150, 0))
	_steps(sim, 20)
	assert_eq(_joined.size(), 1, "nothing joins while the colony is paused")
	sim.colony.set_capture_paused(-1, false)
	_steps(sim, 2)
	assert_eq(_joined, [Vector3i(b, 0, 1), Vector3i(a, 0, 1)], "resumed: it joins")

func test_join_and_part_by_hand() -> void:
	var sim := _sim()
	var r := GooTuning.min_radius()
	# Cell 2 is 3.5 px from cell 1: beyond the capture gap (2.5), within the join reach (4).
	var k := sim.add_creature([{ "position": Vector2(0, 0), "radius": r }, { "position": Vector2(2 * r, 0), "radius": r },
		{ "position": Vector2(4 * r + 3.5, 0), "radius": r }])
	sim.step(DELTA)
	assert_eq(_joined, [Vector3i(k, 0, 1)], "1 and 2 are beyond the capture gap")
	var made := sim.join_cells(k, 1, 2)
	assert_gt(made, 0)
	assert_eq(_joined[-1], Vector3i(k, 1, 2), "the joined event at once")
	_steps(sim, 30)
	var gap := sim.colony.cell_center(k, 1).distance_to(sim.colony.cell_center(k, 2)) - 2 * r
	assert_lt(gap, 1.5, "the sticks pull them together")
	# Part the touching pair: they stay apart while they touch.
	var removed := sim.part_cells(k, 0, 1)
	assert_gt(removed, 0)
	assert_eq(_parted, [Vector3i(k, 0, 1)], "the parted event at once")
	assert_eq(sim.colony.cell_neighbours(k, 1), PackedInt32Array([2]))
	# A refused pair can be joined by hand too.
	var again := sim.join_cells(k, 0, 1)
	assert_gt(again, 0)
	assert_eq(_joined[-1], Vector3i(k, 0, 1))
	assert_eq(sim.part_cells(k, 0, 1), again, "and parted again")
	sim.colony.push_cell(k, 0, Vector2(100, 0))
	_steps(sim, 30)
	sim.colony.push_cell(k, 0, Vector2.ZERO)
	print("    join made %d, part removed %d; pressed together for 0.5 s after the part: neighbours of 0 %s, distance %.1f px" % [
		made, removed, sim.colony.cell_neighbours(k, 0), sim.colony.cell_center(k, 0).distance_to(sim.colony.cell_center(k, 1))])
	assert_eq(sim.colony.cell_neighbours(k, 0), PackedInt32Array(), "a parted pair is not captured again while it touches")
	assert_eq(_joined.size(), 3)
	assert_eq(_parted.size(), 2)

# ---- Anchors ----

## A cell stuck to a much heavier one and pushed round it for 0.7 s (along the wall,
## a little toward the other): how far round it went (rad), and how far its own ring
## turned over that. Through an anchored wall it rolls round (a coin rolled round an equal
## coin turns twice per lap: about 2). A sticky wall carries no force along itself: the
## cell slides round without turning (about 0).
func _roll(mode: int) -> Vector2:
	var sim := _sim()
	var r := GooTuning.min_radius()
	sim.colony.set_join_mode(0, 0, mode)
	var heavy := GooColonySim.cell_floats(Vector2.ZERO, r)
	heavy[7] *= 50.0
	var floats := PackedFloat32Array()
	floats.append_array(heavy)
	floats.append_array(GooColonySim.cell_floats(Vector2(0, -2 * r), r))
	var k := sim.colony.add_creature(floats)
	_steps(sim, 20)
	var line_turn := 0.0
	var ring_turn := 0.0
	var line_prev := (sim.colony.cell_center(k, 1) - sim.colony.cell_center(k, 0)).angle()
	var ring_prev := _ring_angle(sim, k, 1)
	for f: int in 42:
		var out := (sim.colony.cell_center(k, 1) - sim.colony.cell_center(k, 0)).normalized()
		sim.colony.push_cell(k, 1, out.orthogonal() * -500.0 - out * 150.0)
		sim.step(DELTA)
		var line := (sim.colony.cell_center(k, 1) - sim.colony.cell_center(k, 0)).angle()
		var ring := _ring_angle(sim, k, 1)
		line_turn += wrapf(line - line_prev, -PI, PI)
		ring_turn += wrapf(ring - ring_prev, -PI, PI)
		line_prev = line
		ring_prev = ring
	var ratio := ring_turn / line_turn
	print("    %s: went %.2f rad round the heavy cell and turned %.2f rad itself (ratio %.2f); stuck to %s" % [
		"anchored" if mode == GooColony.JOIN_ANCHORED else "sticky", line_turn, ring_turn, ratio, sim.colony.cell_neighbours(k, 1)])
	assert_gt(absf(line_turn), 0.2, "it went round")
	assert_eq(sim.colony.cell_neighbours(k, 1), PackedInt32Array([0]), "and stayed on")
	return Vector2(absf(line_turn), ratio)

## How cell `cell`'s ring is turned: its first bead's direction from its centroid.
static func _ring_angle(sim: GooColonySim, c: int, cell: int) -> float:
	var points := sim.colony.cell_points(c, cell)
	var centre := Vector2.ZERO
	for p: Vector2 in points:
		centre += p
	centre /= points.size()
	return (points[0] - centre).angle()

func test_sticky_walls_slide_where_anchored_ones_resist() -> void:
	var anchored := _roll(GooColony.JOIN_ANCHORED)
	var sticky := _roll(GooColony.JOIN_STICKY)
	assert_gt(sticky.x, 3.0 * anchored.x, "pushed alike, a sticky wall lets it go round much further")
	assert_gt(anchored.y, 1.4, "an anchored wall holds: the cell rolls round")
	assert_lt(absf(sticky.y), 0.6, "a sticky wall slides: the cell turns much less than it would rolling (2)")

func test_a_growing_cell_keeps_its_walls_and_its_anchors_creep() -> void:
	var sim := _sim()
	var r := GooTuning.min_radius()
	var cells: Array = [{ "position": Vector2.ZERO, "radius": r }]
	for i: int in 6:
		cells.append({ "position": Vector2.from_angle(TAU * i / 6.0) * 2.0 * r, "radius": r })
	var k := sim.add_creature(cells)
	_steps(sim, 30)
	assert_eq(sim.colony.cell_neighbours(k, 0).size(), 6)
	var tension_peak := 0.0
	var worst_gap := 0.0
	for f: int in 120:
		sim.colony.resize_cell(k, 0, r * (1.0 + 0.4 * (f + 1) / 120.0))
		sim.step(DELTA)
		tension_peak = maxf(tension_peak, _tension(sim, k))
		worst_gap = maxf(worst_gap, sim.colony.health()["stick_stretch"])
	var tension_end := _tension(sim, k)
	_steps(sim, 180)
	var tension_rest := _tension(sim, k)
	print("    grown to %.1f px over 2 s: neighbours %s, %d parted, gap up to %.2f px, anchor tension %.2f px at its peak, %.2f when it stops growing, %.2f 3 s later; %s" % [
		sim.colony.cell_radius(k, 0), sim.colony.cell_neighbours(k, 0), _parted.size(), worst_gap, tension_peak, tension_end, tension_rest, _sound(sim.colony.health())])
	assert_eq(sim.colony.cell_neighbours(k, 0).size(), 6, "still stuck to all six")
	assert_eq(_parted.size(), 0)
	assert_lt(worst_gap, GooColonySim.CAPTURE * GooTuning.unit, "the walls stay closed, within the capture gap")
	assert_lt(tension_rest, 0.6 * tension_end, "the anchors crept: their tension relaxed")
	assert_almost_eq(sim.colony.cell_radius(k, 0), 1.4 * r, 1e-3)

## The largest anchor tension (px) of creature `c`'s sticks.
static func _tension(sim: GooColonySim, c: int) -> float:
	var st := sim.colony.creature_sticks(c)
	var worst := 0.0
	for q: int in range(0, st.size(), GooColony.STICK_FLOATS):
		worst = maxf(worst, absf(st[q + 11]))
	return worst

# ---- Determinism and soundness ----

func _game(threads: int) -> GooColonySim:
	var sim := GooColonySim.new({ "threads": threads })
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261112
	for c: int in 6:
		var cells := _pack(10, 11 + c, true)
		var k := _add(sim, cells, Vector2((c % 3) * 150.0, (c / 3) * 150.0), rng.randf() * TAU, PackedInt32Array([0]) if c % 2 == 0 else PackedInt32Array())
		sim.colony.push_creature(k, Vector2.from_angle(rng.randf() * TAU) * 900.0)
	return sim

func test_threaded_step_equals_serial_with_adhesion() -> void:
	var serial := _game(1)
	var threaded := _game(4)
	var events_a := PackedInt64Array()
	var events_b := PackedInt64Array()
	var made := 0
	var broken := 0
	for f: int in 240:
		if f % 40 == 39:
			for c: int in serial.colony.creature_count():
				var push := Vector2.from_angle(f * 0.7 + c) * 900.0
				serial.colony.push_creature(c, push)
				threaded.colony.push_creature(c, push)
				serial.colony.push_cell(c, f % 10, push * 12.0)
				threaded.colony.push_cell(c, f % 10, push * 12.0)
		serial.colony.step(DELTA)
		threaded.colony.step(DELTA)
		events_a.append_array(serial.colony.take_events())
		events_b.append_array(threaded.colony.take_events())
		made += serial.colony.stats()["made"]
		broken += serial.colony.stats()["broken"]
	print("    240 frames, 6 clusters: %d sticks made, %d broken, %d events" % [made, broken, events_a.size() / 4])
	assert_gt(broken, 0, "walls broke along the way")
	assert_gt(made, 0)
	assert_eq(events_a, events_b, "the same events in the same order")
	for c: int in serial.colony.creature_count():
		var a := serial.colony.creature_points(c)
		var b := threaded.colony.creature_points(c)
		var same := a.size() == b.size()
		for i: int in mini(a.size(), b.size()):
			if a[i] != b[i]:
				same = false
				break
		assert_true(same, "creature %d's particles are bit for bit the serial ones" % c)
		assert_eq(serial.colony.creature_sticks(c), threaded.colony.creature_sticks(c), "and its sticks")

func test_a_seeded_random_game_of_thrown_clusters_stays_sound() -> void:
	var sim := _game(1)
	sim.cells_joined.connect(func(c: int, a: int, b: int) -> void: _joined.append(Vector3i(c, a, b)))
	sim.cells_parted.connect(func(c: int, a: int, b: int) -> void: _parted.append(Vector3i(c, a, b)))
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	var worst := { "area_min": INF, "area_max": 0.0, "inverted": 0.0, "not_finite": 0.0, "fastest": 0.0 }
	for f: int in 300:
		if f % 30 == 0:
			for c: int in sim.colony.creature_count():
				sim.colony.push_creature(c, Vector2.from_angle(rng.randf() * TAU) * rng.randf_range(300.0, 1500.0))
				sim.colony.push_cell(c, rng.randi_range(0, 9), Vector2.from_angle(rng.randf() * TAU) * rng.randf_range(0.0, 8000.0))
		sim.step(DELTA)
		var h := sim.colony.health()
		for key: String in worst:
			worst[key] = minf(worst[key], h[key]) if key == "area_min" else maxf(worst[key], h[key])
	print("    300 frames of 6 clusters thrown about: fastest %.0f px/s, area %.2f..%.2f, %d inside out, %d not finite; %d joined, %d parted" % [
		worst["fastest"], worst["area_min"], worst["area_max"], int(worst["inverted"]), int(worst["not_finite"]), _joined.size(), _parted.size()])
	assert_eq(worst["not_finite"], 0.0, "no NaN")
	assert_eq(worst["inverted"], 0.0, "no cell inside out")
	assert_gt(worst["area_min"], 0.5)
	assert_lt(worst["area_max"], 1.5)
