extends TestCase
## GooCellWorld2D (docs/cells.md) at the game's unit (0.5: cells 14 px), stepped by hand
## (its physics processing off): spawning and the handle's queries, walls mirrored from
## the scene (concave, moving) with no tunnelling at the speed cap, water per cell (a
## current drifted with, a shear turning a creature), shape-matched regions joined by
## bendable joints, the break test leaving out the creature's own share, joins through the
## join layers and may_join(), splits, cells added and removed, grabs, determinism
## (threaded == serial, a replay identical) and the skins' mesh. Prints what it measures.

const DELTA: float = 1.0 / 60.0
const R: float = 14.0

class VetoWorld extends GooCellWorld2D:
	var asked: int = 0
	func may_join(a: GooCellCreature, _uid_a: int, _b: GooCellCreature, _uid_b: int) -> bool:
		asked += 1
		return a.data.get("joins", true)

func before_each() -> void:
	GooTuning.unit = 0.5

func after_each() -> void:
	GooTuning.unit = 1.0

func _world(threads: int = 1) -> GooCellWorld2D:
	var w := GooCellWorld2D.new()
	w.gravity_scale = 0.0
	w.threads = threads
	add_child(w)
	w.set_physics_process(false)
	return w

func _steps(w: GooCellWorld2D, frames: int) -> void:
	for f: int in frames:
		w.step(DELTA)

func _wall(points: PackedVector2Array, at: Vector2 = Vector2.ZERO, moving: bool = false) -> StaticBody2D:
	var body: StaticBody2D = AnimatableBody2D.new() if moving else StaticBody2D.new()
	if moving:
		(body as AnimatableBody2D).sync_to_physics = false
	body.collision_layer = GooTuning.LAYER_WALLS
	body.position = at
	var poly := CollisionPolygon2D.new()
	poly.polygon = points
	body.add_child(poly)
	add_child(body)
	return body

static func _box(size: Vector2) -> PackedVector2Array:
	return PackedVector2Array([Vector2.ZERO, Vector2(size.x, 0), size, Vector2(0, size.y)])

func test_spawn_and_queries() -> void:
	var w := _world()
	var spawned: Array = []
	w.creature_spawned.connect(func(c: GooCellCreature) -> void: spawned.append(c))
	var design := GooCellDesign.hex_blob(3, R)
	var cr := w.spawn(design, Transform2D(PI / 2, Vector2(400, 300)))
	assert_eq(spawned.size(), 1)
	assert_true(cr.is_alive())
	assert_eq(cr.cell_count(), 37)
	assert_lt(cr.center().distance_to(Vector2(400, 300)), 0.01)
	assert_lt(cr.heading().distance_to(Vector2.DOWN), 1e-4, "forward turned with the spawn")
	assert_almost_eq(cr.mass(), 37 * PI * R * R, 1.0)
	assert_eq(w.creature_at(Vector2(400, 300)), cr)
	assert_null(w.creature_at(Vector2(900, 300)))
	assert_eq(cr.cell_type(0), w.default_type)
	assert_eq(w.creatures().size(), 1)
	var gone: Array = []
	w.creature_despawned.connect(func(c: GooCellCreature) -> void: gone.append(c))
	w.despawn(cr)
	assert_eq(gone, [cr])
	assert_false(cr.is_alive())
	assert_eq(w.creatures().size(), 0)

func test_concave_walls_from_the_scene() -> void:
	# A U-shaped (concave) wall: GooStatics splits it into convex pieces for the cells.
	_wall(PackedVector2Array([Vector2(0, 0), Vector2(40, 0), Vector2(40, 300), Vector2(260, 300), Vector2(260, 0), Vector2(300, 0), Vector2(300, 340), Vector2(0, 340)]), Vector2(300, 200))
	var w := _world()
	var cr := w.spawn(GooCellDesign.hex_blob(2, R), Transform2D(0, Vector2(450, 120)))
	cr.push(Vector2(0, 900))
	var worst := 0.0
	for f: int in 180:
		w.step(DELTA)
		worst = maxf(worst, w.cells().health()[6])
	print("    a 19-cell blob pushed into a U wall (%d convex pieces) for 3 s: deepest wall overlap %.2f px, centre y %.0f" % [w.wall_count(), worst, cr.center().y])
	assert_gt(w.wall_count(), 1)
	assert_lt(worst, 1.0)
	assert_gt(cr.center().y, 400.0, "it went down into the U")
	assert_lt(cr.center().y, 500.0 - R)

func test_a_moving_wall_pushes() -> void:
	var wall := _wall(_box(Vector2(40, 400)), Vector2(100, 100), true)
	var w := _world()
	var cr := w.spawn(GooCellDesign.hex_blob(2, R), Transform2D(0, Vector2(300, 300)))
	_steps(w, 2)
	var worst := 0.0
	for f: int in 120:
		wall.position.x += 4.0
		w.step(DELTA)
		worst = maxf(worst, w.cells().health()[6])
	print("    a wall moving 240 px/s into a resting blob: centre x 300 -> %.0f, deepest overlap %.2f px" % [cr.center().x, worst])
	assert_gt(cr.center().x, 500.0)
	assert_lt(worst, 2.5)

func test_no_tunnelling_at_the_speed_cap() -> void:
	# A 4 px wall and a concave V's seam, fired at from every side at the cap.
	_wall(_box(Vector2(4, 600)), Vector2(600, 0))
	_wall(PackedVector2Array([Vector2(0, 0), Vector2(200, 160), Vector2(400, 0), Vector2(400, 20), Vector2(200, 190), Vector2(0, 20)]), Vector2(400, 700))
	var w := _world()
	var cap := GooCellWorld2D.MAX_SPEED * GooTuning.unit
	var crossed := 0
	var shots := 0
	for k: int in 9:
		var angle := -0.8 + 0.2 * k
		var cr := w.spawn(GooCellDesign.hex_blob(1, R), Transform2D(0, Vector2(400, 300)))
		cr.set_velocity(Vector2.from_angle(angle) * cap)
		var v := w.spawn(GooCellDesign.hex_blob(1, R), Transform2D(0, Vector2(600 + 0.0 * k, 500)))
		v.set_velocity(Vector2.from_angle(PI / 2 + angle * 0.5) * cap)
		_steps(w, 20)
		shots += 2
		for p: Vector2 in cr.positions():
			if p.x > 602.0:
				crossed += 1
		for p: Vector2 in v.positions():
			if p.y > 900.0:
				crossed += 1
		w.clear()
	print("    %d shots at %.0f px/s into a 4 px wall and a concave V's seam: %d cells through" % [shots, cap, crossed])
	assert_eq(crossed, 0)

func test_a_current_carries_a_creature_at_its_speed() -> void:
	var w := _world()
	var cr := w.spawn(GooCellDesign.hex_blob(3, R), Transform2D(0, Vector2(0, 0)))
	w.water_source = func(points: PackedVector2Array) -> PackedVector2Array: return PackedVector2Array([Vector2(60, 0)])
	var speeds := PackedFloat32Array()
	for k: int in 8:
		var x0 := cr.center().x
		_steps(w, 60)
		speeds.append(cr.center().x - x0)
	var speed := speeds[speeds.size() - 1]
	print("    a 37-cell blob in a uniform 60 px/s current (water_source), each second's speed (drag on the outline only): %s px/s" % str(speeds))
	assert_almost_eq(speed, 60.0, 3.0)

func test_a_shear_turns_a_creature() -> void:
	var w := _world()
	# Upright, so the shear runs across its long sides.
	var cr := w.spawn(GooCellDesign.hex_worm(12, 3, R), Transform2D(PI / 2, Vector2.ZERO))
	var k := 0.5
	# Water moving right below the creature's centre line and left above it (on screen):
	# a counter-clockwise shear.
	w.water_source = func(points: PackedVector2Array) -> PackedVector2Array:
		var out := PackedVector2Array()
		out.resize(points.size())
		for i: int in points.size():
			out[i] = Vector2(k * points[i].y, 0)
		return out
	_steps(w, 120)
	print("    a 12 × 3 worm in a shear of %.2f /s (water per cell): turned %.2f rad in 2 s, spinning %.3f rad/s (vorticity / 2 = %.3f)" % [k, cr.turn(), cr.spin(), -k / 2.0])
	assert_lt(cr.turn(), -0.2, "turned counter-clockwise")
	assert_lt(absf(cr.center().x), 5.0, "the centre line's water is still")

func _segmented_worm(segments: int, type: GooCellType) -> GooCellDesign:
	# A worm 5 wide, its segments of 4 columns each a group of their own.
	var d := GooCellDesign.new()
	d.types = [type]
	var long := 4 * segments
	for row: int in 5:
		var y := (row - 2) * 2.0 * R * 0.8660254
		var shift := R if row % 2 == 1 else 0.0
		for k: int in long:
			d.add_cell(Vector2((k - (long - 1) * 0.5) * 2.0 * R + shift, y), R, 0, k / 4)
	return d

func _fit_angle(cr: GooCellCreature, design: GooCellDesign, group: int) -> float:
	# The best-fit turn of one group's cells against the design.
	var p := cr.positions()
	var c := Vector2.ZERO
	var q := Vector2.ZERO
	var n := 0
	for i: int in design.cell_count():
		if design.group_of(i) == group:
			c += p[i]
			q += design.positions[i]
			n += 1
	c /= n
	q /= n
	var sc := 0.0
	var ss := 0.0
	for i: int in design.cell_count():
		if design.group_of(i) == group:
			var a := design.positions[i] - q
			var b := p[i] - c
			sc += a.dot(b)
			ss += a.cross(b)
	return atan2(ss, sc)

func test_shape_regions_and_joints() -> void:
	var w := _world()
	var body := GooCellType.new()
	body.body = GooCellType.Body.SHAPE
	var d := _segmented_worm(3, body)
	var cr := w.spawn(d, Transform2D(0, Vector2.ZERO))
	_steps(w, 1)
	var regions := {}
	for r: int in w.cells().regions(cr.id):
		regions[r] = true
	var joints := w.cells().joints(cr.id)
	var bends := w.cells().link_bends(cr.id)
	var bending := 0
	for b: int in bends:
		bending += b
	print("    a worm of three shape-matched segments: %d regions, %d joints, %d of %d links bending (the joints')" % [regions.size(), joints.size() / 5, bending, bends.size()])
	assert_eq(regions.size(), 3)
	assert_eq(joints.size() / 5, 2)
	assert_eq(bending, joints[4] + joints[9])
	cr.set_joint_angle(body, 0, body, 1, 0.5)
	cr.set_joint_angle(body, 1, body, 2, -0.5)
	_steps(w, 120)
	var a0 := _fit_angle(cr, d, 0)
	var a1 := _fit_angle(cr, d, 1)
	var a2 := _fit_angle(cr, d, 2)
	print("    joints set to +0.5 and -0.5 rad: segments turned %.2f, %.2f, %.2f rad (relative %.2f, %.2f)" % [a0, a1, a2, a1 - a0, a2 - a1])
	assert_almost_eq(a1 - a0, 0.5, 0.12)
	assert_almost_eq(a2 - a1, -0.5, 0.12)
	cr.set_joint_angle(body, 0, body, 1, 0.0)
	cr.set_joint_angle(body, 1, body, 2, 0.0)
	_steps(w, 120)
	assert_almost_eq(_fit_angle(cr, d, 1) - _fit_angle(cr, d, 0), 0.0, 0.05)

func test_link_bodies_bend_every_link() -> void:
	var w := _world()
	var t := GooCellType.new()
	t.body = GooCellType.Body.LINKS
	var d := GooCellDesign.hex_blob(2, R)
	d.types = [t]
	var cr := w.spawn(d)
	_steps(w, 1)
	var bends := w.cells().link_bends(cr.id)
	var shaped := w.cells().shape_matched(cr.id)
	assert_eq(Array(bends).count(1), bends.size())
	assert_eq(Array(shaped).count(1), 0)

func _crash_loads(break_force: float, own_share: bool) -> Array:
	# A swimming 24 × 5 worm alone, and two 91-cell blobs meeting at 600 px/s each; links
	# with oriented bending (their muscles load them hardest).
	var w := _world()
	w.body_mode = GooCellWorld2D.BodyMode.LINKS
	w.break_force = break_force
	w.break_leaves_out_own_share = own_share
	var parted: Array = [0, 0]
	var worm := w.spawn(GooCellDesign.hex_worm(24, 5, R), Transform2D(0, Vector2(0, -600)))
	var a := w.spawn(GooCellDesign.hex_blob(5, R), Transform2D(0, Vector2(-160, 600)))
	var b := w.spawn(GooCellDesign.hex_blob(5, R), Transform2D(0, Vector2(160, 600)))
	w.cells_parted.connect(func(c: GooCellCreature, _x: int, _y: int) -> void: parted[0 if c == worm else 1] += 1)
	worm.set_pose_wave(1.0, worm.design.length(), 1.0)
	_steps(w, 240)
	a.set_velocity(Vector2(600, 0))
	b.set_velocity(Vector2(-600, 0))
	_steps(w, 60)
	return parted

func test_the_break_leaves_out_the_creatures_own_share() -> void:
	var with := _crash_loads(1.5e8, true)
	var without := _crash_loads(1.5e8, false)
	print("    break force 1.5e8, links parted (swimming worm, crash at 600 px/s each): own share left out %s, counted %s" % [str(with), str(without)])
	assert_eq(with[0], 0, "the swimmer keeps its links")
	assert_gt(with[1], 0, "the crash breaks links")
	assert_gt(without[0], 0, "counted, the swimmer's own muscles break it")

func test_joins_through_layers_and_may_join() -> void:
	var w := VetoWorld.new()
	w.gravity_scale = 0.0
	add_child(w)
	w.set_physics_process(false)
	var shy := GooCellType.new()
	shy.join_layer = 2
	shy.join_mask = 2
	var d := GooCellDesign.hex_blob(1, R)
	var plain := w.spawn(d, Transform2D(0, Vector2(0, 0)))
	var other := w.spawn(d, Transform2D(0, Vector2(6 * R + 1.0, 0)))
	var shy_design := GooCellDesign.hex_blob(1, R)
	shy_design.types = [shy]
	var third := w.spawn(shy_design, Transform2D(0, Vector2(-6 * R - 1.0, 0)))
	plain.data["joins"] = false
	other.data["joins"] = false
	assert_eq(w.retopology(), 0, "vetoed")
	assert_gt(w.asked, 0)
	plain.data["joins"] = true
	other.data["joins"] = true
	var joined: Array = []
	var merged: Array = []
	w.cells_joined.connect(func(c: GooCellCreature, x: int, y: int) -> void: joined.append([c, x, y]))
	w.creatures_merged.connect(func(into: GooCellCreature, from: GooCellCreature) -> void: merged.append([into, from]))
	var made := w.retopology()
	print("    three blobs side by side, the third's layers apart: %d links made, %d merges" % [made, merged.size()])
	assert_gt(made, 0)
	assert_eq(joined.size(), made)
	assert_eq(merged.size(), 1)
	assert_eq(merged[0][0], plain)
	assert_eq(merged[0][1], other)
	assert_false(other.is_alive())
	assert_true(third.is_alive(), "its join layers kept it apart")
	assert_eq(plain.cell_count(), 14)

func test_requested_retopology_after_the_step() -> void:
	var w := _world()
	var d := GooCellDesign.hex_blob(1, R)
	var a := w.spawn(d, Transform2D(0, Vector2(0, 0)))
	var b := w.spawn(d, Transform2D(0, Vector2(6 * R + 1.0, 0)))
	w.request_retopology()
	assert_true(b.is_alive())
	w.step(DELTA)
	assert_false(b.is_alive())
	assert_eq(a.cell_count(), 14)

func test_a_split_makes_a_new_creature() -> void:
	var w := _world()
	w.break_force = 2.0e5
	var cr := w.spawn(GooCellDesign.hex_worm(12, 1, R))
	cr.data["name"] = "file"
	var splits: Array = []
	var parted := [0]
	w.creature_split.connect(func(p: GooCellCreature, c: GooCellCreature) -> void: splits.append([p, c]))
	w.cells_parted.connect(func(_c: GooCellCreature, _x: int, _y: int) -> void: parted[0] += 1)
	cr.set_cell_force(0, Vector2(-4.0e6, 0))
	cr.set_cell_force(11, Vector2(4.0e6, 0))
	_steps(w, 30)
	print("    a single file pulled apart by script forces: %d links parted, %d splits" % [parted[0], splits.size()])
	assert_gt(parted[0], 0)
	assert_gt(splits.size(), 0)
	assert_eq(splits[0][0], cr)
	var child: GooCellCreature = splits[0][1]
	assert_true(child.is_alive())
	assert_eq(child.data.get("name"), "file", "a part keeps its parent's data")
	var total := 0
	for c: GooCellCreature in w.creatures():
		total += c.cell_count()
	assert_eq(total, 12)

func test_cells_added_and_removed() -> void:
	var w := _world()
	var cr := w.spawn(GooCellDesign.hex_worm(9, 1, R))
	var end := cr.cell_position(8)
	var uid := cr.add_cell(end + Vector2(2 * R, 0), R)
	assert_eq(cr.cell_count(), 10)
	assert_eq(cr.cell_index(uid), 9)
	_steps(w, 40)
	var splits: Array = []
	w.creature_split.connect(func(p: GooCellCreature, c: GooCellCreature) -> void: splits.append(c))
	cr.remove_cell(cr.uids()[4])
	assert_eq(splits.size(), 1)
	assert_eq(cr.cell_count() + splits[0].cell_count(), 9)

func test_grab_pulls_a_creature() -> void:
	var w := _world()
	var cr := w.spawn(GooCellDesign.hex_blob(3, R), Transform2D(0, Vector2(0, 0)))
	var g := w.grab(cr, Vector2(0, 0))
	assert_gt(g, 0)
	w.move_grab(g, Vector2(200, 0))
	_steps(w, 120)
	print("    a 37-cell blob grabbed at its middle and pulled 200 px: centre at %.0f px after 2 s" % cr.center().x)
	assert_gt(cr.center().x, 150.0)
	w.release_grab(g)
	assert_eq(w.grab(cr, Vector2(5000, 0)), -1, "nothing there")

func _run(threads: int) -> int:
	var w := _world(threads)
	_wall(_box(Vector2(40, 800)), Vector2(700, -400))
	for k: int in 4:
		var cr := w.spawn(GooCellDesign.hex_blob(3, R), Transform2D(0, Vector2((k % 2) * 300.0, (k / 2) * 300.0)))
		cr.set_velocity(Vector2(300.0 if k % 2 == 0 else -300.0, 60.0 * k - 90.0))
	w.break_force = 4.0e7
	var worm := w.spawn(GooCellDesign.hex_worm(12, 3, R), Transform2D(0, Vector2(150, -300)))
	worm.set_pose_wave(1.0, 340.0, 1.0)
	for f: int in 150:
		w.step(DELTA)
		if f == 50:
			w.retopology()
	var h := w.cells().state_hash()
	w.queue_free()
	return h

func test_threaded_equals_serial_and_a_replay() -> void:
	var a := _run(1)
	var b := _run(4)
	var c := _run(1)
	assert_eq(a, b, "threaded == serial")
	assert_eq(a, c, "a replay")

func test_the_skin_mesh() -> void:
	var w := _world()
	w.skin_mesh = GooCellWorld2D.SkinMesh.FLAT
	var spine := GooCellType.new()
	spine.color = Color.CORNFLOWER_BLUE
	var d := GooCellDesign.hex_worm(10, 3, R)
	d.types = [null, spine]
	for i: int in d.cell_count():
		if absf(d.positions[i].y) < 1.0:
			d.cell_types[i] = 1
	var cr := w.spawn(d, Transform2D(0, Vector2(300, 300)))
	w.step(DELTA)
	var m: Array = w.cells().meshes_all(true)
	var points: PackedVector2Array = m[0]
	var lines: PackedVector2Array = m[3]
	var indices: PackedInt32Array = m[5]
	var p := cr.positions()
	var r := cr.radii()
	var worst := -INF
	for v: Vector2 in points:
		var best := INF
		for i: int in p.size():
			best = minf(best, v.distance_to(p[i]) - r[i])
		worst = maxf(worst, best)
	var blue := 0
	for col: Color in (m[1] as PackedColorArray):
		if col.is_equal_approx(Color.CORNFLOWER_BLUE):
			blue += 1
	print("    a 10 × 3 worm with a blue spine: %d triangles over %d vertices, %d border segments, every vertex within %.2f px of a cell's disc (the notches bridged), %d blue vertices" % [indices.size() / 3, points.size(), lines.size() / 2, maxf(worst, 0.0), blue])
	assert_eq(indices.size() % 3, 0)
	assert_gt(indices.size(), 3 * 30)
	for i: int in indices:
		assert_true(i >= 0 and i < points.size(), "an index out of range")
		if i < 0 or i >= points.size():
			break
	assert_gt(lines.size(), 0)
	# The skin bridges the notch between two touching outline discs (√2 − 1 of a radius
	# beyond them at a flat edge) and never reaches further.
	assert_lt(worst, 0.43 * R)
	assert_gt(blue, 0)
	assert_eq(w.draw_stats["vertices"], points.size())
	assert_eq(w.draw_stats["triangles"], indices.size() / 3)
