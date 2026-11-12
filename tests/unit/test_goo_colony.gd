extends TestCase
## GooColony, the colony spike's kernel (addons/goo2d/native/src/colony.rs,
## docs/colony-spike.md): a core cell collides with beads and other cores and is
## pushed by them; bonds hold a creature together; a threaded step gives the same
## bits as a serial one; promotion and demotion swap a core and a ring without a
## pop; and the batch-drawing arrays have the sizes and values the bench's
## RenderingServer calls rely on.

const DELTA: float = 1.0 / 60.0

func before_each() -> void:
	GooTuning.unit = 0.5

func after_each() -> void:
	GooTuning.unit = 1.0

# A cell of radius `r` at `at` with GooTuning's numbers for its size (12 beads for
# the smallest), as GooColony.add_creature() takes it.
static func _cell(at: Vector2, r: float, core: bool) -> PackedFloat32Array:
	var t := GooTuning.tuning(r)
	return PackedFloat32Array([at.x, at.y, r, 1.0 if core else 0.0, t["bead_count"], t["ring_radius"],
		t["bead_radius"], t["bead_mass"], t["pressure_k"], t["shape_match_k"], t["skin_stiffness"],
		t["skin_damping"], t["bending_stiffness"], t["bending_damping"], t["internal_damp"], 1.0,
		t["target_area"], 0.4, 0.7, 0.3])

# A creature of `columns` × `rows` touching cells of the smallest size, the inner ones
# cores when `cores`, its first cell at `origin`.
static func _block(origin: Vector2, columns: int, rows: int, cores: bool) -> PackedFloat32Array:
	var r := GooTuning.min_radius()
	var floats := PackedFloat32Array()
	for i: int in columns:
		for j: int in rows:
			var inner := i > 0 and j > 0 and i < columns - 1 and j < rows - 1
			floats.append_array(_cell(origin + Vector2(i * 2.0 * r, j * 2.0 * r), r, cores and inner))
	return floats

func _colony(threads: int) -> GooColony:
	var colony := GooColony.new()
	colony.set_options({ "threads": threads })
	for c: int in 4:
		var origin := Vector2(c * 190.0, (c % 2) * 20.0)
		var k := colony.add_creature(_block(origin, 5, 4, true))
		colony.build_bonds(k, 1.5)
		colony.push_creature(k, Vector2(300.0 if c % 2 == 0 else -300.0, 0.0))
	return colony

func test_class_is_registered() -> void:
	assert_true(ClassDB.class_exists("GooColony"),
		"GooColony is not registered: build the library with bash tools/build_native.sh")
	assert_eq(GooColony.CELL_STRIDE, 20)

func test_core_collides_with_a_core_and_pushes_it() -> void:
	var r := GooTuning.min_radius()
	var colony := GooColony.new()
	var a := colony.add_creature(_cell(Vector2.ZERO, r, true))
	var b := colony.add_creature(_cell(Vector2(3.0 * r, 0.0), r, true))
	colony.push_creature(a, Vector2(600.0, 0.0))
	var closest := INF
	for f: int in 60:
		colony.step(DELTA)
		closest = minf(closest, colony.creature_center(a).distance_to(colony.creature_center(b)))
	print("    closest centres %.2f px for two %.0f px cores; b moved %.1f px" % [closest, r,
		colony.creature_center(b).x - 3.0 * r])
	assert_gt(colony.creature_center(b).x, 3.0 * r + 10.0, "the struck core is pushed along")
	assert_gt(closest, 2.0 * r - 0.5, "cores do not pass into each other")

func test_core_collides_with_a_ring_and_pushes_it() -> void:
	var r := GooTuning.min_radius()
	var colony := GooColony.new()
	var a := colony.add_creature(_cell(Vector2.ZERO, r, true))
	var b := colony.add_creature(_cell(Vector2(3.0 * r, 0.0), r, false))
	colony.push_creature(a, Vector2(600.0, 0.0))
	var bead_r: float = GooTuning.tuning(r)["bead_radius"]
	var deepest := 0.0
	for f: int in 60:
		colony.step(DELTA)
		var core := colony.creature_points(a)[0]
		for p: Vector2 in colony.creature_points(b):
			deepest = maxf(deepest, r + bead_r - core.distance_to(p))
	print("    deepest bead overlap into the core %.2f px" % deepest)
	assert_gt(colony.creature_center(b).x, 3.0 * r + 10.0, "the ring is pushed along")
	assert_lt(deepest, 1.0, "the ring's beads stay out of the core")
	var info := colony.creature_info(b)
	assert_eq(info[0], 12, "a 12-bead ring")
	assert_eq(colony.creature_info(a)[1], 1, "a core is one particle")

func test_bonds_hold_a_pushed_creature_together() -> void:
	var colony := GooColony.new()
	var k := colony.add_creature(_block(Vector2.ZERO, 5, 5, true))
	var bonds := colony.build_bonds(k, 1.5)
	assert_gt(bonds, 25 * 2, "every cell bonded to its neighbours")
	colony.push_creature(k, Vector2(400.0, 150.0))
	var first := colony.cell_center(k, 0)
	var last := colony.cell_center(k, 24)
	var span := first.distance_to(last)
	for f: int in 90:
		colony.step(DELTA)
	var health := colony.health()
	print("    after 1.5 s pushed: span %.1f -> %.1f px, health %s" % [span,
		colony.cell_center(k, 0).distance_to(colony.cell_center(k, 24)), health])
	assert_almost_eq(colony.cell_center(k, 0).distance_to(colony.cell_center(k, 24)), span, 4.0,
		"the creature keeps its shape")
	assert_gt(colony.creature_center(k).x, 100.0, "and moves")
	assert_eq(health["inverted"], 0.0)
	assert_lt(health["stretch"], 0.2)

func test_threaded_step_equals_serial_step() -> void:
	var serial := _colony(1)
	var threaded := _colony(4)
	var met := 0
	for f: int in 90:
		serial.step(DELTA)
		threaded.step(DELTA)
		met = maxi(met, serial.stats()["cross_hits"])
	assert_gt(met, 0, "the creatures ran into each other")
	for c: int in serial.creature_count():
		var a := serial.creature_points(c)
		var b := threaded.creature_points(c)
		assert_eq(a.size(), b.size())
		var same := true
		for i: int in a.size():
			if a[i] != b[i]:
				same = false
				break
		assert_true(same, "creature %d's particles are bit for bit the serial ones" % c)

func test_mesh_arrays_sizes_and_values() -> void:
	var r := GooTuning.min_radius()
	var colony := GooColony.new()
	var floats := PackedFloat32Array()
	floats.append_array(_cell(Vector2(0, 0), r, false))
	floats.append_array(_cell(Vector2(2.0 * r, 0), r, false))
	floats.append_array(_cell(Vector2(4.0 * r, 0), r, false))
	floats.append_array(_cell(Vector2(r, 1.732 * r), r, true))
	floats.append_array(_cell(Vector2(3.0 * r, 1.732 * r), r, true))
	var k := colony.add_creature(floats)
	colony.build_bonds(k, 1.5)
	var sides := GooColony.CORE_SIDES
	var expected := 3 * (12 + 1) + 2 * (sides + 1)
	assert_eq(colony.vertex_count(k, false), expected)
	assert_eq(colony.vertex_count(k, true), 3 * 13, "without the cores")
	var data := colony.mesh_arrays(k, false)
	var verts: PackedVector2Array = data[0]
	var colors: PackedColorArray = data[1]
	var uvs: PackedVector2Array = data[2]
	var custom: PackedFloat32Array = data[3]
	var indices: PackedInt32Array = data[4]
	assert_eq(verts.size(), expected)
	assert_eq(colors.size(), expected)
	assert_eq(uvs.size(), expected)
	assert_eq(custom.size(), 4 * expected)
	assert_eq(indices.size(), 3 * (3 * 12 + 2 * sides), "one fan per cell")
	# The first ring's fan: its centre is its beads' centroid, its rim a bead radius out.
	var points := colony.creature_points(k)
	var centre := Vector2.ZERO
	for i: int in 12:
		centre += points[i]
	centre /= 12.0
	assert_almost_eq(verts[0].distance_to(centre), 0.0, 1e-3)
	assert_almost_eq(verts[1].distance_to(centre), r, 0.5, "the outline at the cell's radius")
	assert_almost_eq(uvs[1].length(), 1.0, 0.05, "a rim UV is about 1 long")
	assert_eq(uvs[0], Vector2.ZERO)
	assert_almost_eq(custom[0], r, 1e-4, "custom0.x is the cell's radius")
	var rim := 3 * 13 + 1
	assert_almost_eq(uvs[rim].length(), 1.0, 1e-5, "a core's rim UV is 1 long")
	assert_almost_eq(verts[rim].distance_to(points[36]), r, 1e-3, "a core's rim at its radius")
	# Bonded beads are enclosed (weight 0); the outer ones exposed (1).
	var exposed := 0
	var enclosed := 0
	for v: int in 3 * 13:
		if v % 13 == 0:
			continue
		if custom[v * 4 + 1] > 0.5:
			exposed += 1
		else:
			enclosed += 1
	assert_gt(exposed, 0)
	assert_gt(enclosed, 0)
	# The vertex buffer bytes are the vertices as little-endian float pairs.
	var bytes := colony.mesh_positions(k, false)
	assert_eq(bytes.size(), expected * 8)
	assert_almost_eq(bytes.decode_float(0), verts[0].x, 1e-4)
	assert_almost_eq(bytes.decode_float(4), verts[0].y, 1e-4)
	assert_eq(colony.core_instances(k).size(), 2 * GooColony.INSTANCE_FLOATS)

func test_promote_and_demote_swap_a_core_and_a_ring_without_a_pop() -> void:
	var colony := GooColony.new()
	var k := colony.add_creature(_block(Vector2.ZERO, 5, 5, true))
	colony.build_bonds(k, 1.5)
	for f: int in 30:
		colony.step(DELTA)
	var middle := 12
	assert_eq(colony.cell_kind(k, middle), 1, "the middle cell is a core")
	var before := colony.creature_info(k)
	var at := colony.cell_center(k, middle)
	var overlap := colony.promote(k, middle, 1.5)
	var after := colony.creature_info(k)
	print("    promoted: overlap %.3f px, cell moved %.3f px" % [overlap, colony.cell_center(k, middle).distance_to(at)])
	assert_eq(colony.cell_kind(k, middle), 0)
	assert_eq(after[0], before[0] + 12, "twelve beads more")
	assert_eq(after[1], before[1] - 1, "one core less")
	assert_lt(overlap, 0.5, "the new ring clears its neighbours")
	assert_lt(colony.cell_center(k, middle).distance_to(at), 1.0, "and sits where the core was")
	for f: int in 30:
		colony.step(DELTA)
	assert_eq(colony.health()["inverted"], 0.0)
	assert_gt(colony.demote(k, middle, 1.5), -0.5)
	assert_eq(colony.cell_kind(k, middle), 1)
	assert_eq(colony.creature_info(k)[0], before[0])
	assert_eq(colony.promote(k, 0, 1.5), -1.0, "an outer ring is not a core")
