extends TestCase
## Ring bodies (Goo2D in a GooWorld2D) and Godot's physics (docs/godot-physics.md), at
## unit 0.5 and 1 where sizes matter, in real physics frames (Godot's server steps between
## the goo's steps): the proxies (an Area2D's body_entered and body_exited, a ray and a
## shape query resolving to the body, a CharacterBody2D stopped by a resting blob), and
## Godot bodies pushing the goo (a rigid crate thrown at a blob: momentum before and after;
## a crate resting on a blob under gravity; the crate excepted from the proxies so the pair
## is solved once). Prints what it measures.

const PROXY := GooTuning.LAYER_PROXIES
const WALLS := GooTuning.LAYER_WALLS

func after_each() -> void:
	GooTuning.unit = 1.0

func _world(gravity: float = 0.0) -> GooWorld2D:
	var w := GooWorld2D.new()
	w.gravity_scale = gravity
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

# How far bead circles of `body` reach into the box of half size `half` centred on
# `crate` (turned with it): > 0 is an overlap, in px.
static func _overlap(body: Goo2D, crate: Node2D, half: float) -> float:
	var worst := -INF
	var inv := crate.global_transform.affine_inverse()
	for p: Vector2 in body.bead_points():
		var q := inv * p
		var d := maxf(absf(q.x), absf(q.y)) - half
		worst = maxf(worst, body.bead_radius() - d)
	return worst

func test_an_area_ray_and_query_meet_a_drifting_blob() -> void:
	for unit: float in [0.5, 1.0]:
		GooTuning.unit = unit
		var w := _world()
		var r := 40.0 * unit
		var blob := w.spawn(r, Vector2(200, 300))
		var area := Area2D.new()
		area.collision_mask = PROXY
		area.position = Vector2(500, 300)
		area.add_child(_box_shape(Vector2(60, 60) * unit))
		add_child(area)
		var log: Array = []
		area.body_entered.connect(func(b: Node2D) -> void: log.append(["in", b, Engine.get_physics_frames()]))
		area.body_exited.connect(func(b: Node2D) -> void: log.append(["out", b, Engine.get_physics_frames()]))
		await _frames(2)
		blob.set_velocity(Vector2(300, 0) * unit)
		var hit := {}
		var shape_hits: Array = []
		for f: int in 240:
			await get_tree().physics_frame
			if blob.average_velocity().length() < 200.0 * unit:
				blob.set_velocity(Vector2(300, 0) * unit)
			if f == 30:
				var space := w.get_world_2d().direct_space_state
				var c := blob.center()
				var ray := PhysicsRayQueryParameters2D.create(c + Vector2(0, -3 * r), c, PROXY)
				hit = space.intersect_ray(ray)
				var query := PhysicsShapeQueryParameters2D.new()
				var circle := CircleShape2D.new()
				circle.radius = r * 0.5
				query.shape = circle
				query.transform = Transform2D(0, c + Vector2(0, -r))
				query.collision_mask = PROXY
				shape_hits = space.intersect_shape(query)
		print("unit %.1f: area events %s, ray hit %s at %s, shape query hits %d" % [unit, str(log.map(func(e: Array) -> String: return "%s@%d" % [e[0], e[2]])), hit.get("collider"), hit.get("position"), shape_hits.size()])
		assert_eq(log.size(), 2, "entered once and exited once")
		if log.size() == 2:
			assert_eq(log[0][0], "in")
			assert_eq(log[0][1], blob, "the area names the Goo2D")
			assert_eq(log[1][0], "out")
		assert_false(hit.is_empty(), "the ray hits the blob")
		assert_eq(w.body_of(hit.get("collider")), blob)
		assert_gt(shape_hits.size(), 0)
		if not shape_hits.is_empty():
			assert_eq(w.body_of(shape_hits[0]["collider"]), blob)
		assert_lt(hit.get("position", Vector2.ZERO).y, blob.center().y - 0.5 * r, "hit on the rim")
		area.queue_free()
		w.queue_free()
		await _frames(2)

func test_the_hull_is_solid() -> void:
	GooTuning.unit = 0.5
	var w := _world()
	w.proxy_shape = GooProxies.Shape.HULL
	var blob := w.spawn(30.0, Vector2(300, 300))
	await _frames(3)
	var space := w.get_world_2d().direct_space_state
	var query := PhysicsPointQueryParameters2D.new()
	query.position = blob.center()
	query.collision_mask = PROXY
	var inside := space.intersect_point(query)
	assert_eq(inside.size(), 1, "a point at the centre is in the hull")
	assert_eq(w.proxies().shape_count(blob.get_instance_id()), 1)
	w.proxy_shape = GooProxies.Shape.CIRCLES
	await _frames(2)
	assert_eq(w.proxies().shape_count(blob.get_instance_id()), blob.particle_count())
	assert_eq(space.intersect_point(query).size(), 0, "circles leave the middle open")

func test_a_character_is_stopped_by_a_resting_blob() -> void:
	for unit: float in [0.5, 1.0]:
		GooTuning.unit = unit
		var floor_y := 500.0
		_floor(floor_y)
		var w := _world(1.0)
		var r := 40.0 * unit
		var blob := w.spawn(r, Vector2(600, floor_y - r))
		await _frames(120)
		var character := CharacterBody2D.new()
		character.collision_mask = WALLS | PROXY
		var half := Vector2(10, 20) * unit
		character.add_child(_box_shape(half * 2.0))
		character.position = Vector2(400, floor_y - half.y - 1.0)
		add_child(character)
		var hit_blob := false
		var g := GooTuning.gravity()
		for f: int in 180:
			await get_tree().physics_frame
			character.velocity.x = 200.0 * unit
			character.velocity.y += g * get_physics_process_delta_time()
			character.move_and_slide()
			for k: int in character.get_slide_collision_count():
				if w.body_of(character.get_slide_collision(k).get_collider()) == blob:
					hit_blob = true
		var left := INF
		for p: Vector2 in blob.bead_points():
			left = minf(left, p.x - blob.bead_radius())
		var front := character.position.x + half.x
		print("unit %.1f: character front %.1f, blob's left %.1f (gap %.2f px), character x velocity %.1f, collided with the blob %s" % [unit, front, left, left - front, character.velocity.x, hit_blob])
		assert_true(hit_blob, "get_slide_collision names the blob")
		assert_lt(front, left + 1.0 * unit, "not inside the blob")
		assert_lt(character.position.x, 600.0 - r, "stopped before the blob's centre")
		character.queue_free()
		w.queue_free()
		await _frames(2)

func test_a_thrown_crate_and_a_blob_exchange_momentum() -> void:
	for unit: float in [0.5, 1.0]:
		for proxies: bool in [false, true]:
			GooTuning.unit = unit
			var w := _world()
			w.physics_proxies = proxies
			w.push_bodies = true
			var r := 40.0 * unit
			var blob := w.spawn(r, Vector2(600, 300))
			await _frames(2)
			var size := 40.0 * unit
			var crate := _crate(size, Vector2(400, 300), blob.body_mass())
			crate.linear_velocity = Vector2(300, 0) * unit
			await _frames(1)
			var p0 := crate.linear_velocity * crate.mass + blob.average_velocity() * blob.body_mass()
			var worst := -INF
			# The momentum on the first frame the goo gave the crate no impulse after it did
			# (the contact over; the goo's own damping takes its share afterwards).
			var p1 := p0
			var touched := false
			var settled_at := -1
			for f: int in 90:
				await get_tree().physics_frame
				worst = maxf(worst, _overlap(blob, crate, size / 2.0))
				var j := w.kernel().static_impulses()
				var pushing := j.size() >= 4 and Vector2(j[1], j[2]).length() > 0.0
				touched = touched or pushing
				if touched and not pushing and settled_at < 0:
					settled_at = f
					p1 = crate.linear_velocity * crate.mass + blob.average_velocity() * blob.body_mass()
			var excepted := false
			if proxies and w.proxies().has(blob.get_instance_id()):
				excepted = w.proxies().excepted().has(crate.get_rid())
			print("unit %.1f proxies %s: crate %.1f -> %.1f px/s, blob 0 -> %s px/s, momentum %s -> %s after the contact (%.1f%%; frame %d), deepest overlap %.2f px, excepted %s" % [unit, proxies, 300.0 * unit, crate.linear_velocity.x, blob.average_velocity(), p0, p1, 100.0 * (p1 - p0).length() / p0.length(), settled_at, worst, excepted])
			assert_lt(crate.linear_velocity.x, 0.8 * 300.0 * unit, "the crate slowed")
			assert_gt(blob.average_velocity().x, 0.2 * 300.0 * unit, "the blob was pushed")
			assert_lt((p1 - p0).length(), 0.1 * p0.length(), "momentum kept within 10%")
			assert_lt(worst, 2.0 * blob.bead_radius(), "neither ends inside the other")
			assert_lt(_overlap(blob, crate, size / 2.0), 0.5, "apart at the end")
			if proxies:
				assert_true(excepted, "the pushed crate is excepted from the proxy")
			crate.queue_free()
			w.queue_free()
			await _frames(2)

func test_a_crate_rests_on_a_blob() -> void:
	# On a square blob, which does not roll, the crate must stay put; on a round one it is
	# a box balanced on a ball that rolls freely (a rola-bola): what it does is printed.
	for unit: float in [0.5, 1.0]:
		for square: bool in [true, false]:
			GooTuning.unit = unit
			var floor_y := 500.0
			var floor := _floor(floor_y)
			var w := _world(1.0)
			w.push_bodies = true
			var r := 48.0 * unit
			var blob := w.spawn(r, Vector2(600, floor_y - r), GooShape.regular(4, r) if square else null)
			await _frames(60)
			var size := 40.0 * unit
			var crate := _crate(size, Vector2(600, blob.bead_bounds().position.y - size / 2.0 - 2.0), 0.5 * blob.body_mass())
			crate.gravity_scale = GooTuning.gravity() / float(ProjectSettings.get_setting("physics/2d/default_gravity", 980.0))
			await _frames(60)
			var low := INF
			var high := -INF
			var last_low := INF
			var last_high := -INF
			var speed := 0.0
			var x0 := crate.position.x
			for f: int in 300:
				await get_tree().physics_frame
				low = minf(low, crate.position.y)
				high = maxf(high, crate.position.y)
				if f >= 240:
					last_low = minf(last_low, crate.position.y)
					last_high = maxf(last_high, crate.position.y)
					speed = maxf(speed, crate.linear_velocity.length())
			print("unit %.1f %s blob: crate y %.2f .. %.2f over the 5 s from 1 s after landing (%.2f px), %.3f px in the last second (fastest %.2f px/s), drift x %.2f px, turn %.3f rad; blob top %.1f, floor %.1f" % [unit, "square" if square else "round", low, high, high - low, last_high - last_low, speed, crate.position.x - x0, crate.rotation, blob.bead_bounds().position.y, floor_y])
			if square:
				assert_lt(high, floor_y - size / 2.0 - r, "held above the blob's middle")
				assert_lt(high - low, 8.0 * unit, "under 8 px at unit 1 over the 5 s")
				assert_lt(last_high - last_low, 1.0 * unit, "under 1 px at unit 1 in the last second")
				assert_lt(absf(crate.position.x - x0), 4.0 * unit, "does not slide")
				assert_lt(absf(crate.rotation), 0.05)
			crate.queue_free()
			floor.queue_free()
			w.queue_free()
			await _frames(2)

func test_a_character_on_the_wall_layer_pushes_a_blob() -> void:
	# With push_bodies on, a CharacterBody2D on GooTuning.LAYER_WALLS (its mask without the
	# proxies' layer) is a moving obstacle: it walks on and shoves the blob ahead of it.
	GooTuning.unit = 0.5
	var floor_y := 500.0
	var floor := _floor(floor_y)
	var w := _world(1.0)
	w.push_bodies = true
	var r := 20.0
	var blob := w.spawn(r, Vector2(500, floor_y - r))
	await _frames(60)
	var character := CharacterBody2D.new()
	character.collision_layer = WALLS
	character.collision_mask = WALLS
	var half := Vector2(10, 20)
	character.add_child(_box_shape(half * 2.0))
	character.position = Vector2(400, floor_y - half.y - 1.0)
	add_child(character)
	var x0 := blob.center().x
	var deepest := -INF
	for f: int in 120:
		await get_tree().physics_frame
		character.velocity = Vector2(100, character.velocity.y + GooTuning.gravity() * get_physics_process_delta_time())
		character.move_and_slide()
		var inv := character.global_transform.affine_inverse()
		for p: Vector2 in blob.bead_points():
			var q := (inv * p).abs()
			var outside := Vector2(maxf(q.x - half.x, 0.0), maxf(q.y - half.y, 0.0))
			var d := outside.length() if outside != Vector2.ZERO else -minf(half.x - q.x, half.y - q.y)
			deepest = maxf(deepest, blob.bead_radius() - d)
	print("character walked to %.1f, the blob moved %.1f px (now %.1f px/s), deepest bead into the character %.2f px" % [character.position.x, blob.center().x - x0, blob.average_velocity().x, deepest])
	assert_gt(blob.center().x - x0, 80.0, "shoved along")
	assert_lt(deepest, 2.0 * blob.bead_radius(), "not walked through")
	character.queue_free()
	floor.queue_free()
