extends TestCase
## Ring bodies (a GooWorld2D's) and cell creatures (a GooCellWorld2D's) colliding once the
## two worlds are coupled (GooCellWorld2D.couple(), docs/cells.md "Rings and cells"), in
## simulated time: impacts at 300 and 600 px/s each at unit 0.5 and 1 (no cell centre left
## inside a ring, no bead inside a creature, the worst overlap, the momentum), resting on
## each other under gravity, rings well below and above the cells' size, a polygon ring, a
## worm wrapped round a ring, a settled ring woken, determinism, and two worlds left
## uncoupled passing through each other as before. Prints what it measures.

const R: float = 14.0

var rings: GooWorld2D
var cells: GooCellWorld2D
var walls: Array[Node] = []

func before_each() -> void:
	GooTuning.unit = 0.5

func after_each() -> void:
	GooTuning.unit = 1.0

# A ring world and a cell world side by side, coupled unless `couple` is false; zero
# gravity unless `gravity`; no water drag (momentum is measured).
func _scene(gravity: bool = false, couple: bool = true, threads: int = 1) -> void:
	rings = NoMergeWorld.new()
	rings.gravity_scale = 1.0 if gravity else 0.0
	rings.undamped = not gravity
	add_child(rings)
	if not gravity:
		rings.kernel().set_solver({"base_damp": 0.0})
	cells = GooCellWorld2D.new()
	cells.gravity_scale = 1.0 if gravity else 0.0
	cells.drag_enabled = false
	cells.threads = threads
	add_child(cells)
	if couple:
		cells.couple(rings)

## Rings that never merge and, with `undamped`, lose no momentum of their own (no linear
## damping), so the momentum the coupling hands over can be measured.
class NoMergeWorld extends GooWorld2D:
	var undamped: bool = false
	func may_merge(_a: Goo2D, _b: Goo2D) -> bool:
		return false
	func tuning_for(shape: GooShape, tags: Array = []) -> Dictionary:
		var t := super(shape, tags)
		if undamped:
			t["linear_damp"] = 0.0
		return t

func _frames(n: int) -> void:
	for _f: int in n:
		await get_tree().physics_frame

# A floor (a wall both worlds see) whose top is at y.
func _floor(y: float, x0: float = 0.0, x1: float = 1920.0) -> void:
	_wall(Rect2(x0, y, x1 - x0, 60.0))

func _wall(rect: Rect2) -> void:
	var body := StaticBody2D.new()
	body.collision_layer = GooTuning.LAYER_WALLS
	var poly := CollisionPolygon2D.new()
	poly.polygon = PackedVector2Array([rect.position, Vector2(rect.end.x, rect.position.y), rect.end, Vector2(rect.position.x, rect.end.y)])
	body.add_child(poly)
	add_child(body)
	walls.append(body)

# Frees the scene (worlds and walls) and waits a frame.
func _clear() -> void:
	rings.queue_free()
	cells.queue_free()
	for w: Node in walls:
		w.queue_free()
	walls.clear()
	await _frames(1)

# Cell centres of `cr` inside `body`'s bead loop.
static func _cells_inside(cr: GooCellCreature, body: Goo2D) -> int:
	var loop := body.bead_points()
	var n := 0
	for p: Vector2 in cr.positions():
		if Geometry2D.is_point_in_polygon(p, loop):
			n += 1
	return n

# Beads of `body` inside `cr`'s outline (its outline cells' centres).
static func _beads_inside(body: Goo2D, cr: GooCellCreature) -> int:
	var pos := cr.positions()
	var outline := PackedVector2Array()
	for i: int in cr.outline():
		outline.append(pos[i])
	if outline.size() < 3:
		return 0
	var n := 0
	for p: Vector2 in body.bead_points():
		if Geometry2D.is_point_in_polygon(p, outline):
			n += 1
	return n

# The deepest overlap between `body`'s skin and `cr`'s cells: for each cell, its radius +
# the bead radius − its distance to the bead chain (positive: overlapping), or the cell's
# reach + distance when its centre is inside the loop.
static func _overlap(body: Goo2D, cr: GooCellCreature) -> float:
	var loop := body.bead_points()
	var br := body.bead_radius() if body.has_method("bead_radius") else 0.0
	var pos := cr.positions()
	var rad := cr.radii()
	var worst := 0.0
	for i: int in pos.size():
		var p := pos[i]
		var d := INF
		for k: int in loop.size():
			var q := Geometry2D.get_closest_point_to_segment(p, loop[k], loop[(k + 1) % loop.size()])
			d = minf(d, p.distance_to(q))
		var inside := Geometry2D.is_point_in_polygon(p, loop)
		var o := (rad[i] + br + d) if inside else (rad[i] + br - d)
		worst = maxf(worst, o)
	return worst

func _ring_momentum(body: Goo2D) -> Vector2:
	return body.average_velocity() * body.target_area * cells.ring_density

func _momentum(body: Goo2D, cr: GooCellCreature) -> Vector2:
	return _ring_momentum(body) + cr.velocity() * cr.mass()

# A ring of `radius` (`sides` 0: round) and a hex blob of `rings_` rings of cells of radius
# `r`, thrown at each other at `speed` each along x; returns what it measured.
func _impact(speed: float, radius: float, r: float, rings_: int = 3, sides: int = 0, frames: int = 90) -> Dictionary:
	_scene()
	var gap := 6.0 * GooTuning.unit
	var design := GooCellDesign.hex_blob(rings_, r)
	var blob_half := (rings_ * 2.0 + 1.0) * r
	var centre := Vector2(960, 540)
	var body := rings.spawn(radius, centre - Vector2(radius + gap + 40.0, 0.0), GooShape.regular(sides, radius) if sides >= 3 else null)
	var cr := cells.spawn(design, Transform2D(0.0, centre + Vector2(blob_half + 40.0, 0.0)))
	await _frames(1)
	body.set_velocity(Vector2(speed, 0.0))
	cr.set_velocity(Vector2(-speed, 0.0))
	await _frames(1)
	var p0 := _momentum(body, cr)
	var worst_stat := 0.0
	var worst_geo := 0.0
	var inside_max := 0
	var beads_max := 0
	var touched := 0
	for f: int in frames:
		await _frames(1)
		var s := cells.coupling_stats()
		worst_stat = maxf(worst_stat, s["worst"])
		if s["touched"] > 0:
			touched += 1
		worst_geo = maxf(worst_geo, _overlap(body, cr))
		inside_max = maxi(inside_max, _cells_inside(cr, body))
		beads_max = maxi(beads_max, _beads_inside(body, cr))
	var p1 := _momentum(body, cr)
	var scale := absf(speed) * (body.target_area + cr.mass())
	var out := {
		"worst_found": worst_stat, "worst_geo": worst_geo, "cells_inside_max": inside_max,
		"beads_inside_max": beads_max, "cells_inside_end": _cells_inside(cr, body),
		"beads_inside_end": _beads_inside(body, cr), "overlap_end": _overlap(body, cr),
		"p_err": (p1 - p0).length() / scale, "ring_v": body.average_velocity(), "blob_v": cr.velocity(),
		"frames_touching": touched, "sound": body.area() / body.target_area,
		"apart": body.center().distance_to(cr.center()),
	}
	return out

func _report(label: String, m: Dictionary) -> void:
	print("  %s: worst overlap %.2f px found / %.2f px measured after the frames; centres inside max %d (end %d), beads inside max %d (end %d), overlap at end %.2f px; momentum error %.2f %%; ring v (%.0f, %.0f), blob v (%.0f, %.0f); %d frames touching; ring area %.2f of target" % [
		label, m["worst_found"], m["worst_geo"], m["cells_inside_max"], m["cells_inside_end"],
		m["beads_inside_max"], m["beads_inside_end"], m["overlap_end"], 100.0 * m["p_err"],
		m["ring_v"].x, m["ring_v"].y, m["blob_v"].x, m["blob_v"].y, m["frames_touching"], m["sound"]])

func _check_impact(m: Dictionary) -> void:
	assert_eq(m["cells_inside_end"], 0, "no cell centre inside the ring afterwards")
	assert_eq(m["beads_inside_end"], 0, "no bead inside the creature afterwards")
	assert_gt(m["frames_touching"], 0, "they met")
	assert_lt(m["overlap_end"], 2.0 * GooTuning.unit, "apart or in contact, not interpenetrating")
	assert_lt(m["p_err"], 0.05, "momentum kept within 5 %")
	assert_gt(m["sound"], 0.6, "the ring kept its area")

func test_impacts_at_unit_half() -> void:
	for speed: float in [300.0, 600.0]:
		var m := await _impact(speed, 40.0, R)
		_report("unit 0.5, %d px/s each, ring 40 px, cells 14 px" % speed, m)
		_check_impact(m)
		await _clear()

func test_impacts_at_unit_one() -> void:
	GooTuning.unit = 1.0
	for speed: float in [300.0, 600.0]:
		var m := await _impact(speed, 80.0, 2.0 * R)
		_report("unit 1, %d px/s each, ring 80 px, cells 28 px" % speed, m)
		_check_impact(m)
		await _clear()

# The fastest any cell of `cr` or bead of `body` moves (px/s).
static func _fastest(body: Goo2D, cr: GooCellCreature) -> float:
	return maxf(_fastest_bead(body), _fastest_cell(cr))

static func _fastest_bead(body: Goo2D) -> float:
	var v := 0.0
	for u: Vector2 in body.bead_velocities():
		v = maxf(v, u.length())
	return v

static func _fastest_cell(cr: GooCellCreature) -> float:
	var v := 0.0
	for u: Vector2 in cr.velocities():
		v = maxf(v, u.length())
	return v

# Rest under gravity for `seconds`: [ring centre drift px/s over the last 3 s, creature
# drift, fastest particle in the first and last second, worst overlap, centres/beads inside].
func _rest(body: Goo2D, cr: GooCellCreature, seconds: float) -> Dictionary:
	var frames := int(seconds * 60.0)
	var ring_at := Vector2.ZERO
	var blob_at := Vector2.ZERO
	var early := 0.0
	var late := 0.0
	var late_bead := 0.0
	var late_cell := 0.0
	var worst := 0.0
	var inside := 0
	for f: int in frames:
		await _frames(1)
		if f == frames - 180:
			ring_at = body.center()
			blob_at = cr.center()
		if f >= 60 and f < 120:
			early = maxf(early, _fastest(body, cr))
		if f >= frames - 60:
			late = maxf(late, _fastest(body, cr))
			late_bead = maxf(late_bead, _fastest_bead(body))
			late_cell = maxf(late_cell, _fastest_cell(cr))
		if f >= 60:
			worst = maxf(worst, _overlap(body, cr))
			inside = maxi(inside, _cells_inside(cr, body) + _beads_inside(body, cr))
	return {"ring_drift": body.center().distance_to(ring_at) / 3.0, "blob_drift": cr.center().distance_to(blob_at) / 3.0,
		"early": early, "late": late, "late_bead": late_bead, "late_cell": late_cell, "worst": worst, "inside": inside}

func test_a_ring_resting_on_a_creature() -> void:
	_scene(true)
	_floor(800.0)
	var cr := cells.spawn(GooCellDesign.hex_worm(14, 3, R), Transform2D(0.0, Vector2(960, 800.0 - 3.0 * R)))
	var body := rings.spawn(40.0, Vector2(960, 800.0 - 6.0 * R - 50.0))
	await _frames(60)
	var m := await _rest(body, cr, 5.0)
	print("  a 40 px ring on a 14 × 3 worm under gravity, 5 s: ring drifts %.2f px/s, worm %.2f px/s over the last 3 s; fastest particle %.1f px/s in the second second, %.1f in the last; worst overlap %.2f px; centres/beads inside %d" % [
		m["ring_drift"], m["blob_drift"], m["early"], m["late"], m["worst"], m["inside"]])
	assert_lt(body.center().y, cr.center().y - 2.0 * R, "the ring stays on top")
	assert_lt(m["ring_drift"], 2.0, "the ring rests")
	assert_lt(m["blob_drift"], 2.0, "the worm rests")
	assert_lt(m["late"], maxf(m["early"], 20.0), "no jitter growing")
	assert_eq(m["inside"], 0)

func test_a_creature_resting_on_rings() -> void:
	# A blob in the dip between two rings held between two low walls (one ring alone is
	# a ball a creature rolls off, and on two it slides off one side unless it sits in
	# the dip between them: nothing has friction).
	_scene(true)
	_floor(800.0)
	_wall(Rect2(778.0, 740.0, 60.0, 60.0))
	_wall(Rect2(1082.0, 740.0, 60.0, 60.0))
	var body := rings.spawn(40.0, Vector2(900, 800.0 - 40.0))
	var other := rings.spawn(40.0, Vector2(1020, 800.0 - 40.0))
	var cr := cells.spawn(GooCellDesign.hex_blob(2, R), Transform2D(0.0, Vector2(960, 800.0 - 80.0 - 4.0 * R)))
	await _frames(60)
	var m := await _rest(body, cr, 5.0)
	print("  a 19-cell blob in the dip between two 40 px rings held between low walls, under gravity, 5 s: ring drifts %.2f px/s, worm %.2f px/s over the last 3 s; fastest particle %.1f px/s in the second second, %.1f in the last; worst overlap %.2f px; centres/beads inside %d; ring area %.2f of target, the other ring's overlap %.2f px" % [
		m["ring_drift"], m["blob_drift"], m["early"], m["late"], m["worst"], m["inside"], body.area() / body.target_area, _overlap(other, cr)])
	print("    in the last second: fastest bead %.1f px/s, fastest cell %.1f px/s" % [m["late_bead"], m["late_cell"]])
	assert_lt(cr.center().y, body.center().y - 30.0, "the blob stays on top")
	assert_lt(m["ring_drift"], 2.0, "the ring rests")
	assert_lt(m["blob_drift"], 2.0, "the blob rests")
	assert_lt(m["late"], maxf(m["early"], 20.0), "no jitter growing")
	assert_eq(m["inside"], 0)

func test_resting_alone_for_reference() -> void:
	# The same bodies resting on a floor, uncoupled: how much a resting ring's beads and a
	# resting blob's cells move by themselves.
	_scene(true, false)
	_floor(800.0)
	var body := rings.spawn(40.0, Vector2(700, 760.0))
	var cr := cells.spawn(GooCellDesign.hex_blob(2, R), Transform2D(0.0, Vector2(1200, 800.0 - 5.0 * R)))
	await _frames(60)
	var m := await _rest(body, cr, 5.0)
	print("  alone on a floor, 5 s: a 40 px ring drifts %.2f px/s (settled: %s), a 19-cell blob %.2f px/s; in the last second fastest bead %.1f px/s, fastest cell %.1f px/s" % [
		m["ring_drift"], body.settled, m["blob_drift"], m["late_bead"], m["late_cell"]])

func test_rings_below_and_above_the_cells_size() -> void:
	# The smallest ring (14 px at unit 0.5) against cells of 36 px, and a ring of 80 px
	# against cells of 8 px.
	for c: Array in [[14.0, 36.0, 1], [80.0, 8.0, 4]]:
		var m := await _impact(400.0, c[0], c[1], c[2])
		_report("ring %d px, cells %d px, 400 px/s each" % [c[0], c[1]], m)
		_check_impact(m)
		await _clear()

func test_a_polygon_ring() -> void:
	for sides: int in [3, 4]:
		var m := await _impact(400.0, 40.0, R, 3, sides)
		_report("a %d-sided ring of 40 px, 400 px/s each" % sides, m)
		_check_impact(m)
		await _clear()

func test_a_worm_wrapping_round_a_ring() -> void:
	# The ring weighs 40 times its area (else the worm just carries it along).
	_scene()
	cells.body_mode = GooCellWorld2D.BodyMode.NONE
	cells.ring_density = 40.0
	var body := rings.spawn(36.0, Vector2(960, 540))
	var design := GooCellDesign.hex_worm(24, 2, R)
	var cr := cells.spawn(design, Transform2D(PI / 2, Vector2(960 + 36.0 + 3.0 * R, 540)))
	await _frames(1)
	cr.set_velocity(Vector2(-350.0, 0.0))
	var worst := 0.0
	var inside := 0
	var wrap := -INF
	for f: int in 120:
		await _frames(1)
		worst = maxf(worst, cells.coupling_stats()["worst"])
		inside = maxi(inside, _cells_inside(cr, body) + _beads_inside(body, cr))
		# Wrapped: the worm's ends past the ring's centre along its travel.
		var p := cr.positions()
		wrap = maxf(wrap, body.center().x - (p[0].x + p[p.size() - 1].x) * 0.5)
	print("  a 24 × 2 worm (lengths only, floppy) thrown broadside at 350 px/s onto a 36 px ring: worst overlap %.2f px, centres/beads inside at most %d, at the end %d; the worm's ends at most %.0f px past the ring's centre (wrapped round it), then springing back; overlap at end %.2f px; ring area %.2f of target" % [
		worst, inside, _cells_inside(cr, body) + _beads_inside(body, cr), wrap, _overlap(body, cr), body.area() / body.target_area])
	assert_eq(_cells_inside(cr, body) + _beads_inside(body, cr), 0)
	assert_gt(wrap, 36.0, "the worm's ends went round the ring")
	assert_eq(inside, 0, "never inside each other")
	assert_lt(_overlap(body, cr), 2.0 * GooTuning.unit)

func test_a_settled_ring_is_woken() -> void:
	_scene(true)
	_floor(800.0)
	var body := rings.spawn(40.0, Vector2(960, 760.0))
	var frames := 0
	while not body.settled and frames < 600:
		await _frames(1)
		frames += 1
	assert_true(body.settled, "the ring settled on the floor")
	var cr := cells.spawn(GooCellDesign.hex_blob(2, R), Transform2D(0.0, Vector2(940, 600.0)))
	cr.set_velocity(Vector2(0.0, 300.0))
	var woke := -1
	var worst := 0.0
	for f: int in 120:
		await _frames(1)
		if woke < 0 and not body.settled:
			woke = f
		worst = maxf(worst, _overlap(body, cr))
	print("  a settled ring (after %d frames) hit by a falling blob: woken %d frames later, worst overlap %.2f px, ring settled again %s" % [frames, woke, worst, body.settled])
	assert_gt(woke, -1, "woken")
	assert_lt(cr.center().y, body.center().y, "the blob stays on top")
	assert_eq(_cells_inside(cr, body) + _beads_inside(body, cr), 0)

func test_uncoupled_worlds_pass_through() -> void:
	_scene(false, false)
	var body := rings.spawn(40.0, Vector2(800, 540))
	var cr := cells.spawn(GooCellDesign.hex_blob(2, R), Transform2D(0.0, Vector2(1100, 540)))
	await _frames(1)
	body.set_velocity(Vector2(300.0, 0.0))
	cr.set_velocity(Vector2(-300.0, 0.0))
	await _frames(60)
	assert_gt(body.center().x, cr.center().x + 100.0, "passed through each other")
	assert_eq(cells.coupling_stats()["on"], false)
	assert_almost_eq(body.average_velocity().x, 300.0, 1.0)

# A coupled scene of several rings and creatures, `frames` long; the state at the end.
func _replay(threads: int) -> Array:
	await _frames(1)
	_scene(true, true, threads)
	_floor(900.0)
	for k: int in 4:
		rings.spawn(30.0 + 6.0 * k, Vector2(700.0 + 150.0 * k, 400.0 + 40.0 * (k % 2)))
		cells.spawn(GooCellDesign.hex_blob(2, R), Transform2D(0.3 * k, Vector2(760.0 + 150.0 * k, 650.0)))
	await _frames(150)
	var out: Array = [cells.cells().state_hash()]
	for b: Goo2D in rings.bodies():
		out.append(b.bead_points())
	return out

func test_replay_and_threads() -> void:
	var a := await _replay(1)
	await _clear()
	var b := await _replay(1)
	await _clear()
	var c := await _replay(4)
	assert_eq(a, b, "a replay is identical")
	assert_eq(a, c, "threaded == serial")

func test_small_fast_cells_do_not_tunnel_into_a_ring() -> void:
	# A lone cell and a 7-cell blob of 6 px cells shot at a 60 px ring at up to 2400 px/s
	# (the cells' speed cap at unit 0.5 is 3000): no centre ever inside the ring.
	for c: Array in [[0, 1200.0], [0, 2400.0], [1, 2400.0]]:
		_scene()
		var body := rings.spawn(60.0, Vector2(960, 540))
		var cr := cells.spawn(GooCellDesign.hex_blob(c[0], 6.0), Transform2D(0.0, Vector2(1200, 545)))
		await _frames(1)
		cr.set_velocity(Vector2(-c[1], 0.0))
		var inside := 0
		var worst := 0.0
		for f: int in 30:
			await _frames(1)
			inside = maxi(inside, _cells_inside(cr, body))
			worst = maxf(worst, cells.coupling_stats()["worst"])
		print("  %d cell(s) of 6 px at %d px/s into a 60 px ring: centres inside at most %d, worst overlap found %.1f px, blob v (%.0f, %.0f), ring v (%.0f, %.0f)" % [
			cr.cell_count(), c[1], inside, worst, cr.velocity().x, cr.velocity().y, body.average_velocity().x, body.average_velocity().y])
		assert_eq(inside, 0)
		await _clear()

func test_coupled_from_the_ring_world_and_let_go() -> void:
	_scene(false, false)
	rings.couple(cells)
	assert_eq(cells.coupled_world(), rings)
	assert_gt(cells.process_physics_priority, rings.process_physics_priority, "the cells step after the rings")
	var body := rings.spawn(40.0, Vector2(800, 540))
	var cr := cells.spawn(GooCellDesign.hex_blob(2, R), Transform2D(0.0, Vector2(1000, 540)))
	await _frames(1)
	body.set_velocity(Vector2(300.0, 0.0))
	await _frames(40)
	assert_lt(body.center().x, cr.center().x, "they met and did not pass")
	# The ring world freed: the cells uncouple and go on alone.
	rings.queue_free()
	await _frames(3)
	assert_null(cells.coupled_world())
	assert_eq(cells.coupling_stats()["on"], false)
	cells.uncouple()
	assert_eq(cr.cell_count(), 19)
