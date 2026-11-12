extends SceneTree
## GooCells propulsion (docs/explore-cells.md), headless, at the game's unit (cells 14 px):
##   godot --headless --path . -s tools/cells_swim.gd -- [options]
## --shape=worm|blob|tadpole|mixed  (--long=24 --wide=5, --rings=6, --head=61 --tail=24 --tail-wide=3,
##   --count=150 for mixed: a packed worm of radii 14..--rmax)
## --gait=pose|radius|squeeze|thrust  pose: the rest pose bent by a travelling curvature wave
##   (--amp is the slope k·A); radius / squeeze: radius muscles (--amp of the radius);
##   thrust: every cell pushes along its heading (--thrust px/s² × its mass), no undulation
## --freq=1 (Hz) --waves=1 (body lengths over the wavelength) --envelope=0.6
## --ratio=R  the drag's normal over tangential coefficients (tangential = normal / R, both
##   the quadratic and the linear terms); default the fluid game's (10 quadratic, 7.5 linear)
## --drag-scale=S  every drag coefficient × S
## --bend=link|shape --bend-hz --stretch-hz --substeps --threads --seconds=8
## --bias=K   a constant curvature added (1/px): turning by an asymmetric gait
## --twist=A  an angular acceleration about the centre of mass (rad/s²), no net force
## --station  in a 60 px/s current (--current=60), a controller holding the start point
## --crowd=N  N swimmers at once, timed
## Prints one SWIM line per run.

const D := preload("res://tools/cells_design.gd")

var opts := {}

func _initialize() -> void:
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--"):
			var kv := arg.substr(2).split("=")
			opts[kv[0]] = kv[1] if kv.size() > 1 else "1"
	_run.call_deferred()

func o(name: String, def: Variant) -> Variant:
	if not opts.has(name):
		return def
	var v: String = opts[name]
	if def is float:
		return v.to_float()
	if def is int:
		return v.to_int()
	if def is bool:
		return v != "0" and v != "false"
	return v

func design() -> Array[Vector3]:
	match String(o("shape", "worm")):
		"blob":
			return D.blob(int(o("rings", 6)))
		"tadpole":
			return D.tadpole(int(o("head", 61)), int(o("tail", 24)), int(o("tail-wide", 3)))
		"mixed":
			var d := D.packed("worm", int(o("count", 150)), int(o("seed", 3)), 14.0, float(o("rmax", 30.0)), float(o("width-cells", 4.0)))
			return d
		_:
			return D.worm(int(o("long", 24)), int(o("wide", 5)))

func make_world() -> GooCells:
	var cl := GooCells.new()
	var ratio := float(o("ratio", 0.0))
	var ds := float(o("drag-scale", 1.0))
	var dn := 0.1 * ds
	var ln := 60.0 * ds
	var options := {
		"threads": int(o("threads", 1)), "substeps": int(o("substeps", 6)),
		"bend_mode": GooCells.BEND_SHAPE if String(o("bend", "link")) == "shape" else GooCells.BEND_LINK,
		"drag": true, "drag_normal": dn, "drag_linear_normal": ln,
		"drag_tangent": (dn / ratio) if ratio > 0.0 else 0.01 * ds,
		"drag_linear_tangent": (ln / ratio) if ratio > 0.0 else 8.0 * ds,
		"drag_facing": bool(o("facing", false)),
	}
	if opts.has("bend-hz"): options["bend_hz"] = float(o("bend-hz", 4.0))
	if opts.has("stretch-hz"): options["stretch_hz"] = float(o("stretch-hz", 20.0))
	if opts.has("shape-k"): options["shape_k"] = float(o("shape-k", 0.3))
	if opts.has("self"): options["self_mode"] = int(o("self", 0))
	cl.set_options(options)
	return cl

func start_gait(cl: GooCells, c: int, d: Array[Vector3], freq: float, axis: Vector2) -> void:
	var length := D.length_x(d)
	var gait := String(o("gait", "pose"))
	var wavelength := length / float(o("waves", 1.0))
	var half := D.width_y(d) * 0.5
	match gait:
		"pose":
			cl.set_wave(c, GooCells.WAVE_POSE, float(o("amp", 1.0)), wavelength, freq, axis, half, float(o("bias", 0.0)), float(o("envelope", 0.6)))
		"radius":
			cl.set_wave(c, GooCells.WAVE_RADIUS, float(o("amp", 0.3)), wavelength, freq, axis, half, 0.0, 0.0)
		"squeeze":
			cl.set_wave(c, GooCells.WAVE_SQUEEZE, float(o("amp", 0.3)), wavelength, freq, axis, half, 0.0, 0.0)
		"thrust":
			var n := cl.cell_count(c)
			var th := PackedFloat32Array()
			var an := PackedFloat32Array()
			var radii := cl.radii(c)
			for i: int in n:
				th.append(float(o("thrust", 200.0)) * PI * radii[i] * radii[i])
				an.append(axis.angle())
			cl.set_cell_thrust(c, th, an)

func _run() -> void:
	if opts.has("crowd"):
		crowd()
	elif opts.has("station"):
		station()
	else:
		single()
	quit()

func single() -> void:
	var cl := make_world()
	var d := design()
	var c := D.add(cl, d, Vector2.ZERO)
	var freq := float(o("freq", 1.0))
	start_gait(cl, c, d, freq, Vector2.RIGHT)
	if opts.has("twist"):
		cl.twist(c, float(o("twist", 1.0)))
	var length := D.length_x(d)
	var seconds := float(o("seconds", 8.0))
	var warm := 2.0
	var p0 := Vector2.ZERO
	var t0 := 0.0
	var turn_prev := 0.0
	var turned := 0.0
	var swing := 0.0
	var times: Array[float] = []
	var worst := PackedFloat32Array([0, 0, 0, 0, 0, 0, 0, 0])
	var frames := int(seconds * 60.0)
	var head := 0
	var rl := cl.rest_local(c)
	for i: int in rl.size():
		if rl[i].x > rl[head].x:
			head = i
	for f: int in frames:
		var t := Time.get_ticks_usec()
		cl.step(1.0 / 60.0)
		times.append((Time.get_ticks_usec() - t) / 1000.0)
		var turn := cl.creature_turn(c)
		turned += wrapf(turn - turn_prev, -PI, PI)
		turn_prev = turn
		if f == int(warm * 60.0):
			p0 = cl.creature_center(c)
			t0 = turned
		if f > int(warm * 60.0):
			var ctr := cl.creature_center(c)
			var heading := Vector2.from_angle(turn)
			var lateral := absf((cl.centers(c)[head] - ctr).dot(heading.orthogonal()))
			swing = maxf(swing, lateral)
		if f % 10 == 0:
			var h := cl.health()
			for k: int in h.size():
				worst[k] = maxf(worst[k], h[k])
	var p1 := cl.creature_center(c)
	var dt := seconds - warm
	var moved := p1 - p0
	var speed := moved.length() / dt
	var along := moved.dot(Vector2.from_angle(turn_prev)) / dt
	times.sort()
	print("SWIM shape=%s cells=%d length=%.0f gait=%s amp=%.2f freq=%.2f waves=%.2f ratio=%s bend=%s: speed %.1f px/s (along heading %.1f), %.3f body lengths per cycle, turned %.2f rad/s, head swing ±%.0f px, step %.3f ms median (1 creature), strain max %.2f, self overlap %.1f px, shape err %.2f, not finite %d" % [
		o("shape", "worm"), cl.cell_count(c), length, o("gait", "pose"), float(o("amp", 1.0 if String(o("gait", "pose")) == "pose" else 0.3)), freq, float(o("waves", 1.0)), o("ratio", "game"), o("bend", "link"),
		speed, along, speed / (length * maxf(freq, 1e-6)) if String(o("gait", "pose")) != "thrust" else 0.0, (turned - t0) / dt, swing, times[times.size() / 2], worst[3], worst[2], worst[4], int(worst[7])])

func station() -> void:
	var cl := make_world()
	var current := float(o("current", 60.0))
	cl.set_options({"current": Vector2(-current, 0.0)})
	var d := design()
	var c := D.add(cl, d, Vector2.ZERO)
	var length := D.length_x(d)
	var f0 := float(o("freq", 1.0))
	var amp := float(o("amp", 1.0))
	var target := Vector2.ZERO
	var errs: Array[float] = []
	var worst_err := 0.0
	var fsum := 0.0
	for f: int in int(float(o("seconds", 20.0)) * 60.0):
		# The controller: frequency from the error along the current (and its rate), a
		# curvature bias turning the head back upstream (+x) and toward the target's line.
		var ctr := cl.creature_center(c)
		var v := cl.creature_velocity(c)
		var turn := cl.creature_turn(c)
		var err := target - ctr
		# Feed-forward: the frequency whose swim speed (0.2 body lengths a cycle) matches
		# the current; then the error along the current and its rate.
		var ff := current / (0.2 * length)
		var freq := clampf(ff + 0.004 * err.x - 0.006 * v.x, 0.05, 2.5 * f0)
		var want := atan2(clampf(err.y * 0.004, -0.6, 0.6), 1.0)
		var bias := clampf(2.0 * wrapf(want - turn, -PI, PI) - 0.5 * cl.creature_spin(c), -1.0, 1.0) * 0.004
		cl.set_wave(c, GooCells.WAVE_POSE, amp, length / float(o("waves", 1.0)), freq, Vector2.RIGHT, 0.0, bias, float(o("envelope", 0.6)))
		cl.step(1.0 / 60.0)
		if f > 6 * 60:
			var e := (cl.creature_center(c) - target).length()
			errs.append(e)
			worst_err = maxf(worst_err, e)
			fsum += freq
	var mean := 0.0
	for e: float in errs:
		mean += e
	mean /= maxf(errs.size(), 1)
	print("SWIM station current=%.0f px/s shape=%s length=%.0f: mean distance from the point %.0f px (%.2f body lengths), worst %.0f px, mean frequency %.2f Hz" % [current, o("shape", "worm"), length, mean, mean / length, worst_err, fsum / maxf(errs.size(), 1)])

func crowd() -> void:
	var cl := make_world()
	var n := int(o("crowd", 30))
	var d := design()
	var length := D.length_x(d)
	var cols := int(ceil(sqrt(n)))
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var spacing := Vector2(length * 0.85, D.width_y(d) * 2.6)
	for k: int in n:
		var at := Vector2((k % cols) * spacing.x, (k / cols) * spacing.y)
		var turn := rng.randf_range(-0.4, 0.4) + (PI if k % 2 == 1 else 0.0)
		var c := D.add(cl, d, at, turn)
		start_gait(cl, c, d, float(o("freq", 1.0)) * rng.randf_range(0.8, 1.2), Vector2.RIGHT)
	var times: Array[float] = []
	var worst := PackedFloat32Array([0, 0, 0, 0, 0, 0, 0, 0])
	var parts := {"prep_us": 0, "broad_us": 0, "solve_us": 0, "serial_us": 0, "vel_us": 0}
	var pairs := 0
	var frames := int(float(o("seconds", 8.0)) * 60.0)
	for f: int in frames:
		var t := Time.get_ticks_usec()
		cl.step(1.0 / 60.0)
		var ms := (Time.get_ticks_usec() - t) / 1000.0
		if f >= 60:
			times.append(ms)
			var s := cl.stats()
			for k: String in parts:
				parts[k] += s[k]
			pairs += int(s["cross_pairs"])
		if f % 30 == 0:
			var h := cl.health()
			for k: int in h.size():
				worst[k] = maxf(worst[k], h[k])
	times.sort()
	var m := times.size()
	print("SWIM crowd=%d cells=%d threads=%d substeps=%d gait=%s: step median %.2f ms p95 %.2f max %.2f; prep %.2f broad %.2f solve %.2f (contacts %.2f) vel %.2f ms; contact pairs %d; worst cross overlap %.1f px, cells inside another %d, strain %.2f, not finite %d" % [
		n, d.size(), int(o("threads", 1)), int(o("substeps", 6)), o("gait", "pose"), times[m / 2], times[m * 95 / 100], times[m - 1],
		parts["prep_us"] / 1000.0 / m, parts["broad_us"] / 1000.0 / m, parts["solve_us"] / 1000.0 / m, parts["serial_us"] / 1000.0 / m, parts["vel_us"] / 1000.0 / m, pairs / m, worst[0], int(worst[1]), worst[3], int(worst[7])])
