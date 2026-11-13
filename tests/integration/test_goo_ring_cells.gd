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
	var body := StaticBody2D.new()
	body.collision_layer = GooTuning.LAYER_WALLS
	var poly := CollisionPolygon2D.new()
	poly.polygon = PackedVector2Array([Vector2(x0, y), Vector2(x1, y), Vector2(x1, y + 60), Vector2(x0, y + 60)])
	body.add_child(poly)
	add_child(body)

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
		rings.queue_free()
		cells.queue_free()
		await _frames(1)

func test_impacts_at_unit_one() -> void:
	GooTuning.unit = 1.0
	for speed: float in [300.0, 600.0]:
		var m := await _impact(speed, 80.0, 2.0 * R)
		_report("unit 1, %d px/s each, ring 80 px, cells 28 px" % speed, m)
		_check_impact(m)
		rings.queue_free()
		cells.queue_free()
		await _frames(1)
