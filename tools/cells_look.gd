extends SceneTree
## Renders the goo skin of creatures made of cells (goo_honeycomb.gdshader) for one or
## more GooCellLook presets, so a look can be compared and tuned in one command. Under
## xvfb-run:
##   xvfb-run -a -s "-screen 0 1920x1080x24" godot --path . --rendering-driver opengl3
##     --audio-driver Dummy --fixed-fps 60 -s tools/cells_look.gd -- OUT_DIR
##     [--preset=faint|cellular|membrane|all] [--set=uniform=value,uniform=value]
##     [--scene=example|strip|swim|all] [--tag=NAME]
## Writes <TAG>_<scene>.png per preset (TAG the preset's letter, A faint, B cellular,
## C membrane, or --tag): example (examples/cells after 3 s of motion), strip_14px and
## strip_7px (on dark blue water with a pattern: a ring body of goo.gdshader with its
## bubbles still, a 37-cell blob with a patch of a second type and a 24 × 5 worm with a
## spine row bent mid-turn; 14 px cells at GooTuning.unit 1, 7 px at 0.5; the 7 px one
## cropped to what it shows), zoom_border_<size> and zoom_outline_<size> (4× crops,
## nearest, of the worm's spine border and its outline at the bend), zoom_patch_<size>
## (the blob's patch), and swim_a / swim_b (a swimming worm 6 frames apart, cropped about
## the same cell and turned with the worm: its material should not move). --set overrides
## uniforms on top of the preset (numbers, or x;y;z for a vec3), so feedback is numbers.

const LAYOUT := Vector2i(1920, 1080)
const WATER_TOP := Color(0.05, 0.13, 0.24)
const WATER_BOTTOM := Color(0.02, 0.06, 0.14)
const WATER_DOTS := Color(0.32, 0.52, 0.72)
const WATER_LINES := Color(0.16, 0.30, 0.46)
const BODY := Color(0.36, 0.78, 0.5)
const SPINE := Color(0.35, 0.6, 0.95)
const PATCH := Color(0.98, 0.58, 0.28)

var out_dir := "."
var presets: Array[int] = []
var overrides: Dictionary = {}
var scenes: Array[String] = []
var tag := ""

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var preset_arg := "all"
	var scene_arg := "all"
	for a: String in args:
		if a.begins_with("--preset="):
			preset_arg = a.get_slice("=", 1)
		elif a.begins_with("--set="):
			for pair: String in a.trim_prefix("--set=").split(",", false):
				var kv := pair.split("=")
				if kv.size() == 2:
					overrides[kv[0]] = _value(kv[1])
		elif a.begins_with("--scene="):
			scene_arg = a.get_slice("=", 1)
		elif a.begins_with("--tag="):
			tag = a.get_slice("=", 1)
		elif not a.begins_with("--"):
			out_dir = a
	if preset_arg == "all":
		presets = [GooCellLook.Preset.FAINT, GooCellLook.Preset.CELLULAR, GooCellLook.Preset.MEMBRANE]
	else:
		for p: String in preset_arg.split(",", false):
			var k := GooCellLook.preset_named(p)
			if k < 0:
				push_error("cells_look: no preset %s" % p)
				quit(1)
				return
			presets.append(k)
	if scene_arg == "all":
		scenes = ["example", "strip", "swim"]
	else:
		for s: String in scene_arg.split(",", false):
			scenes.append(s)
	DirAccess.make_dir_recursive_absolute(out_dir)
	DisplayServer.window_set_size(LAYOUT)
	_run.call_deferred()

static func _value(text: String) -> Variant:
	if text.contains(";"):
		var p := text.split(";")
		return Vector3(float(p[0]), float(p[1]), float(p[2])) if p.size() == 3 else Vector2(float(p[0]), float(p[1]))
	return float(text)

func _letter(preset: int) -> String:
	if tag != "":
		return tag
	return ["A", "B", "C", "X"][preset]

func _run() -> void:
	for preset: int in presets:
		for s: String in scenes:
			match s:
				"example":
					await _example(preset)
				"strip":
					await _strip(preset, 1.0)
					await _strip(preset, 0.5)
				"swim":
					await _swim(preset)
	quit(0)

func _frames(n: int) -> void:
	for i: int in n:
		await process_frame

func _grab() -> Image:
	await RenderingServer.frame_post_draw
	return root.get_texture().get_image()

func _save(image: Image, scene_name: String, preset: int) -> void:
	var path := out_dir.path_join("%s_%s.png" % [_letter(preset), scene_name])
	image.save_png(path)
	print("cells_look: saved ", path)

func _look(world: GooCellWorld2D, preset: int) -> void:
	world.skin_preset = preset as GooCellLook.Preset
	GooCellLook.apply(world.current_skin_material(), preset as GooCellLook.Preset, overrides)

# --- examples/cells -----------------------------------------------------------------------

func _example(preset: int) -> void:
	GooTuning.unit = 1.0
	var scene: Node = (load("res://examples/cells/cells.tscn") as PackedScene).instantiate()
	root.add_child(scene)
	await process_frame
	var world: GooCellWorld2D = scene.world()
	_look(world, preset)
	await _frames(180)
	var image := await _grab()
	_save(image, "example", preset)
	# The worm's spine border and the blob's thrusters, 4× (canvas = screen here).
	var worm: GooCellCreature = scene.worm
	_save(_crop(image, _border_point(worm, 1), Vector2i(110, 80), 4), "zoom_border_example", preset)
	var blob: GooCellCreature = scene.blob
	_save(_crop(image, _border_point(blob, 1), Vector2i(110, 80), 4), "zoom_thrusters_example", preset)
	scene.queue_free()
	await process_frame

# --- The comparison strip -------------------------------------------------------------------

func _water(parent: Node) -> void:
	var back := ColorRect.new()
	back.size = Vector2(LAYOUT)
	var m := ShaderMaterial.new()
	m.shader = load("res://assets/shaders/backdrop.gdshader")
	m.set_shader_parameter("top_colour", Vector3(WATER_TOP.r, WATER_TOP.g, WATER_TOP.b))
	m.set_shader_parameter("bottom_colour", Vector3(WATER_BOTTOM.r, WATER_BOTTOM.g, WATER_BOTTOM.b))
	m.set_shader_parameter("dot_colour", Vector3(WATER_DOTS.r, WATER_DOTS.g, WATER_DOTS.b))
	m.set_shader_parameter("line_colour", Vector3(WATER_LINES.r, WATER_LINES.g, WATER_LINES.b))
	m.set_shader_parameter("line_strength", 0.5)
	# Not a multiple of the cells' spacing (28 px at unit 1), so no dot sits in every cell.
	m.set_shader_parameter("spacing", 23.0)
	m.set_shader_parameter("vignette", 0.4)
	back.material = m
	parent.add_child(back)

func _type(type_name: StringName, colour: Color) -> GooCellType:
	var t := GooCellType.new()
	t.name = type_name
	t.color = colour
	return t

func _strip(preset: int, unit: float) -> void:
	GooTuning.unit = unit
	var radius := 14.0 * unit
	var root2 := Node2D.new()
	root.add_child(root2)
	_water(root2)
	var rings := GooWorld2D.new()
	rings.gravity_scale = 0.0
	root2.add_child(rings)
	var cells := GooCellWorld2D.new()
	cells.gravity_scale = 0.0
	root2.add_child(cells)
	_look(cells, preset)
	var body := _type(&"body", BODY)
	var spine := _type(&"spine", SPINE)
	var patch := _type(&"patch", PATCH)
	var centre := Vector2(LAYOUT) * 0.5
	var at := func(x: float) -> Vector2: return centre + Vector2(x, 0.0) * unit
	# The ring: as big as the blob, the goo's look with its bubbles still (top down).
	var ring := rings.spawn(92.0 * unit, at.call(-640.0))
	ring.color = BODY
	var skin := ring.get_node("Skin").material as ShaderMaterial
	for k: String in ["bubble_speed", "bubble_lag", "bubble_wobble"]:
		skin.set_shader_parameter(k, 0.0)
	skin.set_shader_parameter("rim_width", 16.0 * unit)
	skin.set_shader_parameter("refraction_px", 18.0 * unit)
	skin.set_shader_parameter("motion_distortion_px", 10.0 * unit)
	# The blob: 37 cells, a patch of the second type off its middle.
	var blob_d := GooCellDesign.hex_blob(3, radius)
	blob_d.types = [body, patch]
	for i: int in blob_d.cell_count():
		if (blob_d.positions[i] - Vector2(radius * 1.2, -radius * 0.8)).length() < radius * 2.6:
			blob_d.cell_types[i] = 1
	var blob := cells.spawn(blob_d, Transform2D(0.0, at.call(-330.0)))
	# The worm: 24 × 5 with a spine row, bent mid-turn by its pose wave's bias.
	var worm_d := GooCellDesign.hex_worm(24, 5, radius)
	worm_d.types = [body, spine]
	for i: int in worm_d.cell_count():
		if absf(worm_d.positions[i].y) < 1.0:
			worm_d.cell_types[i] = 1
	var worm := cells.spawn(worm_d, Transform2D(0.0, at.call(330.0)))
	for f: int in 90:
		worm.set_pose_wave(0.0, 600.0 * unit, 0.0, 1.0 / (480.0 * unit), 0.0)
		await physics_frame
	await _frames(2)
	var image := await _grab()
	var size_name := "%dpx" % int(round(radius))
	if unit < 1.0:
		var box := Rect2i(centre.x - 520 * unit - 300, centre.y - 200, 1040 * unit + 600, 400)
		_save(image.get_region(box), "strip_" + size_name, preset)
	else:
		_save(image, "strip_" + size_name, preset)
	_save(_crop(image, _border_point(worm, 1), Vector2i(110, 80), 4), "zoom_border_" + size_name, preset)
	_save(_crop(image, _outline_point(worm), Vector2i(110, 80), 4), "zoom_outline_" + size_name, preset)
	_save(_crop(image, _border_point(blob, 1), Vector2i(110, 80), 4), "zoom_patch_" + size_name, preset)
	root2.queue_free()
	await process_frame
	GooTuning.unit = 1.0

# A point on a border between type slot `slot`'s cells and the others (their mean
# position over cell pairs of both kinds close together), or the centre.
func _border_point(c: GooCellCreature, slot: int) -> Vector2:
	var p := c.positions()
	var t := c.type_slots()
	var r := c.radii()
	var sum := Vector2.ZERO
	var count := 0
	var centre := c.center()
	var best := INF
	var best_p := centre
	for i: int in p.size():
		if t[i] != slot:
			continue
		for j: int in p.size():
			if t[j] == slot or p[i].distance_to(p[j]) > 2.3 * r[i]:
				continue
			var m := (p[i] + p[j]) * 0.5
			sum += m
			count += 1
			var dd := m.distance_to(centre)
			if dd < best:
				best = dd
				best_p = m
	return best_p

# The outline at the bend's outer side: the outline cell farthest from the worm's centre
# of curvature, approximated by the one farthest along the bend's normal.
func _outline_point(c: GooCellCreature) -> Vector2:
	var o := c.outline()
	var p := c.positions()
	var centre := c.center()
	var h := c.heading()
	var side := h.orthogonal()
	var best := -INF
	var best_p := centre
	for k: int in o:
		var v := p[k] - centre
		var s := absf(v.dot(h)) < 60.0 and v.dot(side) < 0.0
		if s and -v.dot(side) > best:
			best = -v.dot(side)
			best_p = p[k] - side * c.radii()[k] * 0.4
	return best_p

func _crop(image: Image, at: Vector2, half: Vector2i, zoom: int) -> Image:
	var box := Rect2i(Vector2i(at) - half, half * 2).intersection(Rect2i(Vector2i.ZERO, image.get_size()))
	var out := image.get_region(box)
	out.resize(box.size.x * zoom, box.size.y * zoom, Image.INTERPOLATE_NEAREST)
	return out

# --- A swimming worm, two frames apart ----------------------------------------------------

func _swim(preset: int) -> void:
	GooTuning.unit = 1.0
	var root2 := Node2D.new()
	root.add_child(root2)
	_water(root2)
	var cells := GooCellWorld2D.new()
	cells.gravity_scale = 0.0
	root2.add_child(cells)
	_look(cells, preset)
	var body := _type(&"body", BODY)
	var spine := _type(&"spine", SPINE)
	var d := GooCellDesign.hex_worm(24, 5, 14.0)
	d.types = [body, spine]
	for i: int in d.cell_count():
		if absf(d.positions[i].y) < 1.0:
			d.cell_types[i] = 1
	var worm := cells.spawn(d, Transform2D(0.0, Vector2(560, 540)))
	worm.set_swim(60.0, 0.3)
	worm.set_pose_wave(0.5, 672.0, 1.0, 0.0, 0.6)
	await _frames(120)
	var cell := worm.cell_count() / 2 + 2
	for name: String in ["swim_a", "swim_b"]:
		var at := worm.positions()[cell]
		var turn := worm.cell_angle(cell)
		var image := await _grab()
		var crop := _crop(image, at, Vector2i(90, 70), 1)
		# Turned back by the cell's turn about the crop's centre, so the two compare.
		var view := _turned(crop, -turn)
		view.resize(view.get_width() * 4, view.get_height() * 4, Image.INTERPOLATE_NEAREST)
		_save(view, name, preset)
		await _frames(6)
	root2.queue_free()
	await process_frame

# `image` turned by `angle` about its centre (nearest), same size.
func _turned(image: Image, angle: float) -> Image:
	var w := image.get_width()
	var h := image.get_height()
	var out := Image.create(w, h, false, image.get_format())
	var c := Vector2(w, h) * 0.5
	for y: int in h:
		for x: int in w:
			var q := (Vector2(x + 0.5, y + 0.5) - c).rotated(-angle) + c
			var xi := int(q.x)
			var yi := int(q.y)
			if xi >= 0 and yi >= 0 and xi < w and yi < h:
				out.set_pixel(x, y, image.get_pixel(xi, yi))
	return out
