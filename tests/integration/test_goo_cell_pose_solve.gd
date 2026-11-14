extends TestCase
## The handle-driven pose (GooCellWorld2D.pose_solve, GooCellType.pose_handle,
## GooCellCreature.pose_length(), docs/cells.md "The handle-driven pose") reaching the kernel
## from GDScript, at the game's unit (0.5: cells 14 px), stepped by hand: the flag picks the
## handles, the option turns the solve on (off: the same bits as a world that never heard of
## it), pose_length() measures the spine, and a creature with fins keeps their size under
## the wave. The kernel's own proofs are cargo tests (native/src/cells_pose.rs). Prints what
## it measures.

const DELTA: float = 1.0 / 60.0
const R: float = 14.0

func before_each() -> void:
	GooTuning.unit = 0.5

func after_each() -> void:
	GooTuning.unit = 1.0

func _world(solve: bool) -> GooCellWorld2D:
	var w := GooCellWorld2D.new()
	w.gravity_scale = 0.0
	w.draw_skins = false
	w.pose_solve = solve
	add_child(w)
	w.set_physics_process(false)
	return w

func _steps(w: GooCellWorld2D, frames: int) -> void:
	for f: int in frames:
		w.step(DELTA)

## A 24 × 5 worm whose middle row is of a `spine` type (pose_handle as given).
static func _worm(flag: bool) -> GooCellDesign:
	var d := GooCellDesign.hex_worm(24, 5, R)
	var spine := GooCellType.new()
	spine.name = &"spine"
	spine.pose_handle = flag
	d.types = [GooCellType.new(), spine]
	for i: int in d.cell_count():
		if absf(d.positions[i].y) < 1.0:
			d.cell_types[i] = 1
	return d

static func _middle_row(d: GooCellDesign) -> PackedInt32Array:
	var out := PackedInt32Array()
	for i: int in d.cell_count():
		if d.cell_types[i] == 1:
			out.append(i)
	return out

func test_the_flag_and_the_option_reach_the_kernel() -> void:
	var w := _world(true)
	var d := _worm(true)
	var cr := w.spawn(d, Transform2D(0.0, Vector2.ZERO))
	assert_eq(cr.pose_handles(), _middle_row(d), "the flagged row is the spine")
	# The spine's length: 24 centres 2R apart, plus a radius at either end.
	var spine_length := 23.0 * 2.0 * R + 2.0 * R
	print("    a 24 × 5 worm, its middle row flagged: pose_length() %.1f px (the design's %.1f px)" % [cr.pose_length(), d.length()])
	assert_almost_eq(cr.pose_length(), spine_length, 0.01)
	cr.set_pose_wave(0.6, 1.4 * cr.pose_length(), 1.0)
	_steps(w, 30)
	var info := cr.pose_info()
	print("    pose_info() after 30 frames: %s" % info)
	assert_eq(info["source"], 1, "flagged cells")
	assert_true(info["built"])
	assert_true(info["warm"])
	assert_eq(info["solves"], 30)
	assert_eq(info["fallbacks"], 0)
	assert_eq(info["handles"], _middle_row(d))
	# Unflagged: the automatic centreline (three rows within a diameter of the axis).
	var plain := w.spawn(_worm(false), Transform2D(0.0, Vector2(0, 400)))
	assert_eq(plain.pose_handles().size(), 72)
	# The option off: the design's length, and the solve never runs.
	var off := _world(false)
	var o := off.spawn(d, Transform2D(0.0, Vector2.ZERO))
	assert_almost_eq(o.pose_length(), d.length(), 0.01)
	o.set_pose_wave(0.6, 1.4 * o.pose_length(), 1.0)
	_steps(off, 30)
	assert_eq(o.pose_info()["solves"], 0)

## The option off: a world with flagged types swims bit for bit as one without them.
func test_the_option_off_changes_nothing() -> void:
	var hashes: Array[int] = []
	for flag: bool in [false, true]:
		var w := _world(false)
		var cr := w.spawn(_worm(flag), Transform2D(0.2, Vector2.ZERO))
		cr.set_pose_wave(0.6, cr.design.length(), 1.2, 0.001)
		cr.set_swim(55.0, 0.3)
		_steps(w, 120)
		hashes.append(w.cells().state_hash())
		w.queue_free()
	assert_eq(hashes[0], hashes[1])

## A swept fin keeps its cells' size under the solve and swings them with the ribbon.
func test_a_fin_keeps_its_size() -> void:
	var rows := PackedStringArray()
	var got := {}
	for solve: bool in [false, true]:
		var w := _world(solve)
		var d := _worm(true)
		# A fin one cell wide and ten long leaving the worm's top row near its head, swept
		# back at 60° from the axis (the tail is -x).
		var first := d.cell_count()
		var top := -1
		for i: int in first:
			var p := d.positions[i]
			if top < 0 or p.y < d.positions[top].y - 1.0 or (absf(p.y - d.positions[top].y) < 1.0 and absf(p.x - 8.0 * R) < absf(d.positions[top].x - 8.0 * R)):
				top = i
		var dir := Vector2(-0.5, -0.866025)
		for k: int in 10:
			d.positions.append(d.positions[top] + dir * (2.0 * R * (k + 1)))
			d.radii.append(R)
			d.cell_types.append(0)
			if not d.groups.is_empty():
				d.groups.append(0)
			if not d.angles.is_empty():
				d.angles.append(0.0)
		var cr := w.spawn(d, Transform2D(0.0, Vector2.ZERO))
		cr.set_pose_wave(0.55, 1.4 * cr.pose_length(), 1.7, 0.0, 1.0)
		cr.set_swim(55.0, 0.3)
		_steps(w, 60)
		var lo := INF
		var hi := -INF
		for f: int in 70:
			w.step(DELTA)
			var r := cr.radii()
			for i: int in range(first + 3, d.cell_count()):
				lo = minf(lo, r[i] / R)
				hi = maxf(hi, r[i] / R)
		got[solve] = Vector2(lo, hi)
		rows.append("%s: the fin's cells at %.3f..%.3f of their size" % ["pose solve" if solve else "ribbon", lo, hi])
		w.queue_free()
	print("    a 24 × 5 worm with a fin swept back from near its head, at a burst wave:\n      " + "\n      ".join(rows))
	assert_gt(got[true].x, 0.95)
	assert_lt(got[true].y, 1.05)
	assert_true(got[false].x < 0.9 or got[false].y > 1.1, "the ribbon inflates and shrinks them")
