class_name GooShape
extends RefCounted
## The rest outline of a body, a plain value: a round blob's circle or a
## polygon (a square, a triangle, any simple polygon). A body's size is its
## equivalent radius, the radius of the circle of the same area (radius()), so
## sizes, colours, masses and the size-based merge rule read every shape the
## same way a round blob's radius is read.
##
## A pressure ring of a POLYGON shape is built on bead_loop(): the outline inset
## by one bead radius with a bead on every inset corner, so the ring's collision
## outline (the beads' circles) is the polygon with its corners rounded by one
## bead radius. A ROUND shape keeps the circle math of GooTuning.tuning()
## and Goo2D; its outline only draws previews.
##
## Orientation: like GooLoop, outlines run counter-clockwise on screen
## (GooLoop.is_ccw()), centred on their area centroid.

enum Kind { ROUND, POLYGON }

## Points of a ROUND shape's outline: enough for a smooth preview circle.
const ROUND_OUTLINE_POINTS: int = 32
## Turn, in radians, under which consecutive outline edges count as one
## straight edge when an outline is simplified: drops the collinear points a
## polygon offset leaves behind, which would otherwise each claim a bead.
const STRAIGHT_TURN: float = 0.002
## Distance, in px, under which two consecutive outline points are one.
const SAME_POINT: float = 0.01
## Smallest detail, in px, a fused outline keeps (fused()): a point closer than
## this to the line through its two neighbours is dropped. Two fitted outlines
## meet a fraction of a pixel out of line, and the union keeps every such step
## and sliver as points of its own, each of which would claim a bead (and a
## step a corner flag). The points of a filled crease's arc stand 0.75 px off
## the chord of their neighbours and are kept: Geometry2D rounds a 10 px arc in
## steps of 22.5° (5 points per right angle, measured), and finer for larger
## radii at about the same sagitta.
const FUSED_DETAIL: float = 0.5

## ROUND or POLYGON.
var kind: Kind = Kind.ROUND
## Collision outline at rest (the drawn outline): CCW on screen, centred on its
## area centroid, px. For ROUND it is GooLoop.circle_points() of
## ROUND_OUTLINE_POINTS points, only used for drawing previews.
var outline: PackedVector2Array = PackedVector2Array()

# Exact radius of a ROUND shape: the circle math needs it, not the area of its
# 32-point outline.
var _round_radius: float = 0.0

## A round blob's shape of `radius` px.
static func round(radius: float) -> GooShape:
	var shape := GooShape.new()
	shape.kind = Kind.ROUND
	shape._round_radius = radius
	shape.outline = GooLoop.circle_points(Vector2.ZERO, radius, ROUND_OUTLINE_POINTS)
	return shape

## The regular polygon of `sides` sides whose area is a circle's of `radius`
## px, resting on one horizontal side: vertices 0 and 1 are the bottom edge,
## left to right.
static func regular(sides: int, radius: float) -> GooShape:
	var count := maxi(sides, 3)
	# Area of a regular n-gon of circumradius R: (n / 2) R² sin(2π / n) = π r².
	var circumradius := radius * sqrt(TAU / (count * sin(TAU / count)))
	var points := PackedVector2Array()
	for i: int in count:
		# Angles run down the screen from +x (y is down): the bottom edge's
		# middle is at π/2, and decreasing angles run counter-clockwise on screen.
		var angle := PI / 2.0 + PI / count - TAU * i / count
		points.append(Vector2(cos(angle), sin(angle)) * circumradius)
	return polygon(points)

## Any simple polygon `points` (either orientation, anywhere), re-centred on its
## area centroid and made CCW. The input is not modified.
static func polygon(points: PackedVector2Array) -> GooShape:
	var shape := GooShape.new()
	shape.kind = Kind.POLYGON
	var loop := _simplified(points)
	if not GooLoop.is_ccw(loop):
		loop.reverse()
	var centre := _area_centroid(loop)
	for i: int in loop.size():
		loop[i] -= centre
	shape.outline = loop
	return shape

## Equivalent radius, px: the radius of the circle of the same area.
func radius() -> float:
	if kind == Kind.ROUND:
		return _round_radius
	return sqrt(area() / PI)

## Area inside the outline, px².
func area() -> float:
	if kind == Kind.ROUND:
		return PI * _round_radius * _round_radius
	return GooLoop.area(outline)

## Length of the outline, px.
func perimeter() -> float:
	if kind == Kind.ROUND:
		return TAU * _round_radius
	return GooLoop.perimeter(outline)

## True for a round blob's shape.
func is_round() -> bool:
	return kind == Kind.ROUND

## True if the outline has a flat side to rest or stick on: every POLYGON.
func has_flat_surface() -> bool:
	return kind == Kind.POLYGON

## The same outline scaled to the equivalent radius `new_radius`, as a new shape.
func scaled(new_radius: float) -> GooShape:
	if kind == Kind.ROUND:
		return GooShape.round(new_radius)
	var factor := new_radius / radius() if radius() > 0.0 else 0.0
	var shape := GooShape.new()
	shape.kind = kind
	var points := outline.duplicate()
	for i: int in points.size():
		points[i] *= factor
	shape.outline = points
	return shape

## Indices of the outline vertices where it turns by more than `min_angle`
## (radians, either way): all of a regular polygon's for min_angle under its
## exterior angle (120° for a triangle, 90° for a square), none of a ROUND
## shape's 32-point circle for min_angle above 11.25°.
func corners(min_angle: float) -> PackedInt32Array:
	var result := PackedInt32Array()
	var count := outline.size()
	for i: int in count:
		if absf(turn(outline, i)) > min_angle:
			result.append(i)
	return result

## The outline shrunk by `distance` px (Geometry2D.offset_polygon with mitred
## joins, so a polygon's corners stay sharp), the largest piece if it falls
## apart, simplified, CCW and starting at the corner nearest outline[0]. Empty
## if nothing is left: the shape is thinner than 2 × `distance`.
func inset(distance: float) -> PackedVector2Array:
	var best := PackedVector2Array()
	for piece: PackedVector2Array in Geometry2D.offset_polygon(outline, -distance, Geometry2D.JOIN_MITER):
		if GooLoop.area(piece) > GooLoop.area(best):
			best = piece
	best = _simplified(best)
	if best.size() < 3:
		return PackedVector2Array()
	if not GooLoop.is_ccw(best):
		best.reverse()
	var first := 0
	if not outline.is_empty():
		for i: int in best.size():
			if best[i].distance_squared_to(outline[0]) < best[first].distance_squared_to(outline[0]):
				first = i
	var result := best.slice(first)
	result.append_array(best.slice(0, first))
	return result

## The bead-centre loop of a pressure ring of this shape at rest, relative to
## the outline's centroid, `count` beads of `bead_size` px radius, CCW: for
## POLYGON the outline inset by `bead_size` with a bead on every inset corner
## and the rest spread along its edges (GooLoop.polygon_beads()), starting
## at the corner nearest outline[0]; for ROUND the circle `bead_size` inside the
## outline. Empty if the shape is too thin for beads of that size.
func bead_loop(count: int, bead_size: float) -> PackedVector2Array:
	if kind == Kind.ROUND:
		return GooLoop.circle_points(Vector2.ZERO, _round_radius - bead_size, count)
	var rest := inset(bead_size)
	if rest.is_empty():
		return rest
	return GooLoop.polygon_beads(rest, count)

## The outline of two bodies stuck together: the union of the outlines `a`
## and `b` (each a body's outline in the pose it touched in, any orientation,
## in the same space, e.g. fitted_outline()s), its creases at the junction
## filled up to `contact_range` px and nothing else changed. The filling is a
## morphological closing: both outlines grown by `contact_range` with round
## joins, united, and shrunk back by as much (a disc of that radius rolled
## around the outside cannot reach into what it fills); its holes are dropped,
## and the union with `a` and `b` themselves keeps their corners exact where
## the rounding of the closing would shave them. A gap under 2 ×
## `contact_range` between the outlines is bridged. Returned CCW in the
## inputs' space (not re-centred; GooShape.polygon() of it is the fused
## shape), straight runs and details under FUSED_DETAIL removed. Empty if the
## outlines do not make one polygon (they are further apart than that).
static func fused(a: PackedVector2Array, b: PackedVector2Array, contact_range: float) -> PackedVector2Array:
	var none := PackedVector2Array()
	var grown_a := _outer(Geometry2D.offset_polygon(a, contact_range, Geometry2D.JOIN_ROUND))
	var grown_b := _outer(Geometry2D.offset_polygon(b, contact_range, Geometry2D.JOIN_ROUND))
	if grown_a.size() != 1 or grown_b.size() != 1:
		return none
	var grown := _outer(Geometry2D.merge_polygons(grown_a[0], grown_b[0]))
	if grown.size() != 1:
		return none
	var closed := _outer(Geometry2D.offset_polygon(grown[0], -contact_range, Geometry2D.JOIN_ROUND))
	if closed.size() != 1:
		return none
	var result := closed[0]
	for part: PackedVector2Array in [a, b]:
		var united := _outer(Geometry2D.merge_polygons(result, part))
		if united.size() != 1:
			return none
		result = united[0]
	result = _flattened(_simplified(result), FUSED_DETAIL)
	if result.size() < 3 or GooLoop.self_intersects(result):
		return none
	if not GooLoop.is_ccw(result):
		result.reverse()
	return result

## The outline moved rigidly onto a ring of this shape: `rest` is the ring's
## rest shape (Goo2D.rest_shape, its bead loop about its centroid),
## `points` its bead centres now and `bead_size` its bead radius. The outline
## is turned by the rotation that best fits `rest` onto `points`
## (GooLoop.best_fit_rotation()) and placed so the centroid of its bead
## loop (bead_loop(), the loop rest_shape was built from) is the beads'
## centroid. In `points`' space.
func fitted_outline(rest: PackedVector2Array, points: PackedVector2Array, bead_size: float) -> PackedVector2Array:
	var loop := bead_loop(points.size(), bead_size)
	var origin := GooLoop.centroid(loop) if loop.size() == points.size() else Vector2.ZERO
	var angle := GooLoop.best_fit_rotation(rest, points)
	var centre := GooLoop.centroid(points)
	var result := PackedVector2Array()
	for point: Vector2 in outline:
		result.append(centre + (point - origin).rotated(angle))
	return result

## `points` scaled about its area centroid so the outline encloses `area`
## px²; unchanged if `area` or its own area is not positive. A fused merge
## (GooWorld2D.fused_outline()) scales its union to the two parents' areas
## with this, so sticking conserves area like a round merge does: the pull of
## the transition and gravity squash the pair before the swap, and the
## rigidly fitted outlines then overlap (measured: two squares stacked with an
## offset fused into 90.7% of their area, side by side into 98.8%).
static func scaled_to_area(points: PackedVector2Array, area: float) -> PackedVector2Array:
	var current := GooLoop.area(points)
	if area <= 0.0 or current <= 0.0:
		return points
	var factor := sqrt(area / current)
	var centre := _area_centroid(points)
	var result := PackedVector2Array()
	result.resize(points.size())
	for i: int in points.size():
		result[i] = centre + (points[i] - centre) * factor
	return result

## Area centroid of the simple polygon `points` (the vertex mean if it has no
## area): where polygon() of it puts the origin.
static func area_centroid(points: PackedVector2Array) -> Vector2:
	return _area_centroid(points)

## Signed turn, in radians, of the closed loop `points` at vertex `i`: the
## angle from the edge arriving at it to the edge leaving it.
static func turn(points: PackedVector2Array, i: int) -> float:
	var count := points.size()
	var before := points[i] - points[(i + count - 1) % count]
	var after := points[(i + 1) % count] - points[i]
	return before.angle_to(after)

# `points` without repeated points (closer than SAME_POINT) and without points
# where the loop runs straight on (turn under STRAIGHT_TURN).
static func _simplified(points: PackedVector2Array) -> PackedVector2Array:
	var loop := PackedVector2Array()
	for point: Vector2 in points:
		if loop.is_empty() or loop[loop.size() - 1].distance_to(point) >= SAME_POINT:
			loop.append(point)
	while loop.size() > 1 and loop[0].distance_to(loop[loop.size() - 1]) < SAME_POINT:
		loop.remove_at(loop.size() - 1)
	var changed := true
	while changed and loop.size() > 3:
		changed = false
		for i: int in loop.size():
			if absf(turn(loop, i)) < STRAIGHT_TURN:
				loop.remove_at(i)
				changed = true
				break
	return loop

# Area centroid of the simple polygon `points` (the vertex mean if it has no area).
static func _area_centroid(points: PackedVector2Array) -> Vector2:
	var count := points.size()
	var total := Vector2.ZERO
	var twice_area := 0.0
	for i: int in count:
		var a := points[i]
		var b := points[(i + 1) % count]
		var cross := a.cross(b)
		twice_area += cross
		total += (a + b) * cross
	if absf(twice_area) < 0.000001:
		return GooLoop.centroid(points)
	return total / (3.0 * twice_area)

# The outer boundaries among Geometry2D's result `polygons`, holes dropped. The
# largest is an outer boundary; holes wind the other way. (merge_polygons()
# returns outer boundaries counter-clockwise in is_polygon_clockwise()'s sense,
# but offset_polygon() keeps the winding of its input, so the winding alone
# does not tell.)
static func _outer(polygons: Array[PackedVector2Array]) -> Array[PackedVector2Array]:
	var result: Array[PackedVector2Array] = []
	var largest := 0.0
	for polygon: PackedVector2Array in polygons:
		if absf(GooLoop.signed_area(polygon)) > absf(largest):
			largest = GooLoop.signed_area(polygon)
	for polygon: PackedVector2Array in polygons:
		if polygon.size() >= 3 and GooLoop.signed_area(polygon) * largest > 0.0:
			result.append(polygon)
	return result

# The closed loop `points` without the points closer than `detail` px to the
# segment between their two neighbours, the least significant first.
static func _flattened(points: PackedVector2Array, detail: float) -> PackedVector2Array:
	var loop := points.duplicate()
	while loop.size() > 3:
		var count := loop.size()
		var weakest := -1
		var least := detail
		for i: int in count:
			var before := loop[(i + count - 1) % count]
			var after := loop[(i + 1) % count]
			var off := loop[i].distance_to(Geometry2D.get_closest_point_to_segment(loop[i], before, after))
			if off < least:
				least = off
				weakest = i
		if weakest < 0:
			break
		loop.remove_at(weakest)
	return loop

# ---- Cutting a polygon body in rest space ----
# A polygon body's split, made in rest space: the world's cut asks for it when
# a ring of a POLYGON shape is pinched, crushed or cut along the chord between
# two of its beads. The parent's rest outline is moved rigidly onto the beads
# (the pose its shape matching pulls toward, fitted_outline()), cut along the
# chord between the two beads' fitted rest points, run on both ways to where it
# leaves the outline (cut()), and each side becomes a polygon GooShape of its
# own: a square cut on its diagonal gives two triangles, cut off-centre a
# triangle and a trapezoid or pentagon. The cut follows the chord, not the
# whole line through it: on a concave outline (a fused shape, a U, an L) that
# line crosses other arms, which stay whole. Which piece is which side is
# decided by the beads (the piece holding the fitted rest points of beads
# a+1 … b-1 is theirs), so a piece's beads are never built with the other
# side's rest shape (whose rest edges would crush one piece and blow the other
# up within a frame). The pieces share the parent's area exactly as the chord
# divides its outline, not by the areas of the deformed bead loop on either
# side of the chord the way round blobs share it.

## Narrowest a piece may be, in its own bead diameters (2 × its tuning's
## bead_radius), measured as its inscribed width (is_wider_than()): a thinner
## cut is not made and the ring asks again later, as for a piece under
## GooWorld2D.MIN_PIECE_RATIO. A ring needs a little over one bead diameter of width
## for its bead loop to exist at all (bead_loop() is empty below that, and
## Goo2D.make_from_loop() would build it round), so this keeps every piece
## well clear of that. Measured on squares and triangles of radius 28, 40 and 48
## dropped onto the wedge (centred and 15 or 30 px off, at 0, 500 and 1000
## px/s): the halves of a square cut through its middle are 3.3-3.6 bead
## diameters wide (35 px for a 40 px square against 31 px for its pieces' beads)
## and triangles' pieces 3.6-4.7; of the 21 cuts asked for, 18 were made, one
## real sliver was refused (6 px wide, 0.93 bead diameters, though its 14.6 px
## equivalent radius passed MIN_PIECE_RATIO) and two off-centre cuts of a 48 px
## square at 2.75 and 2.97. Rectangles 2.3 … 2.9 bead diameters wide dropped
## from the launch point land and settle holding their shape (under 1.5% RMS
## error), so 2.5 would be safe if more such cuts are wanted. Those widths were
## in the beads of 16-30-bead rings; with 12-22 (native kernel stage 2) a bead
## is a third wider, so the same pieces are a third fewer bead diameters wide
## (the halves of a 48 px square 2.5 instead of 3.3): 2.2 keeps cutting what 3.0
## cut, and still refuses the real slivers (a fifth of a 48 px square, 1.3).
const MIN_PIECE_WIDTH_BEADS: float = 2.2

## Slack, as a fraction of the chord's length, within which cut() takes the
## outline to be met at one of the chord's ends (an end on the outline, such as
## a corner, still makes a cut) rather than crossed between them.
const CHORD_SLACK: float = 0.001
## How deep, in bead radii, cut_ring() lets a chord run on into the outline
## past a bead (cut()'s `depth`) before it joins the bead to its nearest point
## of the outline instead. A bead sits one bead radius in from the outline, and
## the chord's run on past it to the outline stays that shallow or shallower
## (along a face at a slant, or out through a corner); a chord ending on a bead
## in a crease or a concave corner of a fused shape can instead run on through
## the body itself and cut off a part of it that holds none of the piece's
## beads.
const CUT_DEPTH_BEADS: float = 1.5
## Points along a chord's run on past a bead at which cut() measures its depth.
const CUT_DEPTH_SAMPLES: int = 8
## Distance, in bead radii, within which a bead's fitted rest point counts as
## on the chord a ring is cut along (_ring_sides()), so it does not vote for
## the piece it lies in.
const CHORD_ABSTAIN: float = 0.1

## The simple polygon `outline` cut along the chord from `from` to `to`, run on
## past each end to where it first leaves the outline: [the part on the side
## (to - from).orthogonal() points to, the part on the other side], each CCW,
## sharing the outline's area exactly. Only the chord cuts, not the whole line
## through it: on a concave outline the line may cross other arms, and they
## stay whole in whichever part they hang from. An end whose run on to the
## outline goes deeper than `depth` px into it (its distance from the outline,
## sampled along the run) is joined to its nearest point of the outline
## instead, so the cut bends there. Both empty if the chord is not
## inside the outline (its middle outside, or the outline crossed between its
## ends; an end may lie on the outline) or the outline has under 3 points.
static func cut(outline: PackedVector2Array, from: Vector2, to: Vector2, depth: float = INF) -> Array[PackedVector2Array]:
	var sides: Array[PackedVector2Array] = [PackedVector2Array(), PackedVector2Array()]
	var along := to - from
	var count := outline.size()
	if along.length() < SAME_POINT or count < 3:
		return sides
	if not Geometry2D.is_point_in_polygon((from + to) / 2.0, outline):
		return sides
	# The line is from + t × along; its crossings with the outline nearest the
	# chord's middle (t = 0.5) on either side end the cut. A crossing through a
	# vertex is found on both of its edges at the same t, which is harmless.
	var before := -INF
	var after := INF
	var start_end := Vector2(-1.0, 0.0)
	var finish_end := Vector2(-1.0, 0.0)
	for i: int in count:
		var start := outline[i]
		var edge := outline[(i + 1) % count] - start
		var denominator := along.cross(edge)
		if absf(denominator) <= 1e-9 * along.length() * edge.length():
			continue
		var u := (start - from).cross(along) / denominator
		if u < -1e-9 or u > 1.0 + 1e-9:
			continue
		var t := (start - from).cross(edge) / denominator
		if t < 0.5 and t > before:
			before = t
			start_end = Vector2(i, clampf(u, 0.0, 1.0))
		elif t >= 0.5 and t < after:
			after = t
			finish_end = Vector2(i, clampf(u, 0.0, 1.0))
	if start_end.x < 0.0 or finish_end.x < 0.0:
		return sides
	if before > CHORD_SLACK or after < 1.0 - CHORD_SLACK:
		return sides
	if _run_depth(outline, from, from + along * before) > depth:
		start_end = _nearest_on_outline(outline, from)
	if _run_depth(outline, to, from + along * after) > depth:
		finish_end = _nearest_on_outline(outline, to)
	# The cut runs from the outline at start_end through from and to out to
	# the outline at finish_end; each part is the outline walked one way
	# between them, closed by the cut.
	var start_point := _on_outline(outline, start_end)
	var finish_point := _on_outline(outline, finish_end)
	var forward := _walk(outline, start_end, finish_end)
	for point: Vector2 in [to, from]:
		_append_point(forward, point)
	var backward := _walk(outline, finish_end, start_end)
	for point: Vector2 in [from, to]:
		_append_point(backward, point)
	if forward.size() < 3 or backward.size() < 3 or start_point.distance_to(finish_point) < SAME_POINT:
		return sides
	# A bent end can, in a tight spot, cross the rest of the cut.
	if GooLoop.self_intersects(forward) or GooLoop.self_intersects(backward):
		return sides
	# The part walked forward lies on the side of the cut (run from finish to
	# start, against `along`) where the outline's winding puts its inside:
	# across (along.orthogonal()) for a positive shoelace area.
	var forward_across := GooLoop.signed_area(outline) > 0.0
	sides[0] = forward if forward_across else backward
	sides[1] = backward if forward_across else forward
	for k: int in 2:
		var piece := sides[k]
		if not GooLoop.is_ccw(piece):
			piece.reverse()
			sides[k] = piece
	return sides

# The largest distance from the closed loop `outline` of the points of the
# segment from `start` to `end`, sampled at CUT_DEPTH_SAMPLES points past
# `start` (whose own depth does not count).
static func _run_depth(outline: PackedVector2Array, start: Vector2, end: Vector2) -> float:
	var deepest := 0.0
	for k: int in range(1, CUT_DEPTH_SAMPLES + 1):
		var point := start.lerp(end, float(k) / float(CUT_DEPTH_SAMPLES + 1))
		var nearest := _on_outline(outline, _nearest_on_outline(outline, point))
		deepest = maxf(deepest, point.distance_to(nearest))
	return deepest

# The point of the closed loop `outline` at `at` = Vector2(edge index, fraction
# along that edge).
static func _on_outline(outline: PackedVector2Array, at: Vector2) -> Vector2:
	var i := int(at.x)
	return outline[i].lerp(outline[(i + 1) % outline.size()], at.y)

# The point of the closed loop `outline` nearest `point`, as Vector2(edge
# index, fraction along that edge).
static func _nearest_on_outline(outline: PackedVector2Array, point: Vector2) -> Vector2:
	var count := outline.size()
	var best := Vector2(0.0, 0.0)
	var best_distance := INF
	for i: int in count:
		var start := outline[i]
		var edge := outline[(i + 1) % count] - start
		var u := clampf((point - start).dot(edge) / edge.length_squared(), 0.0, 1.0) if edge.length_squared() > 0.0 else 0.0
		var distance := point.distance_squared_to(start + edge * u)
		if distance < best_distance:
			best_distance = distance
			best = Vector2(i, u)
	return best

# The closed loop `outline` walked forward from the point `from_at` to the
# point `to_at` (each Vector2(edge index, fraction along it)): from_at's
# point, the vertices passed, to_at's point.
static func _walk(outline: PackedVector2Array, from_at: Vector2, to_at: Vector2) -> PackedVector2Array:
	var count := outline.size()
	var result := PackedVector2Array([_on_outline(outline, from_at)])
	var i := int(from_at.x)
	var last := int(to_at.x)
	if i != last or to_at.y < from_at.y:
		while true:
			i = (i + 1) % count
			_append_point(result, outline[i])
			if i == last:
				break
	_append_point(result, _on_outline(outline, to_at))
	return result

# Appends `point` to the loop `points` unless it repeats the last point (or
# closes onto the first) within SAME_POINT.
static func _append_point(points: PackedVector2Array, point: Vector2) -> void:
	if not points.is_empty() and (points[points.size() - 1].distance_to(point) < SAME_POINT
			or points[0].distance_to(point) < SAME_POINT):
		return
	points.append(point)

## True if the polygon `outline` is at least `width` px wide everywhere that
## matters: its inscribed width (twice the largest distance it can be inset by
## and leave something, Geometry2D.offset_polygon) exceeds `width`. Exact for
## convex outlines, where that is the diameter of the largest inscribed circle.
static func is_wider_than(outline: PackedVector2Array, width: float) -> bool:
	if outline.size() < 3:
		return false
	return not GooShape.polygon(outline).inset(width / 2.0).is_empty()

## The two pieces of a ring of this shape, a POLYGON, cut in rest space along
## the chord from its bead `a` to its bead `b`: the ring's beads are `points`,
## its rest shape `rest` (one point per bead, about their mean) with beads of
## `bead_size` radius. The cut runs along the chord between the fitted rest
## points of a and b (GooLoop.goal_positions()) across the fitted outline
## (fitted_outline()), to where it leaves the outline (cut(): other arms of a
## concave outline stay whole). Returns two Dictionaries, the first for the
## piece of beads a+1 … b-1 (the one Goo2D.sub_loop(points, a, b) builds: the
## piece holding most of those beads' fitted rest points), the second for the
## other beads' piece, each:
## - "outline": the piece's rest outline in the fitted pose, global px, CCW;
## - "shape": GooShape.polygon() of it, its radius() the equivalent radius of
##   its own area;
## - "tuning": GooTuning.tuning_for() of that shape;
## - "rest_loop": its bead loop (bead_loop() of the tuning's bead_count and
##   bead_radius) in the fitted pose, global px, CCW: the rest loop
##   Goo2D.build_from_loop() takes.
## Empty if the cut is not to be made: this shape is not a POLYGON, a or b is
## out of range or the two are neighbours, the chord is not inside the fitted
## outline (it runs out across a notch), the beads of the two sides do not land
## in two different pieces, a piece's equivalent radius is under `min_radius`,
## or a piece is a sliver
## under MIN_PIECE_WIDTH_BEADS of its bead diameters wide (so no piece ever
## reaches Goo2D.make_from_loop() too thin for its beads).
func cut_ring(rest: PackedVector2Array, points: PackedVector2Array, a: int, b: int,
		bead_size: float, min_radius: float) -> Array[Dictionary]:
	var none: Array[Dictionary] = []
	var sides := _ring_sides(rest, points, a, b, bead_size)
	if sides.is_empty():
		return none
	var pieces: Array[Dictionary] = []
	for side: PackedVector2Array in sides:
		var piece_shape := GooShape.polygon(side)
		if piece_shape.outline.size() < 3 or piece_shape.radius() < min_radius:
			return none
		var tuning := GooTuning.tuning_for(piece_shape)
		if not is_wider_than(piece_shape.outline, MIN_PIECE_WIDTH_BEADS * 2.0 * float(tuning["bead_radius"])):
			return none
		var piece := _ring_piece(side, piece_shape, tuning)
		if piece.is_empty():
			return none
		pieces.append(piece)
	return pieces

## What a ring of this shape, a POLYGON, becomes when a cut along the chord
## from its bead `a` to its bead `b` is refused for a piece too small or too
## thin (cut_ring()) but the ring must still come off what asked for the cut (a
## tip inside it, see GooWorld2D.cut_along()): the larger of the two sides of
## the fitted outline cut_ring() would cut, scaled about its area centroid to
## this shape's whole area (scaled_to_area()), so the crumb is absorbed. Same
## arguments as cut_ring(); returns one Dictionary of the same keys
## ("outline", "shape", "tuning", "rest_loop"), plus "side": 0 if the larger side
## is the one of beads a+1 … b-1 (Goo2D.sub_loop(points, a, b)), 1 for the
## other. Empty if the cut is not to be made at all: this shape is not a
## POLYGON, a or b is out of range or the two are neighbours, the chord is not
## inside the fitted outline or the two sides' beads do not land in two
## different pieces (as for cut_ring()), or the scaled side is too thin for its
## beads.
func trim_ring(rest: PackedVector2Array, points: PackedVector2Array, a: int, b: int,
		bead_size: float) -> Dictionary:
	var sides := _ring_sides(rest, points, a, b, bead_size)
	if sides.is_empty():
		return {}
	var side := 0 if GooLoop.area(sides[0]) >= GooLoop.area(sides[1]) else 1
	var outline_scaled := scaled_to_area(sides[side], area())
	var kept := GooShape.polygon(outline_scaled)
	if kept.outline.size() < 3:
		return {}
	var piece := _ring_piece(outline_scaled, kept, GooTuning.tuning_for(kept))
	if piece.is_empty():
		return {}
	piece["side"] = side
	return piece

# The two pieces of the fitted outline of a ring of this shape (a POLYGON) cut
# along the chord between the fitted rest points of its beads `a` and `b`
# (cut()), as cut_ring() describes: [the piece of beads a+1 … b-1, the
# other's], each CCW. A piece belongs to the beads most of whose fitted rest
# points it holds, not to the side of the line it lies on; a rest point on the
# chord itself (within CHORD_ABSTAIN bead radii: the beads of a straight face
# cut along its own bead line) holds no vote, and a side whose beads all lie
# there takes the piece the other side leaves. Empty if this shape is not a
# POLYGON, a or b is out of range or the two are neighbours, the chord is not
# inside the outline, or the beads of the two sides do not land in two
# different pieces.
func _ring_sides(rest: PackedVector2Array, points: PackedVector2Array, a: int, b: int,
		bead_size: float) -> Array[PackedVector2Array]:
	var none: Array[PackedVector2Array] = []
	var count := points.size()
	if is_round() or rest.size() != count or count < 4:
		return none
	if a < 0 or b < 0 or a >= count or b >= count or a == b:
		return none
	if (a + 1) % count == b or (b + 1) % count == a:
		return none
	var goals := GooLoop.goal_positions(rest, points)
	var pieces := cut(fitted_outline(rest, points, bead_size), goals[a], goals[b], CUT_DEPTH_BEADS * bead_size)
	if pieces[0].is_empty():
		return none
	# votes[2 × side + piece]: how many fitted rest points of the side's beads
	# (side 0: a+1 … b-1, side 1: b+1 … a-1) lie in the piece.
	var votes := PackedInt32Array([0, 0, 0, 0])
	var side := 0
	var i := (a + 1) % count
	while i != a:
		if i == b:
			side = 1
		elif Geometry2D.get_closest_point_to_segment(goals[i], goals[a], goals[b]).distance_to(goals[i]) \
				>= CHORD_ABSTAIN * bead_size:
			for k: int in 2:
				if Geometry2D.is_point_in_polygon(goals[i], pieces[k]):
					votes[2 * side + k] += 1
		i = (i + 1) % count
	# chosen[side]: the piece of the side, -1 while its votes do not tell.
	var chosen := PackedInt32Array([-1, -1])
	for k: int in 2:
		if votes[2 * k] != votes[2 * k + 1]:
			chosen[k] = 0 if votes[2 * k] > votes[2 * k + 1] else 1
	for k: int in 2:
		if chosen[k] < 0 and chosen[1 - k] >= 0 and votes[2 * k] == 0 and votes[2 * k + 1] == 0:
			chosen[k] = 1 - chosen[1 - k]
	if chosen[0] < 0 or chosen[1] < 0 or chosen[0] == chosen[1]:
		return none
	var sides: Array[PackedVector2Array] = [pieces[chosen[0]], pieces[chosen[1]]]
	return sides

# A piece of a cut or trimmed ring: its global `outline_points`, its `shape`
# (GooShape.polygon() of them) and `tuning` (GooTuning.tuning_for() of that),
# and its bead loop moved onto the outline's area centroid, as cut_ring()
# returns them. Empty if the shape is too thin for its beads.
static func _ring_piece(outline_points: PackedVector2Array, shape: GooShape, tuning: Dictionary) -> Dictionary:
	var loop := shape.bead_loop(tuning["bead_count"], tuning["bead_radius"])
	if loop.size() != int(tuning["bead_count"]):
		return {}
	var centre := area_centroid(outline_points)
	for k: int in loop.size():
		loop[k] += centre
	return { "outline": outline_points, "shape": shape, "tuning": tuning, "rest_loop": loop }
