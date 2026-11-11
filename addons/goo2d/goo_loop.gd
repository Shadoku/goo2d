class_name GooLoop
extends RefCounted
## The loop geometry of the goo: math on closed point loops, behind the
## pressure ring soft body: area and orientation, outward edge normals for the
## pressure force, smoothing and resampling for drawing and merging outlines,
## and the best-fit rotation its shape-matching force pulls toward; for polygon
## bodies (GooShape), beads spread over a polygon's edges and smoothing that
## keeps its corners; and cuts along a line (a blade-style cut): whether a
## point is in a ring (pierces()) and the chord the line cuts it on (chord()).
##
## Orientation: Godot's 2D space is y-down, so a loop that runs counter-clockwise
## on screen has a NEGATIVE shoelace area. "CCW" here always means
## counter-clockwise on screen: signed_area() < 0, is_ccw() true. circle_points()
## builds CCW loops, edge_normals() points outward for them, and union_outline()
## returns them.

## Shoelace area ½ Σ (x_i y_(i+1) − x_(i+1) y_i) of the closed loop. Negative for
## a loop that runs counter-clockwise on screen (y-down), positive for clockwise.
static func signed_area(points: PackedVector2Array) -> float:
	var count := points.size()
	var total := 0.0
	for i: int in count:
		total += points[i].cross(points[(i + 1) % count])
	return total * 0.5

## Unsigned area enclosed by the closed loop.
static func area(points: PackedVector2Array) -> float:
	return absf(signed_area(points))

## True if the loop runs counter-clockwise on screen (signed_area() < 0), the
## orientation circle_points() builds and edge_normals() expects.
static func is_ccw(points: PackedVector2Array) -> bool:
	return signed_area(points) < 0.0

## `count` points evenly spaced on the circle, starting at its rightmost point
## and running counter-clockwise on screen (is_ccw() is true).
static func circle_points(center: Vector2, radius: float, count: int) -> PackedVector2Array:
	var points := PackedVector2Array()
	points.resize(maxi(count, 0))
	for i: int in count:
		var angle := -TAU * i / count
		points[i] = center + Vector2(cos(angle), sin(angle)) * radius
	return points

## One normal per edge i → i+1 (the last edge wraps to point 0), pointing outward
## for a CCW loop, with length equal to the edge length: pressure × normal is the
## edge's pressure force.
static func edge_normals(points: PackedVector2Array) -> PackedVector2Array:
	var count := points.size()
	var normals := PackedVector2Array()
	normals.resize(count)
	for i: int in count:
		var edge := points[(i + 1) % count] - points[i]
		normals[i] = Vector2(-edge.y, edge.x)
	return normals

## Chaikin corner cutting of the closed loop: each pass replaces every edge with
## points at ¼ and ¾ along it, doubling the point count. Keeps the orientation.
static func chaikin(points: PackedVector2Array, iterations: int) -> PackedVector2Array:
	var current := points.duplicate()
	for _pass: int in iterations:
		var count := current.size()
		var next := PackedVector2Array()
		next.resize(count * 2)
		for i: int in count:
			var a := current[i]
			var b := current[(i + 1) % count]
			next[2 * i] = a.lerp(b, 0.25)
			next[2 * i + 1] = a.lerp(b, 0.75)
		current = next
	return current

## Chaikin corner cutting that leaves the points flagged in `keep` (one byte per
## point of `points`, non-zero to keep; missing flags count as zero) where they
## are: each pass replaces every edge with points at ¼ and ¾ along it, as
## chaikin() does, and emits a kept point itself just before the edge that
## starts at it, so the two points around it lie on its two edges and the
## corner stays sharp through every pass. With nothing kept the result is
## exactly chaikin()'s. Keeps the orientation.
static func chaikin_keeping(points: PackedVector2Array, iterations: int, keep: PackedByteArray) -> PackedVector2Array:
	var current := points.duplicate()
	var flags := keep.duplicate()
	flags.resize(current.size())
	for _pass: int in iterations:
		var count := current.size()
		var next := PackedVector2Array()
		var next_flags := PackedByteArray()
		for i: int in count:
			var a := current[i]
			var b := current[(i + 1) % count]
			if flags[i] != 0:
				next.append(a)
				next_flags.append(1)
			next.append(a.lerp(b, 0.25))
			next.append(a.lerp(b, 0.75))
			next_flags.append(0)
			next_flags.append(0)
		current = next
		flags = next_flags
	return current

## Total length of the closed loop's edges, the last one wrapping to point 0.
static func perimeter(points: PackedVector2Array) -> float:
	var count := points.size()
	var total := 0.0
	for i: int in count:
		total += points[i].distance_to(points[(i + 1) % count])
	return total

## `count` points on the closed polygon `loop`: one on every vertex, in order
## and starting at vertex 0, and the rest spread along the edges so the gaps
## are as even as they can be (each extra point goes to the edge whose gaps are
## longest at the time), evenly within an edge. Keeps the loop's orientation;
## the points enclose exactly the polygon. With fewer than one point per
## vertex, resample() of the loop instead (the corners cannot all be kept).
static func polygon_beads(loop: PackedVector2Array, count: int) -> PackedVector2Array:
	var vertices := loop.size()
	if count < vertices or vertices == 0:
		return resample(loop, count)
	var lengths := PackedFloat32Array()
	var segments := PackedInt32Array()
	for i: int in vertices:
		lengths.append(loop[i].distance_to(loop[(i + 1) % vertices]))
		segments.append(1)
	for _extra: int in count - vertices:
		var longest := 0
		for i: int in vertices:
			if lengths[i] / segments[i] > lengths[longest] / segments[longest]:
				longest = i
		segments[longest] += 1
	var points := PackedVector2Array()
	for i: int in vertices:
		var a := loop[i]
		var b := loop[(i + 1) % vertices]
		for step: int in segments[i]:
			points.append(a.lerp(b, float(step) / segments[i]))
	return points

## `count` points evenly spaced by arc length around the closed loop, starting
## at loop[0] and keeping its direction.
static func resample(loop: PackedVector2Array, count: int) -> PackedVector2Array:
	var result := PackedVector2Array()
	if count <= 0 or loop.is_empty():
		return result
	var size := loop.size()
	var perimeter := 0.0
	for i: int in size:
		perimeter += loop[i].distance_to(loop[(i + 1) % size])
	result.append(loop[0])
	if perimeter <= 0.0:
		while result.size() < count:
			result.append(loop[0])
		return result
	var step := perimeter / count
	var target := step
	var walked := 0.0
	for i: int in size:
		var a := loop[i]
		var b := loop[(i + 1) % size]
		var length := a.distance_to(b)
		while result.size() < count and target <= walked + length and length > 0.0:
			result.append(a.lerp(b, (target - walked) / length))
			target += step
		walked += length
	# Rounding can leave the last point just past the end of the walk.
	while result.size() < count:
		result.append(loop[size - 1])
	return result

## Outline of the union of two loops, CCW. If they merge into exactly one
## polygon, that polygon; otherwise (apart, or the union has holes) the convex
## hull of all their points.
static func union_outline(a: PackedVector2Array, b: PackedVector2Array) -> PackedVector2Array:
	var merged := Geometry2D.merge_polygons(a, b)
	if merged.size() == 1:
		return _as_ccw(merged[0])
	var hull := Geometry2D.convex_hull(a + b)
	if hull.size() > 1 and hull[0] == hull[hull.size() - 1]:
		hull.remove_at(hull.size() - 1)
	return _as_ccw(hull)

## Mean of the points (zero for an empty array).
static func centroid(points: PackedVector2Array) -> Vector2:
	if points.is_empty():
		return Vector2.ZERO
	var total := Vector2.ZERO
	for point: Vector2 in points:
		total += point
	return total / points.size()

## Angle, in radians, of the rotation that best maps `rest` onto `current`, both
## taken relative to their centroids (point i of one matches point i of the
## other): with q = rest − rest centroid and p = current − current centroid,
## atan2(Σ q × p, Σ q · p). Vector2.rotated() by this angle turns q toward p.
static func best_fit_rotation(rest: PackedVector2Array, current: PackedVector2Array) -> float:
	var rest_centre := centroid(rest)
	var current_centre := centroid(current)
	var cross_sum := 0.0
	var dot_sum := 0.0
	for i: int in mini(rest.size(), current.size()):
		var q := rest[i] - rest_centre
		var p := current[i] - current_centre
		cross_sum += q.cross(p)
		dot_sum += q.dot(p)
	return atan2(cross_sum, dot_sum)

## Where each point of `current` would be if the body were its rest shape moved
## rigidly onto it: current centroid + (rest_i − rest centroid) rotated by
## best_fit_rotation(). The shape-matching force pulls each point toward these.
static func goal_positions(rest: PackedVector2Array, current: PackedVector2Array) -> PackedVector2Array:
	var rest_centre := centroid(rest)
	var current_centre := centroid(current)
	var angle := best_fit_rotation(rest, current)
	var goals := PackedVector2Array()
	goals.resize(rest.size())
	for i: int in rest.size():
		goals[i] = current_centre + (rest[i] - rest_centre).rotated(angle)
	return goals

## True if any two edges of the closed loop that share no vertex cross or touch.
static func self_intersects(loop: PackedVector2Array) -> bool:
	var count := loop.size()
	if count < 4:
		return false
	for i: int in count:
		var a := loop[i]
		var b := loop[(i + 1) % count]
		for j: int in range(i + 2, count):
			# Edge count - 1 ends at vertex 0, where edge 0 starts.
			if i == 0 and j == count - 1:
				continue
			var hit: Variant = Geometry2D.segment_intersects_segment(a, b, loop[j], loop[(j + 1) % count])
			if hit != null:
				return true
	return false

## The first two edges of the closed loop that cross properly, at a point
## inside both (edges that share a vertex, touch or overlap do not count), as
## { "i": int, "j": int, "point": Vector2 } with i < j (the first such i, then
## the first such j); empty if none do.
static func first_crossing(loop: PackedVector2Array) -> Dictionary:
	var count := loop.size()
	if count < 4:
		return {}
	for i: int in count:
		var a := loop[i]
		var b := loop[(i + 1) % count]
		for j: int in range(i + 2, count):
			if i == 0 and j == count - 1:
				continue
			var c := loop[j]
			var d := loop[(j + 1) % count]
			var d1 := _orient(c, d, a)
			var d2 := _orient(c, d, b)
			var d3 := _orient(a, b, c)
			var d4 := _orient(a, b, d)
			if _opposite(d1, d2) and _opposite(d3, d4):
				var t := d1 / (d1 - d2)
				return { "i": i, "j": j, "point": a + (b - a) * t }
	return {}

## The closed loop cut at its crossings into loops that do not cross
## themselves: at the first crossing (first_crossing()) of edges i and j at X,
## the loop becomes loop[0..i], X, loop[j+1..] and X, loop[i+1..j], each cut
## again in turn, at most `max_splits` times in all (a loop left when they run
## out is returned as it is, as is one with no crossing). What a skin outline
## that crosses itself is drawn as, one polygon per loop.
static func split_at_crossings(loop: PackedVector2Array, max_splits: int) -> Array[PackedVector2Array]:
	var out: Array[PackedVector2Array] = []
	var out_flags: Array[PackedByteArray] = []
	var budget := [max_splits]
	_split_at_crossings(loop, PackedByteArray(), out, out_flags, budget)
	return out

## The per-point `flags` of the loop (one byte per point, corner_flags() say)
## carried onto each loop split_at_crossings() cuts it into, in the same order:
## one array per loop, a crossing point flagged 0.
static func split_flags(loop: PackedVector2Array, flags: PackedByteArray, max_splits: int) -> Array[PackedByteArray]:
	var out: Array[PackedVector2Array] = []
	var out_flags: Array[PackedByteArray] = []
	var budget := [max_splits]
	_split_at_crossings(loop, flags, out, out_flags, budget)
	return out_flags

static func _split_at_crossings(loop: PackedVector2Array, flags: PackedByteArray,
		out: Array[PackedVector2Array], out_flags: Array[PackedByteArray], budget: Array) -> void:
	if loop.size() < 3:
		return
	var crossing := first_crossing(loop) if budget[0] > 0 else {}
	if crossing.is_empty():
		out.append(loop)
		out_flags.append(flags)
		return
	budget[0] -= 1
	var i: int = crossing["i"]
	var j: int = crossing["j"]
	var x: Vector2 = crossing["point"]
	var first := loop.slice(0, i + 1)
	first.append(x)
	first.append_array(loop.slice(j + 1))
	var second := PackedVector2Array([x])
	second.append_array(loop.slice(i + 1, j + 1))
	var first_flags := PackedByteArray()
	var second_flags := PackedByteArray()
	if flags.size() == loop.size():
		first_flags = flags.slice(0, i + 1)
		first_flags.append(0)
		first_flags.append_array(flags.slice(j + 1))
		second_flags.append(0)
		second_flags.append_array(flags.slice(i + 1, j + 1))
	_split_at_crossings(first, first_flags, out, out_flags, budget)
	_split_at_crossings(second, second_flags, out, out_flags, budget)

# Twice the signed area of a, b, c: positive if c is left of a -> b.
static func _orient(a: Vector2, b: Vector2, c: Vector2) -> float:
	return (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)

static func _opposite(u: float, v: float) -> bool:
	return (u > 0.0 and v < 0.0) or (u < 0.0 and v > 0.0)

## True if `point` lies inside the closed loop.
static func point_in_loop(point: Vector2, loop: PackedVector2Array) -> bool:
	return Geometry2D.is_point_in_polygon(point, loop)

# `points` in CCW order, reversed if needed.
static func _as_ccw(points: PackedVector2Array) -> PackedVector2Array:
	var result := points.duplicate()
	if not is_ccw(result):
		result.reverse()
	return result

# ---- Cuts along a line (what a blade does) ----
# A blade-style cut of a bead loop: whether the cutting tip is in the ring
# (pierces()) and the chord along the cut's axis the loop is cut on (chord()),
# as two bead indices for the world's cut.

## No chord: chord() found no cut.
const NO_CHORD := Vector2i(-1, -1)

## True if `tip` lies inside the closed bead loop `loop`, or within `reach` px
## of one of its edges: inside the loop grown by `reach`. With a ring's bead
## radius as `reach` that is its collision outline, which a solid blade's tip
## can touch but never get through (the beads overlap, so the bead loop itself
## stays a bead radius clear of the tip).
static func pierces(loop: PackedVector2Array, tip: Vector2, reach: float = 0.0) -> bool:
	if point_in_loop(tip, loop):
		return true
	if reach <= 0.0:
		return false
	var count := loop.size()
	for i: int in count:
		var a := loop[i]
		var b := loop[(i + 1) % count]
		if Geometry2D.get_closest_point_to_segment(tip, a, b).distance_squared_to(tip) <= reach * reach:
			return true
	return false

## The two beads of `loop` at which the line through `tip` along `axis`
## crosses it: the ends of the cut. Each crossing is an edge whose beads lie on
## opposite sides of the line and names the one of its two beads closer to the
## line. Sorted along the axis, the crossings pair up into the spans the line
## runs inside the loop, and the span around the tip is cut: for a convex loop
## the only one, for a concave one the crossings nearest the tip behind and
## ahead of it. With the tip outside the loop, the span nearest to it.
## A bead hooked over the tip (the loop wrapped around it, the line crossing
## the two edges of one bead s on either side of the tip, so the span holds
## nothing but s) is cut off whole: the ends are the beads either side of it,
## s - 1 and s + 1, so a trim (GooWorld2D.cut_along()) takes the body off the
## tip instead of naming two neighbouring beads no cut can be made between.
## Returns NO_CHORD when the line crosses the loop fewer than twice or both ends
## are the same bead (the line only grazes it); never a == b.
static func chord(loop: PackedVector2Array, tip: Vector2, axis: Vector2) -> Vector2i:
	var count := loop.size()
	if count < 3 or axis.is_zero_approx():
		return NO_CHORD
	var along := axis.normalized()
	var across := along.orthogonal()
	var sides := PackedFloat32Array()
	sides.resize(count)
	for i: int in count:
		sides[i] = (loop[i] - tip).dot(across)
	# x: distance of the crossing from the tip along the axis; y: its bead; z:
	# its edge (from bead z to z + 1).
	var crossings: Array[Vector3] = []
	for i: int in count:
		var j := (i + 1) % count
		if (sides[i] < 0.0) == (sides[j] < 0.0):
			continue
		var point := loop[i].lerp(loop[j], sides[i] / (sides[i] - sides[j]))
		var bead := i if absf(sides[i]) <= absf(sides[j]) else j
		crossings.append(Vector3((point - tip).dot(along), bead, i))
	if crossings.size() < 2:
		return NO_CHORD
	crossings.sort_custom(func(p: Vector3, q: Vector3) -> bool: return p.x < q.x)
	var best := 0
	var best_distance := INF
	for k: int in range(0, crossings.size() - 1, 2):
		var behind := crossings[k].x
		var ahead := crossings[k + 1].x
		var distance := 0.0 if behind <= 0.0 and ahead >= 0.0 else minf(absf(behind), absf(ahead))
		if distance < best_distance:
			best_distance = distance
			best = k
	var a := int(crossings[best].y)
	var b := int(crossings[best + 1].y)
	if crossings[best].x < 0.0 and crossings[best + 1].x > 0.0 and count >= 4:
		# The tip is strictly inside this span: if its two edges share a bead,
		# that bead is hooked over the tip; cut it off between its neighbours.
		var first := int(crossings[best].z)
		var second := int(crossings[best + 1].z)
		if (first + 1) % count == second:
			return Vector2i(first, (second + 1) % count)
		if (second + 1) % count == first:
			return Vector2i(second, (first + 1) % count)
	return NO_CHORD if a == b else Vector2i(a, b)

# ---- Resizing ----

## `points` scaled by `factor` about their centroid (centroid()): the
## centroid stays, every turn of the loop is kept, the area is factor² times.
static func scaled(points: PackedVector2Array, factor: float) -> PackedVector2Array:
	var centre := centroid(points)
	var result := PackedVector2Array()
	result.resize(points.size())
	for i: int in points.size():
		result[i] = centre + (points[i] - centre) * factor
	return result

## `points` about their centroid scaled by `squash` along the unit vector
## `axis` and by 1 / squash across it (an area-keeping squash: squash < 1
## flattens the loop along the axis), then by `factor` as a whole.
static func squashed(points: PackedVector2Array, squash: float, axis: Vector2,
		factor: float = 1.0) -> PackedVector2Array:
	var centre := centroid(points)
	var along := axis.normalized() if axis.length_squared() > 0.0 else Vector2.RIGHT
	var across := along.orthogonal()
	var result := PackedVector2Array()
	result.resize(points.size())
	for i: int in points.size():
		var d := points[i] - centre
		result[i] = centre + (along * (d.dot(along) * squash) + across * (d.dot(across) / squash)) * factor
	return result

## One point on the closed loop `loop` per point of the loop `rest` (any
## positions: the loop it should be placed like, in the same space), at the
## same fraction of the perimeter from a start as that rest point is from
## rest[0], the start being the point of `loop` (on an edge, not only at a
## vertex) nearest rest[0]; and with it `values` (one per point of `loop`, a
## velocity each) interpolated along the loop the same way. Returns [points,
## values]. A ring rebuilt with another bead count on its own beads (Goo2D's
## re-ring) keeps its outline, its pose and its motion, and its rest corners
## land on the loop where its corners are.
static func place_like(loop: PackedVector2Array, values: PackedVector2Array,
		rest: PackedVector2Array) -> Array[PackedVector2Array]:
	var count := rest.size()
	var size := loop.size()
	var points := PackedVector2Array()
	var placed := PackedVector2Array()
	if size == 0 or count == 0:
		return [points, placed]
	var has_values := values.size() == size
	# The start: the closest point of the loop's edges to rest[0].
	var start_edge := 0
	var start_along := 0.0
	var best := INF
	for i: int in size:
		var a := loop[i]
		var b := loop[(i + 1) % size]
		var on := Geometry2D.get_closest_point_to_segment(rest[0], a, b)
		var distance := on.distance_squared_to(rest[0])
		if distance < best:
			best = distance
			start_edge = i
			var length := a.distance_to(b)
			start_along = a.distance_to(on) / length if length > 0.0 else 0.0
	var lengths := PackedFloat32Array()
	lengths.resize(size)
	var total := 0.0
	for i: int in size:
		lengths[i] = loop[i].distance_to(loop[(i + 1) % size])
		total += lengths[i]
	var rest_total := perimeter(rest)
	var rest_walked := 0.0
	# Walking from the start: the edge, how far along the loop its start lies
	# from the start point.
	var edge := start_edge
	var walked := -start_along * lengths[start_edge]
	var steps := 0
	for k: int in count:
		if k > 0:
			rest_walked += rest[k - 1].distance_to(rest[k])
		var target := total * rest_walked / rest_total if rest_total > 0.0 else 0.0
		while steps < size and walked + lengths[edge] < target:
			walked += lengths[edge]
			edge = (edge + 1) % size
			steps += 1
		var t := clampf((target - walked) / lengths[edge], 0.0, 1.0) if lengths[edge] > 0.0 else 0.0
		var next := (edge + 1) % size
		points.append(loop[edge].lerp(loop[next], t))
		placed.append(values[edge].lerp(values[next], t) if has_values else Vector2.ZERO)
	return [points, placed]
