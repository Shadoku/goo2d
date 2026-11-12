extends TestCase
## Every Goo2D's Skin carries the goo shader (GooSkin): spawned, merged and split
## blobs alike, its uniforms following the ring each frame, while set_tint() /
## get_tint() still drive the skin colour the shader tints with. Split pieces
## keep the bubbles that were in their part of the ring, and a merged ring keeps
## the bigger parent's. A ring folded through itself sets skin polygons
## Polygon2D can draw, one per loop of the fold, covering every bead. A
## settled ring's skin comes to rest (its smoothed
## velocity at exactly zero) and is not rebuilt until the ring wakes.

const SKIN_SHADER := "res://addons/goo2d/goo.gdshader"

func _world() -> Node2D:
	var root := Node2D.new()
	var arena := (load("res://scenes/arena.tscn") as PackedScene).instantiate() as Arena
	root.add_child(arena)
	var blobs := Node2D.new()
	blobs.name = "Blobs"
	root.add_child(blobs)
	add_child(root)
	return root

func _goo_material(blob: Goo2D) -> ShaderMaterial:
	var skin := blob.get_node_or_null("Skin") as Polygon2D
	if skin == null:
		return null
	return skin.material as ShaderMaterial

func _assert_goo(blob: Goo2D, what: String) -> void:
	var material := _goo_material(blob)
	assert_not_null(material, "%s should carry a ShaderMaterial on its Skin" % what)
	if material != null:
		assert_eq(material.shader.resource_path, SKIN_SHADER, what)

func test_spawned_blob_skin_carries_the_goo_material() -> void:
	var root := _world()
	var radius := GooTuning.radius_at(0.3)
	var blob := Goo2D.make(radius, Vector2(360.0, 500.0), root.get_node("Blobs"))
	_assert_goo(blob, "a spawned blob")
	await wait_frames(2)
	var material := _goo_material(blob)
	if material == null:
		return
	assert_eq(material.get_shader_parameter("point_count"), blob.particle_count())
	var centre: Vector2 = material.get_shader_parameter("center")
	assert_almost_eq(centre.x, blob.center().x, 4.0)
	assert_almost_eq(centre.y, blob.center().y, 4.0)
	assert_almost_eq(material.get_shader_parameter("radius"), radius, radius * 0.05)
	var points: PackedVector2Array = material.get_shader_parameter("points")
	assert_eq(points.size(), GooSkin.MAX_POINTS)
	# The outline pushed to the shader is the collision outline: one bead
	# radius outside the bead centres, so about the blob's radius from its centre.
	assert_almost_eq(points[0].distance_to(blob.center()), radius, radius * 0.25)

func test_tint_round_trips_through_the_skin_colour() -> void:
	var root := _world()
	var blob := Goo2D.make(GooTuning.MIN_RADIUS, Vector2(360.0, 500.0), root.get_node("Blobs"))
	var tint := Color(0.2, 0.7, 0.4, 0.9)
	blob.set_tint(tint)
	assert_eq(blob.get_tint(), tint)
	assert_eq((blob.get_node("Skin") as Polygon2D).color, tint)

func test_merged_and_split_blobs_carry_the_goo_material() -> void:
	var root := _world()
	var blobs := root.get_node("Blobs")
	var radius := GooTuning.radius_at(0.2)
	var a := Goo2D.make(radius, Vector2(320.0, 500.0), blobs)
	var b := Goo2D.make(radius, Vector2(320.0 + 2.0 * radius, 500.0), blobs)
	await wait_frames(1)
	var from: Array[Goo2D] = [a, b]
	var merged := Goo2D.make_merged(GooTuning.merged_radius(radius, radius), blobs, from)
	assert_not_null(merged)
	if merged != null:
		_assert_goo(merged, "a merged blob")
	var loop := a.bead_points()
	var velocities := PackedVector2Array()
	velocities.resize(loop.size())
	var piece := Goo2D.make_from_loop(loop, velocities, blobs)
	_assert_goo(piece, "a split piece")
	await wait_frames(2)
	if merged != null and _goo_material(merged) != null:
		assert_eq(_goo_material(merged).get_shader_parameter("point_count"), merged.particle_count())
	if _goo_material(piece) != null:
		assert_eq(_goo_material(piece).get_shader_parameter("point_count"), piece.particle_count())

func test_warm_up_draws_an_invisible_goo_polygon_then_frees_it() -> void:
	var holder := Node2D.new()
	add_child(holder)
	var polygon := GooSkin.warm_up(holder)
	assert_not_null(polygon)
	if polygon == null:
		return
	assert_eq(polygon.get_parent(), holder)
	assert_eq((polygon.material as ShaderMaterial).shader.resource_path, SKIN_SHADER)
	assert_eq(polygon.color.a, 0.0, "the warm-up polygon must not show")
	assert_true(polygon.visible, "it must still be drawn, so the shader compiles")
	await wait_seconds(GooSkin.WARM_UP_SECONDS + 0.2)
	assert_false(is_instance_valid(polygon), "the warm-up polygon frees itself")

func test_main_scene_warms_up_the_goo_shader() -> void:
	var main := (load("res://scenes/main.tscn") as PackedScene).instantiate()
	add_child(main)
	await wait_frames(1)
	var warm := main.get_node_or_null("GooWarmUp") as Polygon2D
	assert_not_null(warm, "Main should draw the goo shader once at boot")

func _bubbles(blob: Goo2D) -> Dictionary:
	var material := _goo_material(blob)
	if material == null:
		return {}
	return {
		"seed": material.get_shader_parameter("seed"),
		"cell": material.get_shader_parameter("bubble_cell"),
		"origin": material.get_shader_parameter("bubble_origin"),
	}

func _assert_same_bubbles(child: Dictionary, parent: Dictionary, tolerance: float, what: String) -> void:
	assert_false(child.is_empty() or parent.is_empty(), "%s: both carry a goo material" % what)
	if child.is_empty() or parent.is_empty():
		return
	assert_eq(child["seed"], parent["seed"], "%s keeps the seed" % what)
	assert_almost_eq(float(child["cell"]), float(parent["cell"]), 1e-3, "%s keeps the bubble cell" % what)
	var gap := (child["origin"] as Vector2).distance_to(parent["origin"] as Vector2)
	print("    %s: bubble origin %.3f px from the parent's" % [what, gap])
	assert_lt(gap, tolerance, "%s's bubble origin coincides with the parent's" % what)

func test_split_pieces_keep_the_parent_bubbles() -> void:
	timeout_sec = 10.0
	var main := (load("res://scenes/main.tscn") as PackedScene).instantiate()
	add_child(main)
	var game := main.get_node("Game") as Game
	var arena := main.get_node("Arena") as Arena
	var radius := 50.0
	var blob := game.spawn(radius, Vector2(arena.inner_left() + 220.0, Arena.FLOOR_Y - radius))
	await wait_seconds(0.6)
	var parent := _bubbles(blob)
	# Cut from the top bead to the one opposite it along the ring.
	var points := blob.bead_points()
	var top := 0
	for i: int in points.size():
		if points[i].y < points[top].y:
			top = i
	var before := game.bodies().size()
	game.cut(blob, top, (top + points.size() / 2) % points.size())
	var pieces := game.bodies()
	assert_eq(pieces.size(), before + 1, "the cut is made")
	if pieces.size() != before + 1:
		return
	pieces = pieces.filter(func(b: Goo2D) -> bool: return b != blob and b.radius < radius)
	assert_eq(pieces.size(), 2)
	# At the cut, each piece shows the parent's bubbles where they were.
	for piece: Goo2D in pieces:
		_assert_same_bubbles(_bubbles(piece), parent, 0.5, "a split piece at the cut")
	# Then the pieces drift apart and each carries its part of the field along:
	# its origin stays where it was relative to its own centre, in the field's
	# frame (the piece's rest pose turned by its bubble_turn: it turns with it,
	# and grows and deforms with it as it inflates: the field's own px).
	var offsets: Array[Vector2] = []
	for piece: Goo2D in pieces:
		offsets.append(_bubble_offset(piece))
	for _i: int in 10:
		await get_tree().physics_frame
	await wait_frames(1)
	for i: int in pieces.size():
		var drift := _bubble_offset(pieces[i]).distance_to(offsets[i])
		assert_lt(drift, 1e-3, "a piece's bubble field moves with it (offset drifted %.4f px)" % drift)

# The bubble origin a blob last pushed, relative to the centre it pushed with
# it, in the bubble field's own frame and px: minus the centre's place in the
# field (GooSkin.field_point(), the shader's map, × the field's cell).
func _bubble_offset(blob: Goo2D) -> Vector2:
	var material := _goo_material(blob)
	if material == null:
		return Vector2.INF
	return -GooSkin.field_point(material, material.get_shader_parameter("center") as Vector2) * blob._goo.bubble_cell

func test_merged_ring_keeps_the_bigger_parent_bubbles() -> void:
	var root := _world()
	var blobs := root.get_node("Blobs")
	var big_radius := GooTuning.radius_at(0.4)
	var small_radius := GooTuning.radius_at(0.1)
	var small := Goo2D.make(small_radius, Vector2(320.0, 500.0), blobs)
	var big := Goo2D.make(big_radius, Vector2(320.0 + small_radius + big_radius, 500.0), blobs)
	await wait_frames(1)
	var parent := _bubbles(big)
	var other := _bubbles(small)
	var from: Array[Goo2D] = [small, big]
	var merged := Goo2D.make_merged(GooTuning.merged_radius(small_radius, big_radius), blobs, from)
	assert_not_null(merged)
	if merged == null:
		return
	var child := _bubbles(merged)
	assert_ne(child.get("seed"), other.get("seed"), "not the smaller parent's seed")
	_assert_same_bubbles(child, parent, 0.5, "a merged ring")

func test_folded_ring_keeps_a_drawable_skin() -> void:
	var root := _world()
	var radius := GooTuning.radius_at(0.3)
	var blob := Goo2D.make(radius, Vector2(360.0, 500.0), root.get_node("Blobs"))
	var skin := blob.get_node("Skin") as Polygon2D
	var centre := blob.center()
	# Three consecutive beads pushed through the ring past its opposite side,
	# then the skin rebuilt (as _process() does each frame) before physics moves
	# them: the bead loop crosses itself.
	var count := blob.particle_count()
	for i: int in [count - 1, 0, 1]:
		blob.set_bead_position(i, centre - (blob.bead_position(i) - centre) * 1.3)
	assert_true(GooLoop.self_intersects(blob.bead_points()), "precondition: the bead loop crosses itself")
	blob._update_skin()
	var pieces := drawn_pieces(skin)
	assert_gt(pieces.size(), 1, "a folded ring is drawn as one polygon per loop of the fold (Polygon2D.polygons)")
	for k: int in pieces.size():
		assert_false(Geometry2D.triangulate_polygon(pieces[k]).is_empty(),
			"a folded ring's skin polygon %d should triangulate" % k)
	for point: Vector2 in blob.bead_points():
		var inside := false
		for piece: PackedVector2Array in pieces:
			if Geometry2D.is_point_in_polygon(point, piece):
				inside = true
				break
		assert_true(inside, "every bead of a folded ring lies inside one of its skin polygons")
	# Unfolded again, the skin is one polygon.
	for i: int in [count - 1, 0, 1]:
		blob.set_bead_position(i, centre - (blob.bead_position(i) - centre) / 1.3)
	blob._update_skin()
	assert_true(skin.polygons.is_empty(), "a ring that does not cross itself is one polygon again")

## The polygons a Skin draws, in global space: its sub-polygons
## (Polygon2D.polygons, index lists into `polygon`), or the polygon itself.
static func drawn_pieces(skin: Polygon2D) -> Array[PackedVector2Array]:
	var all := skin.get_global_transform() * skin.polygon
	var pieces: Array[PackedVector2Array] = []
	if skin.polygons.is_empty():
		if all.size() >= 3:
			pieces.append(all)
		return pieces
	for indices: PackedInt32Array in skin.polygons:
		var piece := PackedVector2Array()
		for i: int in indices:
			piece.append(all[i])
		pieces.append(piece)
	return pieces

func test_settled_ring_stops_redrawing_its_skin_until_it_wakes() -> void:
	timeout_sec = 15.0
	var root := _world()
	var radius := GooTuning.radius_at(0.3)
	var floor_point := Vector2((Arena.INNER_LEFT + Arena.INNER_RIGHT) / 2.0, Arena.FLOOR_Y - radius)
	var blob := Goo2D.make(radius, floor_point, root.get_node("Blobs"))
	var skin := blob.get_node("Skin") as Polygon2D
	var material := _goo_material(blob)
	var elapsed := 0.0
	while not blob.skin_at_rest() and elapsed < 6.0:
		await get_tree().process_frame
		elapsed += get_process_delta_time()
	assert_true(blob.settled, "the ring should settle on the floor")
	assert_true(blob.skin_at_rest(), "a settled ring's skin should come to rest")
	assert_eq(material.get_shader_parameter("velocity"), Vector2.ZERO,
		"the skin's smoothed velocity ends at exactly zero before it stops updating")
	var drawn := skin.polygon
	assert_false(Geometry2D.triangulate_polygon(drawn).is_empty(), "precondition: a drawn skin")
	# A skin at rest is left as it is: a polygon put there stays.
	var marker := PackedVector2Array([Vector2.ZERO, Vector2(1.0, 0.0), Vector2(0.0, 1.0)])
	skin.polygon = marker
	await wait_frames(3)
	assert_eq(skin.polygon, marker, "a resting ring does not rebuild its skin")
	# Woken and moved, it draws again.
	blob.apply_impulse(Vector2(0.0, -40.0) * blob.body_mass() / blob.particle_count())
	assert_false(blob.skin_at_rest(), "waking ends the skin's rest")
	# Physics frames, not process frames: the kernel moves the beads (and makes
	# a new skin) in a physics frame, which headless process frames can outrun.
	for frame: int in 3:
		await get_tree().physics_frame
	await wait_frames(1)
	assert_ne(skin.polygon, marker, "a woken ring rebuilds its skin")

# --- two-tone bodies -----------------------------------------------------------

const RED := Color(0.9, 0.2, 0.25)
const BLUE := Color(0.2, 0.35, 0.9)

func test_a_two_tone_body_pushes_its_colours_and_division_to_its_material() -> void:
	var root := _world()
	var radius := GooTuning.radius_at(0.3)
	var blob := Goo2D.make(radius, Vector2(Arena.INNER_LEFT + 220.0, Arena.FLOOR_Y - radius), root.get_node("Blobs"))
	var axis := Vector2(1.0, -1.0).normalized()
	blob.set_two_tone(RED, BLUE, axis, 4.0)
	var material := _goo_material(blob)
	assert_true(blob.is_two_tone())
	assert_eq(blob.color, RED)
	assert_eq(blob.second_color, BLUE)
	assert_eq(blob.get_tint(), RED, "the primary is the Skin's colour (COLOR)")
	assert_eq(blob.get_second_tint(), BLUE)
	assert_eq(material.get_shader_parameter("second_color"), BLUE)
	var pushed: Vector2 = material.get_shader_parameter("division_axis")
	assert_true(pushed.distance_to(axis) < 1e-5, "the axis pushed: %s" % pushed)
	assert_almost_eq(material.get_shader_parameter("division_offset"), 4.0, 1e-5)
	# Setting `color` keeps the second colour; clear_two_tone() goes back to one.
	blob.color = Color(0.22, 0.84, 0.46)
	assert_true(blob.is_two_tone(), "a new primary keeps the second colour")
	assert_eq(material.get_shader_parameter("second_color"), BLUE)
	blob.clear_two_tone()
	assert_false(blob.is_two_tone())
	assert_eq(material.get_shader_parameter("second_color"), Color(0.0, 0.0, 0.0, 0.0),
		"one colour again: the skin's single-colour default")
	assert_almost_eq(material.get_shader_parameter("division_offset"), 0.0)

func test_a_settled_two_tone_body_pushes_at_once() -> void:
	# A settled skin stops updating (skin_at_rest()): set_two_tone() must not
	# wait for the next skin update.
	timeout_sec = 15.0
	var root := _world()
	var radius := GooTuning.radius_at(0.3)
	var blob := Goo2D.make(radius, Vector2(Arena.INNER_LEFT + 220.0, Arena.FLOOR_Y - radius), root.get_node("Blobs"))
	var elapsed := 0.0
	while not blob.skin_at_rest() and elapsed < 6.0:
		await get_tree().process_frame
		elapsed += get_process_delta_time()
	assert_true(blob.skin_at_rest(), "precondition: the skin is at rest")
	blob.set_two_tone(RED, BLUE, Vector2.UP, -3.0)
	assert_eq(_goo_material(blob).get_shader_parameter("second_color"), BLUE)
	assert_almost_eq(_goo_material(blob).get_shader_parameter("division_offset"), -3.0, 1e-5)

func test_split_pieces_of_a_two_tone_body_get_both_colours_half_and_half() -> void:
	timeout_sec = 10.0
	var root := _world()
	var world := GooWorld2D.new()
	root.add_child(world)
	var radius := 60.0
	var body := world.spawn(radius, Vector2(Arena.INNER_LEFT + 220.0, Arena.FLOOR_Y - radius))
	await wait_seconds(0.3)
	# A division at an angle, shifted toward the second colour.
	body.set_two_tone(RED, BLUE, Vector2.from_angle(0.9), 8.0)
	var parent_axis := body.division_axis.rotated(body.ring_rotation())
	var points := body.bead_points()
	var top := 0
	for i: int in points.size():
		if points[i].y < points[top].y:
			top = i
	world.cut(body, top, (top + points.size() / 2) % points.size())
	var pieces := world.bodies()
	assert_eq(pieces.size(), 2, "the cut is made")
	for piece: Goo2D in pieces:
		assert_true(piece.is_two_tone(), "a piece is two-tone")
		assert_eq(piece.color, RED, "a piece keeps the primary")
		assert_eq(piece.second_color, BLUE, "and the second colour")
		assert_almost_eq(piece.division_offset, 0.0, 1e-5, "half and half")
		var world_axis := piece.division_axis.rotated(piece.ring_rotation())
		var degrees := rad_to_deg(absf(world_axis.angle_to(parent_axis)))
		print("    a piece's division is %.2f° off its parent's" % degrees)
		assert_lt(degrees, 3.0, "a piece's division runs the parent's way in the world")
		var material := _goo_material(piece)
		assert_eq(material.get_shader_parameter("second_color"), BLUE, "pushed to the piece's skin")
