extends SceneTree
## GooCells cost (docs/explore-cells.md): N creatures of M cells in a walled arena at the
## game's unit, kept colliding (each pushed toward a random point that changes every 2 s)
## or all swimming (a pose wave, steered by a curvature bias toward their point):
##   godot --headless --path . -s tools/cells_bench.gd -- [--creatures=30] [--cells=150]
##     [--shape=blob|worm|mixed|packed (free-form, 14 px)] [--mode=collide|swim] [--threads=4] [--substeps=6]
##     [--frames=360] [--room=1.25 (the arena over the placement grid)] [--self=0|1|2|3] [--collide-all] [--capsules]
##     [--bend=link|shape] [--preset=recommended|plain] [--draw] [--seed=1]
## Prints the step's median / p95 and its parts, the contacts, the worst soundness, and a
## RESULT line.

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

## The settings docs/explore-cells.md recommends.
static func recommended() -> Dictionary:
	return {
		"substeps": 6, "stretch_hz": 60.0, "bend_hz": 40.0, "bend_mode": GooCells.BEND_LINK,
		"link_damp": 0.02, "bend_damp": 0.02, "self_mode": GooCells.SELF_FAR,
		"drag": true, "drag_normal": 0.1, "drag_tangent": 0.005, "drag_linear_normal": 60.0, "drag_linear_tangent": 3.0,
		"contact_pad": 0.0,
	}

func _run() -> void:
	var cl := GooCells.new()
	var options := recommended() if String(o("preset", "recommended")) == "recommended" else {"drag": true}
	options["threads"] = int(o("threads", 4))
	if opts.has("substeps"): options["substeps"] = int(o("substeps", 6))
	if opts.has("self"): options["self_mode"] = int(o("self", 3))
	if opts.has("collide-all"): options["collide_all"] = bool(o("collide-all", true))
	if opts.has("capsules"): options["capsules"] = bool(o("capsules", true))
	if opts.has("pad"): options["contact_pad"] = float(o("pad", 0.2))
	if opts.has("bend"): options["bend_mode"] = GooCells.BEND_SHAPE if String(o("bend", "link")) == "shape" else GooCells.BEND_LINK
	if opts.has("bend-hz"): options["bend_hz"] = float(o("bend-hz", 40.0))
	if opts.has("stretch-hz"): options["stretch_hz"] = float(o("stretch-hz", 60.0))
	if opts.has("iters"): options["contact_iters"] = int(o("iters", 2))
	if opts.has("tension"): options["tension"] = float(o("tension", 0.0))
	cl.set_options(options)
	var n := int(o("creatures", 30))
	var m := int(o("cells", 150))
	var shape := String(o("shape", "blob"))
	var swim := String(o("mode", "collide")) == "swim"
	var rng := RandomNumberGenerator.new()
	rng.seed = int(o("seed", 1))
	var designs: Array = []
	var area := 0.0
	for k: int in n:
		var d: Array[Vector3]
		match shape:
			"worm":
				d = D.worm(int(round(m / 5.0)), 5)
			"mixed":
				d = D.packed("blob", m, 100 + k, 14.0, 44.0)
			"packed":
				d = D.packed("blob", m, 100 + k, 14.0, 14.0)
			_:
				d = D.blob_count(m)
		designs.append(d)
		for c: Vector3 in d:
			area += PI * c.z * c.z
	# Placement: a grid of the designs' boxes (+15 %, rows alternating in direction, a
	# little jitter), never overlapping; the arena around it with room to move (`room`).
	var dl := 0.0
	var dw := 0.0
	for d: Array[Vector3] in designs:
		dl = maxf(dl, D.length_x(d))
		dw = maxf(dw, D.width_y(d))
	var cols := int(ceil(sqrt(n * dw / dl)))
	cols = clampi(cols, 1, n)
	var rows := int(ceil(float(n) / cols))
	var pitch := Vector2(dl * 1.15, dw * 1.3)
	var room := float(o("room", 1.25))
	var size := Vector2(cols * pitch.x, rows * pitch.y) * room
	var side := maxf(size.x, size.y)
	var t := 200.0
	for wall: Rect2 in [Rect2(-t, -t, size.x + 2 * t, t), Rect2(-t, size.y, size.x + 2 * t, t), Rect2(-t, 0, t, size.y), Rect2(size.x, 0, t, size.y)]:
		cl.add_wall(PackedVector2Array([wall.position, wall.position + Vector2(wall.size.x, 0), wall.end, wall.position + Vector2(0, wall.size.y)]))
	var offset := (size - Vector2(cols * pitch.x, rows * pitch.y)) * 0.5
	var targets: Array[Vector2] = []
	var lengths: Array[float] = []
	# The design frame is the world's at the build: a turned creature's axis is turned.
	var axes: Array[Vector2] = []
	for k: int in n:
		var at := offset + Vector2((k % cols + 0.5) * pitch.x, (k / cols + 0.5) * pitch.y)
		var jitter := minf(0.12, 0.25 * dw / dl)
		var turn := rng.randf_range(-jitter, jitter) + (PI if (k / cols) % 2 == 1 else 0.0)
		axes.append(Vector2.from_angle(turn))
		var c := D.add(cl, designs[k], at, turn, func(v: Vector3) -> int: return 1 if v.z > 20.0 else 0)
		targets.append(Vector2(rng.randf() * size.x, rng.randf() * size.y))
		lengths.append(D.length_x(designs[k]))
		if swim:
			cl.set_wave(c, GooCells.WAVE_POSE, 1.0, lengths[k], rng.randf_range(0.8, 1.2), axes[k], 0.0, 0.0, 0.6)
	print("  arena %.0f × %.0f px, cells' area / arena %.2f" % [size.x, size.y, area / (size.x * size.y)])
	var frames := int(o("frames", 360))
	var warm := 60
	var times: Array[float] = []
	var parts := {"prep_us": 0, "broad_us": 0, "solve_us": 0, "serial_us": 0, "vel_us": 0, "topo_us": 0}
	var pairs := 0
	var script_ms := 0.0
	var draw_us := 0
	var worst := PackedFloat32Array([0, 0, 0, 0, 0, 0, 0, 0])
	for f: int in frames:
		var ts := Time.get_ticks_usec()
		if f % 120 == 0:
			for k: int in n:
				targets[k] = Vector2(rng.randf_range(0.15, 0.85) * size.x, rng.randf_range(0.15, 0.85) * size.y)
		for k: int in n:
			var ctr := cl.creature_center(k)
			var to := targets[k] - ctr
			if swim:
				var heading := cl.creature_turn(k) + axes[k].angle()
				var err := wrapf(to.angle() - heading, -PI, PI)
				cl.set_wave(k, GooCells.WAVE_POSE, 1.0, lengths[k], 1.0, axes[k], 0.0, clampf(err, -1.0, 1.0) * 0.003, 0.6)
			else:
				cl.push_creature(k, to.normalized() * 300.0)
		var t0 := Time.get_ticks_usec()
		cl.step(1.0 / 60.0)
		var ms := (Time.get_ticks_usec() - t0) / 1000.0
		if f >= warm:
			script_ms += (t0 - ts) / 1000.0
			times.append(ms)
			var s := cl.stats()
			for key: String in parts:
				parts[key] += s[key]
			pairs += int(s["cross_pairs"])
			if bool(o("draw", false)):
				var sk: Array = cl.skins_all(2)
				draw_us += int(sk[2])
		if f % 20 == 0:
			var h := cl.health()
			for k: int in h.size():
				worst[k] = maxf(worst[k], h[k])
	times.sort()
	var cnt := times.size()
	var med := times[cnt / 2]
	var p95 := times[cnt * 95 / 100]
	var links := int(cl.stats()["links"])
	print("cells_bench %d × %d %s %s threads %d substeps %d self %s: step median %.2f ms, p95 %.2f, min %.2f; prep %.2f broad %.2f solve %.2f (of it contacts between creatures %.2f) vel+breaks %.2f ms; script %.2f ms; contacts %d; links %d%s" % [
		n, m, shape, "swim" if swim else "collide", int(o("threads", 4)), int(options.get("substeps", 6)), str(options.get("self_mode", 0)), med, p95, times[0],
		parts["prep_us"] / 1000.0 / cnt, parts["broad_us"] / 1000.0 / cnt, parts["solve_us"] / 1000.0 / cnt, parts["serial_us"] / 1000.0 / cnt, (parts["vel_us"] + parts["topo_us"]) / 1000.0 / cnt,
		script_ms / cnt, pairs / cnt, links, (", skins (2 Chaikin passes, threaded) %.3f ms" % (draw_us / 1000.0 / cnt)) if bool(o("draw", false)) else ""])
	print("  soundness (worst, every 20th frame): cross overlap %.1f px, cells inside another creature %d, self overlap %.1f px, strain %.2f, shape err %.2f, wall overlap %.1f px, not finite %d" % [worst[0], int(worst[1]), worst[2], worst[3], worst[4], worst[6], int(worst[7])])
	print("RESULT n=%d m=%d shape=%s mode=%s threads=%d median=%.2f p95=%.2f contacts=%d inside=%d overlap=%.1f" % [n, m, shape, "swim" if swim else "collide", int(o("threads", 4)), med, p95, pairs / cnt, int(worst[1]), worst[0]])
	quit()
