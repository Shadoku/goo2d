extends TestCase
## Creatures of cells (GooCellWorld2D) and Godot's physics (docs/godot-physics.md), at
## unit 0.5 and 1 where sizes matter, in real physics frames (Godot's server steps between
## the goo's steps): the proxies (an Area2D's body_entered and body_exited, a ray and a
## shape query resolving to the creature, a hull, a CharacterBody2D stopped by a resting
## creature), and Godot bodies pushing the cells (a rigid crate thrown at a creature:
## momentum before and after; a pushed creature pushing a crate along; a crate resting on
## a creature under gravity; an AnimatableBody2D sweeping through a creature at 300 px/s
## leaving no cell behind it). Prints what it measures.

const PROXY := GooTuning.LAYER_PROXIES
const WALLS := GooTuning.LAYER_WALLS

func after_each() -> void:
	GooTuning.unit = 1.0

func _world(gravity: float = 0.0) -> GooCellWorld2D:
	var w := GooCellWorld2D.new()
	w.gravity_scale = gravity
	w.drag_enabled = false
	w.physics_proxies = true
	add_child(w)
	return w

func _frames(n: int) -> void:
	for f: int in n:
		await get_tree().physics_frame

func _box_shape(size: Vector2) -> CollisionShape2D:
	var shape := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = size
	shape.shape = rect
	return shape

func _floor(y: float) -> StaticBody2D:
	var floor := StaticBody2D.new()
	floor.collision_layer = WALLS
	floor.position = Vector2(640, y + 50)
	floor.add_child(_box_shape(Vector2(3000, 100)))
	add_child(floor)
	return floor

func _crate(size: float, at: Vector2, mass: float) -> RigidBody2D:
	var crate := RigidBody2D.new()
	crate.collision_layer = WALLS
	crate.collision_mask = WALLS | PROXY
	crate.gravity_scale = 0.0
	crate.linear_damp_mode = RigidBody2D.DAMP_MODE_REPLACE
	crate.angular_damp_mode = RigidBody2D.DAMP_MODE_REPLACE
	crate.mass = mass
	crate.position = at
	crate.add_child(_box_shape(Vector2(size, size)))
	add_child(crate)
	return crate

# How far the cells of `creature` reach into the box of half size `half` centred on
# `crate` (turned with it): > 0 is an overlap, in px.
static func _overlap(creature: GooCellCreature, crate: Node2D, half: float) -> float:
	var worst := -INF
	var inv := crate.global_transform.affine_inverse()
	var radii := creature.radii()
	var points := creature.positions()
	for i: int in points.size():
		var q := inv * points[i]
		worst = maxf(worst, radii[i] - (maxf(absf(q.x), absf(q.y)) - half))
	return worst

static func _momentum(creature: GooCellCreature) -> Vector2:
	return creature.velocity() * creature.mass()

func test_an_area_ray_and_query_meet_a_drifting_creature() -> void:
	for unit: float in [0.5, 1.0]:
		GooTuning.unit = unit
		var w := _world()
		var r := 7.0 * unit / 0.5
		var cr := w.spawn(GooCellDesign.hex_blob(2, r), Transform2D(0, Vector2(200, 300)))
		var area := Area2D.new()
		area.collision_mask = PROXY
		area.position = Vector2(500, 300)
		area.add_child(_box_shape(Vector2(30, 30) * unit / 0.5))
		add_child(area)
		var log: Array = []
		area.body_entered.connect(func(b: Node2D) -> void: log.append(["in", b]))
		area.body_exited.connect(func(b: Node2D) -> void: log.append(["out", b]))
		await _frames(2)
		cr.set_velocity(Vector2(300, 0) * unit)
		var hit := {}
		var shape_hits: Array = []
		for f: int in 240:
			await get_tree().physics_frame
			if f == 30:
				var space := w.get_world_2d().direct_space_state
				var c := cr.center()
				hit = space.intersect_ray(PhysicsRayQueryParameters2D.create(c + Vector2(0, -8 * r), c, PROXY))
				var query := PhysicsShapeQueryParameters2D.new()
				var circle := CircleShape2D.new()
				circle.radius = r
				query.shape = circle
				query.transform = Transform2D(0, c + Vector2(0, -4 * r))
				query.collision_mask = PROXY
				shape_hits = space.intersect_shape(query)
		print("unit %.1f: area events %s, ray hit %s at %s, shape query hits %d, proxy circles %d of %d cells" % [unit, str(log.map(func(e: Array) -> String: return e[0])), hit.get("collider"), hit.get("position"), shape_hits.size(), w.proxies().shape_count(cr.id), cr.cell_count()])
		assert_eq(log.size(), 2, "entered once and exited once")
		if log.size() == 2:
			assert_eq(log[0][0], "in")
			assert_eq(w.creature_of(log[0][1]), cr, "the area's body resolves to the creature")
			assert_eq(log[1][0], "out")
		assert_false(hit.is_empty(), "the ray hits the creature")
		assert_eq(w.creature_of(hit.get("collider")), cr)
		assert_eq(hit.get("collider"), cr.proxy_node())
		assert_gt(shape_hits.size(), 0)
		if not shape_hits.is_empty():
			assert_eq(w.creature_of(shape_hits[0]["collider"]), cr)
		assert_eq(w.proxies().shape_count(cr.id), cr.outline().size(), "a circle per boundary cell")
		area.queue_free()
		w.queue_free()
		await _frames(2)

func test_the_hull_and_despawn() -> void:
	GooTuning.unit = 0.5
	var w := _world()
	w.proxy_shape = GooProxies.Shape.HULL
	var cr := w.spawn(GooCellDesign.hex_blob(2, 7.0), Transform2D(0, Vector2(300, 300)))
	await _frames(3)
	var space := w.get_world_2d().direct_space_state
	var query := PhysicsPointQueryParameters2D.new()
	query.position = cr.center()
	query.collision_mask = PROXY
	assert_eq(space.intersect_point(query).size(), 1, "the centre is in the hull")
	assert_eq(w.proxies().shape_count(cr.id), 1)
	w.despawn(cr)
	await _frames(2)
	assert_eq(w.proxies().count(), 0, "the proxy goes with its creature")
	assert_eq(space.intersect_point(query).size(), 0)
	assert_null(w.creature_of(null))

func test_a_character_is_stopped_by_a_resting_creature() -> void:
	for unit: float in [0.5, 1.0]:
		GooTuning.unit = unit
		var floor_y := 500.0
		var floor := _floor(floor_y)
		var w := _world(1.0)
		var r := 7.0 * unit / 0.5
		var cr := w.spawn(GooCellDesign.hex_blob(2, r), Transform2D(0, Vector2(600, floor_y - 5.0 * r)))
		await _frames(120)
		var character := CharacterBody2D.new()
		character.collision_mask = WALLS | PROXY
		var half := Vector2(10, 20) * unit
		character.add_child(_box_shape(half * 2.0))
		character.position = Vector2(400, floor_y - half.y - 1.0)
		add_child(character)
		var hit := false
		var g := GooTuning.gravity()
		for f: int in 180:
			await get_tree().physics_frame
			character.velocity.x = 200.0 * unit
			character.velocity.y += g * get_physics_process_delta_time()
			character.move_and_slide()
			for k: int in character.get_slide_collision_count():
				if w.creature_of(character.get_slide_collision(k).get_collider()) == cr:
					hit = true
		var deepest := -INF
		var inv := character.global_transform.affine_inverse()
		var radii := cr.radii()
		var points := cr.positions()
		for i: int in points.size():
			var q := (inv * points[i]).abs()
			var outside := Vector2(maxf(q.x - half.x, 0.0), maxf(q.y - half.y, 0.0))
			var d := outside.length() if outside != Vector2.ZERO else -minf(half.x - q.x, half.y - q.y)
			deepest = maxf(deepest, radii[i] - d)
		print("unit %.1f: character at x %.1f, deepest cell overlap with it %.2f px, creature centre moved %.2f px, character x velocity %.1f, collided %s" % [unit, character.position.x, deepest, cr.center().x - 600.0, character.velocity.x, hit])
		assert_true(hit, "get_slide_collision names the creature's proxy")
		assert_lt(deepest, 1.0 * unit, "not inside the creature")
		assert_lt(character.position.x, cr.center().x - 2.0 * r, "stopped before the creature's middle")
		character.queue_free()
		floor.queue_free()
		w.queue_free()
		await _frames(2)

func test_a_thrown_crate_and_a_creature_exchange_momentum() -> void:
	for unit: float in [0.5, 1.0]:
		GooTuning.unit = unit
		var w := _world()
		w.push_bodies = true
		var r := 7.0 * unit / 0.5
		var cr := w.spawn(GooCellDesign.hex_blob(3, r), Transform2D(0, Vector2(600, 300)))
		await _frames(2)
		var size := 40.0 * unit
		var crate := _crate(size, Vector2(400, 300), cr.mass())
		crate.linear_velocity = Vector2(300, 0) * unit
		await _frames(1)
		var p0 := crate.linear_velocity * crate.mass + _momentum(cr)
		var worst := -INF
		var p1 := p0
		var touched := false
		var over_at := -1
		for f: int in 120:
			await get_tree().physics_frame
			worst = maxf(worst, _overlap(cr, crate, size / 2.0))
			var j := w.cells().static_impulses()
			var pushing := j.size() >= 4 and Vector2(j[1], j[2]).length() > 0.0
			touched = touched or pushing
			if touched and not pushing and over_at < 0:
				over_at = f
				p1 = crate.linear_velocity * crate.mass + _momentum(cr)
		var excepted := w.proxies().excepted().has(crate.get_rid())
		print("unit %.1f: crate %.1f -> %.1f px/s, creature 0 -> %s px/s, momentum %s -> %s after the contact (%.2f%%; frame %d), deepest overlap %.2f px, excepted from the proxies %s" % [unit, 300.0 * unit, crate.linear_velocity.x, cr.velocity(), p0, p1, 100.0 * (p1 - p0).length() / p0.length(), over_at, worst, excepted])
		assert_lt(crate.linear_velocity.x, 0.8 * 300.0 * unit, "the crate slowed")
		assert_gt(cr.velocity().x, 0.2 * 300.0 * unit, "the creature was pushed")
		assert_gt(over_at, 0, "the contact ended")
		assert_lt((p1 - p0).length(), 0.05 * p0.length(), "momentum kept within 5%")
		assert_lt(worst, 0.5 * r, "neither ends inside the other")
		assert_true(excepted)
		crate.queue_free()
		w.queue_free()
		await _frames(2)

func test_a_pushed_creature_pushes_a_crate_along() -> void:
	GooTuning.unit = 0.5
	var w := _world()
	w.push_bodies = true
	w.drag_enabled = true
	var cr := w.spawn(GooCellDesign.hex_worm(12, 3, 7.0), Transform2D(0, Vector2(300, 300)))
	await _frames(2)
	var crate := _crate(30.0, Vector2(420, 300), 0.5 * cr.mass())
	crate.linear_damp = 2.0
	var x0 := crate.position.x
	for f: int in 180:
		cr.push(Vector2(200, 0))
		await get_tree().physics_frame
	var ahead := crate.position.x - 15.0 - cr.positions()[0].x
	print("crate moved %.1f px in 3 s (now %.1f px/s), creature at %.1f px/s, worst overlap %.2f px" % [crate.position.x - x0, crate.linear_velocity.x, cr.velocity().x, _overlap(cr, crate, 15.0)])
	assert_gt(crate.position.x - x0, 100.0, "pushed along")
	assert_lt(_overlap(cr, crate, 15.0), 3.5, "not inside it")

func test_a_crate_rests_on_a_creature() -> void:
	for unit: float in [0.5, 1.0]:
		GooTuning.unit = unit
		var floor_y := 500.0
		var floor := _floor(floor_y)
		var w := _world(1.0)
		w.push_bodies = true
		var r := 7.0 * unit / 0.5
		var cr := w.spawn(GooCellDesign.hex_blob(3, r), Transform2D(0, Vector2(600, floor_y - 6.3 * r)))
		await _frames(60)
		var top := INF
		for p: Vector2 in cr.positions():
			top = minf(top, p.y - r)
		var size := 30.0 * unit / 0.5
		var crate := _crate(size, Vector2(600, top - size / 2.0 - 1.0), 0.5 * cr.mass())
		crate.gravity_scale = GooTuning.gravity() / float(ProjectSettings.get_setting("physics/2d/default_gravity", 980.0))
		await _frames(60)
		var low := INF
		var high := -INF
		var last_low := INF
		var last_high := -INF
		var x0 := crate.position.x
		for f: int in 300:
			await get_tree().physics_frame
			low = minf(low, crate.position.y)
			high = maxf(high, crate.position.y)
			if f >= 240:
				last_low = minf(last_low, crate.position.y)
				last_high = maxf(last_high, crate.position.y)
		print("unit %.1f: crate y %.2f .. %.2f over the 5 s from 1 s after landing (%.2f px), %.3f px in the last second, drift x %.2f px, turn %.3f rad; creature top %.1f, centre drift %.2f px" % [unit, low, high, high - low, last_high - last_low, crate.position.x - x0, crate.rotation, top, cr.center().x - 600.0])
		assert_lt(high, top + 4.0 * r, "held up by the creature")
		assert_lt(high - low, 4.0 * unit, "under 4 px at unit 1 over the 5 s")
		assert_lt(last_high - last_low, 1.0 * unit, "under 1 px at unit 1 in the last second")
		assert_lt(absf(crate.rotation), 0.1)
		crate.queue_free()
		floor.queue_free()
		w.queue_free()
		await _frames(2)

func test_an_animatable_body_sweeps_through_a_creature() -> void:
	for unit: float in [0.5, 1.0]:
		for push: bool in [true, false]:
			GooTuning.unit = unit
			var w := _world()
			w.push_bodies = push
			var r := 7.0 * unit / 0.5
			var cr := w.spawn(GooCellDesign.hex_blob(3, r), Transform2D(0, Vector2(500, 300)))
			var bar := AnimatableBody2D.new()
			bar.sync_to_physics = false
			bar.collision_layer = WALLS
			var width := 6.0 * unit
			bar.add_child(_box_shape(Vector2(width, 400)))
			bar.position = Vector2(500 - 12.0 * r, 300)
			add_child(bar)
			await _frames(2)
			var speed := 300.0 * unit
			var behind_max := 0
			var behind := 0
			for f: int in 90:
				bar.position.x += speed / 60.0
				await get_tree().physics_frame
				behind = 0
				for p: Vector2 in cr.positions():
					if p.x < bar.position.x:
						behind += 1
				behind_max = maxi(behind_max, behind)
			print("unit %.1f push_bodies %s: bar at %.1f moving %.0f px/s, cells behind it at the end %d (most at once %d) of %d, creature at %.1f px/s" % [unit, push, bar.position.x, speed, behind, behind_max, cr.cell_count(), cr.velocity().x])
			if push:
				assert_eq(behind_max, 0, "no cell left behind")
				assert_gt(cr.velocity().x, 0.5 * speed, "carried along")
			bar.queue_free()
			w.queue_free()
			await _frames(2)
