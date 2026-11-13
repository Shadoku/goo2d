extends SceneTree
## GooCellWorld2D's cost and swimming (docs/cells.md), through the world node itself (walls
## as StaticBody2D nodes mirrored by GooStatics, events, the water fed per cell), at the
## fluid game's unit (0.5; cells 14 px), stepped by hand:
##   godot --headless --path . -s tools/cell_world_bench.gd -- [--creatures=30] [--cells=150]
##     [--mode=collide|swim] [--body=links|shape|regions] [--threads=4] [--substeps=6]
##     [--frames=360] [--water=none|uniform|cells] [--ratio=20] [--seed=1]
##     [--proxies=none|circles|hull] [--real] [--rings=0] [--couple=1] [--servo=0] [--skin=goo|flat]
## collide: hex blobs pushed at 300 px/s² toward a random point that changes every 2 s;
## swim: hex worms (cells / 5 long, 5 wide) swimming by their pose wave (slope 1, a body
## length, 0.8-1.2 Hz) steered toward their point by a curvature bias. --water=cells feeds
## a slow swirl per cell through water_source (one batched call a frame), uniform a world
## current. Prints the step's median / p95 (the whole world.step() without drawing, and
## the kernel's share), and with --draw (run under xvfb-run with --rendering-driver
## opengl3 for the real renderer) the skins' build and hand-over per frame. A RESULT line.
## --rings=N adds a GooWorld2D of N ring bodies (radius 18-26 px, thrown about every 2 s)
## in the gaps between the creatures, coupled to the cells (docs/cells.md, "Rings and
## cells") unless --couple=0, and prints both worlds' steps and the coupling's share (a RINGS
## line); with --proxies the rings get proxies of the same shape too.
## --proxies gives every creature a proxy in Godot's physics (docs/godot-physics.md: a
## circle per boundary cell, or one hull) and implies --real: the world steps in real
## physics frames (run with --fixed-fps 60), so Godot's physics server steps between,
## and the whole frame's wall clock is measured too (what moving the proxies costs the
## server lands there), with the proxies' shapes moved per frame.
##
##   godot --headless --path . -s tools/cell_world_bench.gd -- --swim-test [--body=...]
##     [--ratio=20] [--long=24] [--wide=5] [--freq=1] [--slope=1] [--seconds=10]
## One worm alone in open water: body lengths per stroke cycle and px/s. --body=regions
## makes it --segments=6 shape-matched segments joined by joints.
## --servo=1: every creature turns toward its point by the spin servo (set_spin_servo(), a
## yield of 0.3 and a tip cap of 600 px/s, the target set every frame by spin_toward() of
## its heading error, at most 3 rad/s and 12 rad/s²), the swimmers' wave unbent.
## --thrust=F: every 1/F-th cell a thruster (max_thrust 600 px/s² at unit 1, facings spread
## round), their levels set every frame toward the creature's point (max(0, cos) of facing
## and way, one set_thrust_levels() per creature, outside the timing); --spikes=F: every
## 1/F-th cell (of the others) a spike (tip 1.8 radii out, 0.3 wide), facing outward.

var opts := {}

## The bench's rings never merge (a merge is not what is measured).
class Rings extends GooWorld2D:
	func may_merge(_a: Goo2D, _b: Goo2D) -> bool:
		return false

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

func _run() -> void:
	GooTuning.unit = 0.5
	if opts.has("swim-test"):
		_swim_test()
	else:
		await _bench()
	quit()

## A world set up from the options.
func _world() -> GooCellWorld2D:
	var w := GooCellWorld2D.new()
	w.gravity_scale = 0.0
	w.threads = int(o("threads", 4))
	w.substeps = int(o("substeps", 6))
	w.drag_ratio = float(o("ratio", 20.0))
	match String(o("body", "shape")):
		"links":
			w.body_mode = GooCellWorld2D.BodyMode.LINKS
		_:
			w.body_mode = GooCellWorld2D.BodyMode.SHAPE
	w.draw_skins = bool(o("draw", false))
	w.skin_mesh = GooCellWorld2D.SkinMesh.FLAT if String(o("skin", "goo")) == "flat" else GooCellWorld2D.SkinMesh.GOO
	root.add_child(w)
	w.set_physics_process(false)
	return w

## The type every cell of a regions design has: shape matched, grouped into segments.
var _segment: GooCellType = null

func _design(swim: bool, m: int) -> GooCellDesign:
	var d: GooCellDesign
	if swim:
		d = GooCellDesign.hex_worm(int(round(m / 5.0)), 5, 14.0)
	else:
		var rings := 1
		while 1 + 3 * rings * (rings + 1) < m:
			rings += 1
		var full := GooCellDesign.hex_blob(rings, 14.0)
		var order: Array = range(full.cell_count())
		order.sort_custom(func(a: int, b: int) -> bool: return full.positions[a].length_squared() < full.positions[b].length_squared())
		d = GooCellDesign.new()
		for k: int in m:
			d.add_cell(full.positions[order[k]], 14.0)
	if String(o("body", "shape")) == "regions":
		_regions(d, int(o("segments", 6)))
	var thrust := float(o("thrust", 0.0))
	var spikes := float(o("spikes", 0.0))
	if thrust > 0.0 or spikes > 0.0:
		var plain := GooCellType.new()
		var thruster := GooCellType.new()
		thruster.max_thrust = 600.0
		var spike := GooCellType.new()
		spike.tip_length = 1.8
		spike.tip_radius = 0.3
		if d.types.is_empty():
			d.types = [plain]
		d.types.append(thruster)
		d.types.append(spike)
		var c := d.centroid()
		for i: int in d.cell_count():
			if thrust > 0.0 and i % maxi(1, int(round(1.0 / thrust))) == 0:
				d.cell_types[i] = d.types.size() - 2
				d.angles[i] = float(i) * 2.399
			elif spikes > 0.0 and i % maxi(1, int(round(1.0 / spikes))) == 1:
				d.cell_types[i] = d.types.size() - 1
				d.angles[i] = (d.positions[i] - c).angle()
	return d

## Splits `d` into `segments` groups along x of one shape-matched type.
func _regions(d: GooCellDesign, segments: int) -> void:
	if _segment == null:
		_segment = GooCellType.new()
		_segment.body = GooCellType.Body.SHAPE
	d.types = [_segment]
	var box := d.bounds()
	for i: int in d.cell_count():
		var f := (d.positions[i].x - box.position.x) / maxf(box.size.x, 1.0)
		d.groups[i] = clampi(int(f * segments), 0, segments - 1)

func _bench() -> void:
	var w := _world()
	var n := int(o("creatures", 30))
	var m := int(o("cells", 150))
	var swim := String(o("mode", "collide")) == "swim"
	var servo := int(o("servo", 0)) != 0
	var rng := RandomNumberGenerator.new()
	rng.seed = int(o("seed", 1))
	var design := _design(swim, m)
	var box := design.bounds()
	var pitch := Vector2(box.size.x * 1.15 + 28.0, box.size.y * 1.3 + 28.0)
	var cols := clampi(int(ceil(sqrt(n * pitch.y / pitch.x))), 1, n)
	var rows := int(ceil(float(n) / cols))
	var size := Vector2(cols * pitch.x, rows * pitch.y) * float(o("room", 1.25))
	var t := 200.0
	var walls := StaticBody2D.new()
	walls.collision_layer = GooTuning.LAYER_WALLS
	for rect: Rect2 in [Rect2(-t, -t, size.x + 2 * t, t), Rect2(-t, size.y, size.x + 2 * t, t), Rect2(-t, 0, t, size.y), Rect2(size.x, 0, t, size.y)]:
		var shape := CollisionShape2D.new()
		var r := RectangleShape2D.new()
		r.size = rect.size
		shape.shape = r
		shape.position = rect.get_center()
		walls.add_child(shape)
	root.add_child(walls)
	var offset := (size - Vector2(cols * pitch.x, rows * pitch.y)) * 0.5
	var creatures: Array[GooCellCreature] = []
	var targets: Array[Vector2] = []
	var freqs: Array[float] = []
	for k: int in n:
		var at := offset + Vector2((k % cols + 0.5) * pitch.x, (k / cols + 0.5) * pitch.y)
		var turn := rng.randf_range(-0.1, 0.1) + (PI if (k / cols) % 2 == 1 else 0.0)
		creatures.append(w.spawn(design, Transform2D(turn, at)))
		targets.append(Vector2(rng.randf() * size.x, rng.randf() * size.y))
		freqs.append(rng.randf_range(0.8, 1.2))
	var ring_count := int(o("rings", 0))
	var ring_world: GooWorld2D = null
	var ring_bodies: Array[Goo2D] = []
	if ring_count > 0:
		ring_world = Rings.new()
		ring_world.gravity_scale = 0.0
		root.add_child(ring_world)
		ring_world.set_physics_process(false)
		var spots: Array[Vector2] = []
		for r: int in rows + 1:
			for c: int in cols + 1:
				spots.append(offset + Vector2(c * pitch.x, r * pitch.y))
		for k: int in ring_count:
			var at := spots[k % spots.size()] + Vector2(0.0, 60.0 * (k / spots.size()))
			ring_bodies.append(ring_world.spawn(rng.randf_range(18.0, 26.0), at))
		if bool(o("couple", true)):
			w.couple(ring_world)
	var water := String(o("water", "none"))
	if water == "uniform":
		w.current = Vector2(20.0, 0.0)
	elif water == "cells":
		var centre := size * 0.5
		w.water_source = func(points: PackedVector2Array) -> PackedVector2Array:
			var out := PackedVector2Array()
			out.resize(points.size())
			for i: int in points.size():
				out[i] = (points[i] - centre).orthogonal() * -0.02
			return out
	var proxies := String(o("proxies", "none"))
	var real := bool(o("real", false)) or proxies != "none"
	if proxies != "none":
		w.physics_proxies = true
		w.proxy_shape = GooProxies.Shape.HULL if proxies == "hull" else GooProxies.Shape.CIRCLES
		if ring_world != null:
			ring_world.physics_proxies = true
			ring_world.proxy_shape = w.proxy_shape
	var frame_ms: Array[float] = []
	var update_ms: Array[float] = []
	var moved := 0
	var last_tick := 0
	var frames := int(o("frames", 360))
	var warm := 60
	var times: Array[float] = []
	var kernel: Array[float] = []
	var ring_times: Array[float] = []
	var both: Array[float] = []
	var couple_us: Array[float] = []
	var broad_us: Array[float] = []
	var pairs := 0
	var bead_pairs := 0
	var touched := 0
	var mesh_us := 0
	var submit_us := 0
	var vertices := 0
	var worst := PackedFloat32Array([0, 0, 0, 0, 0, 0, 0, 0])
	var length := design.length()
	for f: int in frames:
		if f % 120 == 0:
			for k: int in n:
				targets[k] = Vector2(rng.randf_range(0.15, 0.85) * size.x, rng.randf_range(0.15, 0.85) * size.y)
		if ring_world != null and f % 120 == 1:
			for b: Goo2D in ring_bodies:
				if is_instance_valid(b):
					b.set_velocity(Vector2.from_angle(rng.randf() * TAU) * 150.0)
		for k: int in n:
			var cr := creatures[k]
			var to := targets[k] - cr.center()
			if servo:
				if f == 0:
					cr.set_spin_servo(0.0, 12.0, 600.0, 0.3)
				var err := wrapf(to.angle() - cr.heading().angle(), -PI, PI)
				cr.set_spin_target(GooCellCreature.spin_toward(err, 3.0, 0.8 * 12.0, 1.0 / 60.0))
			if float(o("thrust", 0.0)) > 0.0:
				var th := cr.thrusters()
				var levels := PackedFloat32Array()
				levels.resize(cr.cell_count())
				var way := to.normalized()
				var fac: PackedVector2Array = th["facings"]
				var idx: PackedInt32Array = th["indices"]
				for q: int in idx.size():
					levels[idx[q]] = maxf(0.0, fac[q].dot(way))
				cr.set_thrust_levels(levels)
			if swim:
				var err := wrapf(to.angle() - cr.heading().angle(), -PI, PI)
				cr.set_pose_wave(1.0, length, freqs[k], 0.0 if servo else clampf(err, -1.0, 1.0) * 0.003)
			else:
				cr.push(to.normalized() * 300.0)
		if real:
			await physics_frame
			var now := Time.get_ticks_usec()
			if last_tick > 0 and f >= warm:
				frame_ms.append((now - last_tick) / 1000.0)
			last_tick = now
		var ring_ms := 0.0
		if ring_world != null:
			var tr := Time.get_ticks_usec()
			ring_world._physics_process(1.0 / 60.0)
			ring_ms = (Time.get_ticks_usec() - tr) / 1000.0
		var t0 := Time.get_ticks_usec()
		w.step(1.0 / 60.0)
		var ms := (Time.get_ticks_usec() - t0) / 1000.0
		if f >= warm:
			times.append(ms)
			ring_times.append(ring_ms)
			both.append(ms + ring_ms)
			if ring_world != null:
				var cs := w.coupling_stats()
				couple_us.append(int(cs.get("us", 0)) / 1000.0)
				broad_us.append(int(cs.get("broad_us", 0)) / 1000.0)
				pairs += int(cs.get("cell_pairs", 0)) + int(cs.get("bead_pairs", 0))
				bead_pairs += int(cs.get("bead_pairs", 0))
				touched += int(cs.get("touched", 0))
			if w.proxies() != null:
				moved += w.proxies().shapes_moved
				update_ms.append(w.proxies().update_usec / 1000.0)
			var s := w.cells().stats()
			var us := 0
			for key: String in ["prep_us", "broad_us", "solve_us", "vel_us", "topo_us"]:
				us += int(s.get(key, 0))
			kernel.append(us / 1000.0)
			if w.draw_skins:
				mesh_us += int(w.draw_stats["mesh_us"])
				submit_us += int(w.draw_stats["submit_us"])
				vertices = int(w.draw_stats["vertices"])
		if f % 20 == 0:
			var h := w.cells().health()
			for k: int in h.size():
				worst[k] = maxf(worst[k], h[k])
	times.sort()
	kernel.sort()
	var cnt := times.size()
	var med := times[cnt / 2]
	var p95 := times[cnt * 95 / 100]
	var draw := ""
	if w.draw_skins:
		draw = ", skins: build %.3f ms, hand-over %.3f ms, %d vertices" % [mesh_us / 1000.0 / cnt, submit_us / 1000.0 / cnt, vertices]
	print("cell_world_bench %d × %d %s body %s water %s threads %d substeps %d: world.step median %.2f ms, p95 %.2f, min %.2f (kernel median %.2f)%s; walls %d" % [
		n, design.cell_count(), "swim" if swim else "collide", String(o("body", "shape")), water, w.threads, w.substeps, med, p95, times[0], kernel[cnt / 2], draw, w.wall_count()])
	if real:
		frame_ms.sort()
		var fc := frame_ms.size()
		var upd := "0"
		if not update_ms.is_empty():
			update_ms.sort()
			upd = "%.2f ms median, p95 %.2f" % [update_ms[update_ms.size() / 2], update_ms[update_ms.size() * 95 / 100]]
		print("  real frames: whole frame median %.2f ms, p95 %.2f; proxies %s: %d, %.0f shapes moved per frame, their update %s" % [frame_ms[fc / 2], frame_ms[fc * 95 / 100], proxies,
			w.proxies().count() if w.proxies() != null else 0, float(moved) / cnt, upd])
	print("  soundness (worst, every 20th frame): cross overlap %.1f px, cells inside another creature %d, self overlap %.1f px, strain %.2f, shape err %.2f, wall overlap %.1f px, not finite %d" % [worst[0], int(worst[1]), worst[2], worst[3], worst[4], worst[6], int(worst[7])])
	if ring_world != null:
		ring_times.sort()
		both.sort()
		couple_us.sort()
		broad_us.sort()
		print("  %d rings, coupled %s: ring world step median %.2f ms, p95 %.2f; both worlds median %.2f ms, p95 %.2f; the coupling inside the cells' step median %.3f ms (broad phase %.3f), p95 %.3f; rings touched per frame %.1f, candidate pairs %.0f (beads %.0f)" % [
			ring_count, w.coupled_world() != null, ring_times[cnt / 2], ring_times[cnt * 95 / 100], both[cnt / 2], both[cnt * 95 / 100], couple_us[cnt / 2], broad_us[cnt / 2], couple_us[cnt * 95 / 100], float(touched) / cnt, float(pairs) / cnt, float(bead_pairs) / cnt])
		print("RINGS rings=%d coupled=%s ring_median=%.2f both_median=%.2f both_p95=%.2f couple_median=%.3f" % [ring_count, w.coupled_world() != null, ring_times[cnt / 2], both[cnt / 2], both[cnt * 95 / 100], couple_us[cnt / 2]])
	print("RESULT n=%d m=%d mode=%s body=%s threads=%d proxies=%s servo=%d median=%.2f p95=%.2f inside=%d" % [n, design.cell_count(), "swim" if swim else "collide", String(o("body", "shape")), w.threads, proxies, int(servo), med, p95, int(worst[1])])

func _swim_test() -> void:
	var w := _world()
	var d := GooCellDesign.hex_worm(int(o("long", 24)), int(o("wide", 5)), 14.0)
	if String(o("body", "shape")) == "regions":
		_regions(d, int(o("segments", 6)))
	var cr := w.spawn(d, Transform2D.IDENTITY)
	var freq := float(o("freq", 1.0))
	var slope := float(o("slope", 1.0))
	var length := d.length()
	cr.set_pose_wave(slope, length, freq)
	var seconds := float(o("seconds", 10.0))
	var warm := 2.0
	var frames := int(seconds * 60.0)
	var start := Vector2.ZERO
	for f: int in frames:
		if f == int(warm * 60.0):
			start = cr.center()
		w.step(1.0 / 60.0)
	var travelled := cr.center().distance_to(start)
	var time := seconds - warm
	var speed := travelled / time
	var h := w.cells().health()
	print("SWIM worm %d × %d body %s ratio %.1f slope %.2f freq %.2f: %.1f px/s, %.3f body lengths a cycle (length %.0f px); strain %.2f, shape err %.2f" % [
		int(o("long", 24)), int(o("wide", 5)), String(o("body", "shape")), w.drag_ratio, slope, freq, speed, speed / freq / length, length, h[3], h[4]])
