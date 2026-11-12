extends SceneTree
## Pictures of GooCells (docs/explore-cells.md), under xvfb-run:
##   xvfb-run -a -s "-screen 0 1920x1080x24" godot --path . --rendering-driver opengl3
##     --audio-driver Dummy -s tools/cells_shot.gd -- OUT_DIR [--scene=NAME|all] [--debug]
## Scenes: worm (a 24 × 5 worm mid-swim, and a tadpole), crash (two 91-cell clusters 0.2 s
## and 1.5 s after meeting at 600 px/s each), ragged (a ragged cluster before and after
## 5 s of surface tension with flowing links), squeeze (a blob pushed through a gap 0.6 of
## its width: stiff, then plastic), mixed (a free-form creature of radii 14..44 px at rest
## and struck), crowd (30 worms swimming in an arena, 4 s in), types (a creature whose
## same-type neighbours read as one piece).
## The look: a creature's skin is its outline surface (the boundary cells pushed out by
## their radius), smoothed, filled; inside it each cell a disc of its type's colour, and
## each link between two cells of one type a capsule of that colour, so a run of one type
## reads as one piece. --debug adds the links, the outline and cell rims.

const D := preload("res://tools/cells_design.gd")
const Bench := preload("res://tools/cells_bench.gd")

var out_dir := "."
var scene := "all"
var debug := false

class View extends Node2D:
	var cl: GooCells
	var debug := false
	var rect := Rect2(0, 0, 1920, 1080)
	var walls: Array[PackedVector2Array] = []
	var skin_colors := [Color(0.30, 0.62, 0.36), Color(0.62, 0.42, 0.25), Color(0.32, 0.47, 0.70), Color(0.62, 0.36, 0.58)]
	var type_colors := [Color(0.47, 0.80, 0.50), Color(0.95, 0.66, 0.32), Color(0.55, 0.75, 1.0), Color(0.96, 0.45, 0.45), Color(0.95, 0.90, 0.45)]
	var label := ""

	func _draw() -> void:
		var s := minf(1920.0 / rect.size.x, 1080.0 / rect.size.y)
		draw_rect(Rect2(0, 0, 1920, 1080), Color(0.05, 0.08, 0.12))
		draw_set_transform(Vector2(960, 540) - rect.get_center() * s, 0.0, Vector2(s, s))
		for w: PackedVector2Array in walls:
			draw_colored_polygon(w, Color(0.35, 0.37, 0.42))
		for c: int in cl.creature_count():
			if not cl.alive(c):
				continue
			var skin := cl.skin(c, 2)
			var sc: Color = skin_colors[c % skin_colors.size()]
			if skin.size() >= 3:
				var ok := Geometry2D.triangulate_polygon(skin)
				if ok.size() > 0:
					draw_colored_polygon(skin, sc.darkened(0.35))
				else:
					# A self-crossing outline: drawn as its points' discs only.
					for p: Vector2 in skin:
						draw_circle(p, 3.0, sc.darkened(0.35))
				var closed := skin.duplicate()
				closed.append(skin[0])
				draw_polyline(closed, sc.lightened(0.25), 2.0 / s * 1.5)
			var p := cl.centers(c)
			var r := cl.radii(c)
			var t := cl.types(c)
			var l := cl.links(c)
			for i: int in p.size():
				var tc: Color = type_colors[t[i] % type_colors.size()]
				if t[i] == 0:
					tc = sc
				draw_circle(p[i], r[i] * 0.82, tc)
			for k: int in range(0, l.size(), 2):
				var a := l[k]
				var b := l[k + 1]
				if t[a] == t[b]:
					var tc: Color = type_colors[t[a] % type_colors.size()]
					if t[a] == 0:
						tc = sc
					draw_line(p[a], p[b], tc, minf(r[a], r[b]) * 1.4)
			if debug:
				for k: int in range(0, l.size(), 2):
					draw_line(p[l[k]], p[l[k + 1]], Color(1, 1, 1, 0.45), 1.0 / s * 1.5)
				var o := cl.outline(c)
				var loop := PackedVector2Array()
				for k: int in o:
					loop.append(p[k])
				if loop.size() > 1:
					loop.append(loop[0])
					draw_polyline(loop, Color(0.2, 1.0, 1.0, 0.8), 1.5 / s * 1.5)
				for i: int in p.size():
					draw_arc(p[i], r[i], 0, TAU, 20, Color(0, 0, 0, 0.6), 1.0 / s * 1.5)
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
		if label != "":
			draw_string(ThemeDB.fallback_font, Vector2(24, 48), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 30, Color(0.9, 0.9, 0.9))

func _initialize() -> void:
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--scene="):
			scene = arg.get_slice("=", 1)
		elif arg == "--debug":
			debug = true
		elif not arg.begins_with("--"):
			out_dir = arg
	DirAccess.make_dir_recursive_absolute(out_dir)
	_run.call_deferred()

func make_view(cl: GooCells, rect: Rect2, label: String) -> View:
	var v := View.new()
	v.cl = cl
	v.rect = rect
	v.debug = debug
	v.label = label
	root.add_child(v)
	return v

func shoot(v: View, name: String) -> void:
	v.queue_redraw()
	await process_frame
	await process_frame
	await RenderingServer.frame_post_draw
	var img := root.get_viewport().get_texture().get_image()
	var path := out_dir.path_join("cells_%s%s.png" % [name, "_debug" if debug else ""])
	img.save_png(path)
	print("saved ", path)
	v.queue_free()
	await process_frame

func steps(cl: GooCells, n: int) -> void:
	for i: int in n:
		cl.step(1.0 / 60.0)

func world() -> GooCells:
	var cl := GooCells.new()
	cl.set_options(Bench.recommended())
	cl.set_options({"threads": 4})
	return cl

func wall(cl: GooCells, v: View, r: Rect2) -> void:
	var pts := PackedVector2Array([r.position, r.position + Vector2(r.size.x, 0), r.end, r.position + Vector2(0, r.size.y)])
	cl.add_wall(pts)
	v.walls.append(pts)

func _run() -> void:
	var all := scene == "all"
	if all or scene == "worm":
		var cl := world()
		var d := D.worm(24, 5)
		var c := D.add(cl, d, Vector2(-500, -120))
		cl.set_wave(c, GooCells.WAVE_POSE, 1.0, D.length_x(d), 1.0, Vector2.RIGHT, 0.0, 0.0, 0.6)
		var tp := D.tadpole(61, 24, 3)
		var c2 := D.add(cl, tp, Vector2(-500, 260))
		cl.set_wave(c2, GooCells.WAVE_POSE, 1.5, D.length_x(tp), 1.0, Vector2.RIGHT, 0.0, 0.0, 0.9)
		steps(cl, 150)
		var v := make_view(cl, Rect2(-1050, -560, 2100, 1120), "worm 24x5 and tadpole, pose wave, 2.5 s")
		await shoot(v, "worm")
	if all or scene == "crowd":
		var cl := world()
		var v := make_view(cl, Rect2(0, 0, 100, 100), "")
		var rng := RandomNumberGenerator.new()
		rng.seed = 1
		var side := 3200.0
		for w: Rect2 in [Rect2(-200, -200, side + 400, 200), Rect2(-200, side, side + 400, 200), Rect2(-200, 0, 200, side), Rect2(side, 0, 200, side)]:
			wall(cl, v, w)
		var d := D.worm(24, 5)
		var axes: Array[Vector2] = []
		for k: int in 30:
			# Rows of five, alternating in direction, never overlapping at the start.
			var at := Vector2((k % 5 + 0.5) * side / 5, (k / 5 + 0.5) * side / 6)
			var turn := rng.randf_range(-0.1, 0.1) + (PI if (k / 5) % 2 == 1 else 0.0)
			axes.append(Vector2.from_angle(turn))
			var c := D.add(cl, d, at, turn)
			cl.set_wave(c, GooCells.WAVE_POSE, 1.0, D.length_x(d), 1.0, axes[k], 0.0, 0.0, 0.6)
		for f: int in 240:
			cl.step(1.0 / 60.0)
		v.rect = Rect2(-200, -200, side + 400, side + 400)
		v.label = "30 worms 24x5 swimming (pose wave, slope 1, 1 Hz), 4 s"
		await shoot(v, "crowd")
	if all or scene == "crash":
		for when: int in [3, 90]:
			var cl := world()
			var a := D.add(cl, D.blob(5), Vector2(-200, 0))
			var b := D.add(cl, D.blob(5), Vector2(200, 30))
			cl.set_velocity(a, Vector2(600, 0))
			cl.set_velocity(b, Vector2(-600, 0))
			steps(cl, 8 + when)
			var v := make_view(cl, Rect2(-560, -315, 1120, 630), "crash 91+91 cells at 600 px/s each, %.2f s after contact" % (when / 60.0))
			await shoot(v, "crash_%d" % when)
	if all or scene == "ragged":
		for t: float in [0.0, 5.0]:
			var cl := world()
			cl.set_options({"tension": 3.0e6, "stretch_hz": 20.0, "plastic_yield": 0.0, "plastic_rate": 2.0, "bend_mode": GooCells.BEND_NONE, "drag": false})
			D.add(cl, D.packed("ragged", 150, 5, 14.0, 14.0), Vector2.ZERO)
			steps(cl, int(t * 60))
			var v := make_view(cl, Rect2(-420, -236, 840, 472), "ragged 150 cells, tension 3e6 with flowing 20 Hz links, %.0f s" % t)
			await shoot(v, "ragged_%d" % int(t))
	if all or scene == "squeeze":
		for mode: String in ["stiff", "soft"]:
			var cl := world()
			var v := make_view(cl, Rect2(-700, -394, 1400, 788), "")
			var d := D.blob(5)
			var width := D.width_y(d)
			var gap := width * 0.6
			wall(cl, v, Rect2(-40, -1000, 80, 1000 - gap * 0.5))
			wall(cl, v, Rect2(-40, gap * 0.5, 80, 1000 - gap * 0.5))
			if mode == "soft":
				cl.set_options({"stretch_hz": 6.0, "bend_hz": 2.0})
			var c := D.add(cl, d, Vector2(-400, 0))
			cl.push_creature(c, Vector2(800, 0))
			var shot_at := 0
			for f: int in 900:
				cl.step(1.0 / 60.0)
				if absf(cl.creature_center(c).x) < 30.0 and shot_at == 0:
					shot_at = f
					break
			if shot_at == 0:
				shot_at = -1
			v.label = "blob 91 cells pushed 800 px/s2 into a gap 0.6 of its width, %s, %s" % [mode, ("centre in the gap at %.1f s" % (shot_at / 60.0)) if shot_at > 0 else "jammed after 15 s"]
			await shoot(v, "squeeze_%s" % mode)
	if all or scene == "mixed":
		var cl := world()
		var d := D.packed("blob", 150, 11, 14.0, 44.0)
		var c := D.add(cl, d, Vector2(-150, 0), 0.0, func(v3: Vector3) -> int: return 1 if v3.z > 28.0 else 0)
		var e := D.add(cl, D.blob(3), Vector2(420, 40))
		cl.set_velocity(e, Vector2(-500, 0))
		steps(cl, 40)
		var v := make_view(cl, Rect2(-640, -360, 1280, 720), "mixed radii 14..44 px (large cells orange), struck by a 37-cell blob at 500 px/s")
		await shoot(v, "mixed")
	if all or scene == "types":
		var cl := world()
		var d := D.blob(6)
		D.add(cl, d, Vector2.ZERO, 0.0, func(v3: Vector3) -> int:
			var p := Vector2(v3.x, v3.y)
			if p.length() > 130.0 and absf(p.angle()) < 0.6: return 3
			if absf(p.y) < 20.0 and p.x < 0.0: return 2
			if p.length() < 50.0: return 4
			return 0)
		var v := make_view(cl, Rect2(-320, -180, 640, 360), "cell types: same-type neighbours drawn as one piece")
		await shoot(v, "types")
	quit()
