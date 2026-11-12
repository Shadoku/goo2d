extends TestCase
## The colony's exposure, core cells and drag (milestone 2 of the colony plan,
## docs/colony-exposure.md), through GooColonySim at unit 0.5: the middle of a hexagonal
## cluster is enclosed and becomes a core while the rim keeps its exposed beads on the
## outside; a pocket inside a ring of cells is found, a bay open to the outside is not;
## rings become cores and cores rings again without a jump and without flicker; enclosed
## beads take no part in collisions and soft cores squash the outer cells less; the drag
## matches the fluid game's law, spares enclosed cells and grows with the outline; a thrown
## cell stops as the game's bodies do; the threaded step equals the serial one with all of
## it on. Each test prints what it measures.

const DELTA: float = 1.0 / 60.0

var _joined: Array = []
var _parted: Array = []

func before_each() -> void:
	GooTuning.unit = 0.5
	_joined.clear()
	_parted.clear()

func after_each() -> void:
	GooTuning.unit = 1.0

# ---- Fixtures ----

func _sim(options: Dictionary = {}) -> GooColonySim:
	var sim := GooColonySim.new(options)
	sim.cells_joined.connect(func(c: int, a: int, b: int) -> void: _joined.append(Vector3i(c, a, b)))
	sim.cells_parted.connect(func(c: int, a: int, b: int) -> void: _parted.append(Vector3i(c, a, b)))
	return sim

## A hexagonal cluster of touching cells of the smallest size, `rings` rings about the
## middle one (2: 19 cells, 3: 37), in rows: [{position, radius}].
static func _hex(rings: int, at: Vector2 = Vector2.ZERO) -> Array:
	var r := GooTuning.min_radius()
	var cells: Array = []
	for q: int in range(-rings, rings + 1):
		for p: int in range(-rings, rings + 1):
			if absi(p + q) <= rings:
				cells.append({ "position": at + Vector2(p * 2.0 * r + q * r, q * sqrt(3.0) * r), "radius": r })
	return cells

## `n` touching cells of the smallest size on a circle (a ring of cells round a hole), the
## cell `skip` left out (-1: none, a closed ring).
static func _circle_of_cells(n: int, skip: int = -1) -> Array:
	var r := GooTuning.min_radius()
	var big := r / sin(PI / n)
	var cells: Array = []
	for i: int in n:
		if i != skip:
			cells.append({ "position": Vector2.from_angle(TAU * i / n) * big, "radius": r })
	return cells

static func _middle(cells: Array) -> int:
	for i: int in cells.size():
		if (cells[i]["position"] as Vector2).is_zero_approx():
			return i
	return -1

static func _steps(sim: GooColonySim, frames: int) -> void:
	for f: int in frames:
		sim.step(DELTA)

static func _exposed_counts(sim: GooColonySim, c: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	for cell: int in sim.colony.cell_count(c):
		out.append(sim.colony.cell_exposed_count(c, cell))
	return out

static func _centre_of(points: PackedVector2Array) -> Vector2:
	var total := Vector2.ZERO
	for p: Vector2 in points:
		total += p
	return total / maxi(points.size(), 1)

static func _count(kinds: PackedInt32Array, kind: int) -> int:
	var n := 0
	for k: int in kinds:
		if k == kind:
			n += 1
	return n

static func _cores(sim: GooColonySim, c: int) -> int:
	var n := 0
	for cell: int in sim.colony.cell_count(c):
		if sim.colony.cell_kind(c, cell) == 1:
			n += 1
	return n

# ---- Exposure and pockets ----

func test_the_middle_of_a_hex_cluster_is_enclosed_the_rim_exposed_only_outside_and_the_middle_becomes_cores() -> void:
	var sim := _sim({ "exposure": true })
	var cells := _hex(2)
	var k := sim.add_creature(cells)
	_steps(sim, 20)
	var counts := _exposed_counts(sim, k)
	var middle := _middle(cells)
	var r := GooTuning.min_radius()
	var inner := 0
	var rim := 0
	var inward := 0
	var outward := 0
	for cell: int in cells.size():
		var at: Vector2 = cells[cell]["position"]
		if at.length() < 2.5 * r:
			inner += counts[cell]
			continue
		rim += 1
		assert_gt(counts[cell], 0, "rim cell %d has exposed beads" % cell)
		# Its exposed beads face away from the cluster, its beads facing in are enclosed.
		var points := sim.colony.cell_points(k, cell)
		var mask := sim.colony.cell_exposed(k, cell)
		var centre := _centre_of(points)
		for i: int in points.size():
			if mask[i] == 1:
				outward += 1
				if (points[i] - centre).dot(centre.normalized()) < 0.0:
					inward += 1
	var kinds := sim.colony.creature_loop_kinds(k)
	var outline := sim.colony.creature_outline(k)
	print("    hex of 19: exposed per cell %s; the 7 inner cells %d exposed beads; %d rim cells, %d exposed beads, %d of them facing in; loops %s, outline %d points" % [
		counts, inner, rim, outward, inward, kinds, outline.size()])
	assert_eq(counts[middle], 0, "the middle cell has no exposed bead")
	assert_eq(inner, 0, "nor do the six around it")
	assert_eq(inward, 0, "the rim's exposed beads all face outward")
	assert_eq(kinds, PackedInt32Array([GooColony.LOOP_OUTSIDE]), "one loop, the outside, no pocket")
	assert_eq(outline.size(), outward, "the outline runs through every exposed bead")
	# Now let enclosed rings become cores.
	sim.colony.set_options({ "auto_cores": true })
	var frames := 0
	while _cores(sim, k) < 7 and frames < 60:
		sim.step(DELTA)
		frames += 1
	_steps(sim, 120)
	print("    auto cores on: %d cores after %d frames (to_core_time %.2f s), %d after 2 s more; parted events %s" % [
		_cores(sim, k), frames, 0.25, _cores(sim, k), _parted])
	assert_eq(sim.colony.cell_kind(k, middle), 1, "the middle cell became a core")
	assert_eq(_cores(sim, k), 7, "the seven enclosed cells, and only they")
	assert_eq(_parted.size(), 0, "a switch is not a parting")
	assert_eq(sim.colony.cell_neighbours(k, middle).size(), 6, "the core is stuck to all six again")

func test_a_pocket_inside_a_ring_of_cells_is_found_and_a_bay_open_to_the_outside_is_not() -> void:
	for skip: int in [-1, 0]:
		var sim := _sim({ "exposure": true })
		var cells := _circle_of_cells(10, skip)
		var k := sim.add_creature(cells)
		_steps(sim, 20)
		var kinds := sim.colony.creature_loop_kinds(k)
		# Beads facing the middle (the hole), and facing away.
		var facing_in := 0
		var facing_in_open := 0
		var facing_out := 0
		var facing_out_open := 0
		for cell: int in cells.size():
			var points := sim.colony.cell_points(k, cell)
			var mask := sim.colony.cell_exposed(k, cell)
			var centre := _centre_of(points)
			for i: int in points.size():
				var along := (points[i] - centre).normalized().dot(centre.normalized())
				if along < -0.9:
					facing_in += 1
					facing_in_open += mask[i]
				elif along > 0.9:
					facing_out += 1
					facing_out_open += mask[i]
		var pocket_area := 0.0
		for li: int in kinds.size():
			if kinds[li] == GooColony.LOOP_POCKET:
				pocket_area = absf(GooLoop.signed_area(sim.colony.creature_loop(k, li)))
		print("    %s ring of %d cells: loops %s (pocket area %.0f px²); beads facing the hole %d exposed of %d, facing out %d of %d" % [
			"closed" if skip < 0 else "open", cells.size(), kinds, pocket_area, facing_in_open, facing_in, facing_out_open, facing_out])
		assert_eq(facing_out_open, facing_out, "beads facing out are exposed")
		if skip < 0:
			assert_eq(_count(kinds, GooColony.LOOP_POCKET), 1, "the hole is a pocket")
			assert_eq(_count(kinds, GooColony.LOOP_OUTSIDE), 1)
			assert_eq(facing_in_open, 0, "beads facing the pocket are enclosed")
			assert_gt(pocket_area, 1000.0)
		else:
			assert_eq(_count(kinds, GooColony.LOOP_POCKET), 0, "an open bay is the outside")
			assert_eq(facing_in_open, facing_in, "beads facing the bay are exposed")

# ---- Switching ----

## The adhesion tests' packing: `count` touching cells, mixed sizes when `mixed`.
static func _pack(count: int, seed_value: int, mixed: bool) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var base := GooTuning.min_radius()
	var cells: Array[Vector3] = []
	var r0 := base * (1.0 + 0.85 * rng.randf()) if mixed else base
	var r1 := base * (1.0 + 0.85 * rng.randf()) if mixed else base
	cells.append(Vector3(0, 0, r0))
	cells.append(Vector3(r0 + r1, 0, r1))
	while cells.size() < count:
		var r := base * (1.0 + 0.85 * rng.randf()) if mixed else base
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
	var out: Array = []
	for c: Vector3 in cells:
		out.append({ "position": Vector2(c.x, c.y) - mean, "radius": c.z })
	return out

static func _centres(sim: GooColonySim, c: int) -> PackedVector2Array:
	var out := PackedVector2Array()
	for cell: int in sim.colony.cell_count(c):
		out.append(sim.colony.cell_center(c, cell))
	return out

func test_rings_become_cores_without_a_jump_and_without_flicker() -> void:
	# Twins: the same cluster with and without the switch; what differs is the switch.
	for mixed: bool in [false, true]:
		var cells := _pack(40, 5, mixed)
		var options := { "exposure": true, "soft_cores": true, "core_anchors": true }
		var a := _sim(options)
		var b := GooColonySim.new(options)
		a.add_creature(cells)
		b.add_creature(cells)
		_steps(a, 30)
		_steps(b, 30)
		a.colony.set_options({ "auto_cores": true })
		var switched_at := -1
		var before := PackedVector2Array()
		var own := 0.0
		var shifts := PackedFloat32Array()
		var vel_shift := 0.0
		var switched: Array[int] = []
		var to_core := 0
		var to_ring := 0
		for f: int in 300:
			var centres := _centres(a, 0)
			a.step(DELTA)
			b.step(DELTA)
			var s := a.colony.stats()
			to_core += s["to_core"]
			to_ring += s["to_ring"]
			if switched_at < 0 and s["to_core"] > 0:
				switched_at = f
				before = centres
				for cell: int in cells.size():
					if a.colony.cell_kind(0, cell) == 1:
						switched.append(cell)
				# The switched cells' centres across the switch frame, against the twin's.
				var ca := _centres(a, 0)
				var cb := _centres(b, 0)
				for cell: int in switched:
					own = maxf(own, ca[cell].distance_to(cb[cell]))
				var va := a.colony.creature_velocities(0)
				var vb := b.colony.creature_velocities(0)
				var nb := va.size() - _cores(a, 0)
				# The rings' beads untouched by the switch: compare those of rings that are
				# rings in both (their indices are the same before the first switched ring).
				for i: int in mini(nb, vb.size()):
					if i >= _first_bead_of_switched(b, switched):
						break
					vel_shift = maxf(vel_shift, va[i].distance_to(vb[i]))
			if switched_at >= 0 and (f == switched_at + 1 or f == switched_at + 5 or f == switched_at + 30):
				var worst := 0.0
				var ca := _centres(a, 0)
				var cb := _centres(b, 0)
				for cell: int in cells.size():
					if not switched.has(cell):
						worst = maxf(worst, ca[cell].distance_to(cb[cell]))
				shifts.append(worst)
		var h := a.colony.health()
		print("    %s cluster of 40: %d rings became cores at frame %d; switched cells' centres off their twins' %.3f px at the switch; other cells' %.3f / %.3f / %.3f px after 1 / 5 / 30 frames; bead velocities %.3f px/s; over 5 s %d to core, %d to ring; %d parted; core radius %.2f..%.2f, area %.2f..%.2f" % [
			"mixed" if mixed else "uniform", switched.size(), switched_at, own, shifts[0], shifts[1], shifts[2], vel_shift,
			to_core, to_ring, _parted.size(), h["core_min"], h["core_max"], h["area_min"], h["area_max"]])
		assert_gt(switched.size(), 0, "rings became cores")
		assert_lt(own, 0.25, "the switched cells do not jump")
		assert_lt(shifts[0], 0.25, "nor do their neighbours")
		assert_lt(shifts[2], 3.0, "and settle close to the twin's (a disc settles a little differently from a ring)")
		assert_eq(to_ring, 0, "no core switches back: no flicker")
		assert_eq(to_core, _cores(a, 0), "each cell switched once")
		assert_eq(_parted.size(), 0)
		_parted.clear()

## The first bead index of the twin's rings that were switched in the other (the beads
## before it belong to rings that come first in both).
static func _first_bead_of_switched(sim: GooColonySim, switched: Array[int]) -> int:
	var first := 1 << 30
	var bead := 0
	for cell: int in sim.colony.cell_count(0):
		var n := sim.colony.cell_points(0, cell).size()
		if sim.colony.cell_kind(0, cell) != 0:
			continue
		if switched.has(cell):
			first = mini(first, bead)
		bead += n
	return first

func test_a_core_whose_neighbour_leaves_comes_back_as_a_ring_with_its_walls() -> void:
	var sim := _sim({ "exposure": true, "auto_cores": true, "soft_cores": true, "core_anchors": true })
	var cells := _hex(2)
	var k := sim.add_creature(cells)
	_steps(sim, 90)
	assert_eq(_cores(sim, k), 7)
	# A rim cell next to an inner core: parted from all its neighbours and pulled away.
	var r := GooTuning.min_radius()
	var leaver := -1
	var core := -1
	for cell: int in cells.size():
		var at: Vector2 = cells[cell]["position"]
		if absf(at.y) < 1.0 and at.x > 3.0 * r:
			leaver = cell
		if absf(at.y) < 1.0 and at.x > r and at.x < 3.0 * r:
			core = cell
	var walls_before := sim.colony.cell_neighbours(k, core).size()
	for other: int in sim.colony.cell_neighbours(k, leaver):
		sim.part_cells(k, leaver, other)
	sim.colony.push_cell(k, leaver, Vector2(3000, 0))
	var frames := 0
	var jump := 0.0
	var speed := 0.0
	while sim.colony.cell_kind(k, core) == 1 and frames < 60:
		var at := sim.colony.cell_center(k, core)
		var v := _cell_velocity(sim, k, core)
		sim.step(DELTA)
		frames += 1
		if sim.colony.cell_kind(k, core) == 0:
			# Where the ring's centre is against where the core was heading.
			jump = sim.colony.cell_center(k, core).distance_to(at + v * DELTA)
			speed = v.length()
	sim.colony.push_cell(k, leaver, Vector2.ZERO)
	_steps(sim, 60)
	var walls := sim.colony.cell_neighbours(k, core)
	var parted_core := 0
	for e: Vector3i in _parted:
		if (e.y == core or e.z == core) and e.y != leaver and e.z != leaver:
			parted_core += 1
	print("    the leaver (cell %d) parted from %d neighbours; the core behind it (cell %d) became a ring after %d frames, its centre %.3f px off where it was heading (at %.1f px/s); its walls %d before, %s after; parted events of it %d; %d cores left; %s" % [
		leaver, _parted.size(), core, frames, jump, speed, walls_before, walls, parted_core, _cores(sim, k), _sound(sim.colony.health())])
	assert_eq(sim.colony.cell_kind(k, core), 0, "the exposed core is a ring again")
	assert_lt(frames, 30)
	assert_lt(jump, 0.3, "without a jump")
	assert_eq(parted_core, 0, "it kept its walls through the switch")
	assert_eq(walls.size(), walls_before - 1, "every wall but the leaver's")
	assert_eq(sim.colony.health()["inverted"], 0.0)

static func _cell_velocity(sim: GooColonySim, c: int, cell: int) -> Vector2:
	# Mean velocity of the cell's particles: beads of a ring, or the core.
	var points := sim.colony.creature_points(c)
	var vels := sim.colony.creature_velocities(c)
	var mine := sim.colony.cell_points(c, cell)
	var total := Vector2.ZERO
	for p: Vector2 in mine:
		var i := points.find(p)
		if i >= 0:
			total += vels[i]
	return total / maxi(mine.size(), 1)

static func _sound(h: Dictionary) -> String:
	return "area %.2f..%.2f, %d inside out, core radius %.2f..%.2f, %d not finite" % [
		h["area_min"], h["area_max"], int(h["inverted"]), h["core_min"], h["core_max"], int(h["not_finite"])]

# ---- Collisions ----

## Two clusters of 37 (their enclosed cells cores when auto_cores is on) thrown into each
## other at `speed` each: the worst ring area, rings inside out, the core radius, the
## contacts, the cross candidates and particles skipped a frame, and the most particles of
## one creature found inside the other's cells (a ring's polygon, or 0.8 of a core's radius).
func _throw(options: Dictionary, speed: float) -> Dictionary:
	var sim := GooColonySim.new(options)
	var a := sim.add_creature(_hex(3, Vector2(-120, 0)))
	var b := sim.add_creature(_hex(3, Vector2(120, 14)))
	_steps(sim, 30)
	sim.colony.set_creature_velocity(a, Vector2(speed, 0))
	sim.colony.set_creature_velocity(b, Vector2(-speed, 0))
	var worst := { "area_min": INF, "inverted": 0.0, "core_min": INF, "hits": 0, "pairs": 0, "skipped": 0, "frames": 0, "inside": 0 }
	for f: int in 90:
		sim.step(DELTA)
		var h := sim.colony.health()
		var s := sim.colony.stats()
		worst["area_min"] = minf(worst["area_min"], h["area_min"])
		worst["inverted"] = maxf(worst["inverted"], h["inverted"])
		worst["core_min"] = minf(worst["core_min"], h["core_min"])
		worst["hits"] = maxi(worst["hits"], s["cross_hits"])
		if s["cross_pairs"] > 0:
			worst["pairs"] += s["cross_pairs"]
			worst["skipped"] += s["cross_skipped"]
			worst["frames"] += 1
		if f % 3 == 0:
			worst["inside"] = maxi(worst["inside"], _inside(sim, a, b) + _inside(sim, b, a))
	worst["cores"] = _cores(sim, a)
	return worst

## How many particles of creature `b` lie inside creature `a`'s cells.
static func _inside(sim: GooColonySim, a: int, b: int) -> int:
	var n := 0
	var points := sim.colony.creature_points(b)
	for cell: int in sim.colony.cell_count(a):
		var poly := sim.colony.cell_points(a, cell)
		if poly.size() == 1:
			var reach: float = 0.8 * sim.colony.cell_radius(a, cell)
			for p: Vector2 in points:
				if p.distance_to(poly[0]) < reach:
					n += 1
			continue
		for p: Vector2 in points:
			if Geometry2D.is_point_in_polygon(p, poly):
				n += 1
	return n

static func _per_frame(w: Dictionary, key: String) -> float:
	return float(w[key]) / maxi(w["frames"], 1)

func test_compliant_cores_squash_the_outer_cells_less_and_nothing_goes_inside_out() -> void:
	# Before: rigid cores (milestones 0 and 1). A soft radius (the core shrinks under load)
	# and compliant contacts with its own creature (the preset's), every particle colliding.
	var base := { "exposure": true, "auto_cores": true, "core_anchors": true, "skip_enclosed": GooColony.SKIP_NONE }
	var rows := [["no cores at all", { "exposure": true, "skip_enclosed": GooColony.SKIP_NONE }], ["rigid cores", base],
		["soft radius", base.merged({ "soft_cores": true })], ["compliant contacts", base.merged({ "core_contact": 0.3 })]]
	for speed: float in [300.0, 600.0]:
		var results: Array = []
		for row: Array in rows:
			var w := _throw(row[1], speed)
			results.append(w)
			print("    %.0f px/s each, %s: %d cores each; outer ring area down to %.2f, %d inside out, core radius down to %.2f; %d contacts at the impact; %d particles inside the other" % [
				speed, row[0], w["cores"], w["area_min"], int(w["inverted"]), w["core_min"], w["hits"], w["inside"]])
		assert_gt(results[1]["hits"], 10, "they met")
		assert_gt(results[3]["area_min"], results[1]["area_min"] + 0.04, "compliant contacts squash the outer cells clearly less")
		assert_eq(results[3]["inverted"], 0.0, "nothing inside out")
		assert_eq(results[3]["inside"], 0, "nor through")

func test_skipping_enclosed_particles_in_collisions_saves_little_and_lets_the_other_through() -> void:
	# Two blobs of 127 cells pressed into each other at 250 px/s² for 3 s (the bench's push),
	# their enclosed cells cores. Skipping the enclosed in contacts between creatures is
	# measured, and is unsound: an outer ring is soft, and the other creature's bead that
	# dents it meets nothing behind it. The default, SKIP_NONE, lets nothing through.
	var rows := [["every particle collides (default)", GooColony.SKIP_NONE], ["cells with no exposed bead skipped", GooColony.SKIP_CELLS],
		["every enclosed bead skipped", GooColony.SKIP_BEADS]]
	var results: Array = []
	for row: Array in rows:
		var sim := GooColonySim.new(GooColonySim.EXPOSURE_OPTIONS.merged({ "skip_enclosed": row[1] }))
		var a := sim.add_creature(_hex(6, Vector2(-200, 0)))
		var b := sim.add_creature(_hex(6, Vector2(200, 30)))
		_steps(sim, 30)
		sim.colony.push_creature(a, Vector2(250, 0))
		sim.colony.push_creature(b, Vector2(-250, 0))
		var w := { "pairs": 0, "skipped": 0, "frames": 0, "inside": 0, "inverted": 0.0 }
		for f: int in 180:
			sim.step(DELTA)
			var s := sim.colony.stats()
			if s["cross_pairs"] > 0:
				w["pairs"] += s["cross_pairs"]
				w["skipped"] += s["cross_skipped"]
				w["frames"] += 1
			w["inverted"] = maxf(w["inverted"], sim.colony.health()["inverted"])
			if f % 30 == 29:
				w["inside"] = maxi(w["inside"], _inside(sim, a, b) + _inside(sim, b, a))
		results.append(w)
		print("    %s: %.0f cross candidates a frame, %.0f particles skipped a frame; %d rings inside out; %d particles inside the other" % [
			row[0], _per_frame(w, "pairs"), _per_frame(w, "skipped"), int(w["inverted"]), w["inside"]])
	assert_gt(results[0]["frames"], 60, "they were pressed together")
	assert_eq(results[0]["skipped"], 0)
	assert_eq(results[0]["inside"], 0, "by default nothing passes into the other")
	assert_eq(results[0]["inverted"], 0.0)
	assert_gt(results[1]["skipped"], 0, "the skip skips")

# ---- Drag ----

## FluidDrag.bead_forces() of the fluid game (src/fluid_drag.gd), ported as it is, with
## its GameSettings numbers given.
static func _game_law(points: PackedVector2Array, velocities: PackedVector2Array, water: Vector2, density: float,
		bead_mass: float, delta: float, c: Dictionary) -> PackedVector2Array:
	var n := points.size()
	var forces := PackedVector2Array()
	forces.resize(n)
	var relative := PackedVector2Array()
	relative.resize(n)
	for i: int in n:
		relative[i] = velocities[i] - water
	var share: float = 0.5 * density
	var p0: Vector2 = points[n - 1]
	var v0: Vector2 = relative[n - 1]
	for j: int in n:
		var p1: Vector2 = points[j]
		var v1: Vector2 = relative[j]
		var ex: float = p1.x - p0.x
		var ey: float = p1.y - p0.y
		var length: float = sqrt(ex * ex + ey * ey)
		if length > 0.000001:
			var tx: float = ex / length
			var ty: float = ey / length
			var vx: float = 0.5 * (v0.x + v1.x)
			var vy: float = 0.5 * (v0.y + v1.y)
			var vn: float = vy * tx - vx * ty
			var vt: float = vx * tx + vy * ty
			var fn: float = -(c["drag_normal"] * absf(vn) + c["drag_linear_normal"]) * vn
			var ft: float = -(c["drag_tangent"] * absf(vt) + c["drag_linear_tangent"]) * vt
			var scale: float = share * length
			var f := Vector2(-ty * fn + tx * ft, tx * fn + ty * ft) * scale
			var i: int = j - 1 if j > 0 else n - 1
			forces[i] += f
			forces[j] += f
		p0 = p1
		v0 = v1
	var limit_per_speed: float = c["drag_max_step"] * bead_mass / delta
	for i: int in n:
		var f: Vector2 = forces[i]
		var limit: float = limit_per_speed * relative[i].length()
		if f.length_squared() > limit * limit:
			forces[i] = f * (limit / f.length())
	return forces

func test_the_kernels_drag_matches_the_games_law_on_a_free_cell() -> void:
	var r := 20.0
	for linear: float in [60.0, 4000.0]:
		var options := GooColonySim.DRAG_OPTIONS.duplicate()
		options["drag_linear_normal"] = linear
		options["exposure"] = true
		var sim := GooColonySim.new(options)
		var k := sim.colony.add_creature(GooColonySim.cell_floats(Vector2.ZERO, r, false, Color.WHITE, 0.0))
		var water := Vector2(-40, 25)
		sim.colony.set_water(k, water)
		# Wobble it so its beads move differently: a throw and a push on its cell.
		sim.colony.set_creature_velocity(k, Vector2(300, -120))
		sim.colony.push_cell(k, 0, Vector2(0, 4000))
		_steps(sim, 4)
		sim.colony.push_cell(k, 0, Vector2.ZERO)
		var points := sim.colony.creature_points(k)
		var velocities := sim.colony.creature_velocities(k)
		sim.step(DELTA)
		var got := sim.colony.creature_drag_forces(k)
		var t := GooTuning.tuning(r)
		var mass: float = t["bead_mass"] * t["bead_count"]
		var density: float = 1.0 * mass / (PI * r * r)
		var want := _game_law(points, velocities, water, density, t["bead_mass"], DELTA, options)
		var worst := 0.0
		var biggest := 0.0
		var clamped := 0
		for i: int in want.size():
			worst = maxf(worst, got[i].distance_to(want[i]))
			biggest = maxf(biggest, want[i].length())
			var limit: float = 0.5 * t["bead_mass"] / DELTA * (velocities[i] - water).length()
			if want[i].length() > limit * 0.999:
				clamped += 1
		print("    linear normal %.0f: %d beads, largest force %.3f, worst difference from the game's law %.7f (%.7f of it), %d beads clamped" % [
			linear, want.size(), biggest, worst, worst / biggest, clamped])
		assert_gt(biggest, 0.0)
		assert_lt(worst, 1e-4 * biggest, "the kernel's drag is the game's law")
		if linear > 1000.0:
			assert_gt(clamped, 0, "the clamp is exercised")

func test_an_enclosed_cell_gets_no_drag_and_a_clusters_drag_follows_its_outline() -> void:
	var rows: Array = []
	for rings: int in [1, 2, 3]:
		var options := GooColonySim.DRAG_OPTIONS.duplicate()
		options["exposure"] = true
		var sim := GooColonySim.new(options)
		var cells := _hex(rings)
		var k := sim.add_creature(cells)
		_steps(sim, 20)
		sim.colony.set_creature_velocity(k, Vector2(100, 0))
		sim.step(DELTA)
		var forces := sim.colony.creature_drag_forces(k)
		var total := Vector2.ZERO
		for f: Vector2 in forces:
			total += f
		# The middle cell (a ring here: no auto cores) gets none.
		var points := sim.colony.creature_points(k)
		var middle := _middle(cells)
		var mine := sim.colony.cell_points(k, middle)
		var middle_force := 0.0
		for p: Vector2 in mine:
			middle_force += forces[points.find(p)].length()
		var outline := sim.colony.creature_outline(k)
		var perimeter := 0.0
		for i: int in outline.size():
			perimeter += outline[i].distance_to(outline[(i + 1) % outline.size()])
		rows.append([cells.size(), -total.x, perimeter])
		print("    hex of %d cells at 100 px/s: drag %.1f, outline %.0f px: %.4f per px of outline, %.3f per cell; the middle cell's drag %.6f" % [
			cells.size(), -total.x, perimeter, -total.x / perimeter, -total.x / cells.size(), middle_force])
		assert_eq(middle_force, 0.0, "an enclosed cell gets no drag")
	var per_outline_spread: float = (rows[2][1] / rows[2][2]) / (rows[0][1] / rows[0][2])
	var per_cell_spread: float = (rows[2][1] / rows[2][0]) / (rows[0][1] / rows[0][0])
	print("    37 cells against 7: drag per px of outline × %.2f, drag per cell × %.2f" % [per_outline_spread, per_cell_spread])
	assert_almost_eq(per_outline_spread, 1.0, 0.25, "the drag follows the outline")
	assert_lt(per_cell_spread, 0.6, "not the number of cells")

func test_a_thrown_cell_stops_like_the_games_bodies() -> void:
	# The fluid game's test: a 30 px body at unit 0.5 thrown at 400 px/s in still water, no
	# damping of its own, the ring's internal damping × 0.25; it stops (speed under 2 % of
	# the throw's) within 2.5 s after 60 to 400 px.
	var sim := GooColonySim.new(GooColonySim.DRAG_OPTIONS)
	var floats := GooColonySim.cell_floats(Vector2.ZERO, 30.0, false, Color.WHITE, 0.0)
	floats[14] *= 0.25
	var k := sim.colony.add_creature(floats)
	sim.step(DELTA)
	sim.colony.set_creature_velocity(k, Vector2(400, 0))
	var start := sim.colony.creature_center(k)
	var stop_time := INF
	var rise := 0.0
	var last := 400.0
	for f: int in 180:
		sim.step(DELTA)
		var speed := sim.colony.creature_velocity(k).length()
		rise = maxf(rise, speed - last)
		last = speed
		if stop_time == INF and speed < 0.02 * 400.0:
			stop_time = (f + 1) * DELTA
	var distance := sim.colony.creature_center(k).distance_to(start)
	print("    a 30 px cell thrown at 400 px/s: %.0f px, stopped after %.2f s, largest rise %.2f px/s (the game's bodies: 60-400 px within 2.5 s)" % [distance, stop_time, rise])
	assert_lt(stop_time, 2.5)
	assert_gt(distance, 60.0)
	assert_lt(distance, 400.0)
	assert_lt(rise, 2.0)

# ---- Core anchors ----

func test_a_wall_anchored_on_a_core_turns_it() -> void:
	var results: Array = []
	for anchors: bool in [false, true]:
		var sim := GooColonySim.new({ "core_anchors": anchors })
		var r := GooTuning.min_radius()
		var floats := PackedFloat32Array()
		floats.append_array(GooColonySim.cell_floats(Vector2.ZERO, r, true))
		floats.append_array(GooColonySim.cell_floats(Vector2(0, -2 * r), r))
		var k := sim.colony.add_creature(floats)
		_steps(sim, 20)
		var turn0 := sim.colony.cell_rotation(k, 0)
		var line0 := (sim.colony.cell_center(k, 1) - sim.colony.cell_center(k, 0)).angle()
		# The ring pushed round the core, a little toward it.
		for f: int in 42:
			var out := (sim.colony.cell_center(k, 1) - sim.colony.cell_center(k, 0)).normalized()
			sim.colony.push_cell(k, 1, out.orthogonal() * -500.0 - out * 150.0)
			sim.colony.push_cell(k, 0, -(out.orthogonal() * -500.0 - out * 150.0))
			sim.step(DELTA)
		var turn := sim.colony.cell_rotation(k, 0) - turn0
		var line := wrapf((sim.colony.cell_center(k, 1) - sim.colony.cell_center(k, 0)).angle() - line0, -PI, PI)
		results.append(absf(turn))
		print("    core anchors %s: the ring went %.2f rad round the core, the core turned %.2f rad; still stuck: %s" % [
			anchors, line, turn, sim.colony.cell_neighbours(k, 1)])
		assert_eq(sim.colony.cell_neighbours(k, 1), PackedInt32Array([0]))
	assert_lt(results[0], 0.01, "a sticky wall cannot turn the core")
	assert_gt(results[1], 0.2, "an anchored one does")

# ---- Determinism ----

func _game(threads: int) -> GooColonySim:
	var options := GooColonySim.EXPOSURE_OPTIONS.duplicate()
	options.merge(GooColonySim.DRAG_OPTIONS)
	options["threads"] = threads
	var sim := GooColonySim.new(options)
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261112
	for c: int in 6:
		var cells := _pack(24, 11 + c, c % 2 == 0)
		var list: Array = []
		var angle := rng.randf() * TAU
		for cell: Dictionary in cells:
			list.append({ "position": Vector2((c % 3) * 260.0, (c / 3) * 260.0) + (cell["position"] as Vector2).rotated(angle), "radius": cell["radius"] })
		var k := sim.add_creature(list)
		sim.colony.push_creature(k, Vector2.from_angle(rng.randf() * TAU) * 900.0)
		var water := PackedVector2Array()
		for i: int in list.size():
			water.append(Vector2.from_angle(i * 0.3 + c) * 30.0)
		sim.colony.set_cell_water(k, water)
	return sim

func test_threaded_step_equals_serial_with_exposure_cores_and_drag() -> void:
	var serial := _game(1)
	var threaded := _game(4)
	var events_a := PackedInt64Array()
	var events_b := PackedInt64Array()
	var switches := 0
	var runs := 0
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
		var s := serial.colony.stats()
		switches += s["to_core"] + s["to_ring"]
		runs += s["exposure_runs"]
	print("    240 frames, 6 clusters with exposure, auto, compliant and anchored cores and per-cell water drag: %d switches, %d exposure passes, %d events" % [switches, runs, events_a.size() / 4])
	assert_gt(switches, 0, "cells switched along the way")
	assert_eq(events_a, events_b, "the same events in the same order")
	for c: int in serial.colony.creature_count():
		assert_eq(serial.colony.creature_points(c), threaded.colony.creature_points(c), "creature %d's particles are bit for bit the serial ones" % c)
		assert_eq(serial.colony.creature_velocities(c), threaded.colony.creature_velocities(c))
		assert_eq(serial.colony.creature_exposure(c), threaded.colony.creature_exposure(c))
		assert_eq(serial.colony.creature_sticks(c), threaded.colony.creature_sticks(c))
	var h := serial.colony.health()
	assert_eq(h["not_finite"], 0.0)
	assert_eq(h["inverted"], 0.0)
