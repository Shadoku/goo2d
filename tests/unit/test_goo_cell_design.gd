extends TestCase
## GooCellDesign and GooCellType (docs/cells.md): the builders, cells added and removed,
## the derived links, the problems a design reports, a .tres round trip with its types
## palette, a type's kernel parameters and its join layers.

const PATH := "user://test_goo_cell_design.tres"

func after_each() -> void:
	GooTuning.unit = 1.0
	if FileAccess.file_exists(PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(PATH))

func test_builders_and_links() -> void:
	var blob := GooCellDesign.hex_blob(2, 10.0)
	assert_eq(blob.cell_count(), 19)
	assert_eq(blob.links().size() / 2, 42)
	assert_lt(blob.centroid().length(), 1e-4)
	var worm := GooCellDesign.hex_worm(24, 5, 14.0)
	assert_eq(worm.cell_count(), 120)
	assert_almost_eq(worm.length(), 24 * 28.0 + 14.0, 0.01)
	assert_eq(worm.problems(), PackedStringArray())

func test_add_and_remove_cells() -> void:
	var d := GooCellDesign.new()
	assert_eq(d.add_cell(Vector2(0, 0), 10.0, 0, 3, 0.5), 0)
	assert_eq(d.add_cell(Vector2(20, 0), 10.0), 1)
	assert_eq(d.cell_count(), 2)
	assert_eq(d.group_of(0), 3)
	assert_almost_eq(d.angle_of(0), 0.5)
	assert_eq(d.links(), PackedInt32Array([0, 1]))
	d.remove_cell(0)
	assert_eq(d.cell_count(), 1)
	assert_eq(d.group_of(0), 0)
	d.clear()
	assert_eq(d.cell_count(), 0)

func test_a_types_radius_factor_changes_the_links() -> void:
	var big := GooCellType.new()
	big.radius_factor = 1.5
	var d := GooCellDesign.new()
	d.types = [null, big]
	d.add_cell(Vector2.ZERO, 10.0, 1)
	d.add_cell(Vector2(24, 0), 10.0, 0)
	assert_eq(d.radius_of(0), 15.0)
	assert_eq(d.radius_of(1), 10.0)
	assert_eq(d.type_of(0), big)
	assert_null(d.type_of(1))
	assert_eq(d.links().size(), 2, "15 + 10 > 24: linked")

func test_problems() -> void:
	var d := GooCellDesign.new()
	d.add_cell(Vector2.ZERO, 10.0)
	d.add_cell(Vector2(5, 0), 10.0)
	d.add_cell(Vector2(200, 0), 10.0)
	var p := d.problems()
	assert_eq(p.size(), 2, str(p))
	assert_true(p[0].contains("overlap"))
	assert_true(p[1].contains("cell 2 links to nothing"))
	d.radii.resize(2)
	assert_true(d.problems()[0].contains("arrays of different lengths"))

func test_round_trip() -> void:
	var t := GooCellType.new()
	t.name = &"thruster"
	t.color = Color.ORANGE
	t.body = GooCellType.Body.LINKS
	t.behaviours = {"force": 300.0}
	var d := GooCellDesign.hex_blob(1, 12.0)
	d.types = [null, t]
	d.cell_types[3] = 1
	d.groups[3] = 2
	d.angles[3] = 1.25
	d.forward = Vector2.UP
	assert_eq(ResourceSaver.save(d, PATH), OK)
	var back := ResourceLoader.load(PATH, "", ResourceLoader.CACHE_MODE_IGNORE) as GooCellDesign
	assert_not_null(back)
	assert_eq(back.positions, d.positions)
	assert_eq(back.radii, d.radii)
	assert_eq(back.cell_types, d.cell_types)
	assert_eq(back.groups, d.groups)
	assert_eq(back.angles, d.angles)
	assert_eq(back.forward, Vector2.UP)
	assert_eq(back.types.size(), 2)
	assert_null(back.types[0])
	assert_eq(back.types[1].name, &"thruster")
	assert_eq(back.types[1].body, GooCellType.Body.LINKS)
	assert_eq(back.types[1].behaviours["force"], 300.0)
	assert_eq(back.links(), d.links())

func test_type_kernel_params_and_joins() -> void:
	GooTuning.unit = 0.5
	var t := GooCellType.new()
	t.body = GooCellType.Body.SHAPE
	t.contact_pad = 4.0
	var p := t.kernel_params()
	assert_eq(p["body"], GooCells.BEND_SHAPE)
	assert_almost_eq(p["pad"], 2.0)
	assert_eq(GooCellType.new().kernel_params()["body"], GooCells.BODY_DEFAULT)
	var a := GooCellType.new()
	var b := GooCellType.new()
	b.join_layer = 2
	b.join_mask = 2
	assert_true(a.joins(a))
	assert_false(a.joins(b), "b only joins layer 2, which a is not in")
	a.join_layer = 3
	assert_true(a.joins(b))
