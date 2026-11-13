extends TestCase
## The goo skin of GooCellWorld2D's creatures (goo_honeycomb.gdshader, docs/cells.md
## "Drawing") at unit 0.5, stepped by hand: the default material and its preset, the look
## table (each type's colour, wall colour and look row) reaching the material and following
## update_type(), the cell table, the mesh's attributes (three cells a triangle, the
## outline distance in px), the FLAT mesh and its shader kept, and a custom material.

const DELTA: float = 1.0 / 60.0
const R: float = 14.0

func before_each() -> void:
	GooTuning.unit = 0.5

func after_each() -> void:
	GooTuning.unit = 1.0

func _world() -> GooCellWorld2D:
	var w := GooCellWorld2D.new()
	w.gravity_scale = 0.0
	add_child(w)
	w.set_physics_process(false)
	return w

func _worm(w: GooCellWorld2D, spine: GooCellType) -> GooCellCreature:
	var d := GooCellDesign.hex_worm(10, 3, R)
	d.types = [null, spine]
	for i: int in d.cell_count():
		if absf(d.positions[i].y) < 1.0:
			d.cell_types[i] = 1
	return w.spawn(d, Transform2D(0, Vector2(300, 300)))

func test_the_default_material_and_its_preset() -> void:
	var w := _world()
	var m := w.current_skin_material() as ShaderMaterial
	assert_not_null(m)
	assert_eq(m.shader.resource_path, GooCellLook.SHADER_PATH)
	assert_eq(w.skin_preset, GooCellLook.Preset.MEMBRANE)
	var membrane: Dictionary = GooCellLook.PRESETS[GooCellLook.Preset.MEMBRANE]
	assert_almost_eq(float(m.get_shader_parameter("wall_strength")), float(membrane["wall_strength"]), 1e-6)
	assert_almost_eq(float(m.get_shader_parameter("cell_light")), 0.2, 1e-6)
	w.skin_preset = GooCellLook.Preset.CELLULAR
	var cellular: Dictionary = GooCellLook.PRESETS[GooCellLook.Preset.CELLULAR]
	assert_almost_eq(float(m.get_shader_parameter("cell_light")), float(cellular["cell_light"]), 1e-6)
	# The shader's own defaults are MEMBRANE's (a custom material of it gets the look).
	var faint: Dictionary = GooCellLook.PRESETS[GooCellLook.Preset.FAINT]
	var code: String = m.shader.code
	for key: String in membrane:
		var re := RegEx.create_from_string("uniform float " + key + "\\b[^=;]*= ([0-9.]+);")
		var found := re.search(code)
		assert_not_null(found, key)
		if found != null:
			assert_almost_eq(found.get_string(1).to_float(), float(membrane[key]), 1e-6)
	# Every preset names the same uniforms, each one the shader's.
	var names: Array = []
	for u: Dictionary in m.shader.get_shader_uniform_list():
		names.append(String(u["name"]))
	for p: int in GooCellLook.PRESETS:
		assert_eq((GooCellLook.PRESETS[p] as Dictionary).size(), faint.size())
		for key: String in GooCellLook.PRESETS[p]:
			assert_has(names, key)
	assert_eq(GooCellLook.preset_named("Membrane"), GooCellLook.Preset.MEMBRANE)
	assert_eq(GooCellLook.preset_named("b"), GooCellLook.Preset.CELLULAR)
	assert_eq(GooCellLook.preset_named("nope"), -1)

func test_the_look_table_reaches_the_material() -> void:
	var w := _world()
	var spine := GooCellType.new()
	spine.color = Color.CORNFLOWER_BLUE
	spine.wall_color = Color(0.1, 0.2, 0.3, 0.5)
	spine.wall_strength = 2.0
	spine.dome = 0.5
	spine.gloss = 1.5
	spine.opacity = 0.75
	var cr := _worm(w, spine)
	w.step(DELTA)
	var slot := w.type_slot(spine)
	var table := w.look_table()
	var colours: PackedColorArray = table["type_color"]
	var walls: PackedColorArray = table["type_wall"]
	var looks: PackedVector4Array = table["type_look"]
	assert_eq(colours.size(), 16)
	assert_eq(colours[slot], Color.CORNFLOWER_BLUE)
	assert_eq(colours[0], w.default_type.color)
	assert_eq(walls[slot], Color(0.1, 0.2, 0.3, 0.5))
	assert_eq(looks[slot], Vector4(2.0, 0.5, 1.5, 0.75))
	assert_eq(looks[0], Vector4(1, 1, 1, 1))
	# An edited type reaches it through update_type().
	spine.color = Color.ORANGE
	spine.gloss = 0.25
	w.update_type(spine)
	table = w.look_table()
	assert_eq((table["type_color"] as PackedColorArray)[slot], Color.ORANGE)
	assert_almost_eq((table["type_look"] as PackedVector4Array)[slot].z, 0.25, 1e-6)
	# The cell table: two RGBA float texels a cell, the cells' centres in it.
	var tex := w.cell_table()
	assert_not_null(tex)
	assert_eq((w.current_skin_material() as ShaderMaterial).get_shader_parameter("cell_table"), tex)
	var img := tex.get_image()
	assert_eq(img.get_format(), Image.FORMAT_RGBAF)
	assert_eq(img.get_width(), 2 * GooCellWorld2D.TABLE_COLUMNS)
	var p := cr.positions()
	var t := cr.type_slots()
	for i: int in [0, 7, p.size() - 1]:
		var a := img.get_pixel(2 * i, 0)
		var b := img.get_pixel(2 * i + 1, 0)
		assert_lt(Vector2(a.r, a.g).distance_to(p[i]), 0.01)
		assert_almost_eq(a.b, cr.radii()[i], 1e-3)
		assert_eq(int(b.r), t[i])
		assert_true(b.g >= 0.0 and b.g < 1.0, "a seed in 0..1")
	assert_almost_eq(float((w.current_skin_material() as ShaderMaterial).get_shader_parameter("length_unit")), 0.5, 1e-6)

func test_the_goo_mesh() -> void:
	var w := _world()
	var spine := GooCellType.new()
	var cr := _worm(w, spine)
	w.step(DELTA)
	var m: Array = w.cells().meshes_all_goo(false)
	var points: PackedVector2Array = m[0]
	var attrs: PackedColorArray = m[1]
	var outward: PackedVector2Array = m[2]
	var indices: PackedInt32Array = m[5]
	var n := cr.cell_count()
	assert_eq(int(m[7]), n)
	assert_eq((m[6] as PackedFloat32Array).size(), 8 * n)
	assert_eq(w.draw_stats["vertices"], points.size())
	var on_skin := 0
	var p := cr.positions()
	var worst := -INF
	for k: int in range(0, indices.size(), 3):
		var a := attrs[indices[k]]
		for j: int in 3:
			var o := attrs[indices[k + j]]
			assert_true(o.r == a.r and o.g == a.g and o.b == a.b, "one triple a triangle")
		var third := -a.b - 1.0 if a.b < 0.0 else a.b
		for x: float in [a.r, a.g, third]:
			assert_true(x >= 0.0 and x < n and x == floorf(x), "an index into the table")
	for v: int in points.size():
		if attrs[v].a == 0.0:
			on_skin += 1
			assert_almost_eq(outward[v].length(), 1.0, 1e-3)
		var best := INF
		for i: int in n:
			best = minf(best, points[v].distance_to(p[i]) - cr.radii()[i])
		worst = maxf(worst, best)
	print("    a 10 × 3 worm's goo skin: %d triangles over %d vertices (%d on the skin), every vertex within %.2f px of a cell's disc" % [indices.size() / 3, points.size(), on_skin, maxf(worst, 0.0)])
	assert_gt(on_skin, 0)
	assert_lt(worst, 0.43 * R)

func test_the_flat_mesh_and_a_custom_material() -> void:
	var w := _world()
	w.skin_mesh = GooCellWorld2D.SkinMesh.FLAT
	assert_eq((w.current_skin_material() as ShaderMaterial).shader.resource_path, "res://addons/goo2d/goo_cells.gdshader")
	var spine := GooCellType.new()
	spine.color = Color.CORNFLOWER_BLUE
	_worm(w, spine)
	w.step(DELTA)
	assert_null(w.cell_table())
	var flat: Array = w.cells().meshes_all(false)
	assert_eq(w.draw_stats["vertices"], (flat[0] as PackedVector2Array).size())
	var custom := ShaderMaterial.new()
	custom.shader = load(GooCellLook.SHADER_PATH)
	w.skin_mesh = GooCellWorld2D.SkinMesh.GOO
	w.skin_material = custom
	assert_eq(w.current_skin_material(), custom)
	w.step(DELTA)
	assert_eq(custom.get_shader_parameter("cell_table"), w.cell_table())
	assert_eq((w.look_table()["type_color"] as PackedColorArray)[w.type_slot(spine)], Color.CORNFLOWER_BLUE)
	# The preset leaves a game's own material alone.
	custom.set_shader_parameter("wall_strength", 0.9)
	w.skin_preset = GooCellLook.Preset.FAINT
	assert_almost_eq(float(custom.get_shader_parameter("wall_strength")), 0.9, 1e-6)
