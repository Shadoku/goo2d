extends TestCase
## Both bridges at once: a cell world coupled to a ring world (GooCellWorld2D.couple(),
## docs/cells.md "Rings and cells") with physics_proxies and push_bodies on in both
## (docs/godot-physics.md), in real physics frames at unit 0.5 and zero gravity: a ring, a
## creature and a RigidBody2D crate thrown at one point together. Nothing ends inside
## anything else (cell centres in the ring, beads in the creature, either in the crate), no
## error is printed, the momentum of the three is kept once the ring world's
## body_mass_scale weighs the ring as the coupling does (left at 1 it is not: printed), a
## replay is identical, the crate is
## excepted from both worlds' proxies and the proxies of the two worlds never meet in
## Godot's server; an Area2D on the proxies' layer sees the ring and the creature. Prints what
## it measures.

const PROXY := GooTuning.LAYER_PROXIES
const WALLS := GooTuning.LAYER_WALLS
const CENTRE := Vector2(640, 400)
const SPEED := 150.0

var rings: GooWorld2D
var cells: GooCellWorld2D

func before_each() -> void:
	GooTuning.unit = 0.5

func after_each() -> void:
	GooTuning.unit = 1.0

## Rings that never merge and lose no momentum of their own.
class Rings extends GooWorld2D:
	func may_merge(_a: Goo2D, _b: Goo2D) -> bool:
		return false
	func tuning_for(shape: GooShape, tags: Array = []) -> Dictionary:
		var t := super(shape, tags)
		t["linear_damp"] = 0.0
		return t

func _frames(n: int) -> void:
	for _f: int in n:
		await get_tree().physics_frame

func _scene() -> void:
	rings = Rings.new()
	rings.gravity_scale = 0.0
	rings.physics_proxies = true
	rings.push_bodies = true
	add_child(rings)
	rings.kernel().set_solver({"base_damp": 0.0})
	cells = GooCellWorld2D.new()
	cells.gravity_scale = 0.0
	cells.drag_enabled = false
	cells.threads = 1
	cells.physics_proxies = true
	cells.push_bodies = true
	add_child(cells)
	cells.couple(rings)

func _crate(size: float, at: Vector2, mass: float) -> RigidBody2D:
	var crate := RigidBody2D.new()
	crate.collision_layer = WALLS
	crate.collision_mask = WALLS | PROXY
	crate.gravity_scale = 0.0
	crate.linear_damp_mode = RigidBody2D.DAMP_MODE_REPLACE
	crate.angular_damp_mode = RigidBody2D.DAMP_MODE_REPLACE
	crate.mass = mass
	crate.position = at
	var shape := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = Vector2(size, size)
	shape.shape = rect
	crate.add_child(shape)
	add_child(crate)
	return crate

static func _cells_inside_ring(cr: GooCellCreature, body: Goo2D) -> int:
	var loop := body.bead_points()
	var n := 0
	for p: Vector2 in cr.positions():
		if Geometry2D.is_point_in_polygon(p, loop):
			n += 1
	return n

static func _beads_inside_creature(body: Goo2D, cr: GooCellCreature) -> int:
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

# How far any of `points` (each of radius `radii[i]`, or radii[0] for all) reaches into the
# box of half size `half` on `crate`: > 0 an overlap, px.
static func _into_crate(points: PackedVector2Array, radii: PackedFloat32Array, crate: Node2D, half: float) -> float:
	var worst := -INF
	var inv := crate.global_transform.affine_inverse()
	for i: int in points.size():
		var q := inv * points[i]
		var r := radii[i] if radii.size() > 1 else radii[0]
		worst = maxf(worst, r - (maxf(absf(q.x), absf(q.y)) - half))
	return worst

# Centres strictly inside the crate's box.
static func _centres_in_crate(points: PackedVector2Array, crate: Node2D, half: float) -> int:
	var inv := crate.global_transform.affine_inverse()
	var n := 0
	for p: Vector2 in points:
		var q := inv * p
		if absf(q.x) < half and absf(q.y) < half:
			n += 1
	return n

func _momentum(body: Goo2D, cr: GooCellCreature, crate: RigidBody2D) -> Vector2:
	return body.average_velocity() * body.target_area * cells.ring_density + cr.velocity() * cr.mass() + crate.linear_velocity * crate.mass

# The three thrown together; returns what was measured and the final state.
func _throw(frames: int = 150, match_masses: bool = true, ring_v: float = SPEED, cell_v: float = SPEED, crate_v: float = SPEED, ring_x: float = -90.0, cell_x: float = 90.0) -> Dictionary:
	_scene()
	var radius := 24.0
	var half := 16.0
	var body := rings.spawn(radius, CENTRE + Vector2(ring_x, 0))
	var cr := cells.spawn(GooCellDesign.hex_blob(2, 7.0), Transform2D(0.0, CENTRE + Vector2(cell_x, 0)))
	# The ring world pushes the crate with its kernel's bead masses, the coupling weighs
	# the ring as its area × ring_density in the cells' units: one body_mass_scale on the
	# ring world makes the three agree for this ring (body mass per area depends on size).
	if match_masses:
		rings.body_mass_scale = body.body_mass() / (body.target_area * cells.ring_density) * cells.body_mass_scale
	var crate_mass := cr.mass() * 0.5
	var crate := _crate(2.0 * half, CENTRE + Vector2(0, -90), crate_mass)
	var area := Area2D.new()
	area.collision_mask = PROXY
	area.position = CENTRE
	var ashape := CollisionShape2D.new()
	var circle := CircleShape2D.new()
	circle.radius = 12.0
	ashape.shape = circle
	area.add_child(ashape)
	add_child(area)
	var seen := {"ring": 0, "creature": 0, "other": 0}
	area.body_entered.connect(func(b: Node2D) -> void:
		if rings.body_of(b) != null:
			seen["ring"] += 1
		elif cells.creature_of(b) != null:
			seen["creature"] += 1
		else:
			seen["other"] += 1)
	await _frames(2)
	body.set_velocity(Vector2(ring_v, 0.0))
	cr.set_velocity(Vector2(-cell_v, 0.0))
	crate.linear_velocity = Vector2(0.0, crate_v)
	await _frames(1)
	var p0 := _momentum(body, cr, crate)
	var m := {"cells_in_ring": 0, "beads_in_creature": 0, "centres_in_crate": 0, "ring_into_crate": -INF, "cells_into_crate": -INF, "touched_crate_ring": false, "touched_crate_cells": false}
	var br := PackedFloat32Array([body.bead_radius()])
	for f: int in frames:
		await get_tree().physics_frame
		m["cells_in_ring"] = maxi(m["cells_in_ring"], _cells_inside_ring(cr, body))
		m["beads_in_creature"] = maxi(m["beads_in_creature"], _beads_inside_creature(body, cr))
		m["centres_in_crate"] = maxi(m["centres_in_crate"], _centres_in_crate(body.bead_points(), crate, half) + _centres_in_crate(cr.positions(), crate, half))
		var ro := _into_crate(body.bead_points(), br, crate, half)
		var co := _into_crate(cr.positions(), cr.radii(), crate, half)
		m["ring_into_crate"] = maxf(m["ring_into_crate"], ro)
		m["cells_into_crate"] = maxf(m["cells_into_crate"], co)
		m["touched_crate_ring"] = m["touched_crate_ring"] or ro > -1.0
		m["touched_crate_cells"] = m["touched_crate_cells"] or co > -1.0
	var p1 := _momentum(body, cr, crate)
	m["p0"] = p0
	m["p1"] = p1
	m["final_ring_into_crate"] = _into_crate(body.bead_points(), br, crate, half)
	m["final_cells_into_crate"] = _into_crate(cr.positions(), cr.radii(), crate, half)
	m["final_cells_in_ring"] = _cells_inside_ring(cr, body)
	m["final_beads_in_creature"] = _beads_inside_creature(body, cr)
	m["seen"] = seen.duplicate()
	m["excepted_rings"] = rings.proxies().excepted().has(crate.get_rid())
	m["excepted_cells"] = cells.proxies().excepted().has(crate.get_rid())
	# The two worlds' proxies in Godot's server: kinematic, and neither detects the other.
	var ring_rid := rings.proxies().rid_of(body.get_instance_id())
	var cell_rid := cells.proxies().rid_of(cr.id)
	m["proxy_masks"] = [PhysicsServer2D.body_get_collision_mask(ring_rid), PhysicsServer2D.body_get_collision_mask(cell_rid)]
	m["proxy_modes"] = [PhysicsServer2D.body_get_mode(ring_rid), PhysicsServer2D.body_get_mode(cell_rid)]
	m["state"] = [body.bead_points(), cr.positions(), crate.global_transform, crate.linear_velocity]
	m["speeds"] = [body.average_velocity(), cr.velocity(), crate.linear_velocity]
	area.queue_free()
	crate.queue_free()
	rings.queue_free()
	cells.queue_free()
	await _frames(2)
	return m

func test_a_ring_a_creature_and_a_crate_thrown_together() -> void:
	var m := await _throw()
	var p0: Vector2 = m["p0"]
	var p1: Vector2 = m["p1"]
	print("cells in the ring (worst frame) %d, beads in the creature %d, centres in the crate %d; deepest into the crate: ring beads %.2f px, cells %.2f px (final %.2f, %.2f); touched the crate: ring %s, creature %s" % [
		m["cells_in_ring"], m["beads_in_creature"], m["centres_in_crate"], m["ring_into_crate"], m["cells_into_crate"], m["final_ring_into_crate"], m["final_cells_into_crate"], m["touched_crate_ring"], m["touched_crate_cells"]])
	print("speeds after: ring %s, creature %s, crate %s px/s; momentum %s -> %s (%.2f%% change)" % [m["speeds"][0], m["speeds"][1], m["speeds"][2], p0, p1, 100.0 * (p1 - p0).length() / p0.length()])
	print("area saw %s; crate excepted from the ring proxies %s, the cell proxies %s; proxy masks %s, modes %s (kinematic %d)" % [m["seen"], m["excepted_rings"], m["excepted_cells"], m["proxy_masks"], m["proxy_modes"], PhysicsServer2D.BODY_MODE_KINEMATIC])
	assert_true(m["touched_crate_ring"] and m["touched_crate_cells"], "the crate met the ring and the creature")
	assert_lt((p1 - p0).length(), 0.02 * p0.length(), "the three's momentum kept within 2% (the ring world's body_mass_scale matched)")
	assert_eq(m["cells_in_ring"], 0, "no cell centre in the ring at any frame")
	assert_eq(m["beads_in_creature"], 0, "no bead in the creature at any frame")
	assert_eq(m["centres_in_crate"], 0, "no bead or cell centre in the crate at any frame")
	var bead_r := 0.5 * 7.0
	assert_lt(m["final_ring_into_crate"], 0.5 * bead_r, "the ring ends outside the crate")
	assert_lt(m["final_cells_into_crate"], 0.5 * 7.0, "the creature ends outside the crate")
	assert_eq(m["final_cells_in_ring"], 0)
	assert_eq(m["final_beads_in_creature"], 0)
	assert_eq(m["seen"]["ring"], 1, "the area saw the ring once")
	assert_eq(m["seen"]["creature"], 1, "the area saw the creature once")
	assert_eq(m["seen"]["other"], 0)
	assert_true(m["excepted_rings"], "the crate excepted from the ring world's proxies")
	assert_true(m["excepted_cells"], "the crate excepted from the cell world's proxies")
	assert_eq(m["proxy_masks"], [0, 0], "the proxies detect nothing, so they never meet each other")
	assert_eq(m["proxy_modes"], [PhysicsServer2D.BODY_MODE_KINEMATIC, PhysicsServer2D.BODY_MODE_KINEMATIC])

# Left at body_mass_scale 1, the ring world weighs the ring by its kernel's bead masses
# against the crate (here about 1/180 of what the coupling weighs it): the crate then barely
# notices the ring, and the momentum in the coupling's units is not kept.
func test_unmatched_ring_masses_for_reference() -> void:
	var m := await _throw(150, false)
	var p0: Vector2 = m["p0"]
	var p1: Vector2 = m["p1"]
	print("ring world body_mass_scale 1: momentum %s -> %s (%.0f%% change); speeds after: ring %s, creature %s, crate %s; cells in the ring %d, beads in the creature %d, centres in the crate %d" % [
		p0, p1, 100.0 * (p1 - p0).length() / p0.length(), m["speeds"][0], m["speeds"][1], m["speeds"][2], m["cells_in_ring"], m["beads_in_creature"], m["centres_in_crate"]])
	assert_eq(m["cells_in_ring"], 0)
	assert_eq(m["beads_in_creature"], 0)
	assert_eq(m["centres_in_crate"], 0)

func test_a_replay_is_identical() -> void:
	var a := await _throw(90)
	var b := await _throw(90)
	var same: bool = a["state"] == b["state"]
	print("replay identical: %s (crate %s vs %s)" % [same, a["state"][2], b["state"][2]])
	assert_true(same, "the same throw twice ends in the same state")

