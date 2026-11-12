class_name GooSkin
extends RefCounted
## The look of one blob's skin: a ShaderMaterial of the goo shader
## (res://addons/goo2d/goo.gdshader) of its own, and the per-blob uniforms that
## shader needs, pushed every frame by update(): the collision outline in global
## space (the shader measures each fragment's distance to it for the pseudo-3D
## rim), the centre, the radius, a smoothed velocity (motion ripple, bubbles
## trailing), and the bubble field: a seed (bubble layout), an origin and a cell
## size. The field is state the skin carries, not something derived from the
## blob's identity and size: it moves with the blob's centre, turns with it,
## and inherit() copies it to a new skin, so the pieces of a split ring (and a
## merged ring) show exactly the bubbles that were there before. It also
## follows the body's material as the body grows or shrinks and as its rest
## outline deforms (set_field_matrix(): Goo2D measures how its beads have
## moved in their rest space while it resizes, deforms or inflates): the field
## is fixed in the rest space it was made in, and the skin pushes the map from
## that space to the body's rest space now, its uniform scale in `bubble_cell`
## (and the origin's offset) and the rest, an area-keeping squash, as
## `bubble_basis`. A two-tone division is carried the same way. A body never
## resized, deformed, merged or cut pushes the identity and its cell as born,
## exactly as before.
##
## The shader is swappable: `shader` (set_shader()) draws the skin with another
## canvas_item shader, null meaning the addon's goo shader. The skin keeps
## pushing the same uniforms (UNIFORMS) whatever the shader declares, and
## remembers what it last pushed, so a swap on a live blob re-pushes them at
## once. The contract a replacement may rely on heads goo.gdshader.
##
## Everything here works headless: set_shader_parameter() only stores values, so
## tests can read them back with get_shader_parameter(). The shader itself only
## compiles under a real renderer (check.py's render stage).

const SHADER_PATH := "res://addons/goo2d/goo.gdshader"
## Size of the shader's points[] array. A loop with more points is resampled
## evenly down to this many; a shorter one is padded with its last point.
const MAX_POINTS: int = 32
## The uniforms the skin pushes, the contract a replacement shader may use (it
## may declare any subset; a value for a uniform a shader lacks is ignored
## silently): `point_count` (int), `points` (vec2[MAX_POINTS], the collision
## outline in global space), `center`, `radius`, `velocity` (smoothed, px/s),
## `rotation` (radians, the ring's best-fit rotation from its rest shape,
## set_rotation()), `seed`, `bubble_origin` (a point that turns with the body
## about its centre, see bubble_offset), `bubble_cell` (px: the field's cell
## times the body's growth since the field was made), `bubble_turn` (radians:
## the bubble field is fixed in the body's rest pose, turned by `rotation` +
## `bubble_turn`, the turn it was inherited with), `bubble_basis` (a mat2, a
## Transform2D here: the body's rest deformation since the field was made, in
## its rest space, with determinant 1, the scale being in bubble_cell; the
## identity for a body never deformed; see field_point() for the whole map),
## and a two-tone body's `second_color` (transparent black: none, the body is
## drawn in COLOR alone), `division_axis` (a unit vector in the body's rest
## space, pointing toward the second colour's side) and `division_offset` (px
## along it from the rest centroid to the division; set_two_tone(), carried
## with the material as the body grows and deforms).
const UNIFORMS: PackedStringArray = ["point_count", "points", "center", "radius", "velocity",
	"rotation", "seed", "bubble_origin", "bubble_cell", "bubble_turn", "bubble_basis", "second_color",
	"division_axis", "division_offset"]
## The `second_color` of a body drawn in one colour (clear_two_tone()):
## transparent black, which the shaders read as "the same as COLOR".
const NO_SECOND_COLOR := Color(0.0, 0.0, 0.0, 0.0)
## Time constant, in seconds, of the exponential smoothing of the velocity the
## shader sees: long enough to hide per-frame jitter of the beads' motion, short
## enough that a launch shows at once.
const VELOCITY_SMOOTHING: float = 0.1
## Speeds above this (px/s at GooTuning.unit 1, scaled by the unit) are
## clamped before smoothing.
const MAX_SPEED: float = 4000.0
## Smallest bubble cell, px at GooTuning.unit 1 (scaled by the unit): a blob's
## cell is 0.48 of its radius at birth, but no smaller than this.
const MIN_BUBBLE_CELL: float = 16.0
## Seconds the warm_up() polygon stays in the tree before freeing itself.
const WARM_UP_SECONDS: float = 0.25

# The addon's goo shader, loaded once and shared by every skin drawing with it.
static var _goo_shader: Shader
static var _instances: int = 0

## This skin's material; attach() puts it on a Polygon2D. It stays the same
## instance for the skin's life: a shader swap changes its `shader` only.
var material: ShaderMaterial
## The shader the skin draws with; null for the addon's goo shader (SHADER_PATH).
## Setting it is set_shader().
var shader: Shader = null:
	set = set_shader
## Random-looking per-instance value the shader hashes bubble cells with.
var noise_seed: float = 0.0
## Where the bubble field's origin sits relative to the blob's centre (in the
## bubble field's own frame and px: the rest pose turned by bubble_turn, at
## the size the field was made at, so the origin turns, grows and deforms with
## the body): zero for a blob of its own, the parent's origin seen from this
## blob's centre after inherit().
var bubble_offset: Vector2 = Vector2.ZERO
## How far the bubble field is turned from the body's rest pose, radians, on
## top of `rotation`: zero for a blob of its own; after inherit(), what keeps
## the parent's bubbles where they were while this body's rest pose differs.
var bubble_turn: float = 0.0
## How much the skin's patterns (the bubbles, a two-tone division, a facet
## cut: everything `rotation` turns) roll with the body's sideways motion, on
## top of the ring's own rotation: 1 turns them as a wheel of the body's
## radius would at its horizontal speed (a slick-surfaced goo slides more than
## it rolls, so its ring barely turns; this makes it read as rolling, and a
## straight fall still turns nothing); 0, the default, the ring's rotation
## alone. The roll so far (roll()) is kept and handed on by inherit().
var motion_roll: float = 0.0
## Size, in px of the field's own rest space, of the bubble field's cells:
## max(radius * 0.48, 16) of the radius the first update() sees (0 until then),
## kept from then on, or the parent's after inherit(). The `bubble_cell`
## pushed is this times the field matrix's scale (set_field_matrix()).
var bubble_cell: float = 0.0
## The global point the bubble field's origin is offset from (bubble_offset);
## not finite (the default): the `center` update() is given. A link's bridge
## puts it on the neck, which its polygon's centroid slides along.
var field_center: Vector2 = Vector2.INF

var _velocity: Vector2 = Vector2.ZERO
# The ring's own rotation last given to set_rotation(), and the roll motion_roll
# has added up so far: the `rotation` pushed is their sum.
var _ring_rotation: float = 0.0
var _roll: float = 0.0
var _points: PackedVector2Array = PackedVector2Array()
# The field matrix (field_matrix()), in the body's rest space.
var _field: Transform2D = Transform2D.IDENTITY
# A two-tone division in the field's rest space (set_two_tone(), carried by
# field_matrix() to the rest space now when pushed), and the field matrix it
# was last pushed with.
var _division_axis: Vector2 = Vector2.RIGHT
var _division_offset: float = 0.0
var _division_map: Transform2D = Transform2D.IDENTITY
# Every uniform the skin last pushed (_push()), by name: what set_shader()
# pushes again into a swapped shader.
var _pushed: Dictionary[StringName, Variant] = {}

func _init() -> void:
	material = ShaderMaterial.new()
	material.shader = _default_shader()
	_instances += 1
	# Golden-ratio steps spread consecutive seeds evenly, never repeating.
	noise_seed = fposmod(_instances * 0.6180339887, 1.0) * 97.0 + 1.0
	_push(&"seed", noise_seed)
	_points.resize(MAX_POINTS)
	_push(&"point_count", 0)
	_push(&"points", _points)
	_push(&"velocity", Vector2.ZERO)
	_push(&"rotation", 0.0)
	_push(&"bubble_basis", Transform2D.IDENTITY)
	clear_two_tone()

## Draws the skin with `new_shader` (null: the addon's goo shader) from now on:
## swaps the material's shader, the material itself staying the one attach()
## put on the polygon, and pushes again every uniform the skin last pushed, so
## a swap on a live blob shows it as it was at once. (A ShaderMaterial keeps its
## parameters across a shader swap, but the skin does not lean on that.)
func set_shader(new_shader: Shader) -> void:
	shader = new_shader
	material.shader = new_shader if new_shader != null else _default_shader()
	for uniform: StringName in _pushed:
		material.set_shader_parameter(uniform, _pushed[uniform])

# The addon's goo shader, loaded on first use.
static func _default_shader() -> Shader:
	if _goo_shader == null:
		_goo_shader = load(SHADER_PATH) as Shader
	return _goo_shader

## Adds to `parent` a tiny, fully transparent Polygon2D drawn with `with_shader`
## (null: the goo shader) through a skin of its own, every uniform pushed,
## which frees itself after WARM_UP_SECONDS. The renderer compiles a shader the
## first time something draws with it, so drawing this once at boot moves that
## hitch off the first blob's spawn, and makes the scene alone enough for
## check.py's render stage to catch that shader's errors. Call it once per
## shader the scene draws skins with.
static func warm_up(parent: Node, with_shader: Shader = null) -> Polygon2D:
	var polygon := Polygon2D.new()
	polygon.name = "GooWarmUp"
	polygon.polygon = PackedVector2Array([Vector2.ZERO, Vector2(4.0, 0.0), Vector2(0.0, 4.0)])
	# Transparent through its vertex colour, not its modulate: an item whose
	# modulate is transparent is skipped by the renderer and would not compile.
	polygon.color = Color(1.0, 1.0, 1.0, 0.0)
	var skin := GooSkin.new()
	skin.set_shader(with_shader)
	skin.attach(polygon)
	skin.update(polygon.polygon, Vector2.ONE, 2.0, Vector2.ZERO, 0.0)
	parent.add_child(polygon)
	polygon.get_tree().create_timer(WARM_UP_SECONDS).timeout.connect(polygon.queue_free)
	return polygon

## Draws `polygon` with this skin's material. Keep the polygon antialiased: the
## shader does not cut its edge.
func attach(polygon: Polygon2D) -> void:
	polygon.material = material

## Pushes this frame's uniforms: `loop` (the blob's collision outline, global
## space, a closed loop, at most MAX_POINTS after resampling), its `center`,
## `radius`, `velocity` (px/s) smoothed over `delta` seconds, and the bubble
## field's origin (`center` + bubble_offset) and cell.
func update(loop: PackedVector2Array, center: Vector2, radius: float, velocity: Vector2,
		delta: float) -> void:
	var count := loop.size()
	var source := loop
	if count > MAX_POINTS:
		source = GooLoop.resample(loop, MAX_POINTS)
		count = MAX_POINTS
	for i: int in MAX_POINTS:
		if i < count:
			_points[i] = source[i]
		elif count > 0:
			_points[i] = source[count - 1]
		else:
			_points[i] = center
	update_padded(_points, count, center, radius, velocity, delta)

## update() with the outline already as the shader takes it: `points` holds
## exactly MAX_POINTS points, the first `count` of them the outline and the rest
## padding (GooKernel.shader_points() hands it over like that).
func update_padded(points: PackedVector2Array, count: int, center: Vector2, radius: float,
		velocity: Vector2, delta: float) -> void:
	_push(&"point_count", count)
	_push(&"points", points)
	var safe_center := center if center.is_finite() else Vector2.ZERO
	var safe_radius := radius if is_finite(radius) else 0.0
	_push(&"center", safe_center)
	_push(&"radius", safe_radius)
	_advance_roll(velocity, safe_radius, delta)
	_push(&"velocity", _smooth_velocity(velocity, delta))
	_make_field(safe_radius)
	_push_bubbles(safe_center)

## update_padded() without the outline: the centre, radius and smoothed
## velocity (and the bubbles riding along) of a blob whose outline the shader
## already has.
func update_motion(center: Vector2, radius: float, velocity: Vector2, delta: float) -> void:
	var safe_center := center if center.is_finite() else Vector2.ZERO
	var safe_radius := radius if is_finite(radius) else 0.0
	_push(&"center", safe_center)
	_push(&"radius", safe_radius)
	_advance_roll(velocity, radius if is_finite(radius) else 0.0, delta)
	_push(&"velocity", _smooth_velocity(velocity, delta))
	_make_field(safe_radius)
	_push_bubbles(safe_center)

# The field is made on the first update: its cell from the `radius` then.
func _make_field(radius: float) -> void:
	if bubble_cell <= 0.0:
		bubble_cell = maxf(radius * 0.48, MIN_BUBBLE_CELL * GooTuning.unit)

## Sets the field matrix: the map from the rest space the bubble field was made
## in (and a two-tone division set in) to the body's rest space now, about its
## centre (the frame the ring's rotation turns into the world): how the body's
## material has grown and deformed since. The bubbles and the division follow
## it from the next update on. Goo2D measures it from its
## beads while its rest outline changes (a resize, a rest deformation, a
## merged or cut ring's inflate) and leaves it alone otherwise; the identity,
## the default, draws the field as made. A matrix with a determinant that is
## not positive, or not finite, is ignored.
func set_field_matrix(map: Transform2D) -> void:
	map.origin = Vector2.ZERO
	if not map.is_finite() or map.determinant() <= 0.0:
		return
	_field = map

## The field matrix (set_field_matrix()): the identity for a body never
## resized, deformed, merged or cut; after inherit(), the parent's as seen from
## this body.
func field_matrix() -> Transform2D:
	return _field

# The field matrix as the shader's frame sees it: that frame turns with the
# roll as well as the ring (motion_roll), so the rest-space matrix is turned
# back by the roll; the matrix itself without a roll.
func _pattern_field() -> Transform2D:
	if _roll == 0.0 or _field == Transform2D.IDENTITY:
		return _field
	return Transform2D(-_roll, Vector2.ZERO) * _field * Transform2D(_roll, Vector2.ZERO)

# A matrix that is a plain positive scale (the same along both axes, no turn or
# shear): that scale; 0 for any other.
static func _plain_scale(map: Transform2D) -> float:
	if map.x.y == 0.0 and map.y.x == 0.0 and map.x.x == map.y.y and map.x.x > 0.0:
		return map.x.x
	return 0.0

## Takes over the bubble field of `from` (another blob's skin, its centre at
## `from_center` now) for a blob centred at `own_center`: the same seed and cell
## size, the origin where `from`'s is, and `from`'s smoothed velocity (so the
## bubbles' lag and the ripple do not jump). The world-space bubbles of both
## skins coincide right after, and later update()s move them with this blob.
## Used by the pieces of a split ring and by a merged ring.
## `from_rotation` and `own_rotation` (radians) are the two rings' rotations
## from their rest poses (Goo2D.ring_rotation()) right now: the field keeps
## turning as `from` had it (bubble_turn), whatever this ring's rest pose is.
func inherit(from: GooSkin, from_center: Vector2, own_center: Vector2,
		from_rotation: float = 0.0, own_rotation: float = 0.0) -> void:
	if from == null:
		return
	noise_seed = from.noise_seed
	bubble_cell = from.bubble_cell
	_velocity = from._velocity
	motion_roll = from.motion_roll
	_roll = from._roll
	_ring_rotation = own_rotation if is_finite(own_rotation) else 0.0
	# The field's turn in the world: the parent's ring rotation, roll and turn.
	var turn := from_rotation + from._roll + from.bubble_turn
	bubble_turn = turn - (_ring_rotation + _roll)
	if not is_finite(bubble_turn):
		bubble_turn = 0.0
		turn = _ring_rotation + _roll
	# What the parent's field had grown and deformed by is carried over: the
	# field matrix, seen from this body's rest space, so nothing jumps.
	var from_map := from._pattern_field()
	var scale := _plain_scale(from_map)
	if from_map == Transform2D.IDENTITY:
		_field = Transform2D.IDENTITY
		bubble_offset = (from_center + from.bubble_offset.rotated(turn) - own_center).rotated(-turn)
	else:
		# The parent's map from its field to the world, about its centre:
		# R(its rotation) × its matrix × R(its bubble_turn); the same map seen
		# from this body's frame, turned `delta` from the parent's (a plain
		# scale looks the same from any frame).
		var from_turn := from_rotation + from._roll
		var origin := from_center + from_map.basis_xform(from.bubble_offset.rotated(from.bubble_turn)).rotated(from_turn)
		var delta := from_turn - (_ring_rotation + _roll)
		var carried := from_map if scale > 0.0 \
			else Transform2D(delta, Vector2.ZERO) * from_map * Transform2D(-delta, Vector2.ZERO)
		_field = carried if _roll == 0.0 or scale > 0.0 \
			else Transform2D(_roll, Vector2.ZERO) * carried * Transform2D(-_roll, Vector2.ZERO)
		bubble_offset = carried.affine_inverse().basis_xform((origin - own_center).rotated(-(_ring_rotation + _roll))) \
			.rotated(-bubble_turn)
	if not bubble_offset.is_finite():
		bubble_offset = Vector2.ZERO
	if not _field.is_finite() or _field.determinant() <= 0.0:
		_field = Transform2D.IDENTITY
	_rebase_division()
	_push(&"seed", noise_seed)
	_push(&"velocity", _velocity)
	_push(&"rotation", _ring_rotation + _roll)
	_push_bubbles(own_center if own_center.is_finite() else Vector2.ZERO)

## Pushes `angle` (radians) as the `rotation` uniform: how far the body has
## turned from its rest pose (Goo2D.ring_rotation(), the best-fit rotation of
## the rest shape onto the beads), so a shader can turn a pattern with the
## body. Goo2D pushes it whenever the outline changes.
func set_rotation(angle: float) -> void:
	_ring_rotation = angle if is_finite(angle) else 0.0
	_push(&"rotation", _ring_rotation + _roll)

## The roll motion_roll has added to `rotation` so far, radians.
func roll() -> float:
	return _roll

# Adds this frame's roll (motion_roll × the turn a wheel of `radius` makes
# moving velocity.x × delta; y-down: moving right turns clockwise, positive)
# and pushes the rotation with it.
func _advance_roll(velocity: Vector2, radius: float, delta: float) -> void:
	if motion_roll == 0.0 or radius <= 0.0 or delta <= 0.0 or not velocity.is_finite():
		return
	_roll += velocity.x * delta / radius * motion_roll
	_push(&"rotation", _ring_rotation + _roll)

## Draws the body in two colours: COLOR (the Skin's colour) on one side of a
## division and `second` on the other. The division is a straight line fixed
## in the body's rest space (the frame `rotation` turns into the world, about
## `center`): `axis` (normalised here) points toward `second`'s side, and
## `offset` is how far along it, in px from the rest centroid, the line
## crosses it (0: through the centre). Pushed at once, so a settled body (whose
## skin no longer updates) shows it too; remembered like every uniform.
## The division is given in the body's rest space as it is now (px at its size
## now, deformed as it is now) and stays on that material from then on: as the
## body grows or deforms (set_field_matrix()) the line pushed is the same
## material's.
func set_two_tone(second: Color, axis: Vector2, offset: float) -> void:
	var unit := axis.normalized() if axis.is_finite() and axis.length_squared() > 0.0 else Vector2.RIGHT
	_push(&"second_color", second)
	_set_division(unit, offset if is_finite(offset) else 0.0)

# Keeps the division `axis` (unit) and `offset` given in the rest space now,
# carried back into the field's rest space, and pushes it.
func _set_division(axis: Vector2, offset: float) -> void:
	var map := _pattern_field()
	_division_axis = axis
	_division_offset = offset
	var scale := _plain_scale(map)
	if scale > 0.0:
		_division_offset = offset / scale
	elif map != Transform2D.IDENTITY:
		# The line {x: x·axis = offset} of the rest space now is {r: r·(Mᵀ axis) =
		# offset} of the field's, M the field matrix.
		var normal := map.basis_xform_inv(axis)
		var length := normal.length()
		if length > 0.000001 and normal.is_finite():
			_division_axis = normal / length
			_division_offset = offset / length
	_push_division(map)

# Pushes the division kept in the field's rest space as it lies in the rest
# space now, through `map` (_pattern_field()).
func _push_division(map: Transform2D) -> void:
	_division_map = map
	var scale := _plain_scale(map)
	if map == Transform2D.IDENTITY or scale > 0.0:
		_push(&"division_axis", _division_axis)
		_push(&"division_offset", _division_offset * (scale if scale > 0.0 else 1.0))
		return
	# {r: r·a = o} carried by M is {x: x·(M⁻ᵀ a) = o}; normalised to px.
	var normal := map.affine_inverse().basis_xform_inv(_division_axis)
	var length := normal.length()
	if length <= 0.000001 or not normal.is_finite():
		return
	_push(&"division_axis", normal / length)
	_push(&"division_offset", _division_offset / length)

# The field matrix changed under the division without the body moving (a
# field inherited): keeps the division where it was drawn.
func _rebase_division() -> void:
	var axis: Variant = _pushed.get(&"division_axis", Vector2.RIGHT)
	var offset: Variant = _pushed.get(&"division_offset", 0.0)
	_set_division(axis as Vector2, float(offset))

## Draws the body in one colour again (COLOR alone): `second_color`
## NO_SECOND_COLOR, the axis +x, the offset 0, as a new skin starts.
func clear_two_tone() -> void:
	set_two_tone(NO_SECOND_COLOR, Vector2.RIGHT, 0.0)

## Where the global `point` lies in the bubble field `material` draws (a skin's
## material, its uniforms as GooSkin last pushed them), in cells: the shader's
## map, goo.gdshader's "Bubbles" block (keep the two in sync), up to the bubble
## layer's uv before its seed offset. `drift` is what the shader adds to the
## point first, the rise and the lag ((0, TIME × bubble_speed) − velocity ×
## bubble_lag): zero, the default, is the field at TIME 0 of a body at rest (or
## of a game that sets both to 0). A point fixed in the body's material keeps
## its field_point() as the body moves, turns, grows and deforms; times the
## skin's bubble_cell it is in the field's own px (the rest space the field
## was made in).
static func field_point(from: ShaderMaterial, point: Vector2, drift: Vector2 = Vector2.ZERO) -> Vector2:
	var origin: Variant = from.get_shader_parameter(&"bubble_origin")
	var rotation: Variant = from.get_shader_parameter(&"rotation")
	var turn: Variant = from.get_shader_parameter(&"bubble_turn")
	var basis: Variant = from.get_shader_parameter(&"bubble_basis")
	var cell: Variant = from.get_shader_parameter(&"bubble_cell")
	var bd := point - (origin as Vector2 if origin != null else Vector2.ZERO) + drift
	var rest := bd.rotated(-(float(rotation) if rotation != null else 0.0))
	if basis is Transform2D and basis != Transform2D.IDENTITY:
		rest = (basis as Transform2D).affine_inverse().basis_xform(rest)
	var lp := rest.rotated(-(float(turn) if turn != null else 0.0))
	return lp / maxf(float(cell) if cell != null else 1.0, 0.000001)

## The smoothed velocity the shader was last given, px/s.
func smoothed_velocity() -> Vector2:
	return _velocity

## Sets the smoothed velocity to zero and gives the shader that, as for a blob
## at rest: once its smoothing has all but died away, it is not worth
## updating the uniforms further (Goo2D stops calling update() on a settled
## ring).
func stop() -> void:
	_velocity = Vector2.ZERO
	_push(&"velocity", _velocity)

# The field's origin turns with the body: the offset, in the field's frame, is
# turned by bubble_turn into the rest space, carried by the field matrix
# (growth and deformation) and turned by the rotation last pushed. The matrix
# is pushed as its uniform scale (into the cell) and the rest (bubble_basis,
# determinant 1); the identity pushes the cell as born.
func _push_bubbles(center: Vector2) -> void:
	var rotation: float = float(_pushed.get(&"rotation", 0.0))
	var from := field_center if field_center.is_finite() else center
	var map := _pattern_field()
	if map == Transform2D.IDENTITY:
		_push(&"bubble_origin", from + bubble_offset.rotated(rotation + bubble_turn))
		_push(&"bubble_cell", maxf(bubble_cell, 1.0))
		_push(&"bubble_basis", Transform2D.IDENTITY)
	else:
		var scale := _plain_scale(map)
		var basis := Transform2D.IDENTITY
		if scale <= 0.0:
			scale = sqrt(absf(map.determinant()))
			if scale <= 0.000001 or not is_finite(scale):
				scale = 1.0
			basis = Transform2D(map.x / scale, map.y / scale, Vector2.ZERO)
		_push(&"bubble_origin", from + map.basis_xform(bubble_offset.rotated(bubble_turn)).rotated(rotation))
		_push(&"bubble_cell", maxf(bubble_cell * scale, 1.0))
		_push(&"bubble_basis", basis)
	_push(&"bubble_turn", bubble_turn)
	if map != _division_map:
		_push_division(map)

func _smooth_velocity(velocity: Vector2, delta: float) -> Vector2:
	if not velocity.is_finite() or not is_finite(delta) or delta <= 0.0:
		return _velocity
	var target := velocity.limit_length(MAX_SPEED * GooTuning.unit)
	_velocity = _velocity.lerp(target, 1.0 - exp(-delta / VELOCITY_SMOOTHING))
	return _velocity

# Sets the uniform `uniform` to `value` and remembers it for set_shader().
func _push(uniform: StringName, value: Variant) -> void:
	_pushed[uniform] = value
	material.set_shader_parameter(uniform, value)
