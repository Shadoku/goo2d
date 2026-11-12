extends SceneTree
## Renders the colony's adhesion (docs/colony-adhesion.md) and exposure
## (docs/colony-exposure.md) in a few set scenes to PNGs, to look at: each ring cell its
## outline (beads pushed out a bead radius), each core a disc with a tick showing its turn,
## each stick a line from its bead to where it holds on the other skin (yellow, red as its
## load nears the break force); with exposure, every exposed bead a white dot and every
## enclosed one a dark dot, the outside loop a thin white line, pockets filled blue.
##
##   xvfb-run -a -s "-screen 0 1920x1080x24" godot --path . --rendering-driver opengl3 \
##     --audio-driver Dummy -s tools/colony_shot.gd -- OUT_DIR [--scene=NAME|all]
##
## rest: a mixed-size cluster of 30 at rest (2 s). pull: the same with its left and right
## thirds pulled apart hard for 0.5 s. collide: two clusters of 20 thrown at each other,
## 0.6 s after they met. exposure: a mixed cluster of 40 whose enclosed cells became cores,
## beside a closed ring of 10 cells round a pocket and an open one of 9 round a bay (2 s).
## crash: two clusters of 37 with cores thrown at each other at 300 px/s each, compliant
## cores, at the impact (8 frames after the throw). Every scene runs with GooColonySim.EXPOSURE_OPTIONS.
## Milestone 3's (docs/colony-tension.md), with GooColonySim.tension_options() (or
## --tension=T, the strength at unit 1): ragged: a ragged cluster of 30 as placed (left,
## not stepped), after 5 s without tension (middle) and with it (right). wall: two equal
## cells (top) and a cell beside one 1.6 times its size (bottom) after 3 s, without tension
## (left) and with it (right). worm: a single file of 12 cells (top) and a worm three cells
## wide (bottom) after 5 s, without tension (left) and with it (right).
## swim: a worm of 24 × 5 cells (its inside cores) after 4 s of tools/colony_swim.gd's bend
## gait (amp 0.3, 1.5 waves, 0.5 Hz) with GooColonySim.frozen_options() (docs/colony-frozen.md).
## --frozen: every scene with frozen_options() (drag and tension on); --beads=K: K beads for
## the smallest cell (GooColonySim.cell_floats()'s `beads`).
## GooTuning.unit 0.5, drawn 4 screen px per px (exposure and crash: 3; ragged, worm, swim:
## 2; wall: 5).

const UNIT: float = 0.5
const ZOOM: float = 4.0

var _sim: GooColonySim
var _view: View
var _out: String = ""
var _scenes: PackedStringArray = []
var _scene: int = -1
var _frame: int = 0
var _frames: int = 0
var _pull: float = 0.0
var _cells: Array[Vector3] = []
var _tension: float = -1.0
var _beads: int = -1
var _frozen: bool = false
var _swim: Array = []

class View extends Node2D:
	var sim: GooColonySim
	func _draw() -> void:
		var colony := sim.colony
		var colours := [Color(0.95, 0.55, 0.35), Color(0.45, 0.7, 0.95), Color(0.6, 0.85, 0.45)]
		var limit := GooColonySim.BREAK_FORCE * GooTuning.unit
		for c: int in colony.creature_count():
			var base: Color = colours[c % colours.size()]
			for cell: int in colony.cell_count(c):
				var points := colony.cell_points(c, cell)
				var tint := base.lerp(Color.WHITE, 0.15 * (cell % 3))
				if points.size() == 1:
					draw_circle(points[0], colony.cell_radius(c, cell), tint.darkened(0.25))
					continue
				var centre := Vector2.ZERO
				for p: Vector2 in points:
					centre += p
				centre /= points.size()
				var bead_r: float = colony.cell_bead_radius(c, cell)
				var outline := PackedVector2Array()
				var n := points.size()
				for i: int in n:
					var e := points[(i + 1) % n] - points[(i + n - 1) % n]
					var normal := Vector2(-e.y, e.x).normalized()
					if normal.dot(points[i] - centre) < 0.0:
						normal = -normal
					outline.append(points[i] + normal * bead_r)
				if Geometry2D.triangulate_polygon(outline).size() > 0:
					draw_colored_polygon(outline, tint)
				outline.append(outline[0])
				draw_polyline(outline, tint.darkened(0.5), 1.0 / ZOOM * 1.5)
			var all := colony.creature_points(c)
			# Exposure: pockets filled, the outside traced, beads dotted.
			var kinds := colony.creature_loop_kinds(c)
			for li: int in kinds.size():
				var loop := colony.creature_loop(c, li)
				if loop.size() < 3:
					continue
				if kinds[li] == GooColony.LOOP_POCKET:
					if Geometry2D.triangulate_polygon(loop).size() > 0:
						draw_colored_polygon(loop, Color(0.2, 0.45, 1.0, 0.55))
				else:
					var closed := loop.duplicate()
					closed.append(loop[0])
					draw_polyline(closed, Color(0.3, 1, 1, 0.9), 0.6)
			var exposure := colony.creature_exposure(c)
			for i: int in exposure.size():
				draw_circle(all[i], 0.9, Color.WHITE if exposure[i] == 1 else Color(0.1, 0.1, 0.15))
			for cell: int in colony.cell_count(c):
				if colony.cell_kind(c, cell) != 1:
					continue
				var at := colony.cell_center(c, cell)
				var r: float = colony.cell_radius(c, cell)
				draw_line(at, at + Vector2.from_angle(colony.cell_rotation(c, cell)) * r * 0.7, Color(0.1, 0.1, 0.15), 1.0)
				draw_arc(at, r * 0.3, 0.0, TAU, 12, Color.WHITE if colony.cell_exposed_count(c, cell) > 0 else Color(0.1, 0.1, 0.15), 0.8)
			var st := colony.creature_sticks(c)
			for q: int in range(0, st.size(), GooColony.STICK_FLOATS):
				if st[q + 1] > 0.5 or st[q + 3] > 0.5:
					continue
				var from := all[int(st[q])]
				var ring_cell := int(st[q + 6])
				var other := colony.cell_points(c, ring_cell)
				var s := st[q + 4]
				var e := int(s) % other.size()
				var to := other[e].lerp(other[(e + 1) % other.size()], s - floorf(s))
				var load := clampf(st[q + 8] / limit, 0.0, 1.0)
				draw_line(from, to, Color(1.0, 1.0 - load, 0.1), 1.0 / ZOOM * 2.0)

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var which := "all"
	for arg: String in args:
		if arg.begins_with("--scene="):
			which = arg.get_slice("=", 1)
		elif arg.begins_with("--tension="):
			_tension = arg.get_slice("=", 1).to_float()
		elif arg.begins_with("--beads="):
			_beads = arg.get_slice("=", 1).to_int()
		elif arg == "--frozen":
			_frozen = true
		elif not arg.begins_with("--"):
			_out = arg
	if _out.is_empty():
		push_error("colony_shot: give an output directory")
		quit(1)
		return
	_scenes = PackedStringArray(["rest", "pull", "collide", "exposure", "crash", "ragged", "wall", "worm", "swim"]) if which == "all" else PackedStringArray([which])
	GooTuning.unit = UNIT
	RenderingServer.set_default_clear_color(Color(0.08, 0.09, 0.12))
	_next_scene()

func _next_scene() -> void:
	_scene += 1
	if _view != null:
		_view.queue_free()
	if _scene >= _scenes.size():
		quit(0)
		return
	var options := GooColonySim.EXPOSURE_OPTIONS.duplicate()
	if _scenes[_scene] in ["ragged", "wall", "worm"]:
		options.merge(GooColonySim.tension_options() if _tension < 0.0 else GooColonySim.tension_options(_tension), true)
	if _frozen or _scenes[_scene] == "swim":
		options = GooColonySim.frozen_options() if _tension < 0.0 else GooColonySim.frozen_options(_tension)
	_sim = GooColonySim.new(options)
	if _beads > 0:
		_sim.cell_beads = _beads
	_view = View.new()
	_view.sim = _sim
	var zoom := ZOOM
	match _scenes[_scene]:
		"crash", "exposure":
			zoom = 3.0
		"ragged", "worm", "swim":
			zoom = 2.0
		"wall":
			zoom = 5.0
	_view.scale = Vector2(zoom, zoom)
	_view.position = Vector2(960, 540)
	root.add_child(_view)
	_frame = 0
	match _scenes[_scene]:
		"rest", "pull":
			_cells = _pack(30, 7)
			_add(_cells, Vector2.ZERO, 0.0)
			_frames = 120 if _scenes[_scene] == "rest" else 150
		"collide":
			var cells := _pack(20, 3)
			var a := _add(cells, Vector2(-80, 0), 0.0)
			var b := _add(cells, Vector2(80, 12), 1.3)
			_sim.colony.push_creature(a, Vector2(3600, 0))
			_sim.colony.push_creature(b, Vector2(-3600, 0))
			_frames = 66
		"exposure":
			_add(_pack(40, 5), Vector2(-150, 0), 0.0)
			var r := GooTuning.min_radius()
			for skip: int in [-1, 0]:
				var list: Array = []
				var big := r / sin(PI / 10.0)
				for i: int in 10:
					if i != skip:
						list.append({ "position": Vector2(60.0 if skip == 0 else 200.0, 0) + Vector2.from_angle(TAU * i / 10.0) * big, "radius": r })
				_sim.add_creature(list)
			_frames = 120
		"crash":
			var hex: Array[Vector3] = []
			var r := GooTuning.min_radius()
			for q: int in range(-3, 4):
				for p: int in range(-3, 4):
					if absi(p + q) <= 3:
						hex.append(Vector3(p * 2.0 * r + q * r, q * sqrt(3.0) * r, r))
			_add(hex, Vector2(-120, 0), 0.0)
			_add(hex, Vector2(120, 14), 0.0)
			_frames = 30 + 8
		"ragged":
			var cells := ragged_cluster(30, 3)
			for i: int in 3:
				var k := _sim.add_creature(_offset(cells, Vector2((i - 1) * 300.0, 0)))
				if i == 0:
					_sim.colony.set_asleep(k, true)
				elif i == 1:
					_sim.colony.set_creature_tension(k, 0.0)
			_frames = 300
		"wall":
			var r := GooTuning.min_radius()
			for row: int in 2:
				var r2 := r if row == 0 else 1.6 * r
				for i: int in 2:
					var at := Vector2((i - 0.5) * 110.0, (row - 0.5) * 70.0)
					var k := _sim.add_creature([{ "position": at + Vector2(-r, 0), "radius": r }, { "position": at + Vector2(r2, 0), "radius": r2 }])
					if i == 0:
						_sim.colony.set_creature_tension(k, 0.0)
			_frames = 180
		"worm":
			for row: int in 2:
				var cells := worm_cells(12 if row == 0 else 10, 1 if row == 0 else 3, 1)
				for i: int in 2:
					var k := _sim.add_creature(_offset(cells, Vector2((i - 0.5) * 400.0 - 150.0, (row - 0.5) * 160.0)))
					if i == 0:
						_sim.colony.set_creature_tension(k, 0.0)
			_frames = 300
		"swim":
			# A worm of 24 × 5 cells, its inside cores, swimming 4 s by tools/colony_swim.gd's
			# bend gait with the frozen preset (drag and tension on).
			var r := GooTuning.min_radius()
			var list: Array = []
			_swim.clear()
			for c: int in 24:
				for j: int in 5:
					list.append({ "position": Vector2(c * 2.0 * r + (j % 2) * r, j * sqrt(3.0) * r), "radius": r,
						"core": j > 0 and j < 4 and c > 0 and c < 23 })
					_swim.append(Vector2(c / 23.0, (j - 2) / 2.0))
			_sim.add_creature(list)
			_frames = 240
	_view.queue_redraw()

static func _offset(cells: Array, by: Vector2) -> Array:
	var out: Array = []
	for c: Dictionary in cells:
		var d := c.duplicate()
		d["position"] = (c["position"] as Vector2) + by
		out.append(d)
	return out

## A ragged cluster of `count` cells of the smallest size: each new cell touches a cell
## picked at random, in a random direction, where it overlaps none (a random walk of
## branches: deep bays, arms one cell wide). Centred.
static func ragged_cluster(count: int, seed_value: int) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var r := GooTuning.min_radius()
	var at: Array[Vector2] = [Vector2.ZERO]
	while at.size() < count:
		var p := at[rng.randi() % at.size()] + Vector2.from_angle(rng.randf() * TAU) * 2.0 * r
		var free := true
		for q: Vector2 in at:
			if q.distance_to(p) < 2.0 * r - 0.01:
				free = false
				break
		if free:
			at.append(p)
	var mean := Vector2.ZERO
	for p: Vector2 in at:
		mean += p
	mean /= at.size()
	var cells: Array = []
	for p: Vector2 in at:
		cells.append({ "position": p - mean, "radius": r })
	return cells

## A worm `length` cells long and `wide` cells wide (rows offset half a cell, touching),
## each cell jittered by up to 0.3 px (seeded): centred.
static func worm_cells(length: int, wide: int, seed_value: int) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var r := GooTuning.min_radius()
	var cells: Array = []
	var span := Vector2((length - 1) * 2.0 * r + (r if wide > 1 else 0.0), (wide - 1) * sqrt(3.0) * r)
	for i: int in length:
		for j: int in wide:
			var p := Vector2(i * 2.0 * r + (r if j % 2 == 1 else 0.0), j * sqrt(3.0) * r) - span * 0.5
			p += Vector2(rng.randf_range(-0.3, 0.3), rng.randf_range(-0.3, 0.3))
			cells.append({ "position": p, "radius": r })
	return cells

func _add(cells: Array[Vector3], at: Vector2, angle: float) -> int:
	var list: Array = []
	for c: Vector3 in cells:
		list.append({ "position": at + Vector2(c.x, c.y).rotated(angle), "radius": c.z })
	return _sim.add_creature(list)

func _physics_process(delta: float) -> bool:
	if _view == null or _scene >= _scenes.size():
		return false
	var name := _scenes[_scene]
	if name == "swim":
		# tools/colony_swim.gd's bend gait: a wave of muscles running tail-ward.
		var ramp := clampf((_frame - 20) / 40.0, 0.0, 1.0)
		var scales := PackedFloat32Array()
		for uv: Vector2 in _swim:
			scales.append(1.0 + 0.3 * ramp * sin(TAU * (1.5 * uv.x + 0.5 * _frame * delta)) * uv.y)
		_sim.colony.set_cell_muscles(0, scales)
	if name == "pull" and _frame == 120:
		for i: int in _cells.size():
			var side := signf(_cells[i].x) if absf(_cells[i].x) > 15.0 else 0.0
			_sim.colony.push_cell(0, i, Vector2(side * 2500.0, 0))
	if name == "collide" and _frame == 10:
		_sim.colony.push_creature(0, Vector2.ZERO)
		_sim.colony.push_creature(1, Vector2.ZERO)
	if name == "crash" and _frame == 30:
		_sim.colony.set_creature_velocity(0, Vector2(300, 0))
		_sim.colony.set_creature_velocity(1, Vector2(-300, 0))
	_sim.step(delta)
	_frame += 1
	_view.position = Vector2(960, 540) - _centre() * _view.scale.x
	_view.queue_redraw()
	if _frame == _frames:
		_save.call_deferred(name)
		_frame += 1000000
	return false

func _centre() -> Vector2:
	var total := Vector2.ZERO
	for c: int in _sim.colony.creature_count():
		total += _sim.colony.creature_center(c)
	return total / _sim.colony.creature_count()

func _save(name: String) -> void:
	await RenderingServer.frame_post_draw
	var image := root.get_viewport().get_texture().get_image()
	var path := _out.path_join("colony_%s.png" % name)
	image.save_png(path)
	var h := _sim.colony.health()
	var st := _sim.colony.stats()
	print("colony_shot: %s -> %s (%d sticks; area %.2f..%.2f, %d inside out; %d rings, %d cores; %d beads exposed, %d enclosed, %d pockets)" % [name, path, h["sticks"],
		h["area_min"], h["area_max"], int(h["inverted"]), st["rings"], st["cores"], st["exposed"], st["enclosed"], st["pockets"]])
	_next_scene()

## A cluster of `count` touching cells of mixed sizes (the adhesion test's packing).
static func _pack(count: int, seed_value: int) -> Array[Vector3]:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var base := GooTuning.min_radius()
	var cells: Array[Vector3] = []
	var r0 := base * (1.0 + 0.85 * rng.randf())
	var r1 := base * (1.0 + 0.85 * rng.randf())
	cells.append(Vector3(0, 0, r0))
	cells.append(Vector3(r0 + r1, 0, r1))
	while cells.size() < count:
		var r := base * (1.0 + 0.85 * rng.randf())
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
