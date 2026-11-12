extends TestCase
## GooSkin: the per-blob ShaderMaterial of the goo shader and the uniforms it
## pushes each frame (outline points padded or resampled to 32, centre, radius,
## smoothed velocity, a per-instance seed, the bubble field's origin and cell).
## Shaders are not compiled headless, but the material and its parameters are,
## so this is what can be checked here.

func _circle(count: int, centre: Vector2, radius: float) -> PackedVector2Array:
	var points := PackedVector2Array()
	for i: int in count:
		var angle := TAU * i / count
		points.append(centre + Vector2(cos(angle), sin(angle)) * radius)
	return points

func _attached() -> GooSkin:
	var polygon := Polygon2D.new()
	autofree(polygon)
	var skin := GooSkin.new()
	skin.attach(polygon)
	return skin

func test_attach_gives_the_polygon_a_goo_shader_material() -> void:
	var polygon := Polygon2D.new()
	autofree(polygon)
	var skin := GooSkin.new()
	skin.attach(polygon)
	var material := polygon.material as ShaderMaterial
	assert_not_null(material, "the polygon should carry a ShaderMaterial")
	if material == null:
		return
	assert_eq(material, skin.material)
	assert_not_null(material.shader)
	assert_eq(material.shader.resource_path, GooSkin.SHADER_PATH)

func test_each_skin_owns_its_material() -> void:
	var a := _attached()
	var b := _attached()
	assert_ne(a.material, b.material)
	assert_eq(a.material.shader, b.material.shader, "the shader itself is shared")

func test_update_pushes_points_padded_to_32() -> void:
	var skin := _attached()
	var loop := _circle(20, Vector2(300.0, 400.0), 50.0)
	skin.update(loop, Vector2(300.0, 400.0), 50.0, Vector2.ZERO, 1.0 / 60.0)
	var m := skin.material
	assert_eq(m.get_shader_parameter("point_count"), 20)
	var points: PackedVector2Array = m.get_shader_parameter("points")
	assert_eq(points.size(), GooSkin.MAX_POINTS)
	for i: int in 20:
		assert_eq(points[i], loop[i])
	assert_eq(m.get_shader_parameter("center"), Vector2(300.0, 400.0))
	assert_almost_eq(m.get_shader_parameter("radius"), 50.0)

func test_update_resamples_a_loop_longer_than_32() -> void:
	var skin := _attached()
	var loop := _circle(50, Vector2.ZERO, 80.0)
	skin.update(loop, Vector2.ZERO, 80.0, Vector2.ZERO, 1.0 / 60.0)
	assert_eq(skin.material.get_shader_parameter("point_count"), GooSkin.MAX_POINTS)
	var points: PackedVector2Array = skin.material.get_shader_parameter("points")
	assert_eq(points.size(), GooSkin.MAX_POINTS)
	for point: Vector2 in points:
		assert_almost_eq(point.length(), 80.0, 2.0, "resampled points stay on the loop")
	# Evenly spaced: neighbouring gaps all about the same.
	var gap := points[0].distance_to(points[1])
	for i: int in GooSkin.MAX_POINTS:
		assert_almost_eq(points[i].distance_to(points[(i + 1) % GooSkin.MAX_POINTS]), gap, gap * 0.2)

func test_velocity_is_smoothed_toward_the_input() -> void:
	var skin := _attached()
	var loop := _circle(16, Vector2.ZERO, 30.0)
	skin.update(loop, Vector2.ZERO, 30.0, Vector2(600.0, 0.0), 1.0 / 60.0)
	var first: Vector2 = skin.material.get_shader_parameter("velocity")
	assert_gt(first.x, 0.0, "moves toward the input")
	assert_lt(first.x, 600.0, "but not all the way in one frame")
	for _i: int in 120:
		skin.update(loop, Vector2.ZERO, 30.0, Vector2(600.0, 0.0), 1.0 / 60.0)
	var settled: Vector2 = skin.material.get_shader_parameter("velocity")
	assert_almost_eq(settled.x, 600.0, 1.0, "converges on a steady input")

func test_velocity_never_goes_nan() -> void:
	var skin := _attached()
	var loop := _circle(16, Vector2.ZERO, 30.0)
	skin.update(loop, Vector2.ZERO, 30.0, Vector2(NAN, INF), 1.0 / 60.0)
	skin.update(loop, Vector2.ZERO, 30.0, Vector2(100.0, 0.0), 0.0)
	skin.update(loop, Vector2.ZERO, 30.0, Vector2(100.0, 0.0), NAN)
	skin.update(loop, Vector2.ZERO, 30.0, Vector2(-INF, 5.0), 1.0 / 60.0)
	var v: Vector2 = skin.material.get_shader_parameter("velocity")
	assert_true(v.is_finite(), "velocity %s should be finite" % v)

func test_empty_loop_is_harmless() -> void:
	var skin := _attached()
	skin.update(PackedVector2Array(), Vector2.ZERO, 30.0, Vector2.ZERO, 1.0 / 60.0)
	assert_eq(skin.material.get_shader_parameter("point_count"), 0)
	var points: PackedVector2Array = skin.material.get_shader_parameter("points")
	assert_eq(points.size(), GooSkin.MAX_POINTS)

func test_seeds_differ_between_instances() -> void:
	var a := _attached()
	var b := _attached()
	var seed_a: float = a.material.get_shader_parameter("seed")
	var seed_b: float = b.material.get_shader_parameter("seed")
	assert_ne(seed_a, seed_b)

func _param(skin: GooSkin, name: String) -> Variant:
	return skin.material.get_shader_parameter(name)

func _assert_vec_near(actual: Vector2, expected: Vector2, tolerance: float, msg: String) -> void:
	assert_true(actual.distance_to(expected) <= tolerance,
		"%s: expected %s, got %s" % [msg, expected, actual])

func test_bubble_field_follows_a_lone_blob() -> void:
	var skin := _attached()
	var a := Vector2(300.0, 400.0)
	skin.update(_circle(16, a, 50.0), a, 50.0, Vector2.ZERO, 1.0 / 60.0)
	_assert_vec_near(_param(skin, "bubble_origin"), a, 1e-4, "starts on the centre")
	var b := Vector2(420.0, 380.0)
	skin.update(_circle(16, b, 50.0), b, 50.0, Vector2.ZERO, 1.0 / 60.0)
	_assert_vec_near(_param(skin, "bubble_origin"), b, 1e-4, "moves with the centre")

func test_first_update_sets_bubble_cell_from_the_radius_then_keeps_it() -> void:
	var skin := _attached()
	skin.update(_circle(16, Vector2.ZERO, 100.0), Vector2.ZERO, 100.0, Vector2.ZERO, 1.0 / 60.0)
	assert_almost_eq(skin.bubble_cell, 48.0, 1e-4, "max(radius * 0.48, 16)")
	assert_almost_eq(_param(skin, "bubble_cell"), 48.0, 1e-4)
	skin.update(_circle(16, Vector2.ZERO, 60.0), Vector2.ZERO, 60.0, Vector2.ZERO, 1.0 / 60.0)
	assert_almost_eq(skin.bubble_cell, 48.0, 1e-4, "a later radius does not rescale the bubbles")
	assert_almost_eq(_param(skin, "bubble_cell"), 48.0, 1e-4)
	var small := _attached()
	small.update(_circle(16, Vector2.ZERO, 20.0), Vector2.ZERO, 20.0, Vector2.ZERO, 1.0 / 60.0)
	assert_almost_eq(small.bubble_cell, 16.0, 1e-4, "never below 16 px")

func test_inherit_continues_the_parent_bubble_field() -> void:
	var parent := _attached()
	var a := Vector2(300.0, 400.0)
	parent.update(_circle(20, a, 80.0), a, 80.0, Vector2.ZERO, 1.0 / 60.0)
	var child := _attached()
	var b := Vector2(340.0, 420.0)
	child.update(_circle(12, b, 40.0), b, 40.0, Vector2.ZERO, 1.0 / 60.0)
	assert_ne(_param(child, "seed"), _param(parent, "seed"), "unrelated before inheriting")
	child.inherit(parent, a, b)
	_assert_vec_near(_param(child, "bubble_origin"), _param(parent, "bubble_origin"), 1e-3,
		"the origins coincide right after inheriting")
	assert_eq(child.noise_seed, parent.noise_seed)
	assert_eq(_param(child, "seed"), _param(parent, "seed"))
	assert_almost_eq(child.bubble_cell, parent.bubble_cell, 1e-4)
	assert_almost_eq(_param(child, "bubble_cell"), parent.bubble_cell, 1e-4,
		"the parent's cell, not one from the child's radius")
	# Later updates move the field with the child's own centre.
	var origin: Vector2 = _param(child, "bubble_origin")
	var shift := Vector2(25.0, -10.0)
	child.update(_circle(12, b + shift, 40.0), b + shift, 40.0, Vector2.ZERO, 1.0 / 60.0)
	_assert_vec_near(_param(child, "bubble_origin"), origin + shift, 1e-3, "moves with the child")
	assert_almost_eq(_param(child, "bubble_cell"), parent.bubble_cell, 1e-4, "keeps the inherited cell")

func test_inherit_keeps_the_field_turning_as_the_parent_had_it() -> void:
	var parent := _attached()
	var a := Vector2(300.0, 400.0)
	parent.set_rotation(1.0)
	parent.update(_circle(20, a, 80.0), a, 80.0, Vector2.ZERO, 1.0 / 60.0)
	assert_almost_eq(float(_param(parent, "bubble_turn")), 0.0, 1e-6, "a blob of its own: no turn")
	var child := _attached()
	var b := Vector2(340.0, 420.0)
	child.update(_circle(12, b, 40.0), b, 40.0, Vector2.ZERO, 1.0 / 60.0)
	# The parent's ring has turned 1.0 from its rest pose, the child's 0.3 from
	# its own: the field keeps the parent's turn, 0.7 on top of the child's.
	child.inherit(parent, a, b, 1.0, 0.3)
	assert_almost_eq(child.bubble_turn, 0.7, 1e-6, "the parent's turn over the child's rest pose")
	assert_almost_eq(float(_param(child, "bubble_turn")), 0.7, 1e-6, "pushed at once")
	assert_almost_eq(float(_param(child, "rotation")), 0.3, 1e-6, "the child's rotation pushed with it")
	_assert_vec_near(_param(child, "bubble_origin"), _param(parent, "bubble_origin"), 1e-3,
		"the origins coincide right after inheriting")
	# As the child turns on, the origin turns with it about its centre.
	child.set_rotation(0.3 + 0.5)
	child.update(_circle(12, b, 40.0), b, 40.0, Vector2.ZERO, 1.0 / 60.0)
	_assert_vec_near(_param(child, "bubble_origin"), b + (a - b).rotated(0.5), 1e-3,
		"the field turns about the child's centre")

func test_motion_roll_turns_the_patterns_with_sideways_motion() -> void:
	var skin := _attached()
	var a := Vector2(300.0, 400.0)
	skin.set_rotation(0.3)
	skin.update(_circle(16, a, 50.0), a, 50.0, Vector2(100.0, 0.0), 0.1)
	assert_almost_eq(float(_param(skin, "rotation")), 0.3, 1e-6, "off by default: the ring's rotation alone")
	skin.motion_roll = 1.0
	skin.update(_circle(16, a, 50.0), a, 50.0, Vector2(100.0, 0.0), 0.1)
	assert_almost_eq(skin.roll(), 0.2, 1e-6, "100 px/s for 0.1 s over a radius of 50: 0.2 rad")
	assert_almost_eq(float(_param(skin, "rotation")), 0.5, 1e-6, "the ring's rotation plus the roll")
	skin.update(_circle(16, a, 50.0), a, 50.0, Vector2(0.0, 300.0), 0.1)
	assert_almost_eq(float(_param(skin, "rotation")), 0.5, 1e-6, "a straight fall rolls nothing")
	skin.update(_circle(16, a, 50.0), a, 50.0, Vector2(-50.0, 0.0), 0.1)
	assert_almost_eq(float(_param(skin, "rotation")), 0.4, 1e-6, "moving left rolls back")
	skin.set_rotation(0.6)
	assert_almost_eq(float(_param(skin, "rotation")), 0.7, 1e-6, "a new ring rotation keeps the roll")
	skin.update_motion(a, 50.0, Vector2(100.0, 0.0), 0.05)
	assert_almost_eq(float(_param(skin, "rotation")), 0.8, 1e-6, "update_motion() rolls too")

func test_inherit_carries_the_roll() -> void:
	var parent := _attached()
	var a := Vector2(300.0, 400.0)
	parent.motion_roll = 1.0
	parent.set_rotation(0.3)
	parent.update(_circle(20, a, 80.0), a, 80.0, Vector2(160.0, 0.0), 0.1)
	assert_almost_eq(parent.roll(), 0.2, 1e-6)
	var child := _attached()
	var b := Vector2(340.0, 420.0)
	child.update(_circle(12, b, 40.0), b, 40.0, Vector2.ZERO, 1.0 / 60.0)
	child.inherit(parent, a, b, 0.3, 0.1)
	assert_almost_eq(child.motion_roll, 1.0, 1e-6, "rolls on as the parent did")
	assert_almost_eq(child.roll(), 0.2, 1e-6, "the roll so far")
	assert_almost_eq(float(_param(child, "rotation")), 0.3, 1e-6, "the child's rotation plus the roll")
	assert_almost_eq(child.bubble_turn, 0.2, 1e-6, "the parent's ring rotation over the child's")
	_assert_vec_near(_param(child, "bubble_origin"), _param(parent, "bubble_origin"), 1e-3,
		"the origins coincide right after inheriting")

func test_inherit_chains_through_an_offset_parent() -> void:
	var grandparent := _attached()
	var a := Vector2(100.0, 100.0)
	grandparent.update(_circle(16, a, 80.0), a, 80.0, Vector2.ZERO, 1.0 / 60.0)
	var parent := _attached()
	var b := Vector2(150.0, 90.0)
	parent.update(_circle(16, b, 50.0), b, 50.0, Vector2.ZERO, 1.0 / 60.0)
	parent.inherit(grandparent, a, b)
	var c := Vector2(170.0, 60.0)
	parent.update(_circle(16, c, 50.0), c, 50.0, Vector2.ZERO, 1.0 / 60.0)
	var child := _attached()
	var d := Vector2(190.0, 40.0)
	child.inherit(parent, c, d)
	_assert_vec_near(_param(child, "bubble_origin"), _param(parent, "bubble_origin"), 1e-3,
		"an inherited offset is carried on, not reset to the parent's centre")

func test_inherit_carries_the_smoothed_velocity() -> void:
	var parent := _attached()
	var loop := _circle(16, Vector2.ZERO, 30.0)
	for _i: int in 30:
		parent.update(loop, Vector2.ZERO, 30.0, Vector2(500.0, -200.0), 1.0 / 60.0)
	var velocity: Vector2 = _param(parent, "velocity")
	var child := _attached()
	child.inherit(parent, Vector2.ZERO, Vector2(10.0, 0.0))
	_assert_vec_near(_param(child, "velocity"), velocity, 1e-3, "pushed at once")
	# Smoothing continues from the parent's value, not from rest.
	child.update(loop, Vector2.ZERO, 30.0, velocity, 1.0 / 60.0)
	_assert_vec_near(_param(child, "velocity"), velocity, 1e-2, "no jump back toward rest")

# ---- A swapped shader (GooSkin.shader, set_shader()) ----

## A canvas_item shader declaring only some of the uniforms GooSkin pushes
## (centre, radius, points and seed; no velocity, no bubbles): a replacement
## may declare any subset.
func _partial_shader() -> Shader:
	var shader := Shader.new()
	shader.code = "shader_type canvas_item;\n" \
		+ "uniform vec2 center;\nuniform float radius;\nuniform vec2 points[32];\nuniform float seed;\n" \
		+ "void fragment() {\n\tCOLOR = vec4(COLOR.rgb * fract(seed + radius / 100.0), COLOR.a);\n}\n"
	return shader

func test_a_new_skin_draws_with_the_default_goo_shader() -> void:
	var skin := _attached()
	assert_null(skin.shader, "no shader of its own: the addon's goo shader")
	assert_eq(skin.material.shader.resource_path, GooSkin.SHADER_PATH)

func test_set_shader_swaps_the_shader_of_the_same_material() -> void:
	var polygon := Polygon2D.new()
	autofree(polygon)
	var skin := GooSkin.new()
	skin.attach(polygon)
	var material := skin.material
	var custom := _partial_shader()
	skin.set_shader(custom)
	assert_eq(skin.shader, custom)
	assert_eq(skin.material, material, "the same material, so the polygon needs no re-attach")
	assert_eq(polygon.material, material)
	assert_eq(material.shader, custom)

func test_set_shader_null_goes_back_to_the_goo_shader() -> void:
	var skin := _attached()
	skin.set_shader(_partial_shader())
	skin.set_shader(null)
	assert_null(skin.shader)
	assert_eq(skin.material.shader.resource_path, GooSkin.SHADER_PATH)

func test_the_shader_property_swaps_like_set_shader() -> void:
	var skin := _attached()
	var custom := _partial_shader()
	skin.shader = custom
	assert_eq(skin.material.shader, custom)

func test_a_swap_keeps_every_uniform_last_pushed() -> void:
	var skin := _attached()
	var loop := _circle(20, Vector2(300.0, 400.0), 50.0)
	skin.update(loop, Vector2(300.0, 400.0), 50.0, Vector2(240.0, 0.0), 1.0 / 60.0)
	var before := {}
	for name: String in GooSkin.UNIFORMS:
		before[name] = _param(skin, name)
		assert_not_null(before[name], "%s was pushed before the swap" % name)
	skin.set_shader(_partial_shader())
	for name: String in GooSkin.UNIFORMS:
		assert_eq(_param(skin, name), before[name], "%s survives the swap" % name)
	var points: PackedVector2Array = _param(skin, "points")
	assert_eq(points.size(), GooSkin.MAX_POINTS)
	assert_eq(points[3], loop[3])
	assert_eq(_param(skin, "center"), Vector2(300.0, 400.0))
	assert_eq(_param(skin, "seed"), skin.noise_seed)
	# And back to the goo shader: still all there.
	skin.set_shader(null)
	for name: String in GooSkin.UNIFORMS:
		assert_eq(_param(skin, name), before[name], "%s survives the swap back" % name)

func test_a_swapped_skin_keeps_pushing_every_uniform() -> void:
	# The shader declares neither velocity nor the bubbles; the skin pushes them
	# all the same (silently), so a later swap finds them current.
	var skin := _attached()
	skin.set_shader(_partial_shader())
	var a := Vector2(120.0, 80.0)
	skin.update(_circle(16, a, 40.0), a, 40.0, Vector2(300.0, 0.0), 1.0 / 60.0)
	assert_eq(_param(skin, "center"), a)
	assert_almost_eq(_param(skin, "radius"), 40.0)
	assert_eq(_param(skin, "point_count"), 16)
	var velocity: Vector2 = _param(skin, "velocity")
	assert_gt(velocity.x, 0.0)
	_assert_vec_near(_param(skin, "bubble_origin"), a, 1e-4, "the bubble field is pushed too")

func test_inherit_onto_a_swapped_skin_pushes_the_parent_field() -> void:
	var parent := _attached()
	var a := Vector2(300.0, 400.0)
	parent.update(_circle(20, a, 80.0), a, 80.0, Vector2.ZERO, 1.0 / 60.0)
	var child := _attached()
	child.set_shader(_partial_shader())
	child.inherit(parent, a, Vector2(320.0, 400.0))
	assert_eq(_param(child, "seed"), parent.noise_seed)
	child.set_shader(null)
	assert_eq(_param(child, "seed"), parent.noise_seed, "inherited values are re-pushed on a swap")
	_assert_vec_near(_param(child, "bubble_origin"), _param(parent, "bubble_origin"), 1e-3,
		"the inherited bubble field too")

func test_rotation_is_pushed_and_survives_a_swap() -> void:
	# A new skin starts unrotated; set_rotation() pushes the angle, and a swap
	# re-pushes it like every other uniform.
	var skin := _attached()
	assert_has(GooSkin.UNIFORMS, "rotation")
	assert_almost_eq(_param(skin, "rotation"), 0.0)
	skin.set_rotation(0.7)
	assert_almost_eq(_param(skin, "rotation"), 0.7)
	skin.set_shader(_partial_shader())
	assert_almost_eq(_param(skin, "rotation"), 0.7, 1e-6, "survives the swap")
	skin.set_rotation(-1.2)
	assert_almost_eq(_param(skin, "rotation"), -1.2)

# --- two-tone uniforms ---------------------------------------------------------

func test_two_tone_uniforms_are_pushed_at_init_with_their_single_colour_defaults() -> void:
	# A new skin draws one colour: second_color transparent black (the shader
	# reads it as "the same as COLOR"), the axis along +x, the offset 0.
	var skin := _attached()
	for name: String in ["second_color", "division_axis", "division_offset"]:
		assert_has(GooSkin.UNIFORMS, name)
	assert_eq(_param(skin, "second_color"), Color(0.0, 0.0, 0.0, 0.0))
	assert_eq(_param(skin, "division_axis"), Vector2.RIGHT)
	assert_almost_eq(_param(skin, "division_offset"), 0.0)

func test_set_two_tone_pushes_the_second_colour_and_the_division() -> void:
	var skin := _attached()
	var blue := Color(0.2, 0.35, 0.9)
	var axis := Vector2(0.6, -0.8)
	skin.set_two_tone(blue, axis, 7.5)
	assert_eq(_param(skin, "second_color"), blue)
	_assert_vec_near(_param(skin, "division_axis"), axis, 1e-6, "the axis as given")
	assert_almost_eq(_param(skin, "division_offset"), 7.5)
	skin.clear_two_tone()
	assert_eq(_param(skin, "second_color"), Color(0.0, 0.0, 0.0, 0.0), "back to one colour")
	assert_eq(_param(skin, "division_axis"), Vector2.RIGHT)
	assert_almost_eq(_param(skin, "division_offset"), 0.0)

func test_set_two_tone_normalises_the_axis_and_survives_a_swap() -> void:
	var skin := _attached()
	var red := Color(0.9, 0.2, 0.25)
	skin.set_two_tone(red, Vector2(0.0, 3.0), -4.0)
	_assert_vec_near(_param(skin, "division_axis"), Vector2.DOWN, 1e-6, "a unit axis")
	skin.set_shader(_partial_shader())
	assert_eq(_param(skin, "second_color"), red, "re-pushed after the swap")
	_assert_vec_near(_param(skin, "division_axis"), Vector2.DOWN, 1e-6, "the axis too")
	assert_almost_eq(_param(skin, "division_offset"), -4.0)
	skin.set_shader(null)
	assert_eq(_param(skin, "second_color"), red, "and after the swap back")

# --- the field following the body's material (the field matrix) ---------------

# Growth `s`, then a squash along `axis` (1 / squash across) and √`area`, in
# the rest space.
static func _deform_map(s: float, squash: float, axis: Vector2, area: float) -> Transform2D:
	var u := axis.normalized()
	var v := Vector2(-u.y, u.x)
	var k := s * sqrt(area)
	return Transform2D((u * (squash * u.x) + v * (v.x / squash)) * k,
		(u * (squash * u.y) + v * (v.y / squash)) * k, Vector2.ZERO)

static func _scale(s: float) -> Transform2D:
	return Transform2D(Vector2(s, 0.0), Vector2(0.0, s), Vector2.ZERO)

func test_a_skin_never_deformed_pushes_the_identity_basis() -> void:
	var skin := _attached()
	assert_has(GooSkin.UNIFORMS, "bubble_basis")
	assert_eq(_param(skin, "bubble_basis"), Transform2D.IDENTITY, "pushed at init")
	assert_eq(skin.field_matrix(), Transform2D.IDENTITY)
	skin.update(_circle(16, Vector2(300.0, 400.0), 50.0), Vector2(300.0, 400.0), 50.0, Vector2.ZERO, 1.0 / 60.0)
	assert_eq(_param(skin, "bubble_basis"), Transform2D.IDENTITY)
	assert_eq(_param(skin, "bubble_cell"), 24.0, "the cell as born, exactly")
	skin.set_field_matrix(Transform2D.IDENTITY)
	skin.update_motion(Vector2(300.0, 400.0), 50.0, Vector2.ZERO, 1.0 / 60.0)
	assert_eq(_param(skin, "bubble_basis"), Transform2D.IDENTITY)
	assert_eq(_param(skin, "bubble_cell"), 24.0)

func test_field_point_is_the_shaders_map() -> void:
	# The uniforms of a plain skin: (p − origin) turned back by rotation +
	# bubble_turn, in cells.
	var skin := _attached()
	var a := Vector2(300.0, 400.0)
	skin.set_rotation(0.4)
	skin.update(_circle(16, a, 50.0), a, 50.0, Vector2.ZERO, 1.0 / 60.0)
	var p := Vector2(330.0, 380.0)
	var expected := (p - (_param(skin, "bubble_origin") as Vector2)).rotated(-0.4) / 24.0
	_assert_vec_near(GooSkin.field_point(skin.material, p), expected, 1e-5, "the plain map")
	var drift := Vector2(0.0, 12.0)
	_assert_vec_near(GooSkin.field_point(skin.material, p, drift), expected + drift.rotated(-0.4) / 24.0, 1e-5,
		"the drift added before the turn")

func test_the_field_grows_with_the_body() -> void:
	var skin := _attached()
	var a := Vector2(300.0, 400.0)
	skin.set_rotation(0.3)
	skin.update(_circle(16, a, 50.0), a, 50.0, Vector2.ZERO, 1.0 / 60.0)
	var material_points: Array[Vector2] = [Vector2(10.0, 0.0), Vector2(-20.0, 15.0), Vector2(5.0, -30.0)]
	var before: Array[Vector2] = []
	for r: Vector2 in material_points:
		before.append(GooSkin.field_point(skin.material, a + r.rotated(0.3)))
	# Grown to 1.5 times its size and moved: each material point 1.5 times as far
	# from the centre keeps its place in the field.
	var b := Vector2(360.0, 380.0)
	skin.set_field_matrix(_scale(1.5))
	skin.update(_circle(16, b, 75.0), b, 75.0, Vector2.ZERO, 1.0 / 60.0)
	for i: int in material_points.size():
		_assert_vec_near(GooSkin.field_point(skin.material, b + (material_points[i] * 1.5).rotated(0.3)), before[i],
			1e-5, "a material point keeps its place")
	assert_eq(float(_param(skin, "bubble_cell")), 36.0, "the cell grows with it")
	assert_eq(skin.bubble_cell, 24.0, "the field's own cell is kept")
	assert_eq(_param(skin, "bubble_basis"), Transform2D.IDENTITY, "a plain scale stays in the cell")

func test_the_field_deforms_with_the_body() -> void:
	var skin := _attached()
	var a := Vector2(300.0, 400.0)
	skin.set_rotation(-0.6)
	skin.update(_circle(16, a, 40.0), a, 40.0, Vector2.ZERO, 1.0 / 60.0)
	var material_points: Array[Vector2] = [Vector2(10.0, 0.0), Vector2(-20.0, 15.0), Vector2(5.0, -30.0)]
	var before: Array[Vector2] = []
	for r: Vector2 in material_points:
		before.append(GooSkin.field_point(skin.material, a + r.rotated(-0.6)))
	var map := _deform_map(1.1, 1.6, Vector2(1.0, 2.0), 0.7)
	skin.set_field_matrix(map)
	skin.update_motion(a, 44.0, Vector2.ZERO, 1.0 / 60.0)
	for i: int in material_points.size():
		_assert_vec_near(GooSkin.field_point(skin.material, a + map.basis_xform(material_points[i]).rotated(-0.6)),
			before[i], 1e-4, "a material point keeps its place under a squash")
	var basis: Transform2D = _param(skin, "bubble_basis")
	assert_almost_eq(basis.determinant(), 1.0, 1e-5, "the basis keeps the area")
	assert_almost_eq(float(_param(skin, "bubble_cell")), 19.2 * 1.1 * sqrt(0.7), 1e-3,
		"the scale is in the cell (born 0.48 of the radius)")
	skin.set_field_matrix(Transform2D.IDENTITY)
	skin.update_motion(a, 40.0, Vector2.ZERO, 1.0 / 60.0)
	assert_eq(_param(skin, "bubble_basis"), Transform2D.IDENTITY, "back to the identity")
	assert_almost_eq(float(_param(skin, "bubble_cell")), 19.2, 1e-5)

func test_a_field_matrix_that_folds_or_is_not_finite_is_ignored() -> void:
	var skin := _attached()
	skin.set_field_matrix(_scale(1.2))
	skin.set_field_matrix(Transform2D(Vector2(1.0, 0.0), Vector2(0.0, -1.0), Vector2.ZERO))
	skin.set_field_matrix(Transform2D(Vector2(NAN, 0.0), Vector2(0.0, 1.0), Vector2.ZERO))
	skin.set_field_matrix(Transform2D(Vector2.ZERO, Vector2.ZERO, Vector2.ZERO))
	assert_eq(skin.field_matrix(), _scale(1.2), "the last good one kept")

func test_inherit_from_a_deformed_parent_does_not_jump_and_then_follows_the_child() -> void:
	var parent := _attached()
	var a := Vector2(300.0, 400.0)
	parent.set_rotation(0.5)
	parent.update(_circle(20, a, 60.0), a, 60.0, Vector2.ZERO, 1.0 / 60.0)
	parent.set_field_matrix(_deform_map(1.1, 1.4, Vector2(0.0, 1.0), 1.2))
	parent.update_motion(a, 66.0, Vector2.ZERO, 1.0 / 60.0)
	var child := _attached()
	var b := Vector2(330.0, 410.0)
	child.update(_circle(12, b, 30.0), b, 30.0, Vector2.ZERO, 1.0 / 60.0)
	child.inherit(parent, a, b, 0.5, 0.2)
	var probes: Array[Vector2] = [b, b + Vector2(12.0, -5.0), b + Vector2(-9.0, 14.0), a]
	for p: Vector2 in probes:
		_assert_vec_near(GooSkin.field_point(child.material, p) * child.bubble_cell,
			GooSkin.field_point(parent.material, p) * parent.bubble_cell, 1e-3, "no jump at birth")
	# The child then grows 1.25 times about its centre: its material points keep
	# their places.
	var before: Array[Vector2] = []
	for p: Vector2 in probes:
		before.append(GooSkin.field_point(child.material, p))
	child.set_field_matrix(_scale(1.25) * child.field_matrix())
	child.update_motion(b, 37.5, Vector2.ZERO, 1.0 / 60.0)
	for i: int in probes.size():
		_assert_vec_near(GooSkin.field_point(child.material, b + (probes[i] - b) * 1.25), before[i], 1e-4,
			"grows with the child")

func test_inherit_from_a_grown_parent_keeps_the_basis_the_identity() -> void:
	var parent := _attached()
	var a := Vector2(300.0, 400.0)
	parent.set_rotation(0.9)
	parent.update(_circle(20, a, 60.0), a, 60.0, Vector2.ZERO, 1.0 / 60.0)
	parent.set_field_matrix(_scale(1.3))
	parent.update_motion(a, 78.0, Vector2.ZERO, 1.0 / 60.0)
	var child := _attached()
	var b := Vector2(330.0, 410.0)
	child.inherit(parent, a, b, 0.9, -0.4)
	assert_eq(child.field_matrix(), _scale(1.3), "a plain scale carried over as it is")
	assert_eq(_param(child, "bubble_basis"), Transform2D.IDENTITY, "exactly the identity basis")
	_assert_vec_near(GooSkin.field_point(child.material, b + Vector2(5.0, 7.0)) * child.bubble_cell,
		GooSkin.field_point(parent.material, b + Vector2(5.0, 7.0)) * parent.bubble_cell, 1e-3, "no jump")

func test_a_two_tone_division_follows_the_growth_and_the_squash() -> void:
	var skin := _attached()
	var a := Vector2(300.0, 400.0)
	skin.update(_circle(16, a, 40.0), a, 40.0, Vector2.ZERO, 1.0 / 60.0)
	var axis := Vector2(0.6, 0.8)
	skin.set_two_tone(Color.BLUE, axis, 5.0)
	# Points of the rest space on the division and off it, then carried by a
	# growth of 1.5 and a squash: the pushed division (rest space, px) still
	# runs through the first, and the others keep their px distance as carried.
	var on_line: Array[Vector2] = [axis * 5.0, axis * 5.0 + Vector2(-0.8, 0.6) * 12.0]
	var map := _deform_map(1.5, 0.7, Vector2(1.0, -0.4), 1.3)
	skin.set_field_matrix(map)
	skin.update_motion(a, 60.0, Vector2.ZERO, 1.0 / 60.0)
	var pushed_axis: Vector2 = _param(skin, "division_axis")
	var pushed_offset := float(_param(skin, "division_offset"))
	assert_almost_eq(pushed_axis.length(), 1.0, 1e-5, "a unit axis")
	for r: Vector2 in on_line:
		assert_almost_eq(map.basis_xform(r).dot(pushed_axis) - pushed_offset, 0.0, 1e-4, "on the division still")
	var off := axis * 15.0
	var normal := map.affine_inverse().basis_xform_inv(axis)
	assert_almost_eq(map.basis_xform(off).dot(pushed_axis) - pushed_offset, 10.0 / normal.length(), 1e-4,
		"10 px past it then, carried")
	# A division set on the deformed body is taken as it is drawn then.
	skin.set_two_tone(Color.BLUE, Vector2.UP, -3.0)
	_assert_vec_near(_param(skin, "division_axis"), Vector2.UP, 1e-5, "as given")
	assert_almost_eq(float(_param(skin, "division_offset")), -3.0, 1e-4)
	skin.set_field_matrix(Transform2D.IDENTITY)
	skin.update_motion(a, 40.0, Vector2.ZERO, 1.0 / 60.0)
	var back := map.basis_xform_inv(Vector2.UP)
	_assert_vec_near(_param(skin, "division_axis"), back.normalized(), 1e-5, "carried back with the material")
	assert_almost_eq(float(_param(skin, "division_offset")), -3.0 / back.length(), 1e-4)

func test_field_center_moves_the_field_origin_off_the_centre() -> void:
	var skin := _attached()
	var a := Vector2(300.0, 400.0)
	skin.field_center = Vector2(320.0, 390.0)
	skin.update(_circle(16, a, 40.0), a, 40.0, Vector2.ZERO, 1.0 / 60.0)
	_assert_vec_near(_param(skin, "bubble_origin"), Vector2(320.0, 390.0), 1e-5, "the field's origin there")
	_assert_vec_near(_param(skin, "center"), a, 1e-5, "the shader's centre is still the centre")

# --- the shaders ----------------------------------------------------------------

# The declaration line of `uniform` in the shader at `path`, or "".
static func _declaration(path: String, uniform: String) -> String:
	var code := FileAccess.get_file_as_string(path)
	var regex := RegEx.create_from_string("(?m)^uniform\\s+\\w+\\s+" + uniform + "\\b[^;]*;")
	var found := regex.search(code)
	return found.get_string() if found != null else ""

func test_the_goo_shader_declares_bubble_basis_and_bubble_wobble() -> void:
	var basis := _declaration(GooSkin.SHADER_PATH, "bubble_basis")
	assert_true(basis.begins_with("uniform mat2 bubble_basis") and basis.contains("= mat2(1.0)"),
		"bubble_basis: a mat2, the identity by default (%s)" % basis)
	var wobble := _declaration(GooSkin.SHADER_PATH, "bubble_wobble")
	assert_true(wobble.begins_with("uniform float bubble_wobble") and wobble.ends_with("= 1.0;"),
		"bubble_wobble: a float, 1 by default (%s)" % wobble)

func test_the_gem_shader_cuts_its_facets_in_the_deformed_rest_space() -> void:
	var basis := _declaration("res://assets/goo/gem.gdshader", "bubble_basis")
	assert_true(basis.begins_with("uniform mat2 bubble_basis") and basis.contains("= mat2(1.0)"),
		"bubble_basis: a mat2, the identity by default (%s)" % basis)
