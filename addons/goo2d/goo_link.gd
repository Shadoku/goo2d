class_name GooLink
extends RefCounted
## One link between two bodies of a GooWorld2D (GooWorld2D.link()): what the
## world keeps about it (the bodies, its strength, rest angle and anchors) and
## its bridge skin, plus the link's geometry as pure static functions.
##
## A link ties a patch of beads on body `a` to a patch on body `b`, pair by
## pair, in the world's kernel (GooKernel.add_link(), the kernel's links.rs):
## compliant distance constraints between the pairs and an angular term pulling
## the bodies' relative rotation toward the link's rest angle. Each patch is
## named by an anchor, a point in its body's REST space (the frame of
## Goo2D.rest_shape), so it survives the ring being rebuilt: the bead nearest
## it is the patch's middle (patch()). `strength` (0..1) sets how wide the
## patches are: at 1 about the smaller body's radius (GooTuning.LINK_PATCH_RATIO),
## down to one pair, a thread; it also scales the angular term.
##
## The bridge skin: a polygon spanning the neck between the two outlines
## (bridge_polygon()), drawn under every body (an internal child of the world,
## in front of its other children, so the bodies' skins cover the parts inside
## them) with a goo skin of its own (a GooSkin whose outline is the bridge, so
## the shader's rim runs along the neck's waist), in the larger body's tint,
## shader and look uniforms (followed whenever they change, follow_look()).
## The pair reads as one blob with a waist. Its bubble field rides the neck's
## material: the neck's beads (both patches with the beads beyond their ends
## that pass through, through_a and through_b) are its material points; the
## field's origin is their mean (GooSkin.field_center, where the polygon's
## centroid would slide as its outline changes) and its map the affine one that
## best carries their places in the field to where they are now (least squares,
## GooSkin.set_field_matrix(), the bridge's `rotation` left at 0: the turn is
## in the map), so the neck's bubbles turn as the pair turns, stretch as it is
## pulled, shear as a joint bends and grow as a body does. Their places are
## read off the field when the bridge is first drawn and again whenever the
## patch is tied anew or a body re-rung (the link sent again), the origin kept
## where it was, so nothing jumps.

## Points along each of the bridge's two waist curves.
const BRIDGE_SAMPLES: int = 8
## How far toward the neck's axis a waist curve's control point may be pulled,
## as a fraction of the way from its chord's middle to the axis (the curves
## then never reach the axis, so they never cross).
const BRIDGE_WAIST_MAX: float = 0.6
## The pull used when the outlines' tangents give none.
const BRIDGE_WAIST: float = 0.3
## The least pull: a thick neck still reads as a waist, not a band.
const BRIDGE_WAIST_MIN: float = 0.2

## The link's handle in its world (and its id in the kernel).
var handle: int = -1
## The two bodies.
var a: Goo2D
var b: Goo2D
## 0..1: the patch's width (and the angular term's stiffness).
var strength: float = 1.0
## Radians the rest pose turns `b` relative to `a` (0: as linked).
var rest_angle: float = 0.0
## The patches' middles, in each body's rest space.
var anchor_a: Vector2 = Vector2.ZERO
var anchor_b: Vector2 = Vector2.ZERO
## The patch as last sent to the kernel: tied bead pairs, flat [bead of a,
## bead of b, ...], and the beads of each that pass through the other's.
var pairs: PackedInt32Array = PackedInt32Array()
var through_a: PackedInt32Array = PackedInt32Array()
var through_b: PackedInt32Array = PackedInt32Array()
## The bridge: its polygon (in the world's space) and skin; null until drawn.
var bridge: Polygon2D = null
var skin: GooSkin = null

var _drawn_versions: Vector2i = Vector2i(-2, -2)
var _look_shader: Shader = null
# The look uniforms follow_look() copies (those the larger body's shader
# declares that are not GooSkin.UNIFORMS), read once per shader.
var _look_names: Array[StringName] = []
# The neck's beads the bridge's field follows (through_a, then through_b, as
# they were when their places were read) and their places in the field, about
# their mean.
var _neck_beads: PackedInt32Array = PackedInt32Array()
var _neck_places: PackedVector2Array = PackedVector2Array()
# Their mean when last drawn: the field's origin is kept where it was when the
# beads change (GooSkin.bubble_offset takes up the move).
var _neck_mean: Vector2 = Vector2.INF
# The bodies' bead counts when the places were read: a re-rung body's beads
# are other beads under the same indices until the link is tied again.
var _neck_counts: Vector2i = Vector2i(-1, -1)

func _init(link_handle: int, body_a: Goo2D, body_b: Goo2D, link_strength: float,
		rest_anchor_a: Vector2, rest_anchor_b: Vector2) -> void:
	handle = link_handle
	a = body_a
	b = body_b
	strength = clampf(link_strength, 0.0, 1.0)
	anchor_a = rest_anchor_a
	anchor_b = rest_anchor_b

## Sends the link to `kernel` (again: the patch recomputed from the anchors on
## the bodies' rings as they are now, eased in from where they are). False if
## the kernel refused it (a ring missing).
func attach(kernel: GooKernel) -> bool:
	var patch_info := patch(a.rest_shape, anchor_a, b.rest_shape, anchor_b, strength, a.radius, b.radius)
	pairs = patch_info["pairs"]
	through_a = patch_info["through_a"]
	through_b = patch_info["through_b"]
	var params := kernel_params(a.bead_radius(), b.bead_radius(), strength, rest_angle)
	# The way the farthest pair has to close, at GooTuning.link_ease_speed().
	var farthest := 0.0
	for k: int in range(0, pairs.size() - 1, 2):
		farthest = maxf(farthest, a.bead_position(pairs[k]).distance_to(b.bead_position(pairs[k + 1])))
	params["ease_time"] = ease_time(farthest - float(params["gap"]))
	return kernel.add_link(handle, a.get_instance_id(), b.get_instance_id(), pairs, through_a, through_b, params)

## Seconds a new link eases in over when its pairs have up to `way` px to
## close: GooTuning.LINK_EASE_TIME, or longer at GooTuning.link_ease_speed().
static func ease_time(way: float) -> float:
	return maxf(GooTuning.LINK_EASE_TIME, absf(way) / GooTuning.link_ease_speed())

## The kernel's knobs for a link between bodies of bead radii `bead_a` and
## `bead_b` at `link_strength` and `angle` (GooKernel.add_link()'s params; its
## ease_time the shortest, GooTuning.LINK_EASE_TIME: attach() lengthens it
## for bodies linked apart).
static func kernel_params(bead_a: float, bead_b: float, link_strength: float, angle: float) -> Dictionary:
	var s := clampf(link_strength, 0.0, 1.0)
	return {
		"gap": GooTuning.LINK_GAP * (bead_a + bead_b),
		"stiffness": GooTuning.LINK_STIFFNESS,
		"damping": GooTuning.LINK_DAMPING,
		"bend_stiffness": GooTuning.LINK_BEND_STIFFNESS * s,
		"bend_damping": GooTuning.LINK_BEND_DAMPING * sqrt(s),
		"rest_angle": angle,
		"ease_time": GooTuning.LINK_EASE_TIME,
		"min_rest": GooTuning.LINK_MIN_REST * (bead_a + bead_b),
	}

## The anchors facing each other on `body_a` and `body_b` as they are now:
## the rest-space points of the closest pair of their beads, [anchor of a,
## anchor of b].
static func facing_anchors(body_a: Goo2D, body_b: Goo2D) -> PackedVector2Array:
	var points_a := body_a.bead_points()
	var points_b := body_b.bead_points()
	var best := INF
	var pair := Vector2i.ZERO
	for i: int in points_a.size():
		for j: int in points_b.size():
			var d := points_a[i].distance_squared_to(points_b[j])
			if d < best:
				best = d
				pair = Vector2i(i, j)
	var rest_a := body_a.rest_shape
	var rest_b := body_b.rest_shape
	if pair.x >= rest_a.size() or pair.y >= rest_b.size():
		return PackedVector2Array([Vector2.ZERO, Vector2.ZERO])
	return PackedVector2Array([rest_a[pair.x], rest_b[pair.y]])

## The rest-space point of `body` nearest the global `point` on its bead loop
## (an anchor given in the world, turned into the body's rest frame).
static func rest_anchor(body: Goo2D, point: Vector2) -> Vector2:
	var points := body.bead_points()
	var best := INF
	var nearest := 0
	for i: int in points.size():
		var d := points[i].distance_squared_to(point)
		if d < best:
			best = d
			nearest = i
	return body.rest_shape[nearest] if nearest < body.rest_shape.size() else Vector2.ZERO

## The tied patch of a link at `link_strength` between rings whose rest loops
## are `rest_a` and `rest_b` (bead order, in their rest spaces), anchored at
## `anchor_a` and `anchor_b` there, of radii `radius_a` and `radius_b`:
## { "pairs": flat [bead of a, bead of b, ...] from one side of the neck to the
## other, "through_a", "through_b": the tied beads of each and
## GooTuning.LINK_THROUGH_BEADS more beyond either end }. The patch is about
## link_strength × LINK_PATCH_RATIO × the smaller radius wide: 2m + 1 pairs,
## m from the wider bead spacing of the two (0 at least: one pair), each
## ring's beads stepped by its own spacing so the pairs face each other, and
## b's run the other way along its loop (facing patches of two loops of the
## same winding run opposite ways). At most half of either ring is tied.
static func patch(rest_a: PackedVector2Array, rest_anchor_a: Vector2, rest_b: PackedVector2Array,
		rest_anchor_b: Vector2, link_strength: float, radius_a: float, radius_b: float) -> Dictionary:
	var result := { "pairs": PackedInt32Array(), "through_a": PackedInt32Array(), "through_b": PackedInt32Array() }
	var count_a := rest_a.size()
	var count_b := rest_b.size()
	if count_a < 3 or count_b < 3:
		return result
	var mid_a := _nearest(rest_a, rest_anchor_a)
	var mid_b := _nearest(rest_b, rest_anchor_b)
	var spacing_a := GooLoop.perimeter(rest_a) / count_a
	var spacing_b := GooLoop.perimeter(rest_b) / count_b
	var spacing := maxf(spacing_a, spacing_b)
	var width := clampf(link_strength, 0.0, 1.0) * GooTuning.LINK_PATCH_RATIO * minf(radius_a, radius_b)
	var half := roundi(0.5 * width / maxf(spacing, 0.000001))
	# At most a quarter of either ring on each side.
	half = mini(half, mini(int(count_a * 0.25 * spacing_a / spacing), int(count_b * 0.25 * spacing_b / spacing)))
	half = maxi(half, 0)
	var run_b := -1 if GooLoop.is_ccw(rest_a) == GooLoop.is_ccw(rest_b) else 1
	var pairs_out := PackedInt32Array()
	var lowest := Vector2i(0, 0)
	var highest := Vector2i(0, 0)
	for k: int in range(-half, half + 1):
		var step_a := roundi(k * spacing / spacing_a)
		var step_b := roundi(k * spacing / spacing_b)
		pairs_out.append(posmod(mid_a + step_a, count_a))
		pairs_out.append(posmod(mid_b + run_b * step_b, count_b))
		lowest = Vector2i(mini(lowest.x, step_a), mini(lowest.y, step_b))
		highest = Vector2i(maxi(highest.x, step_a), maxi(highest.y, step_b))
	var extra := GooTuning.LINK_THROUGH_BEADS
	var through_a_out := PackedInt32Array()
	for step: int in range(lowest.x - extra, highest.x + extra + 1):
		var bead := posmod(mid_a + step, count_a)
		if not through_a_out.has(bead):
			through_a_out.append(bead)
	var through_b_out := PackedInt32Array()
	for step: int in range(lowest.y - extra, highest.y + extra + 1):
		var bead := posmod(mid_b + run_b * step, count_b)
		if not through_b_out.has(bead):
			through_b_out.append(bead)
	result["pairs"] = pairs_out
	result["through_a"] = through_a_out
	result["through_b"] = through_b_out
	return result

static func _nearest(points: PackedVector2Array, target: Vector2) -> int:
	var best := INF
	var nearest := 0
	for i: int in points.size():
		var d := points[i].distance_squared_to(target)
		if d < best:
			best = d
			nearest = i
	return nearest

## The bridge skin's polygon (global, like the bead loops it is built from)
## between body a, whose bead centres are `points_a` with beads of
## `bead_radius_a` px, tied at its beads `beads_a` (in pair order), and body b
## (`points_b`, `beads_b` the partners, `bead_radius_b`): a closed simple
## polygon spanning the neck, empty if nothing can be built. Its ends on each
## body are the beads one beyond the outermost tied ones (so a thread has a
## neck too), pushed out to the collision outline (a bead radius along the
## loop's outward normal); between them it reaches back into each body
## (halfway from the patch's middle bead to the body's centre, where the
## body's own skin covers it) and crosses the gap along two waist curves, one
## each side of the neck's axis (the line through the patches' middles): a
## quadratic from one body's end to the other's, its control point where the
## two outlines' tangents at the ends meet (so the waist leaves each outline
## smoothly), kept between BRIDGE_WAIST_MIN and BRIDGE_WAIST_MAX of the way
## from the chord's middle to the axis (so the two curves never cross). A polygon that still cannot be
## triangulated (bodies folded into each other) falls back to the convex hull
## of its corner points, which always can.
static func bridge_polygon(points_a: PackedVector2Array, beads_a: PackedInt32Array, bead_radius_a: float,
		points_b: PackedVector2Array, beads_b: PackedInt32Array, bead_radius_b: float) -> PackedVector2Array:
	var count_a := points_a.size()
	var count_b := points_b.size()
	if count_a < 3 or count_b < 3 or beads_a.is_empty() or beads_a.size() != beads_b.size():
		return PackedVector2Array()
	var middle := beads_a.size() / 2
	var mid_a := points_a[posmod(beads_a[middle], count_a)]
	var mid_b := points_b[posmod(beads_b[middle], count_b)]
	var axis := mid_b - mid_a
	if axis.length_squared() < 0.000001:
		axis = GooLoop.centroid(points_b) - GooLoop.centroid(points_a)
	if axis.length_squared() < 0.000001:
		return PackedVector2Array()
	axis = axis.normalized()
	var across := Vector2(-axis.y, axis.x)
	var ends_a := _ends(points_a, beads_a, mid_a, across)
	var ends_b := _ends(points_b, beads_b, mid_a, across)
	var a_minus := _out(points_a, ends_a.x, bead_radius_a)
	var a_plus := _out(points_a, ends_a.y, bead_radius_a)
	var b_minus := _out(points_b, ends_b.x, bead_radius_b)
	var b_plus := _out(points_b, ends_b.y, bead_radius_b)
	var inner_a := mid_a.lerp(GooLoop.centroid(points_a), 0.5)
	var inner_b := mid_b.lerp(GooLoop.centroid(points_b), 0.5)
	var axis_from := mid_a
	var corners := PackedVector2Array([a_minus, inner_a, a_plus, b_plus, inner_b, b_minus])
	var on_sides := (a_minus - axis_from).dot(across) < 0.0 and (b_minus - axis_from).dot(across) < 0.0 \
		and (a_plus - axis_from).dot(across) > 0.0 and (b_plus - axis_from).dot(across) > 0.0
	var polygon := PackedVector2Array()
	if on_sides:
		polygon.append(a_minus)
		polygon.append(inner_a)
		polygon.append(a_plus)
		polygon.append_array(_waist(a_plus, _tangent(points_a, ends_a.y, ends_a.w), b_plus,
			_tangent(points_b, ends_b.y, ends_b.w), axis_from, axis))
		polygon.append(inner_b)
		polygon.append(b_minus)
		polygon.append_array(_waist(b_minus, _tangent(points_b, ends_b.x, ends_b.z), a_minus,
			_tangent(points_a, ends_a.x, ends_a.z), axis_from, axis))
		if GooLoop.signed_area(polygon) > 0.0:
			polygon.reverse()
		if not Geometry2D.triangulate_polygon(polygon).is_empty() and not GooLoop.self_intersects(polygon):
			return polygon
	var hull := Geometry2D.convex_hull(corners)
	if hull.size() > 1 and hull[0] == hull[hull.size() - 1]:
		hull.remove_at(hull.size() - 1)
	if hull.size() < 3 or Geometry2D.triangulate_polygon(hull).is_empty():
		return PackedVector2Array()
	if GooLoop.signed_area(hull) > 0.0:
		hull.reverse()
	return hull

# The bridge's end beads on one body tied at `beads` (pair order): one bead
# beyond each end of the patch along the loop, as Vector4i(the end on the
# −`across` side of the axis through `from`, the end on the +`across` side,
# the step (±1) that walks from the first back into the patch, the same for
# the second).
static func _ends(points: PackedVector2Array, beads: PackedInt32Array, from: Vector2,
		across: Vector2) -> Vector4i:
	var count := points.size()
	var first := posmod(beads[0], count)
	var last := posmod(beads[beads.size() - 1], count)
	var run := 1
	if beads.size() > 1:
		var forward := posmod(last - first, count)
		run = 1 if forward <= count / 2 else -1
	var lo := posmod(first - run, count)
	var hi := posmod(last + run, count)
	# lo walks back into the patch by +run, hi by −run.
	if (points[lo] - from).dot(across) <= (points[hi] - from).dot(across):
		return Vector4i(lo, hi, run, -run)
	return Vector4i(hi, lo, -run, run)

# Bead `i` of the loop pushed out `distance` along its outward normal.
static func _out(points: PackedVector2Array, i: int, distance: float) -> Vector2:
	var count := points.size()
	var edge := points[(i + 1) % count] - points[(i + count - 1) % count]
	var normal := Vector2(-edge.y, edge.x).normalized()
	if not GooLoop.is_ccw(points):
		normal = -normal
	return points[i] + normal * distance

# The loop's direction at bead `i` walking `step` (±1) along it.
static func _tangent(points: PackedVector2Array, i: int, step: int) -> Vector2:
	var count := points.size()
	return (points[posmod(i + step, count)] - points[posmod(i - step, count)]).normalized()

# The waist curve from `from` (leaving it along `from_dir`) to `to` (arriving
# against `to_dir`, which points from `to` back along its outline toward the
# neck), sampled with BRIDGE_SAMPLES points between its ends (ends excluded),
# its control point kept on its side of the axis through `axis_from` along
# `axis` (see bridge_polygon()).
static func _waist(from: Vector2, from_dir: Vector2, to: Vector2, to_dir: Vector2, axis_from: Vector2,
		axis: Vector2) -> PackedVector2Array:
	var chord_middle := (from + to) * 0.5
	var on_axis := axis_from + axis * (chord_middle - axis_from).dot(axis)
	var toward := on_axis - chord_middle
	var pull := BRIDGE_WAIST
	if toward.length_squared() > 0.000001:
		var meet: Variant = Geometry2D.line_intersects_line(from, from_dir, to, to_dir)
		if meet != null:
			var point: Vector2 = meet
			if (point - from).dot(from_dir) > 0.0 and (point - to).dot(to_dir) > 0.0:
				pull = clampf((point - chord_middle).dot(toward) / toward.length_squared(), BRIDGE_WAIST_MIN,
					BRIDGE_WAIST_MAX)
	var control := chord_middle + toward * pull
	var samples := PackedVector2Array()
	for k: int in range(1, BRIDGE_SAMPLES + 1):
		var t := float(k) / (BRIDGE_SAMPLES + 1)
		samples.append(from.lerp(control, t).lerp(control.lerp(to, t), t))
	return samples

## Draws the bridge under `world`'s bodies (in `holder`, the world's internal
## node for bridges) for this frame: the polygon from the bodies' beads as they
## are now, its skin's uniforms, the larger body's tint, shader and look. Skips
## the work while both bodies' skins are unchanged and settled.
func draw_bridge(holder: Node2D, kernel: GooKernel, delta: float) -> void:
	if pairs.size() < 2 or not is_instance_valid(a) or not is_instance_valid(b):
		return
	var versions := Vector2i(kernel.skin_version(a.get_instance_id()), kernel.skin_version(b.get_instance_id()))
	var big := a if a.radius >= b.radius else b
	if bridge == null:
		bridge = Polygon2D.new()
		bridge.name = "Bridge%d" % handle
		bridge.antialiased = true
		skin = GooSkin.new()
		skin.attach(bridge)
		holder.add_child(bridge)
	if skin.shader != big.skin_shader or _look_shader == null:
		skin.set_shader(big.skin_shader)
		_copy_look(big)
	else:
		follow_look()
	bridge.color = big.get_tint()
	if versions == _drawn_versions and a.settled and b.settled:
		return
	_drawn_versions = versions
	var beads_a := PackedInt32Array()
	var beads_b := PackedInt32Array()
	for k: int in range(0, pairs.size() - 1, 2):
		beads_a.append(pairs[k])
		beads_b.append(pairs[k + 1])
	var polygon := bridge_polygon(a.bead_points(), beads_a, a.bead_radius(), b.bead_points(), beads_b,
		b.bead_radius())
	if polygon.is_empty():
		return
	var centre := GooLoop.centroid(polygon)
	var to_local := holder.get_global_transform().affine_inverse()
	bridge.polygon = to_local * polygon if to_local != Transform2D.IDENTITY else polygon
	_follow_neck()
	skin.update(polygon, centre, minf(a.radius, b.radius), (a.average_velocity() + b.average_velocity()) * 0.5,
		delta)

# The bridge's field follows the neck's beads (see the head): the origin on
# their mean, the map fitted to their places (read again when the patch
# changed).
func _follow_neck() -> void:
	var points_a := a.bead_points()
	var points_b := b.bead_points()
	var beads := through_a + through_b
	var points := PackedVector2Array()
	for k: int in beads.size():
		var on_a := k < through_a.size()
		var loop := points_a if on_a else points_b
		if loop.is_empty():
			return
		points.append(loop[posmod(beads[k], loop.size())])
	var count := points.size()
	if count < 2:
		return
	var mean := Vector2.ZERO
	for point: Vector2 in points:
		mean += point
	mean /= count
	var places := PackedVector2Array()
	places.resize(count)
	for i: int in count:
		places[i] = points[i] - mean
	var counts := Vector2i(points_a.size(), points_b.size())
	if beads != _neck_beads or counts != _neck_counts or _neck_places.size() != count:
		# Their places in the field as it is now; the field's origin kept where
		# it was (a new set of beads has another mean).
		var back := skin.field_matrix().affine_inverse()
		for i: int in count:
			places[i] = back.basis_xform(places[i])
		if _neck_mean.is_finite():
			skin.bubble_offset += back.basis_xform(_neck_mean - mean)
		_neck_beads = beads
		_neck_counts = counts
		_neck_places = places
	else:
		skin.set_field_matrix(GooLoop.affine_fit(_neck_places, places))
	skin.field_center = mean
	_neck_mean = mean

# Copies the larger body's look uniforms (those not in GooSkin.UNIFORMS, which
# the bridge's skin pushes itself: rim width, refraction...) onto the bridge's
# material, and its bubble seed; remembers their names for follow_look().
func _copy_look(big: Goo2D) -> void:
	_look_shader = skin.material.shader
	_look_names.clear()
	var source := _look_source(big)
	if source == null or source.shader == null:
		return
	for uniform: Dictionary in source.shader.get_shader_uniform_list():
		var uniform_name := StringName(uniform["name"])
		if GooSkin.UNIFORMS.has(uniform_name):
			continue
		_look_names.append(uniform_name)
		var value: Variant = source.get_shader_parameter(uniform_name)
		if value != null:
			skin.material.set_shader_parameter(uniform_name, value)
	var seed_value: Variant = source.get_shader_parameter(&"seed")
	if seed_value != null:
		skin.noise_seed = seed_value
		skin.material.set_shader_parameter(&"seed", seed_value)

## Copies onto the bridge each look uniform of its larger body's skin that
## differs from the bridge's (a look changed on the body after the bridge was
## first drawn: a game's rim width, bubble_lag, bubble_wobble...). draw_bridge()
## calls it every frame: one read and compare per look uniform, a write only
## for one that changed.
func follow_look() -> void:
	if skin == null or not is_instance_valid(a) or not is_instance_valid(b):
		return
	var source := _look_source(a if a.radius >= b.radius else b)
	if source == null:
		return
	for uniform_name: StringName in _look_names:
		var value: Variant = source.get_shader_parameter(uniform_name)
		if value != null and value != skin.material.get_shader_parameter(uniform_name):
			skin.material.set_shader_parameter(uniform_name, value)

# The larger body's skin material, or null.
static func _look_source(big: Goo2D) -> ShaderMaterial:
	var from := big.get_node_or_null(^"Skin") as Polygon2D
	return from.material as ShaderMaterial if from != null else null

## Frees the bridge (the link is gone).
func free_bridge() -> void:
	if bridge != null and is_instance_valid(bridge):
		bridge.queue_free()
	bridge = null
