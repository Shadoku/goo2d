class_name GooSkin
extends RefCounted
## The look of one blob's skin: a ShaderMaterial of the goo shader
## (res://addons/goo2d/goo.gdshader) of its own, and the per-blob uniforms that
## shader needs, pushed every frame by update(): the collision outline in global
## space (the shader measures each fragment's distance to it for the pseudo-3D
## rim), the centre, the radius, a smoothed velocity (motion ripple, bubbles
## trailing), and the bubble field: a seed (bubble layout), an origin and a cell
## size. The field is state the skin carries, not something derived from the
## blob's identity and size: it moves with the blob's centre, keeps its cell
## size when the radius changes, and inherit() copies it to a new skin, so the
## pieces of a split ring (and a merged ring) show exactly the bubbles that were
## there before.
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
## about its centre, see bubble_offset), `bubble_cell`, `bubble_turn` (radians:
## the bubble field is fixed in the body's rest pose, turned by `rotation` +
## `bubble_turn`, the turn it was inherited with), and a two-tone
## body's `second_color` (transparent black: none, the body is drawn in COLOR
## alone), `division_axis` (a unit vector in the body's rest space, pointing
## toward the second colour's side) and `division_offset` (px along it from the
## rest centroid to the division; set_two_tone()).
const UNIFORMS: PackedStringArray = ["point_count", "points", "center", "radius", "velocity",
	"rotation", "seed", "bubble_origin", "bubble_cell", "bubble_turn", "second_color",
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
## Where the bubble field's origin sits relative to the blob's centre (px, in
## the bubble field's frame: the rest pose turned by bubble_turn, so the origin
## turns with the body): zero for a blob of its own, the parent's origin seen
## from this blob's centre after inherit().
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
## Size, in px, of the bubble field's cells: max(radius * 0.48, 16) of the radius
## the first update() sees (0 until then), kept from then on, or the parent's
## after inherit().
var bubble_cell: float = 0.0

var _velocity: Vector2 = Vector2.ZERO
# The ring's own rotation last given to set_rotation(), and the roll motion_roll
# has added up so far: the `rotation` pushed is their sum.
var _ring_rotation: float = 0.0
var _roll: float = 0.0
var _points: PackedVector2Array = PackedVector2Array()
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
	if bubble_cell <= 0.0:
		bubble_cell = maxf(safe_radius * 0.48, MIN_BUBBLE_CELL * GooTuning.unit)
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
	if bubble_cell <= 0.0:
		bubble_cell = maxf(safe_radius * 0.48, MIN_BUBBLE_CELL * GooTuning.unit)
	_push_bubbles(safe_center)

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
	bubble_offset = (from_center + from.bubble_offset.rotated(turn) - own_center).rotated(-turn)
	if not bubble_offset.is_finite():
		bubble_offset = Vector2.ZERO
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
func set_two_tone(second: Color, axis: Vector2, offset: float) -> void:
	var unit := axis.normalized() if axis.is_finite() and axis.length_squared() > 0.0 else Vector2.RIGHT
	_push(&"second_color", second)
	_push(&"division_axis", unit)
	_push(&"division_offset", offset if is_finite(offset) else 0.0)

## Draws the body in one colour again (COLOR alone): `second_color`
## NO_SECOND_COLOR, the axis +x, the offset 0, as a new skin starts.
func clear_two_tone() -> void:
	set_two_tone(NO_SECOND_COLOR, Vector2.RIGHT, 0.0)

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
# turned by the rotation last pushed plus bubble_turn.
func _push_bubbles(center: Vector2) -> void:
	var angle: float = float(_pushed.get(&"rotation", 0.0)) + bubble_turn
	_push(&"bubble_origin", center + bubble_offset.rotated(angle))
	_push(&"bubble_cell", maxf(bubble_cell, 1.0))
	_push(&"bubble_turn", bubble_turn)

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
