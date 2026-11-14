extends TestCase
## GooCellWorld2D's swim drive, one-step forces, damping, the along-edge linear drag and the
## automatic thread count (docs/cells.md, "Swimming", "Braking", "Threads"), at the game's
## unit (0.5: cells 14 px), stepped by hand. A 24 × 5 worm in open water, drag ratio 20.
## Prints what it measures.

const DELTA: float = 1.0 / 60.0
const R: float = 14.0
## The worm's swim drive and toned-down stroke (docs/cells.md, "Swimming").
const SWIM: float = 55.0
const PULSE: float = 0.3
const SLOPE: float = 0.3

func before_each() -> void:
	GooTuning.unit = 0.5

func after_each() -> void:
	GooTuning.unit = 1.0

func _world(threads: int = 1) -> GooCellWorld2D:
	var w := GooCellWorld2D.new()
	w.gravity_scale = 0.0
	w.threads = threads
	w.draw_skins = false
	add_child(w)
	w.set_physics_process(false)
	return w

func _steps(w: GooCellWorld2D, frames: int) -> void:
	for f: int in frames:
		w.step(DELTA)

## [px/s along its path, rad/s, px/s along its first heading] of a 24 × 5 worm over 8 s
## after 2 s: a pose wave of `slope` (and `bias`
## 1/px) at 1 Hz, a body length long, and a swim drive of `acc` px/s².
func _swim(slope: float, acc: float, bias: float = 0.0, spawn_turn: float = 0.0, solve: bool = false) -> Array:
	var w := _world()
	w.pose_solve = solve
	var d := GooCellDesign.hex_worm(24, 5, R)
	var cr := w.spawn(d, Transform2D(spawn_turn, Vector2.ZERO))
	if slope > 0.0 or bias != 0.0:
		cr.set_pose_wave(slope, d.length(), 1.0, bias)
	if acc != 0.0:
		cr.set_swim(acc, PULSE)
	_steps(w, 120)
	var start := cr.center()
	var along := cr.heading()
	# The path's length and the turn summed frame by frame (a fast turn passes ±π).
	var path := 0.0
	var turned := 0.0
	var at := start
	var turn := cr.turn()
	for f: int in 480:
		w.step(DELTA)
		path += cr.center().distance_to(at)
		at = cr.center()
		turned += wrapf(cr.turn() - turn, -PI, PI)
		turn = cr.turn()
	var out := [path / 8.0, turned / 8.0, (at - start).dot(along) / 8.0]
	w.queue_free()
	return out

func test_the_swim_drive_carries_a_worm_with_a_toned_down_stroke() -> void:
	var stroke := _swim(1.0, 0.0)
	var low := _swim(SLOPE, 0.0)
	var force := _swim(0.0, SWIM)
	var both := _swim(SLOPE, SWIM)
	# The swim acceleration that alone gives the low stroke's speed: its thrust in kind.
	var a := 0.0
	var b := SWIM
	for k: int in 8:
		var mid := 0.5 * (a + b)
		if _swim(0.0, mid)[0] < low[0]:
			a = mid
		else:
			b = mid
	var equivalent := 0.5 * (a + b)
	print("    a 24 × 5 worm: the full stroke alone (slope 1) %.1f px/s; slope %.2f alone %.1f; the drive alone (%.0f px/s², pulse %.1f) %.1f; both %.1f px/s" % [stroke[0], SLOPE, low[0], SWIM, PULSE, force[0], both[0]])
	print("    the drive's share of both: %.0f %% by the drive alone's speed, %.0f %% by what the stroke adds, %.0f %% by thrust (the stroke ≈ a drive of %.1f px/s²)" % [100.0 * force[0] / both[0], 100.0 * (both[0] - low[0]) / both[0], 100.0 * SWIM / (SWIM + equivalent), equivalent])
	assert_gt(both[0], 150.0)
	assert_lt(both[0], 190.0)
	assert_gt(both[2], 0.98 * both[0], "along its heading")
	assert_gt(SWIM / (SWIM + equivalent), 0.8)
	assert_lt(SWIM / (SWIM + equivalent), 0.92)
	assert_almost_eq(force[1], 0.0, 0.01, "straight without a bias")
	var back := _swim(0.0, -SWIM)
	print("    the drive at −%.0f px/s²: %.1f px/s along its heading" % [SWIM, back[2]])
	assert_lt(back[2], -0.9 * force[0])

func test_a_bent_body_steers_itself() -> void:
	_bent_body_steers(false)

## The same with the handle-driven pose (GooCellWorld2D.pose_solve; the worm's automatic
## centreline its spine).
func test_a_bent_body_steers_itself_with_the_pose_solve() -> void:
	_bent_body_steers(true)

func _bent_body_steers(solve: bool) -> void:
	var lines := PackedStringArray()
	var last := 0.0
	for bias: float in [0.0005, 0.001, 0.002, 0.004]:
		var both := _swim(SLOPE, SWIM, bias, 0.0, solve)
		var force := _swim(0.0, SWIM, bias, 0.0, solve)
		lines.append("bias %.4f /px: %.3f rad/s at %.0f px/s (the drive alone, the body bent %.3f rad/s at %.0f px/s; v × bias %.3f)" % [bias, both[1], both[0], force[1], force[0], both[0] * bias])
		assert_gt(both[1], last, "more bias, a faster turn")
		assert_gt(force[1], 0.5 * both[1], "the drive follows the bend")
		last = both[1]
	var mirrored := _swim(SLOPE, SWIM, -0.002, 0.0, solve)
	print("    a worm swimming by the drive and the toned-down stroke, steered by the pose wave's curvature bias alone (no twist)%s:\n      %s\n      bias −0.002: %.3f rad/s" % [", the handle-driven pose" if solve else "", "\n      ".join(lines), mirrored[1]])
	assert_lt(mirrored[1], 0.0, "a negative bias turns it counter-clockwise")
	# Turned at spawn: the drive goes its way.
	var turned := _swim(0.0, SWIM, 0.0, PI / 2, solve)
	assert_gt(turned[2], 0.98 * turned[0])

func test_swim_weights_share_the_drive() -> void:
	var w := _world()
	var fin := GooCellType.new()
	fin.swim_weight = 4.0
	var none := GooCellType.new()
	none.swim_weight = 0.0
	var plain := GooCellDesign.hex_worm(24, 5, R)
	var d := GooCellDesign.hex_worm(24, 5, R)
	d.types = [none, fin]
	for i: int in d.cell_count():
		d.cell_types[i] = 1 if absf(d.positions[i].y) < 1.0 else 0
	var a := w.spawn(plain, Transform2D(0, Vector2(0, -300)))
	var b := w.spawn(d, Transform2D(0, Vector2(0, 300)))
	a.set_swim(SWIM, 0.0)
	b.set_swim(SWIM, 0.0)
	w.step(DELTA)
	var va := a.velocity().x
	var vb := b.velocity().x
	print("    the drive at %.0f px/s² for one step: plain worm %.4f px/s, its spine row alone pushing %.4f px/s" % [SWIM, va, vb])
	assert_almost_eq(vb, va, 0.02 * va, "the weights share the drive out, the total kept")
	_steps(w, 300)
	print("    after 5 s: plain %.0f px/s, spine-driven %.0f px/s (the same push from fewer cells)" % [a.velocity().length(), b.velocity().length()])
	assert_gt(b.center().x, 200.0)

func test_one_step_forces() -> void:
	var w := _world()
	w.drag_enabled = false
	var cr := w.spawn(GooCellDesign.hex_blob(3, R))
	cr.push_once(Vector2(600, 0))
	w.step(DELTA)
	var v1 := cr.velocity()
	w.step(DELTA)
	print("    push_once(600 px/s²): %.3f px/s after its step, %.3f after the next" % [v1.x, cr.velocity().x])
	assert_almost_eq(v1.x, 10.0, 0.05)
	assert_almost_eq(cr.velocity().x, v1.x, 0.01)
	cr.push(Vector2(0, 120))
	cr.push_once(Vector2(0, 120))
	cr.push_once(Vector2(0, 120))
	var vy := cr.velocity().y
	w.step(DELTA)
	assert_almost_eq(cr.velocity().y - vy, 6.0, 0.05, "the kept push plus two once-pushes")
	vy = cr.velocity().y
	w.step(DELTA)
	assert_almost_eq(cr.velocity().y - vy, 2.0, 0.05, "then the kept one alone")
	cr.push(Vector2.ZERO)
	cr.twist_once(4.0)
	w.step(DELTA)
	var s1 := cr.spin()
	w.step(DELTA)
	print("    twist_once(4 rad/s²): spin %.4f rad/s after its step, %.4f after the next" % [s1, cr.spin()])
	assert_gt(s1, 0.04)
	assert_lt(cr.spin(), s1 * 1.02)
	var n := cr.cell_count()
	var forces := PackedVector2Array()
	forces.resize(n)
	forces.fill(Vector2(0, -60.0 * cr.mass() / n))
	vy = cr.velocity().y
	cr.add_cell_forces_once(forces)
	w.step(DELTA)
	assert_almost_eq(cr.velocity().y - vy, -1.0, 0.02)
	vy = cr.velocity().y
	w.step(DELTA)
	assert_almost_eq(cr.velocity().y, vy, 0.01)

## The 24 × 5 worm at full speed (the drive and the toned-down stroke), let go (both
## stopped) with `damping` 1/s linear and angular, or with the along-edge linear drag set:
## [speed let go, s until under 5 px/s, px then, s until under a tenth of its speed, px
## then, px after 10 s, px/s after 10 s].
func _glide(damping: float, linear_tangent: float = -1.0) -> Array:
	var w := _world()
	w.drag_linear_tangent = linear_tangent
	var d := GooCellDesign.hex_worm(24, 5, R)
	var cr := w.spawn(d)
	cr.set_pose_wave(SLOPE, d.length(), 1.0)
	cr.set_swim(SWIM, PULSE)
	_steps(w, 360)
	var v0 := cr.velocity().length()
	cr.stop_wave()
	cr.stop_swim()
	cr.set_damping(damping, damping)
	var start := cr.center()
	var out := [v0, -1.0, 0.0, -1.0, 0.0, 0.0, 0.0]
	for f: int in 600:
		w.step(DELTA)
		var v := cr.velocity().length()
		if out[3] < 0.0 and v < 0.1 * v0:
			out[3] = (f + 1) * DELTA
			out[4] = cr.center().distance_to(start)
		if out[1] < 0.0 and v < 5.0:
			out[1] = (f + 1) * DELTA
			out[2] = cr.center().distance_to(start)
	out[5] = cr.center().distance_to(start)
	out[6] = cr.velocity().length()
	w.queue_free()
	return out

func test_damping_brakes_the_glide() -> void:
	var lines := PackedStringArray()
	var last := INF
	for k: float in [0.0, 0.5, 1.0, 1.5, 2.0, 3.0, 4.0]:
		var g := _glide(k)
		lines.append("damping %.1f /s: let go at %.0f px/s; under a tenth after %.2f s, %.0f px; under 5 px/s after %.2f s, %.0f px; after 10 s %.0f px, %.1f px/s" % [k, g[0], g[3], g[4], g[1], g[2], g[5], g[6]])
		assert_lt(g[5], last, "more damping, a shorter glide")
		last = g[5]
		if k >= 1.0:
			assert_almost_eq(g[5], g[0] / k, 0.35 * g[0] / k, "about v / k: an exponential decay on top of the drag")
			assert_lt(g[6], 0.5)
	print("    the worm let go at full speed (drive and stroke stopped), damping set, linear and angular alike:\n      %s" % "\n      ".join(lines))

func test_the_along_edge_linear_drag() -> void:
	var lines := PackedStringArray()
	var speeds: Array[float] = []
	for lt: float in [-1.0, 10.0, 20.0, 40.0]:
		var g := _glide(0.0, lt)
		speeds.append(g[0])
		lines.append("%s: swims %.0f px/s; let go, under 5 px/s after %.2f s, %.0f px; after 10 s %.0f px, %.1f px/s" % ["linear tangent %.0f px/s" % lt if lt >= 0.0 else "default (60 / 20 = 3 px/s)", g[0], g[1], g[2], g[5], g[6]])
	print("    the along-edge linear drag on its own (no damping), the same drive:\n      %s" % "\n      ".join(lines))
	assert_lt(speeds[3], speeds[0], "it brakes swimming too")
	# The default sends nothing new: the world's options as before.
	var w := _world()
	var cr := w.spawn(GooCellDesign.hex_worm(12, 3, R))
	cr.set_velocity(Vector2(100, 0))
	_steps(w, 60)
	var default_x := cr.center().x
	var w2 := _world()
	var cr2 := w2.spawn(GooCellDesign.hex_worm(12, 3, R))
	w2.drag_linear_tangent = 3.0
	cr2.set_velocity(Vector2(100, 0))
	_steps(w2, 60)
	assert_eq(cr2.center().x, default_x, "-1 is drag_linear_normal / drag_ratio")

func _run(threads: int) -> int:
	var w := _world(threads)
	w.break_force = 4.0e7
	var fin := GooCellType.new()
	fin.swim_weight = 2.5
	var d := GooCellDesign.hex_worm(12, 3, R)
	d.types = [null, fin]
	for i: int in d.cell_count():
		d.cell_types[i] = 1 if absf(d.positions[i].y) < 1.0 else 0
	var crs: Array[GooCellCreature] = []
	for k: int in 4:
		var cr := w.spawn(d, Transform2D(0.4 * k, Vector2((k % 2) * 420.0, (k / 2) * 300.0)))
		cr.set_pose_wave(SLOPE, 168.0, 1.0, 0.001 * (k - 1.5))
		cr.set_swim(SWIM * (1 + k), PULSE)
		cr.set_damping(0.3 * k, 0.5 * k)
		crs.append(cr)
	for f: int in 150:
		if f % 5 == 0:
			for cr: GooCellCreature in crs:
				cr.push_once(Vector2(0, 200))
				cr.twist_once(1.0)
				var forces := PackedVector2Array()
				forces.resize(3)
				forces.fill(Vector2(-3.0e4, 0))
				cr.add_cell_forces_once(forces)
		w.step(DELTA)
		if f == 70:
			w.retopology()
	var h := w.cells().state_hash()
	w.queue_free()
	return h

func test_threaded_equals_serial_and_a_replay_with_all_of_it() -> void:
	var a := _run(1)
	assert_eq(a, _run(4), "threaded == serial")
	assert_eq(a, _run(0), "automatic threads")
	assert_eq(a, _run(1), "a replay")

func test_automatic_threads() -> void:
	var w := _world(0)
	var cores := OS.get_processor_count()
	w.spawn(GooCellDesign.hex_blob(3, R))
	w.step(DELTA)
	print("    threads 0 (%d cores): one 37-cell creature runs on %d thread(s)" % [cores, w.threads_in_use()])
	assert_eq(w.threads_in_use(), 1)
	for k: int in 14:
		w.spawn(GooCellDesign.hex_blob(4, R), Transform2D(0, Vector2(300 + 260 * (k % 4), 300 * (k / 4 + 1))))
	w.step(DELTA)
	var cells := 37 + 14 * 61
	print("    %d cells in 15 creatures: %d thread(s) (the table's %d)" % [cells, w.threads_in_use(), GooCells.auto_threads(cells, 15, cores)])
	assert_eq(w.threads_in_use(), GooCells.auto_threads(cells, 15, cores))
	assert_eq(w.threads_in_use(), mini(2, cores), "891 cells: two")
	assert_eq(GooCells.auto_threads(4500, 30, 4), 4)
	assert_eq(GooCells.auto_threads(4500, 2, 4), 2)
	assert_eq(GooCells.auto_threads(150, 1, 4), 1)
	w.threads = 3
	w.step(DELTA)
	assert_eq(w.threads_in_use(), 3, "an explicit count still works")
