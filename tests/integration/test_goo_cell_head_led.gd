extends TestCase
## Head-led turning (GooCellCreature.set_turn_lead(), docs/cells.md "Head-led turning") on
## elastic bodies at the fluid game's sizes and unit (0.5: the 10 × 5 thruster ship of 7 px
## cells, the 24 × 5 worm of 7 px and of 14 px cells (the boss), a 37-cell blob), the world's
## drag, the spin servo at the game's turn profile (CellTurning: the half turn 0.25 s at
## 84 px to 1 s at 690 px; max spin 4.77 / (time + 0.09), its acceleration that over 0.05 of
## it) steered by spin_toward(): half and quarter turns from rest and while swimming (the
## ship on its rear thrusters, the worms by the drive and a gentle pose wave), at lead 0,
## 0.5 and 1 and at elasticity 0 and the recommended one. Prints what it measures.

const R: float = 7.0
const ELASTIC: float = 0.65

func before_each() -> void:
	GooTuning.unit = 0.5

func after_each() -> void:
	GooTuning.unit = 1.0

func _frames(n: int) -> void:
	for _f: int in n:
		await get_tree().physics_frame

static func ship() -> GooCellDesign:
	var d := GooCellDesign.hex_worm(10, 5, R)
	var thruster := GooCellType.new()
	thruster.max_thrust = 9600.0
	d.types = [GooCellType.new(), thruster]
	var rear := {}
	for i: int in d.cell_count():
		var row := roundi(d.positions[i].y / R)
		if not rear.has(row) or d.positions[i].x < d.positions[rear[row]].x:
			rear[row] = i
	for row: int in rear:
		d.cell_types[rear[row]] = 1
	return d

static func designs() -> Dictionary:
	return { "ship 10 × 5": ship(), "worm 24 × 5": GooCellDesign.hex_worm(24, 5, R), "boss worm 24 × 5 (14 px)": GooCellDesign.hex_worm(24, 5, 2.0 * R), "blob 37": GooCellDesign.hex_blob(3, R) }

static func size_of(d: GooCellDesign) -> float:
	var best := 0.0
	for i: int in d.positions.size():
		for j: int in range(i, d.positions.size()):
			best = maxf(best, d.positions[i].distance_to(d.positions[j]) + d.radii[i] + d.radii[j])
	return best

## The game's servo for a creature of `size`: [half-turn time, max spin, acceleration].
static func profile(size: float) -> Vector3:
	var time := lerpf(0.25, 1.0, clampf((size - 84.0) / (690.0 - 84.0), 0.0, 1.0))
	var pace := time + 0.09
	var spin := 4.77 / pace
	return Vector3(time, spin, spin / (0.05 * pace))

static func bend(cr: GooCellCreature, rest: PackedVector2Array) -> float:
	var p := cr.positions()
	var lo := INF
	var hi := -INF
	for q: Vector2 in rest:
		lo = minf(lo, q.x)
		hi = maxf(hi, q.x)
	var c: Array[Vector2] = [Vector2.ZERO, Vector2.ZERO, Vector2.ZERO]
	var m: Array[float] = [0.0, 0.0, 0.0]
	for i: int in p.size():
		var k := clampi(int(floor((rest[i].x - lo) / (hi - lo) * 3.0)), 0, 2)
		c[k] += p[i]
		m[k] += 1.0
	for k: int in 3:
		c[k] /= m[k]
	var a := c[1] - c[0]
	var b := c[2] - c[1]
	return atan2(a.cross(b), a.dot(b))

## One turn of `angle` (rad, clockwise) by creature `name` at `lead` and elasticity `e`,
## from rest or swimming: [time to face within 5° (INF: not in 3 s), overshoot (rad), peak
## bend (rad, signed into the turn: positive is the head ahead of the turn), the bend at the
## first tenth of the turn time, the tail's swing (px off the line it lay on), the centre's
## path off its line (px), the speed while turning (px/s, swimming), the error 1 s after
## facing (rad), lead used, worst strain].
func _turn(name: String, angle: float, lead: float, e: float, swim: bool) -> Array:
	var d: GooCellDesign = designs()[name]
	var w := GooCellWorld2D.new()
	w.gravity_scale = 0.0
	w.draw_skins = false
	w.elasticity = e
	add_child(w)
	var cr := w.spawn(d, Transform2D(0.0, Vector2(900, 540)))
	var rest := PackedVector2Array()
	var c0 := cr.center()
	for q: Vector2 in cr.positions():
		rest.append(q - c0)
	var tail := 0
	for i: int in rest.size():
		if rest[i].x < rest[tail].x:
			tail = i
	var prof := profile(size_of(d))
	if swim:
		if name.begins_with("ship"):
			var levels := PackedFloat32Array()
			levels.resize(cr.cell_count())
			levels.fill(1.0)
			cr.set_thrust_levels(levels)
		else:
			cr.set_pose_wave(0.3, d.length(), 1.0)
			cr.set_swim(110.0, 0.3)
		await _frames(90)
	cr.set_turn_lead(lead)
	cr.set_spin_servo(0.0, prof.z, INF, 1.0)
	var start := cr.turn()
	var goal := start + angle
	var turned := 0.0
	var last := start
	var from := cr.center()
	var way := Vector2.RIGHT.rotated(start)
	var tail0 := (cr.positions()[tail] - from).dot(way.orthogonal())
	var reached := INF
	var over := 0.0
	var peak := 0.0
	var early := 0.0
	var swing := 0.0
	var path := 0.0
	var after := 0.0
	var strain := 0.0
	var dist := 0.0
	var t := 0.0
	var prev := from
	for f: int in 180:
		var err := goal - (start + turned)
		cr.set_spin_target(GooCellCreature.spin_toward(err, prof.y, 0.8 * prof.z, 1.0 / 60.0))
		await get_tree().physics_frame
		t += 1.0 / 60.0
		turned += wrapf(cr.turn() - last, -PI, PI)
		last = cr.turn()
		err = goal - (start + turned)
		var b := bend(cr, rest) * signf(angle)
		if absf(b) > absf(peak):
			peak = b
		if t <= 0.1 * prof.x + 0.001:
			early = b
		var tp := cr.positions()[tail] - from
		swing = maxf(swing, absf(tp.dot(way.orthogonal()) - tail0))
		var cp := cr.center() - from
		path = maxf(path, absf(cp.dot(way.orthogonal())))
		strain = maxf(strain, w.cells().health()[3])
		if reached == INF:
			dist += cr.center().distance_to(prev)
		prev = cr.center()
		if reached == INF and absf(err) < deg_to_rad(5.0):
			reached = t
		if reached < INF:
			over = maxf(over, -err * signf(angle))
			if t <= reached + 1.0:
				after = err
	var lead_used: float = cr.spin_servo()["lead_used"]
	w.queue_free()
	await _frames(2)
	var speed := dist / reached if reached < INF else 0.0
	return [reached, over, peak, early, swing, path, speed, after, lead_used, strain]

func test_half_and_quarter_turns_led_by_the_head() -> void:
	var rows: Array[String] = []
	var got: Dictionary = {}
	for name: String in designs():
		var prof := profile(size_of(designs()[name]))
		rows.append("%s: %.0f px, the game's half turn %.2f s (servo %.1f rad/s, %.0f rad/s²)" % [name, size_of(designs()[name]), prof.x, prof.y, prof.z])
		for swim: bool in [false, true]:
			for angle: float in [PI - 0.001, PI / 2.0]:
				for setting: Vector2 in [Vector2(0.0, 0.0), Vector2(ELASTIC, 0.0), Vector2(ELASTIC, 0.5), Vector2(ELASTIC, 1.0)]:
					var r := await _turn(name, angle, setting.y, setting.x, swim)
					got[[name, swim, angle, setting]] = r
					rows.append("  %s %s, elasticity %.2f lead %.1f (used %.2f): faces in %s, overshoot %.1f°, bend %+.1f° at most (%+.1f° at a tenth of the turn time), tail swings %.0f px, centre %.0f px off its line%s, 1 s later %.2f°, strain %.3f" % ["half" if angle > 2.0 else "quarter", "swimming" if swim else "from rest", setting.x, setting.y, r[8], ("%.2f s" % r[0]) if r[0] < INF else "never", rad_to_deg(r[1]), rad_to_deg(r[2]), rad_to_deg(r[3]), r[4], r[5], (", %.0f px/s through the turn" % r[6]) if swim else "", rad_to_deg(r[7]), r[9]])
					assert_lt(r[0], 3.0, "%s faces its heading" % name)
					assert_lt(absf(r[7]), deg_to_rad(5.0), "%s holds it" % name)
	for r: String in rows:
		print("    " + r)
	var half := PI - 0.001
	for name: String in ["ship 10 × 5", "worm 24 × 5", "boss worm 24 × 5 (14 px)"]:
		var rigid: Array = got[[name, false, half, Vector2(ELASTIC, 0.0)]]
		var led: Array = got[[name, false, half, Vector2(ELASTIC, 1.0)]]
		assert_gt(led[2], 2.0 * absf(rigid[2]) + deg_to_rad(5.0), "%s bends into a head-led turn" % name)
		assert_lt(led[0], 1.25 * rigid[0], "%s's head-led half turn within a quarter of the rigid one's time" % name)
	var blob0: Array = got[["blob 37", false, half, Vector2(ELASTIC, 0.0)]]
	var blob1: Array = got[["blob 37", false, half, Vector2(ELASTIC, 1.0)]]
	assert_eq(blob1[8], 0.0, "a round blob is not led")
	assert_almost_eq(blob1[0], blob0[0], 0.02, "and turns as before")
