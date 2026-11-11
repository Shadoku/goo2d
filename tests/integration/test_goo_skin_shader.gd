extends TestCase
## A swappable skin shader: Goo2D.skin_shader draws a body's Skin with another
## shader (null: the addon's goo shader), GooWorld2D.skin_shader is the shader of
## every body in the world that has none of its own (set at any time: the
## bodies already in the world follow), and the pieces of a split
## and a merged body carry their parent's. The uniforms the skin pushed survive
## a swap on a live body. Shaders are not compiled headless; the materials and
## their parameters are what is checked here.

## Time a merge may take: physics settling plus the longest merge transition.
const MERGE_TIMEOUT: float = 3.0 + GooWorld2D.MergeTransition.MAX_DURATION

# A canvas_item shader declaring only some of the uniforms GooSkin pushes.
func _shader(tint: String) -> Shader:
	var shader := Shader.new()
	shader.code = "shader_type canvas_item;\n" \
		+ "uniform vec2 center;\nuniform float radius;\n" \
		+ "void fragment() {\n\tCOLOR = vec4(COLOR.rgb * %s, COLOR.a);\n}\n" % tint
	return shader

func _material(body: Goo2D) -> ShaderMaterial:
	var skin := body.get_node_or_null("Skin") as Polygon2D
	if skin == null:
		return null
	return skin.material as ShaderMaterial

func _drawn_with(body: Goo2D) -> Shader:
	var material := _material(body)
	return material.shader if material != null else null

# The arena (walls and floor on GooTuning.LAYER_WALLS, its blades inert
# without a Game) and a plain GooWorld2D drawing with `world_shader`.
func _world(world_shader: Shader = null) -> GooWorld2D:
	var arena := (load("res://scenes/arena.tscn") as PackedScene).instantiate() as Arena
	add_child(arena)
	var world := GooWorld2D.new()
	world.skin_shader = world_shader
	add_child(world)
	return world

func _middle() -> Vector2:
	return Vector2(Arena.INNER_LEFT + Arena.INNER_WIDTH / 2.0, Arena.FLOOR_Y - 200.0)

func test_a_body_draws_with_the_goo_shader_by_default() -> void:
	var world := _world()
	var body := world.spawn(40.0, _middle())
	assert_null(body.skin_shader)
	assert_eq(_drawn_with(body).resource_path, GooSkin.SHADER_PATH)

func test_a_world_shader_draws_every_body_spawned_in_it() -> void:
	var world_shader := _shader("0.5")
	var world := _world(world_shader)
	var ball := world.spawn(40.0, _middle())
	var square := world.spawn(40.0, _middle() + Vector2(150.0, 0.0), GooShape.regular(4, 40.0))
	for body: Goo2D in [ball, square]:
		assert_eq(body.skin_shader, world_shader)
		assert_eq(_drawn_with(body), world_shader, "%s draws with the world's shader" % body.name)

# A world's shader set (or changed) while bodies are in it reaches every body
# drawn with the world's at once: those that had none of their own and those
# given the world's earlier. A body with a shader of its own keeps it.
func test_a_world_shader_set_later_draws_the_bodies_already_in_it() -> void:
	var world := _world()
	var plain := world.spawn(40.0, _middle())
	var own := world.spawn(40.0, _middle() + Vector2(150.0, 0.0))
	var own_shader := _shader("0.8")
	own.skin_shader = own_shader
	await wait_frames(2)
	assert_eq(_drawn_with(plain).resource_path, GooSkin.SHADER_PATH, "the goo shader before")
	var first := _shader("0.5")
	world.skin_shader = first
	assert_eq(plain.skin_shader, first)
	assert_eq(_drawn_with(plain), first, "a body with none of its own takes the world's at once")
	assert_eq(_drawn_with(own), own_shader, "a body with its own keeps it")
	var second := _shader("0.3")
	world.skin_shader = second
	assert_eq(_drawn_with(plain), second, "the world's old shader was not the body's own")
	assert_eq(_drawn_with(own), own_shader)
	var later := world.spawn(40.0, _middle() + Vector2(-150.0, 0.0))
	assert_eq(_drawn_with(later), second, "a body spawned after takes the world's")
	world.skin_shader = null
	assert_null(plain.skin_shader)
	assert_eq(_drawn_with(plain).resource_path, GooSkin.SHADER_PATH, "null: back to the goo shader")
	assert_eq(_drawn_with(later).resource_path, GooSkin.SHADER_PATH)
	assert_eq(_drawn_with(own), own_shader)

# A world packed with two placed bodies, one with a shader of its own, as a
# scene saved from the editor would hold them: both build in their _ready()
# and the world registers them in its own.
func test_a_placed_body_keeps_its_own_shader_under_a_world_shader() -> void:
	var world_shader := _shader("0.5")
	var own_shader := _shader("0.8")
	var source := GooWorld2D.new()
	autofree(source)
	source.skin_shader = world_shader
	var plain := Goo2D.new()
	plain.name = "Plain"
	plain.radius = 40.0
	plain.position = _middle()
	source.add_child(plain)
	plain.owner = source
	var own := Goo2D.new()
	own.name = "Own"
	own.radius = 40.0
	own.position = _middle() + Vector2(150.0, 0.0)
	own.skin_shader = own_shader
	source.add_child(own)
	own.owner = source
	var packed := PackedScene.new()
	assert_eq(packed.pack(source), OK)
	var arena := (load("res://scenes/arena.tscn") as PackedScene).instantiate() as Arena
	add_child(arena)
	var world := packed.instantiate() as GooWorld2D
	add_child(world)
	await wait_frames(2)
	assert_eq(world.bodies().size(), 2, "both placed bodies are registered")
	var placed_plain := world.get_node("Plain") as Goo2D
	var placed_own := world.get_node("Own") as Goo2D
	assert_gt(placed_plain.particle_count(), 0, "built in its _ready()")
	assert_eq(placed_plain.skin_shader, world_shader)
	assert_eq(_drawn_with(placed_plain), world_shader, "no shader of its own: the world's")
	assert_eq(placed_own.skin_shader, own_shader)
	assert_eq(_drawn_with(placed_own), own_shader, "its own shader wins over the world's")

func test_a_live_body_swaps_its_shader_at_once_keeping_its_uniforms() -> void:
	var world := _world()
	var body := world.spawn(40.0, _middle())
	await wait_frames(3)
	var material := _material(body)
	var center: Vector2 = material.get_shader_parameter("center")
	var points: PackedVector2Array = material.get_shader_parameter("points")
	var noise: float = material.get_shader_parameter("seed")
	var count: int = material.get_shader_parameter("point_count")
	assert_gt(count, 0, "the skin was pushed before the swap")
	var custom := _shader("0.5")
	body.skin_shader = custom
	assert_eq(_material(body), material, "the same material: the Skin needs no re-attach")
	assert_eq(material.shader, custom)
	assert_eq(material.get_shader_parameter("center"), center)
	assert_eq(material.get_shader_parameter("points"), points)
	assert_eq(material.get_shader_parameter("seed"), noise)
	assert_eq(material.get_shader_parameter("point_count"), count)
	body.skin_shader = null
	assert_eq(material.shader.resource_path, GooSkin.SHADER_PATH, "null goes back to the goo shader")

func test_split_pieces_keep_their_parent_shader() -> void:
	var world_shader := _shader("0.5")
	var own_shader := _shader("0.8")
	var world := _world(world_shader)
	var body := world.spawn(GooTuning.radius_at(0.6), _middle())
	body.skin_shader = own_shader
	await wait_frames(3)
	var points := body.bead_points()
	var top := 0
	for i: int in points.size():
		if points[i].y < points[top].y:
			top = i
	world.cut(body, top, (top + points.size() / 2) % points.size())
	await wait_frames(1)
	var pieces := world.bodies()
	assert_eq(pieces.size(), 2, "the body was cut in two")
	for piece: Goo2D in pieces:
		assert_ne(piece, body)
		assert_eq(piece.skin_shader, own_shader, "a piece keeps its parent's shader, not the world's")
		assert_eq(_drawn_with(piece), own_shader)

func test_a_merged_body_keeps_its_parents_shader() -> void:
	var world_shader := _shader("0.5")
	var own_shader := _shader("0.8")
	var world := _world(world_shader)
	var radius := GooTuning.MIN_RADIUS
	var gap := radius * 2.0 - 4.0
	var x := Arena.INNER_LEFT + Arena.INNER_WIDTH / 2.0
	var a := world.spawn(radius, Vector2(x - gap / 2.0, Arena.FLOOR_Y - radius))
	var b := world.spawn(radius, Vector2(x + gap / 2.0, Arena.FLOOR_Y - radius))
	a.skin_shader = own_shader
	b.skin_shader = own_shader
	var fired := await await_signal(world.merged, MERGE_TIMEOUT)
	assert_true(fired, "touching %.0f px blobs should merge within %.2f s" % [radius, MERGE_TIMEOUT])
	await wait_frames(2)
	var bodies := world.bodies()
	assert_eq(bodies.size(), 1)
	if bodies.size() == 1:
		assert_eq(bodies[0].skin_shader, own_shader, "the merged body keeps its parents' shader")
		assert_eq(_drawn_with(bodies[0]), own_shader)

# A lone body (no world), its export set before it enters the tree as a scene
# instantiated from the editor would have it, builds in its _ready() and draws
# with it.
func test_a_lone_placed_body_draws_with_its_shader() -> void:
	var custom := _shader("0.5")
	var holder := Node2D.new()
	autofree(holder)
	var source := Goo2D.new()
	source.radius = 40.0
	source.position = Vector2(400.0, 300.0)
	source.skin_shader = custom
	holder.add_child(source)
	source.owner = holder
	var packed := PackedScene.new()
	assert_eq(packed.pack(holder), OK)
	var scene := packed.instantiate() as Node2D
	add_child(scene)
	var body := scene.get_child(0) as Goo2D
	assert_not_null(body)
	if body == null:
		return
	await wait_frames(2)
	assert_gt(body.particle_count(), 0, "built in its _ready()")
	assert_eq(body.skin_shader, custom)
	assert_eq(_drawn_with(body), custom)
	assert_gt(int(_material(body).get_shader_parameter("point_count")), 0, "and its uniforms pushed")

func test_the_skin_follows_the_ring_rotation() -> void:
	# ring_rotation() is the best-fit rotation of the rest shape onto the beads
	# (GooLoop.best_fit_rotation()), what a shader needs to turn a pattern with
	# the body; the skin pushes it as the `rotation` uniform every time the
	# outline changes.
	var world := _world()
	var body := world.spawn(60.0, _middle(), GooShape.regular(4, 60.0))
	await wait_frames(2)
	assert_almost_eq(body.ring_rotation(), 0.0, 0.05, "a fresh square sits in its rest pose")
	var angle := 0.5
	var centre := body.center()
	var points := body.bead_points()
	for i: int in points.size():
		body.set_bead_position(i, centre + (points[i] - centre).rotated(angle))
	assert_almost_eq(body.ring_rotation(), angle, 0.02, "the beads were turned by 0.5 rad")
	await wait_frames(2)
	# Shape matching keeps the ring in its turned pose (the best fit is the
	# turned one), and the skin's uniform follows.
	assert_almost_eq(body.ring_rotation(), angle, 0.1, "still turned after a step")
	var pushed: float = _material(body).get_shader_parameter("rotation")
	assert_almost_eq(pushed, body.ring_rotation(), 0.05, "the skin pushed the rotation")
