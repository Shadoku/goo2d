extends SceneTree
## GooCells collisions (docs/explore-cells.md), headless, at the game's unit (cells 14 px):
##   godot --headless --path . -s tools/cells_crash.gd -- [scenes] [--threads=1]
## Scenes (default all): crash, tunnel, snag, wall, squeeze, curl, impact.
## crash   two hex clusters (91 + 91, and 91 + 37) thrown into each other at 300 and 600 px/s
##         each, for each contact model (boundary discs, every disc, outline capsules, padded
##         boundary discs): the deepest overlap, cells ending inside the other, the shape
##         error at the impact and 2 s later, the rebound
## tunnel  a 7-cell creature fired into a 127-cell blob at 600..3000 px/s
## snag    two 30 × 5 worms pressed together side by side, one pulled along: its sliding speed
##         against the same pull alone (1 = no snag)
## wall    a 91-cell blob thrown at a wall at 300..1200 px/s
## squeeze a 91-cell blob pushed through gaps 0.8 / 0.6 / 0.45 of its width: stiff, soft,
##         plastic, plastic with recovery
## curl    a 30 × 3 worm bent until it would curl onto itself, per own-contact mode
## impact  a 127-cell blob slammed into a wall at 1200 px/s, per own-contact mode
## Every scene prints lines starting with its name; RESULT lines for scripts.

const D := preload("res://tools/cells_design.gd")
const Bench := preload("res://tools/cells_bench.gd")

var threads := 1
var scenes: Array[String] = []

func _initialize() -> void:
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--threads="):
			threads = arg.get_slice("=", 1).to_int()
		elif not arg.begins_with("--"):
			scenes.append(arg)
	if scenes.is_empty():
		scenes = ["crash", "tunnel", "snag", "wall", "squeeze", "curl", "impact"]
	_run.call_deferred()

func world(extra: Dictionary = {}) -> GooCells:
	var cl := GooCells.new()
	cl.set_options(Bench.recommended())
	cl.set_options({"threads": threads})
	cl.set_options(extra)
	return cl

func box(cl: GooCells, r: Rect2) -> void:
	cl.add_wall(PackedVector2Array([r.position, r.position + Vector2(r.size.x, 0), r.end, r.position + Vector2(0, r.size.y)]))

func _run() -> void:
	for s: String in scenes:
		call("scene_" + s)
	quit()

const MODELS := {
	"boundary discs": {},
	"every disc": {"collide_all": true},
	"outline capsules": {"capsules": true},
	"padded boundary 0.3": {"contact_pad": 0.3},
	"soft contacts 30 Hz": {"contact_hz": 30.0},
}

func scene_crash() -> void:
	for pair: Array in [[5, 5], [5, 3]]:
		for speed: float in [300.0, 600.0]:
			for model: String in MODELS:
				var cl := world(MODELS[model])
				var a := D.add(cl, D.blob(pair[0]), Vector2(-260, 0))
				var b := D.add(cl, D.blob(pair[1]), Vector2(260, 25))
				cl.set_velocity(a, Vector2(speed, 0))
				cl.set_velocity(b, Vector2(-speed, 0))
				var deepest := 0.0
				var inside_max := 0
				var shape_max := 0.0
				var ms := 0.0
				for f: int in 180:
					var t := Time.get_ticks_usec()
					cl.step(1.0 / 60.0)
					ms = maxf(ms, (Time.get_ticks_usec() - t) / 1000.0)
					var h := cl.health()
					deepest = maxf(deepest, h[0])
					inside_max = maxi(inside_max, int(h[1]))
					shape_max = maxf(shape_max, h[4])
				var end := cl.health()
				print("crash %d+%d cells at %.0f px/s each, %s: deepest overlap %.1f px, cells inside the other (max) %d, at the end %d; shape err at impact %.2f, 3 s later %.3f; speeds after %.0f / %.0f px/s; slowest step %.2f ms" % [
					cl.cell_count(a), cl.cell_count(b), speed, model, deepest, inside_max, int(end[1]), shape_max, end[4], cl.creature_velocity(a).x, cl.creature_velocity(b).x, ms])

func scene_tunnel() -> void:
	for model: String in ["boundary discs", "every disc", "outline capsules"]:
		for speed: float in [600.0, 1200.0, 2000.0, 3000.0]:
			var cl := world(MODELS[model])
			var big := D.add(cl, D.blob(6), Vector2(0, 0))
			var small := D.add(cl, D.blob(1), Vector2(-500, 3))
			cl.set_velocity(small, Vector2(speed, 0))
			var inside_max := 0
			var deepest := 0.0
			for f: int in 120:
				cl.step(1.0 / 60.0)
				var h := cl.health()
				inside_max = maxi(inside_max, int(h[1]))
				deepest = maxf(deepest, h[0])
			var end := cl.health()
			var through := cl.creature_center(small).x > 0.0
			print("tunnel 7 cells into 127 at %.0f px/s, %s: deepest overlap %.1f px, small cells inside the big one (max) %d, at the end %d, %s" % [speed, model, deepest, inside_max, int(end[1]), "PASSED THROUGH" if through else "stopped outside" if end[1] == 0 else "STUCK INSIDE"])

func scene_snag() -> void:
	var d := D.worm(30, 5)
	var alone := 0.0
	for model: String in ["alone"] + MODELS.keys():
		var cl := world(MODELS.get(model, {}))
		var a := D.add(cl, d, Vector2(0, -D.width_y(d) * 0.5 - 1.0))
		var b := -1
		if model != "alone":
			b = D.add(cl, d, Vector2(0, D.width_y(d) * 0.5 + 1.0))
		cl.push_creature(a, Vector2(300, 150))
		if b >= 0:
			cl.push_creature(b, Vector2(0, -150))
		var x0 := 0.0
		for f: int in 240:
			cl.step(1.0 / 60.0)
			if f == 60:
				x0 = cl.creature_center(a).x - (cl.creature_center(b).x if b >= 0 else 0.0)
		var rel := (cl.creature_center(a).x - (cl.creature_center(b).x if b >= 0 else 0.0) - x0) / 3.0
		if model == "alone":
			alone = rel
		var h := cl.health()
		print("snag 30x5 worm pulled 300 px/s² along another, pressed 150 px/s² into it, %s: slides %.0f px/s relative, %.2f of alone; overlap %.1f px, cells inside %d" % [model, rel, rel / maxf(alone, 1e-6), h[0], int(h[1])])

func scene_wall() -> void:
	for speed: float in [300.0, 600.0, 1200.0]:
		var cl := world()
		box(cl, Rect2(300, -1000, 200, 2000))
		var c := D.add(cl, D.blob(5), Vector2(0, 0))
		cl.set_velocity(c, Vector2(speed, 0))
		var wall := 0.0
		var shape := 0.0
		var recovered := -1.0
		for f: int in 240:
			cl.step(1.0 / 60.0)
			var h := cl.health()
			wall = maxf(wall, h[6])
			shape = maxf(shape, h[4])
			if shape > 0.1 and h[4] < 0.05 and recovered < 0.0:
				recovered = f / 60.0
		print("wall 91-cell blob at %.0f px/s: wall overlap %.1f px, shape err at impact %.2f, back within 0.05 at %.2f s, rebound %.0f px/s" % [speed, wall, shape, recovered, cl.creature_velocity(c).x])

func scene_squeeze() -> void:
	var variants := {
		"stiff (60/40 Hz)": {},
		"soft (10/3 Hz)": {"stretch_hz": 10.0, "bend_hz": 3.0},
		"plastic (yield 0.05, 3/s)": {"plastic_yield": 0.05, "plastic_rate": 3.0},
		"plastic + recovery 0.3/s": {"plastic_yield": 0.05, "plastic_rate": 3.0, "plastic_recover": 0.3},
		"plastic, no bending": {"plastic_yield": 0.05, "plastic_rate": 3.0, "bend_mode": GooCells.BEND_NONE},
		"plastic yield 0.01": {"plastic_yield": 0.01, "plastic_rate": 3.0, "plastic_recover": 0.3},
		"medium (20/6 Hz)": {"stretch_hz": 20.0, "bend_hz": 6.0},
		"soft (6/2 Hz)": {"stretch_hz": 6.0, "bend_hz": 2.0},
		"soft (10/3 Hz) + plastic 0.05": {"stretch_hz": 10.0, "bend_hz": 3.0, "plastic_yield": 0.05, "plastic_rate": 3.0, "plastic_recover": 0.3},
		"breaks at 1.5e5 + rejoin every 10 frames": {"break_force": 1.5e5, "rejoin": true},
		"soft (10/3) breaks at 6e4 + rejoin": {"stretch_hz": 10.0, "bend_hz": 3.0, "break_force": 6.0e4, "rejoin": true},
	}
	var d := D.blob(5)
	var width := D.width_y(d)
	for frac: float in [0.8, 0.6, 0.45]:
		for name: String in variants:
			var opts: Dictionary = variants[name].duplicate()
			var rejoin: bool = opts.get("rejoin", false)
			opts.erase("rejoin")
			var cl := world(opts)
			var gap := width * frac
			var max_load := 0.0
			box(cl, Rect2(-40, -2000, 80, 2000 - gap * 0.5))
			box(cl, Rect2(-40, gap * 0.5, 80, 2000 - gap * 0.5))
			var c := D.add(cl, d, Vector2(-width, 0))
			cl.push_creature(c, Vector2(800, 0))
			var passed := -1.0
			var narrow := INF
			var worst := PackedFloat32Array([0, 0, 0, 0, 0, 0, 0, 0])
			var total := 0
			for f: int in 900:
				var t := Time.get_ticks_usec()
				cl.step(1.0 / 60.0)
				if rejoin and f % 10 == 9:
					cl.join(cl.find_captures(2.0, true))
				total += Time.get_ticks_usec() - t
				for ld: float in cl.link_loads(c):
					max_load = maxf(max_load, ld)
				var h := cl.health()
				for k: int in 8:
					worst[k] = maxf(worst[k], h[k])
				var p := cl.centers(c)
				var lo := INF
				for q: Vector2 in p:
					lo = minf(lo, q.x)
				if lo > 40.0 and passed < 0.0:
					passed = f / 60.0
					break
			var shape_after := -1.0
			if passed > 0.0:
				cl.push_creature(c, Vector2.ZERO)
				for f: int in 600:
					cl.step(1.0 / 60.0)
				shape_after = cl.shape_error(c)
			var parts := 0
			for k: int in cl.creature_count():
				if cl.alive(k): parts += 1
			print("squeeze 91-cell blob (%.0f px wide) pushed 800 px/s² into a gap %.2f of it, %s: %s; worst strain %.2f, wall overlap %.1f px; shape err 10 s after %.2f; largest link load %.0f; creatures after %d; %.3f ms a frame" % [width, frac, name, ("through in %.1f s" % passed) if passed > 0 else "JAMMED (15 s)", worst[3], worst[6], shape_after, max_load, parts, total / 1000.0 / 900.0])

func scene_curl() -> void:
	var d := D.worm(30, 3)
	for mode: Array in [["none", GooCells.SELF_NONE], ["not two links apart", GooCells.SELF_FAR], ["every unlinked pair", GooCells.SELF_UNLINKED], ["opt-in head/tail types", GooCells.SELF_TYPES]]:
		var cl := world({"self_mode": mode[1], "bend_hz": 15.0})
		cl.set_type(1, {"self_collide": true})
		var c := D.add(cl, d, Vector2.ZERO, 0.0, func(v: Vector3) -> int: return 1 if absf(v.x) > 300.0 else 0)
		# A constant curvature closing the worm into more than a full circle.
		cl.set_wave(c, GooCells.WAVE_POSE, 0.0, 1000.0, 0.0, Vector2.RIGHT, 0.0, 1.5 * TAU / D.length_x(d), 0.0)
		var worst := 0.0
		var ms := 0.0
		for f: int in 240:
			var t := Time.get_ticks_usec()
			cl.step(1.0 / 60.0)
			ms += (Time.get_ticks_usec() - t) / 1000.0
			worst = maxf(worst, cl.health()[2])
		print("curl 30x3 worm bent to 1.5 turns, own contacts %s: deepest overlap of its own unlinked cells %.1f px (a cell is 28 px across), %.3f ms a frame" % [mode[0], worst, ms / 240.0])

func scene_impact() -> void:
	for mode: Array in [["none", GooCells.SELF_NONE], ["not two links apart", GooCells.SELF_FAR], ["every unlinked pair", GooCells.SELF_UNLINKED]]:
		for bend: Array in [["links", GooCells.BEND_LINK], ["shape matching", GooCells.BEND_SHAPE], ["no bending", GooCells.BEND_NONE]]:
			var cl := world({"self_mode": mode[1], "bend_mode": bend[1]})
			box(cl, Rect2(300, -1000, 200, 2000))
			var c := D.add(cl, D.blob(6), Vector2(-100, 0))
			cl.set_velocity(c, Vector2(1200, 0))
			var worst := PackedFloat32Array([0, 0, 0, 0, 0, 0, 0, 0])
			for f: int in 180:
				cl.step(1.0 / 60.0)
				var h := cl.health()
				for k: int in 8:
					worst[k] = maxf(worst[k], h[k])
			print("impact 127-cell blob into a wall at 1200 px/s, own contacts %s, bending %s: own overlap %.1f px, strain %.2f, shape err max %.2f, 3 s later %.3f, wall overlap %.1f px" % [mode[0], bend[0], worst[2], worst[3], worst[4], cl.shape_error(c), worst[6]])
