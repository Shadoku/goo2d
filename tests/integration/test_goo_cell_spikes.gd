extends TestCase
## Spike tips (docs/cells.md, "Spike tips"): a cell type's tip, a small disc out along the
## cell's facing held rigidly by the cell, colliding with walls, moving obstacles, coupled
## rings and other creatures' cells and tips; the contacts' detail for damage (the other
## creature's cell and uid, which side's tip, the closing speed, the impulse, the point;
## hits()); and cells removed mid-fight. At the fluid game's unit (0.5), in real physics
## frames. Prints what it measures.

const R: float = 14.0
const BOSS_SPIN: float = 4.5

var _things: Array[Node] = []

func before_each() -> void:
	GooTuning.unit = 0.5

func after_each() -> void:
	GooTuning.unit = 1.0

func _frames(n: int) -> void:
	for _f: int in n:
		await get_tree().physics_frame

func _world() -> GooCellWorld2D:
	var w := GooCellWorld2D.new()
	w.gravity_scale = 0.0
	w.draw_skins = false
	add_child(w)
	_things.append(w)
	return w

func _clear() -> void:
	for n: Node in _things:
		if is_instance_valid(n):
			n.queue_free()
	_things.clear()
	await _frames(1)

func _wall(rect: Rect2, rotation: float = 0.0) -> StaticBody2D:
	var body := StaticBody2D.new()
	body.collision_layer = GooTuning.LAYER_WALLS
	var poly := CollisionPolygon2D.new()
	var h := rect.size * 0.5
	poly.polygon = PackedVector2Array([-h, Vector2(h.x, -h.y), h, Vector2(-h.x, h.y)])
	body.add_child(poly)
	body.position = rect.get_center()
	body.rotation = rotation
	add_child(body)
	_things.append(body)
	return body

static func spike_type(length: float = 2.0, radius: float = 0.3) -> GooCellType:
	var t := GooCellType.new()
	t.name = &"spike"
	t.color = Color(0.9, 0.85, 0.7)
	t.tip_length = length
	t.tip_radius = radius
	return t

## The boss: a 24 × 5 worm of 14 px cells (690 px) whose three frontmost cells are spikes
## facing `facing` (rad, in the design: PI/2 points down, the way a clockwise spin moves its
## head).
func _boss(facing: float) -> GooCellDesign:
	var d := GooCellDesign.hex_worm(24, 5, R)
	d.types = [GooCellType.new(), spike_type()]
	var order: Array[int] = []
	for i: int in d.cell_count():
		order.append(i)
	order.sort_custom(func(a: int, b: int) -> bool: return d.positions[a].x > d.positions[b].x)
	for k: int in 3:
		d.cell_types[order[k]] = 1
		d.angles[order[k]] = facing
	return d

## Spins the boss at BOSS_SPIN (full power) for `frames` with `probe` called after each
## frame with (worm, tips) and returning a Dictionary of what it saw; returns the fastest
## tip speed and the probe's worst values.
func _spin(w: GooCellWorld2D, centre: Vector2, frames: int, probe: Callable, facing: float = PI / 2.0) -> Dictionary:
	var worm := w.spawn(_boss(facing), Transform2D(0.0, centre))
	worm.set_contact_tracking(true)
	worm.set_spin_servo(BOSS_SPIN, 60.0)
	var out := {"fastest": 0.0, "hit_speed": 0.0, "worm": worm}
	var last := PackedVector2Array()
	for f: int in frames:
		await _frames(1)
		var tips := worm.tips()
		var at: PackedVector2Array = tips["positions"]
		if last.size() == at.size():
			for k: int in at.size():
				out["fastest"] = maxf(out["fastest"], at[k].distance_to(last[k]) * 60.0)
		last = at
		for h: Dictionary in worm.hits(200.0):
			if h["tip"]:
				out["hit_speed"] = maxf(out["hit_speed"], h["speed"])
		var seen: Dictionary = probe.call(worm, tips)
		for k: String in seen:
			out[k] = maxf(out.get(k, -INF), seen[k])
	return out

## The boss's reach: its farthest cell's edge from its centre at spawn.
func _reach() -> float:
	var d := _boss(0.0)
	var reach := 0.0
	for i: int in d.cell_count():
		reach = maxf(reach, d.positions[i].length() + R)
	return reach

func test_a_spiked_creature_stops_short_of_a_wall_by_its_tips() -> void:
	var w := _world()
	_wall(Rect2(900, 0, 60, 1000))
	# A block 6 × 7 of 7 px cells, its front column spikes; its heading held by the spin
	# servo (a creature pushed onto a wall by spikes ahead of its centre is an inverted
	# pendulum: a game steers it).
	var d := GooCellDesign.hex_worm(6, 7, 7.0)
	d.types = [GooCellType.new(), spike_type(2.0, 0.3)]
	var front := -INF
	for p: Vector2 in d.positions:
		front = maxf(front, p.x)
	for i: int in d.cell_count():
		if d.positions[i].x > front - 8.0:
			d.cell_types[i] = 1
	var blob := w.spawn(d, Transform2D(0.0, Vector2(700, 500)))
	blob.set_contact_tracking(true)
	blob.set_spin_servo(0.0, 50.0)
	blob.push(Vector2(300, 0))
	await _frames(240)
	var nearest := INF
	var r := blob.radii()
	var p := blob.positions()
	for i: int in p.size():
		nearest = minf(nearest, 900.0 - (p[i].x + r[i]))
	var tips := blob.tips()
	var tip_gap := INF
	for k: int in (tips["positions"] as PackedVector2Array).size():
		tip_gap = minf(tip_gap, 900.0 - (tips["positions"][k].x + tips["radii"][k]))
	var tip_contacts := 0
	for c: Dictionary in blob.contacts():
		if c["kind"] == GooCellCreature.Touch.WALL and c["tip"]:
			tip_contacts += 1
	print("    a 6 × 7 block (7 px) pushed at a wall at 150 px/s², its front column spikes (tip 2 radii out, 0.3 wide), heading held: its cells stop %.1f px short (the tips' reach %.1f px), the tips %.2f px from the wall, %d tip contacts" % [nearest, (2.0 + 0.3 - 1.0) * 7.0, tip_gap, tip_contacts])
	assert_gt(nearest, 0.6 * (2.0 + 0.3 - 1.0) * 7.0, "held off by its tips")
	assert_lt(absf(tip_gap), 1.0)
	assert_gt(tip_contacts, 0)
	await _clear()

func test_a_spinning_boss_worms_spikes_do_not_pass_a_thin_wall() -> void:
	var w := _world()
	var c := Vector2(960, 300)
	var reach := _reach()
	# The spikes face outward (along the worm), so their tips reach past the body; a radial
	# bar 4 px thick straight below the centre, just past the body's reach: only the tips
	# meet it, side on, at the spin's speed.
	var bar := Rect2(c.x - 2.0, c.y + reach + 1.0, 4.0, 80.0)
	_wall(bar)
	# Passed through: a tip from the bar's right to its left within one frame, both ends
	# alongside the bar (not round its ends).
	var last := {}
	var got := await _spin(w, c, 120, func(worm: GooCellCreature, tips: Dictionary) -> Dictionary:
		var deepest := -INF
		var passed := 0.0
		for k: int in (tips["positions"] as PackedVector2Array).size():
			var q: Vector2 = tips["positions"][k]
			var rt: float = tips["radii"][k]
			var along := func(p: Vector2) -> bool: return p.y > bar.position.y + rt and p.y < bar.end.y - rt
			if along.call(q):
				deepest = maxf(deepest, rt - absf(q.x - c.x) + 2.0)
				var p: Vector2 = last.get(k, q)
				if along.call(p) and p.x > bar.end.x and q.x < bar.position.x:
					passed = 1.0
			last[k] = q
		return {"deepest": deepest, "passed": passed}, 0.0)
	print("    the boss worm spun at %.1f rad/s (full power): tips up to %.0f px/s, hitting a 4 px bar at %.0f px/s; deepest a tip got into the bar %.2f px; passed %s" % [BOSS_SPIN, got["fastest"], got["hit_speed"], maxf(0.0, got.get("deepest", 0.0)), got.get("passed", 0.0) > 0.0])
	assert_gt(got["fastest"], 1400.0)
	assert_gt(got["hit_speed"], 1000.0)
	assert_eq(got.get("passed", 0.0), 0.0)
	assert_lt(got.get("deepest", 0.0), 3.0)
	await _clear()

func test_a_spinning_boss_worms_spikes_meet_another_creature_and_report_it() -> void:
	var w := _world()
	var c := Vector2(960, 300)
	var reach := _reach()
	var target := w.spawn(GooCellDesign.hex_blob(3, R), Transform2D(0.0, c + Vector2(0, reach + 4.0 * R)))
	target.set_contact_tracking(true)
	var details := {}
	var got := await _spin(w, c, 120, func(worm: GooCellCreature, tips: Dictionary) -> Dictionary:
		var pts := target.positions()
		var outline := PackedVector2Array()
		for i: int in target.outline():
			outline.append(pts[i])
		var inside := 0.0
		var deepest := -INF
		var rr := target.radii()
		for k: int in (tips["positions"] as PackedVector2Array).size():
			var q: Vector2 = tips["positions"][k]
			if Geometry2D.is_point_in_polygon(q, outline):
				inside += 1.0
			for i: int in pts.size():
				deepest = maxf(deepest, tips["radii"][k] + rr[i] - q.distance_to(pts[i]))
		for h: Dictionary in worm.hits(300.0):
			if h["tip"] and h["kind"] == GooCellCreature.Touch.CREATURE and not details.has("worm"):
				details["worm"] = h
		for h: Dictionary in target.contacts():
			if h["other_tip"] and not details.has("target"):
				details["target"] = h
		return {"inside": inside, "deepest": deepest})
	var hw: Dictionary = details.get("worm", {})
	var ht: Dictionary = details.get("target", {})
	print("    the boss's spikes into a 37-cell blob of 14 px cells: tips up to %.0f px/s, hit at %.0f px/s; tips inside its outline %d frames, deepest into a cell %.2f px (cells 14 px)" % [got["fastest"], got["hit_speed"], int(got.get("inside", 0.0)), got.get("deepest", 0.0)])
	print("    the worm's first tip hit: %s" % [_brief(hw)])
	print("    the blob's record of it: %s" % [_brief(ht)])
	assert_eq(got.get("inside", 0.0), 0.0)
	assert_lt(got.get("deepest", 0.0), R)
	assert_false(hw.is_empty(), "the worm reports a tip hit")
	assert_eq(hw["what"], target)
	assert_true(hw["other_uid"] in target.uids() or hw["other_uid"] >= 0)
	assert_gt(hw["speed"], 300.0)
	assert_gt(hw["impulse"], 0.0)
	assert_false(hw["other_tip"])
	assert_false(ht.is_empty(), "the blob records the other's tip")
	assert_eq(ht["what"], got["worm"])
	assert_false(ht["tip"])
	await _clear()

static func _brief(h: Dictionary) -> String:
	if h.is_empty():
		return "none"
	return "cell %d (uid %d), tip %s, other cell %d (uid %d), other tip %s, %.0f px/s, impulse %.0f, at %s" % [h["cell"], h["uid"], h["tip"], h["other_cell"], h["other_uid"], h["other_tip"], h["speed"], h["impulse"], h["point"]]

class NoMergeWorld extends GooWorld2D:
	func may_merge(_a: Goo2D, _b: Goo2D) -> bool:
		return false

func test_a_spinning_boss_worms_spikes_hit_a_coupled_ring_and_cut_it_there() -> void:
	var rings := NoMergeWorld.new()
	rings.gravity_scale = 0.0
	add_child(rings)
	_things.append(rings)
	var w := _world()
	w.couple(rings)
	var c := Vector2(960, 300)
	var reach := _reach()
	var ring := rings.spawn(28.0, c + Vector2(0, reach + 10.0))
	var splits := [0]
	rings.body_split.connect(func(_id: int, _pieces: Array) -> void: splits[0] += 1)
	var cut := [false]
	var hit := {}
	var got := await _spin(w, c, 90, func(worm: GooCellCreature, tips: Dictionary) -> Dictionary:
		var inside := 0.0
		for body: Goo2D in rings.bodies():
			var loop := body.bead_points()
			for q: Vector2 in tips["positions"]:
				if Geometry2D.is_point_in_polygon(q, loop):
					inside += 1.0
		if not cut[0]:
			for h: Dictionary in worm.hits(300.0):
				if h["tip"] and h["kind"] == GooCellCreature.Touch.RING and is_instance_valid(h["what"]):
					hit.merge(h)
					cut[0] = rings.cut_along(h["what"], h["point"], -h["normal"])
					break
		return {"inside": inside})
	await _frames(2)
	print("    the boss's spikes into a coupled 28 px ring: tips up to %.0f px/s, hit at %.0f px/s; tips inside a ring %d frames; the hit: %s; cut_along there %s, splits %d" % [got["fastest"], got["hit_speed"], int(got.get("inside", 0.0)), _brief(hit), cut[0], splits[0]])
	assert_false(hit.is_empty())
	assert_eq(got.get("inside", 0.0), 0.0)
	assert_true(cut[0], "the contact point is one cut_along() accepts")
	assert_gt(splits[0], 0)
	await _clear()

func test_a_spinning_boss_worms_spikes_hit_a_crate() -> void:
	var w := _world()
	w.push_bodies = true
	w.body_mass_scale = 1000.0
	var c := Vector2(960, 300)
	var reach := _reach()
	var crate := RigidBody2D.new()
	crate.collision_layer = GooTuning.LAYER_WALLS
	crate.collision_mask = GooTuning.LAYER_WALLS
	crate.gravity_scale = 0.0
	crate.mass = 10.0
	crate.position = c + Vector2(0, reach + 24.0)
	var shape := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = Vector2(60, 60)
	shape.shape = rect
	crate.add_child(shape)
	add_child(crate)
	_things.append(crate)
	var fastest := [0.0]
	var got := await _spin(w, c, 120, func(worm: GooCellCreature, tips: Dictionary) -> Dictionary:
		var deepest := -INF
		var inv := crate.global_transform.affine_inverse()
		for k: int in (tips["positions"] as PackedVector2Array).size():
			var q: Vector2 = inv * tips["positions"][k]
			var rt: float = tips["radii"][k]
			deepest = maxf(deepest, rt - maxf(absf(q.x), absf(q.y)) + 30.0)
		fastest[0] = maxf(fastest[0], crate.linear_velocity.length())
		var obstacle := 0.0
		for h: Dictionary in worm.hits(100.0):
			if h["tip"] and h["kind"] == GooCellCreature.Touch.OBSTACLE:
				obstacle = h["impulse"]
		return {"deepest": deepest, "obstacle": obstacle})
	print("    the boss's spikes into a 60 px crate (mass 10 × 1000): tips up to %.0f px/s, hit at %.0f px/s; deepest a tip got into the crate %.2f px; the crate at up to %.0f px/s; a tip's impulse on it up to %.0f" % [got["fastest"], got["hit_speed"], maxf(0.0, got["deepest"]), fastest[0], got.get("obstacle", 0.0)])
	assert_lt(got["deepest"], 4.0)
	assert_gt(got.get("obstacle", 0.0), 0.0)
	assert_gt(fastest[0], 10.0, "the tips pushed the crate")
	await _clear()

# ---- Removing cells mid-fight ----

## A victim with thrusters front and back and spikes in the middle (a 12 × 1 single file,
## 7 px cells), hit by a spiked attacker; every cell a tip hits faster than the threshold
## is removed (by its uid, as a game would).
func test_removing_cells_mid_fight_keeps_thrusters_tips_and_contacts_sound() -> void:
	var w := _world()
	var thruster := GooCellType.new()
	thruster.max_thrust = 400.0
	var spike := spike_type(1.8, 0.3)
	var victim_design := GooCellDesign.new()
	victim_design.types = [GooCellType.new(), thruster, spike]
	for k: int in 16:
		var t := 0
		if k < 3 or k > 12:
			t = 1
		elif k == 7:
			t = 2
		victim_design.add_cell(Vector2((k - 7.5) * 14.0, 0.0), 7.0, t, 0, PI / 2.0 if t == 2 else 0.0)
	var victim := w.spawn(victim_design, Transform2D(0.0, Vector2(960, 500)))
	victim.set_contact_tracking(true)
	# Its thrusters at levels told apart by uid.
	var thr := victim.thrusters()
	var by_uid := {}
	var levels := PackedFloat32Array()
	levels.resize(victim.cell_count())
	for k: int in (thr["indices"] as PackedInt32Array).size():
		var level := 0.05 * (k + 1)
		levels[thr["indices"][k]] = level
		by_uid[thr["uids"][k]] = level
	var stale := levels.duplicate()
	assert_true(victim.set_thrust_levels(levels))
	var version := victim.topology_version()
	var parts: Array[GooCellCreature] = [victim]
	w.creature_split.connect(func(_parent: GooCellCreature, child: GooCellCreature) -> void: parts.append(child))
	var attacker_design := GooCellDesign.hex_blob(2, 7.0)
	attacker_design.types = [GooCellType.new(), spike_type(2.0, 0.3)]
	for i: int in attacker_design.cell_count():
		if attacker_design.positions[i].y > 10.0:
			attacker_design.cell_types[i] = 1
			attacker_design.angles[i] = PI / 2.0
	var attacker := w.spawn(attacker_design, Transform2D(0.0, Vector2(960, 420)))
	attacker.set_contact_tracking(true)
	attacker.push(Vector2(0, 500))
	var removed: Array[int] = []
	var stale_named := 0
	var worst_inside := 0
	for f: int in 120:
		await _frames(1)
		for h: Dictionary in attacker.hits(40.0):
			if removed.has(h["other_uid"]):
				stale_named += 1
			if h["tip"] and h["what"] is GooCellCreature and h["other_uid"] >= 0 and not removed.has(h["other_uid"]):
				var cr: GooCellCreature = h["what"]
				if cr.is_alive() and cr.cell_index(h["other_uid"]) >= 0 and removed.size() < 4:
					cr.remove_cell(h["other_uid"])
					removed.append(h["other_uid"])
		var health := w.cells().health()
		worst_inside = maxi(worst_inside, int(health[1]))
		assert_eq(health[7], 0.0, "every position finite")
	print("    a spiked blob driven into a single file of 16 with thrusters at both ends: %d cells removed by the tips' hits (uids %s), %d parts, contacts naming a removed uid after its removal %d, cells inside another creature at worst %d" % [removed.size(), removed, parts.size(), stale_named, worst_inside])
	assert_gt(removed.size(), 0, "a tip hit a cell")
	assert_eq(stale_named, 0, "no contact names a removed cell")
	assert_ne(victim.topology_version(), version, "the topology changed")
	assert_false(victim.set_thrust_levels(stale), "a levels array from before the removal is refused")
	# Every surviving thruster kept its level, by uid, whichever part it is in now.
	var kept := 0
	for part: GooCellCreature in parts:
		if not part.is_alive():
			continue
		var t := part.thrusters()
		var lv := part.thrust_levels()
		for k: int in (t["uids"] as PackedInt32Array).size():
			var uid: int = t["uids"][k]
			assert_true(by_uid.has(uid))
			assert_almost_eq(lv[t["indices"][k]], by_uid[uid], 1e-6)
			kept += 1
		var tips := part.tips()
		for uid: int in tips["uids"]:
			assert_false(removed.has(uid))
	print("    thrusters kept with their levels by uid: %d of %d" % [kept, by_uid.size()])
	assert_gt(kept, 0)
	await _clear()

func test_a_split_keeps_each_parts_thrusters_and_tips() -> void:
	var w := _world()
	w.drag_enabled = false
	var thruster := GooCellType.new()
	thruster.max_thrust = 400.0
	var d := GooCellDesign.new()
	d.types = [GooCellType.new(), thruster, spike_type()]
	for k: int in 9:
		var t := 1 if k == 0 or k == 8 else (2 if k == 2 or k == 6 else 0)
		d.add_cell(Vector2((k - 4) * 14.0, 0.0), 7.0, t, 0, PI if k == 0 else (PI / 2.0 if t == 2 else 0.0))
	var worm := w.spawn(d, Transform2D(0.0, Vector2(600, 400)))
	var t := worm.thrusters()
	var levels := PackedFloat32Array()
	levels.resize(worm.cell_count())
	for i: int in t["indices"]:
		levels[i] = 1.0
	worm.set_thrust_levels(levels)
	await _frames(5)
	var parts: Array[GooCellCreature] = [worm]
	w.creature_split.connect(func(_parent: GooCellCreature, child: GooCellCreature) -> void: parts.append(child))
	worm.remove_cell(worm.uids()[4])
	assert_eq(parts.size(), 2, "split in two")
	var v0 := [parts[0].velocity(), parts[1].velocity()]
	await _frames(30)
	for k: int in 2:
		var p := parts[k]
		var th := p.thrusters()
		assert_eq((th["indices"] as PackedInt32Array).size(), 1, "each part kept its thruster")
		assert_almost_eq(p.thrust_levels()[th["indices"][0]], 1.0, 1e-6)
		assert_eq((p.tips()["indices"] as PackedInt32Array).size(), 1, "and its spike")
	print("    a single file of 9 split in the middle: the parts thrust apart at %.1f and %.1f px/s after 0.5 s (from %.1f, %.1f)" % [parts[0].velocity().x, parts[1].velocity().x, v0[0].x, v0[1].x])
	# The head's thruster faces back (PI), the tail's forward: they push apart.
	assert_lt(parts[0].velocity().x * parts[1].velocity().x, 0.0)
	await _clear()
