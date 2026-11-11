extends TestCase
## Blobs dropped into the Arena: small blobs rebound visibly and higher than big
## ones, and beads touching a wall grip it (GooTuning.WALL_GRIP_DAMP, applied
## by the kernel) and let go once they leave it.

const DROP_HEIGHT: float = 500.0
const WATCH_SECONDS: float = 1.5
## Sideways acceleration, in px/s², that presses a blob against the wall.
const PRESS: float = 300.0

# Builds a fresh Arena with a Blobs container under a new root added to the test.
func _make_world() -> Node2D:
	var root := Node2D.new()
	var arena := (load("res://scenes/arena.tscn") as PackedScene).instantiate() as Arena
	root.add_child(arena)
	var blobs := Node2D.new()
	blobs.name = "Blobs"
	root.add_child(blobs)
	add_child(root)
	return root

# Lowest point of any bead's collision circle.
func _lowest_y(blob: Goo2D) -> float:
	var lowest := -INF
	for point: Vector2 in blob.bead_points():
		lowest = maxf(lowest, point.y + blob.bead_radius())
	return lowest

# Drops a blob of `radius` from DROP_HEIGHT above the floor and returns how far
# its centre rises after first touching the floor.
func _rebound(radius: float) -> float:
	var root := _make_world()
	var start := Vector2((Arena.INNER_LEFT + Arena.INNER_RIGHT) / 2.0, Arena.FLOOR_Y - radius - DROP_HEIGHT)
	var blob: Goo2D = Goo2D.make(radius, start, root.get_node("Blobs"))
	var contact_y := NAN
	var highest := INF
	var watched := 0.0
	var step := 1.0 / Engine.physics_ticks_per_second
	var elapsed := 0.0
	while watched < WATCH_SECONDS and elapsed < 4.0:
		await get_tree().physics_frame
		elapsed += step
		var centre_y := blob.center().y
		if is_nan(contact_y):
			if _lowest_y(blob) >= Arena.FLOOR_Y - 2.0:
				contact_y = centre_y
				highest = centre_y
		else:
			highest = minf(highest, centre_y)
			watched += step
	root.free()
	assert_false(is_nan(contact_y), "radius %.1f blob never reached the floor" % radius)
	return contact_y - highest

func test_arena_material_matches_constants() -> void:
	var arena := (load("res://scenes/arena.tscn") as PackedScene).instantiate() as Arena
	add_child(arena)
	var material := arena.physics_material_override
	assert_not_null(material, "the arena needs a PhysicsMaterial")
	assert_almost_eq(material.friction, Arena.WALL_FRICTION, 0.0001, "wall friction")
	assert_almost_eq(material.bounce, Arena.WALL_BOUNCE, 0.0001, "wall bounce")

func test_small_blobs_rebound_higher_than_big_ones() -> void:
	timeout_sec = 20.0
	var small := await _rebound(GooTuning.MIN_RADIUS)
	var big := await _rebound(GooTuning.MAX_RADIUS)
	print("    rebound from %d px: radius %.0f %.1f px, radius %.0f %.1f px"
		% [DROP_HEIGHT, GooTuning.MIN_RADIUS, small, GooTuning.MAX_RADIUS, big])
	# (40 px when the beads were Rapier bodies, which bounced each bead off the
	# floor with the joints solved in the same velocity pass.)
	# The kernel's contacts are position constraints: the bottom beads' bounce
	# is taken back by the skin within a substep, and the ring rebounds on its
	# pressure alone, 15-20 px for the smallest (more for 40-60 px blobs, 25-35).
	assert_gt(small, 12.0, "the smallest blob should visibly bounce")
	assert_gt(small, big, "the smallest blob should bounce higher than the largest")

func test_beads_touching_a_wall_grip_it() -> void:
	var root := _make_world()
	var radius := GooTuning.MIN_RADIUS
	var start := Vector2(Arena.INNER_LEFT + radius + 1.0, Arena.FLOOR_Y - radius)
	var blob: Goo2D = Goo2D.make(radius, start, root.get_node("Blobs"))
	# Pressed against the wall, as by its neighbours in a pile: a round blob left
	# to settle beside a wall rolls or bounces off it (a pressure ring's
	# flattening pushes it away within a few frames).
	var per_particle := blob.body_mass() / blob.particle_count()
	var step := 1.0 / Engine.physics_ticks_per_second
	for frame: int in int(0.5 * Engine.physics_ticks_per_second):
		blob.apply_impulse(Vector2(-PRESS, 0.0) * per_particle * step)
		await get_tree().physics_frame
	var gripping := 0
	var gripping_wall := 0
	for i: int in blob.particle_count():
		var point := blob.bead_position(i)
		var near_wall := point.x - blob.bead_radius() <= Arena.INNER_LEFT + 2.0
		var near_floor := point.y + blob.bead_radius() >= Arena.FLOOR_Y - 2.0
		if blob.bead_gripping(i):
			gripping += 1
			if near_wall:
				gripping_wall += 1
			assert_true(near_wall or near_floor, "a gripping bead %s is at the wall or the floor" % point)
	print("    %d of %d particles gripping the arena, %d of them at the wall"
		% [gripping, blob.particle_count(), gripping_wall])
	assert_gt(gripping_wall, 0, "a blob pressed against the wall should grip it")
	# Thrown off the wall and the floor, every particle lets go within a few frames.
	blob.set_velocity(Vector2(300.0, -900.0))
	await wait_frames(8)
	for i: int in blob.particle_count():
		assert_false(blob.bead_gripping(i), "a bead in the air grips nothing")
	blob.free()
	await wait_frames(2)
	root.free()
	await wait_frames(2)
