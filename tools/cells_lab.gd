extends SceneTree
## GooCells measurements that are not cost, crash or swim (docs/explore-cells.md):
##   godot --headless --path . -s tools/cells_lab.gd -- [scenes]
## loads     the links' smoothed loads while a worm swims, a blob is pushed, two blobs crash
##           and a blob hits a wall: where a break force can sit
## topo      the cost of a retopology (find + join) on 30 creatures, of add_cell/remove_cell,
##           of a build; a creature torn by a pull: parts and events
## mixed     free-form creatures of radii 14..44 (and 14..14) against a hex blob: links per
##           cell, rest drift, a crash's soundness, the solve's time per cell
## bend      oriented links against shape matching: a worm's swim speed, an impact's peak
##           and recovery, a pulled tail's sag and recovery, the cost
## tension   a ragged cluster rounding (or not) per link model, and its net force
## steer     turning: a worm by a curvature bias, a blob by twist (zero net force), a seeker
##           pair (half the cells pulled toward a point, the rest pushed back)

const D := preload("res://tools/cells_design.gd")
const Bench := preload("res://tools/cells_bench.gd")

var scenes: Array[String] = []

func _initialize() -> void:
	for arg: String in OS.get_cmdline_user_args():
		if not arg.begins_with("--"):
			scenes.append(arg)
	if scenes.is_empty():
		scenes = ["loads", "topo", "mixed", "bend", "tension", "steer"]
	_run.call_deferred()

func _run() -> void:
	for s: String in scenes:
		call("scene_" + s)
	quit()

func world(extra: Dictionary = {}) -> GooCells:
	var cl := GooCells.new()
	cl.set_options(Bench.recommended())
	cl.set_options(extra)
	return cl

func max_load(cl: GooCells) -> float:
	var m := 0.0
	for c: int in cl.creature_count():
		if cl.alive(c):
			for l: float in cl.link_loads(c):
				m = maxf(m, l)
	return m

func scene_loads() -> void:
	var cases := {}
	var cl := world()
	var d := D.worm(30, 5)
	var w := D.add(cl, d, Vector2.ZERO)
	cl.set_wave(w, GooCells.WAVE_POSE, 1.0, D.length_x(d), 1.0, Vector2.RIGHT, 0.0, 0.0, 0.6)
	var m := 0.0
	for f: int in 300:
		cl.step(1.0 / 60.0)
		if f > 60: m = maxf(m, max_load(cl))
	cases["worm 30x5 swimming (pose wave, slope 1, 1 Hz)"] = m
	cl = world()
	var b := D.add(cl, D.blob(5), Vector2.ZERO)
	cl.push_creature(b, Vector2(800, 0))
	m = 0.0
	for f: int in 300:
		cl.step(1.0 / 60.0)
		if f > 60: m = maxf(m, max_load(cl))
	cases["blob 91 pushed 800 px/s²"] = m
	for speed: float in [300.0, 600.0]:
		cl = world()
		var a := D.add(cl, D.blob(5), Vector2(-260, 0))
		var e := D.add(cl, D.blob(5), Vector2(260, 25))
		cl.set_velocity(a, Vector2(speed, 0))
		cl.set_velocity(e, Vector2(-speed, 0))
		m = 0.0
		for f: int in 120:
			cl.step(1.0 / 60.0)
			m = maxf(m, max_load(cl))
		cases["two blobs of 91 crash at %.0f px/s each" % speed] = m
	cl = world()
	cl.add_wall(PackedVector2Array([Vector2(300, -1000), Vector2(500, -1000), Vector2(500, 1000), Vector2(300, 1000)]))
	b = D.add(cl, D.blob(5), Vector2.ZERO)
	cl.set_velocity(b, Vector2(600, 0))
	m = 0.0
	for f: int in 120:
		cl.step(1.0 / 60.0)
		m = maxf(m, max_load(cl))
	cases["blob 91 into a wall at 600 px/s"] = m
	for k: String in cases:
		print("loads %s: largest smoothed link load %s" % [k, String.num_scientific(cases[k])])

func scene_topo() -> void:
	var cl := world({"threads": 1})
	var t := Time.get_ticks_usec()
	for k: int in 30:
		D.add(cl, D.blob(7), Vector2((k % 6) * 423.0, (k / 6) * 423.0))
	print("topo build of 30 × 169 creatures: %.2f ms (%.0f µs each)" % [(Time.get_ticks_usec() - t) / 1000.0, (Time.get_ticks_usec() - t) / 30.0])
	for f: int in 10:
		cl.step(1.0 / 60.0)
	t = Time.get_ticks_usec()
	var found := cl.find_captures(4.0, false)
	var t1 := Time.get_ticks_usec()
	var made := cl.join(found)
	var t2 := Time.get_ticks_usec()
	print("topo retopology over 30 × 169 creatures 1 px apart: find %.2f ms (%d pairs), join %.2f ms (%d links)" % [(t1 - t) / 1000.0, found.size() / 4, (t2 - t1) / 1000.0, made])
	cl = world({"threads": 1})
	for k: int in 30:
		D.add(cl, D.blob_count(150), Vector2((k % 6) * 600.0, (k / 6) * 600.0))
	for f: int in 10:
		cl.step(1.0 / 60.0)
	t = Time.get_ticks_usec()
	found = cl.find_captures(4.0, false)
	print("topo retopology over 30 × 150 creatures apart: find %.2f ms (%d pairs)" % [(Time.get_ticks_usec() - t) / 1000.0, found.size() / 4])
	t = Time.get_ticks_usec()
	var edge := cl.centers(0)[0]
	var at := edge + (edge - cl.creature_center(0)).normalized() * 28.0
	cl.add_cell(0, at, 14.0, 0)
	t1 = Time.get_ticks_usec()
	cl.remove_cell(1, 10)
	t2 = Time.get_ticks_usec()
	print("topo add_cell on a 150-cell creature %.0f µs, remove_cell %.0f µs" % [t1 - t, t2 - t1])
	cl = world({"break_force": 3.0e6})
	var c := D.add(cl, D.worm(24, 3), Vector2.ZERO)
	var n := cl.cell_count(c)
	var forces := PackedVector2Array()
	forces.resize(n)
	var rl := cl.rest_local(c)
	for i: int in n:
		forces[i] = Vector2(signf(rl[i].x) * 1.5e6 if absf(rl[i].x) > 250.0 else 0.0, 0)
	cl.set_cell_forces(c, forces)
	var events := PackedInt32Array()
	for f: int in 60:
		cl.step(1.0 / 60.0)
		events.append_array(cl.take_events())
	var parted := 0
	var split := 0
	for k: int in range(0, events.size(), 4):
		if events[k] == GooCells.EVENT_PARTED: parted += 1
		if events[k] == GooCells.EVENT_SPLIT: split += 1
	var alive := 0
	for k: int in cl.creature_count():
		if cl.alive(k): alive += 1
	print("topo a 24 × 3 worm torn by its ends (break force 3e6): %d links parted, %d splits, %d creatures, health %s" % [parted, split, alive, cl.health()])

func scene_mixed() -> void:
	for name: String in ["hex 14", "packed 14..14", "packed 14..30", "packed 14..44"]:
		var designs: Array = []
		for k: int in 6:
			match name:
				"hex 14": designs.append(D.blob_count(150))
				"packed 14..14": designs.append(D.packed("blob", 150, 20 + k, 14.0, 14.0))
				"packed 14..30": designs.append(D.packed("blob", 150, 20 + k, 14.0, 30.0))
				_: designs.append(D.packed("blob", 150, 20 + k, 14.0, 44.0))
		var cl := world({"threads": 1})
		var links := 0
		var cells := 0
		for k: int in 6:
			var c := D.add(cl, designs[k], Vector2((k % 3) * 1000.0, (k / 3) * 1000.0))
			links += cl.links(c).size() / 2
			cells += cl.cell_count(c)
		var p0: Array = []
		for c: int in 6:
			p0.append(cl.centers(c))
		var solve := 0
		for f: int in 120:
			cl.step(1.0 / 60.0)
			solve += int(cl.stats()["solve_us"])
		var drift := 0.0
		for c: int in 6:
			var p := cl.centers(c)
			for i: int in p.size():
				drift = maxf(drift, p[i].distance_to(p0[c][i]))
		# A crash: the first two thrown at each other.
		var cl2 := world()
		var a := D.add(cl2, designs[0], Vector2(-400, 0))
		var b := D.add(cl2, designs[1], Vector2(400, 30))
		cl2.set_velocity(a, Vector2(600, 0))
		cl2.set_velocity(b, Vector2(-600, 0))
		var worst := PackedFloat32Array([0, 0, 0, 0, 0, 0, 0, 0])
		for f: int in 180:
			cl2.step(1.0 / 60.0)
			var h := cl2.health()
			for k: int in 8: worst[k] = maxf(worst[k], h[k])
		print("mixed %s: %.2f links per cell, rest drift %.4f px in 2 s, solve %.2f µs per cell a frame (1 thread); crash at 600 px/s each: overlap %.1f px, cells inside %d, own overlap %.1f px, shape err %.2f -> %.3f" % [
			name, float(links) / cells, drift, solve / 120.0 / cells, worst[0], int(worst[1]), worst[2], worst[4], cl2.shape_error(a)])

func scene_bend() -> void:
	var models := {"oriented links (40 Hz)": {"bend_mode": GooCells.BEND_LINK}, "oriented links (15 Hz)": {"bend_mode": GooCells.BEND_LINK, "bend_hz": 15.0},
		"shape matching k 0.3": {"bend_mode": GooCells.BEND_SHAPE, "shape_k": 0.3}, "shape matching k 0.6": {"bend_mode": GooCells.BEND_SHAPE, "shape_k": 0.6}, "none": {"bend_mode": GooCells.BEND_NONE}}
	for name: String in models:
		# Swim.
		var cl := world(models[name])
		var d := D.worm(24, 5)
		var c := D.add(cl, d, Vector2.ZERO)
		cl.set_wave(c, GooCells.WAVE_POSE, 1.0, D.length_x(d), 1.0, Vector2.RIGHT, 0.0, 0.0, 0.6)
		var solve := 0
		for f: int in 120:
			cl.step(1.0 / 60.0)
		var x0 := cl.creature_center(c).x
		for f: int in 240:
			cl.step(1.0 / 60.0)
			solve += int(cl.stats()["solve_us"])
		var speed := (cl.creature_center(c).x - x0) / 4.0
		# Sag: a 30 × 3 worm held at its head (the head cells pinned by a strong pull to their
		# place), its tail pushed sideways 400 px/s², then let go.
		var cl2 := world(models[name])
		var w := D.add(cl2, D.worm(30, 3), Vector2.ZERO)
		var n := cl2.cell_count(w)
		var rl := cl2.rest_local(w)
		var forces := PackedVector2Array()
		forces.resize(n)
		for i: int in n:
			if rl[i].x < -300.0:
				forces[i] = Vector2(0, 400.0) * PI * 196.0
		cl2.set_cell_forces(w, forces)
		var start := cl2.centers(w)
		for f: int in 120:
			cl2.step(1.0 / 60.0)
		var sag := cl2.shape_error(w)
		cl2.set_cell_forces(w, PackedVector2Array())
		for f: int in 120:
			cl2.step(1.0 / 60.0)
		var back := cl2.shape_error(w)
		# Impact.
		var cl3 := world(models[name])
		cl3.add_wall(PackedVector2Array([Vector2(300, -1000), Vector2(500, -1000), Vector2(500, 1000), Vector2(300, 1000)]))
		var bl := D.add(cl3, D.blob(5), Vector2.ZERO)
		cl3.set_velocity(bl, Vector2(600, 0))
		var peak := 0.0
		var rec := -1.0
		for f: int in 180:
			cl3.step(1.0 / 60.0)
			var e := cl3.shape_error(bl)
			peak = maxf(peak, e)
			if peak > 0.1 and e < 0.05 and rec < 0.0: rec = f / 60.0
		print("bend %s: worm 24x5 swims %.0f px/s (%.3f bl/cycle), solve %.3f ms a frame; tail pushed sideways 2 s: shape err %.2f, 2 s after release %.3f; blob into a wall at 600 px/s: peak shape err %.2f, back under 0.05 at %.2f s" % [name, speed, speed / D.length_x(d), solve / 240000.0, sag, back, peak, rec])

func scene_tension() -> void:
	var models := {"stiff links, no flow": {}, "stiff, flowing (yield 0, 2/s)": {"plastic_yield": 0.0, "plastic_rate": 2.0},
		"no bending, flowing": {"bend_mode": GooCells.BEND_NONE, "plastic_yield": 0.0, "plastic_rate": 2.0},
		"no bending, flowing, recovering 0.5/s": {"bend_mode": GooCells.BEND_NONE, "plastic_yield": 0.0, "plastic_rate": 2.0, "plastic_recover": 0.5},
		"20 Hz links, no bending, flowing": {"stretch_hz": 20.0, "bend_mode": GooCells.BEND_NONE, "plastic_yield": 0.0, "plastic_rate": 2.0}}
	for name: String in models:
		for tension: float in [3.0e5, 3.0e6]:
			var cl := world(models[name])
			cl.set_options({"tension": tension, "drag": false})
			var c := D.add(cl, D.packed("ragged", 150, 5, 14.0, 14.0), Vector2.ZERO)
			var r0 := roundness(cl, c)
			for f: int in 300:
				cl.step(1.0 / 60.0)
			var m := cl.momentum()
			var mass := 0.0
			for r: float in cl.radii(c):
				mass += PI * r * r
			print("tension %s, %s: perimeter²/4πA %.2f -> %.2f in 5 s; net velocity %.4f px/s; strain %.3f" % [String.num_scientific(tension), name, r0, roundness(cl, c), Vector2(m[0], m[1]).length() / mass, cl.health()[3]])

func roundness(cl: GooCells, c: int) -> float:
	var p := cl.centers(c)
	var per := 0.0
	var area := 0.0
	var o := cl.outline(c)
	for i: int in o.size():
		var a := p[o[i]]
		var b := p[o[(i + 1) % o.size()]]
		per += a.distance_to(b)
		area += a.cross(b) * 0.5
	return per * per / (4.0 * PI * absf(area))

func scene_steer() -> void:
	# A worm turning by a curvature bias while it swims.
	for bias: float in [0.0005, 0.001, 0.002]:
		var cl := world()
		var d := D.worm(24, 5)
		var c := D.add(cl, d, Vector2.ZERO)
		cl.set_wave(c, GooCells.WAVE_POSE, 1.0, D.length_x(d), 1.0, Vector2.RIGHT, 0.0, bias, 0.6)
		var turned := 0.0
		var prev := 0.0
		for f: int in 360:
			cl.step(1.0 / 60.0)
			var t := cl.creature_turn(c)
			if f >= 120: turned += wrapf(t - prev, -PI, PI)
			prev = t
		print("steer worm 24x5 swimming with a curvature bias %.4f /px: turns %.2f rad/s, speed %.0f px/s" % [bias, turned / 4.0, cl.creature_velocity(c).length()])
	# Twist on a blob and a worm: no net force.
	for shape: String in ["blob 127", "worm 24x5"]:
		for alpha: float in [1.0, 4.0]:
			var cl := world()
			var c := D.add(cl, D.blob(6) if shape == "blob 127" else D.worm(24, 5), Vector2.ZERO)
			cl.twist(c, alpha)
			var turned := 0.0
			var prev := 0.0
			for f: int in 240:
				cl.step(1.0 / 60.0)
				var t := cl.creature_turn(c)
				if f >= 120: turned += wrapf(t - prev, -PI, PI)
				prev = t
			print("steer %s twisted %.1f rad/s²: settles at %.2f rad/s (drag balancing it), centre drift %.1f px" % [shape, alpha, turned / 2.0, cl.creature_center(c).length()])
	# A seeker pair on a blob: the cells nearer a target pulled toward it, the rest pushed
	# away, equal totals: no net force, a turn toward the target.
	var cl := world()
	var c := D.add(cl, D.blob(6), Vector2.ZERO)
	var target := Vector2(0, -1000)
	var n := cl.cell_count(c)
	var turned := 0.0
	var prev := 0.0
	for f: int in 300:
		var p := cl.centers(c)
		var ctr := cl.creature_center(c)
		var axis := Vector2.from_angle(cl.creature_turn(c))
		var forces := PackedVector2Array()
		forces.resize(n)
		var to := (target - ctr).normalized()
		var front := 0
		for i: int in n:
			if (p[i] - ctr).dot(axis) > 0.0: front += 1
		for i: int in n:
			var pull := 100.0 * PI * 196.0 * n
			forces[i] = to * pull / front if (p[i] - ctr).dot(axis) > 0.0 else -to * pull / (n - front)
		cl.set_cell_forces(c, forces)
		cl.step(1.0 / 60.0)
		var t := cl.creature_turn(c)
		turned += wrapf(t - prev, -PI, PI)
		prev = t
	print("steer blob 127 seeker pair (100 px/s² × its mass each way: front pulled toward a point above, back pushed away, equal totals): turned %.2f rad in 5 s toward %.2f, centre drift %.1f px" % [turned, -PI * 0.5, cl.creature_center(c).length()])
