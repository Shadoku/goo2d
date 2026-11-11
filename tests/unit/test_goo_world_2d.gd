extends TestCase
## Unit tests for GooWorld2D's pure parts: the merge rules (which sizes combine,
## and into what; which shapes stick, flat face to flat face),
## GooWorld2D.MergeQueue (per-frame collection and deduplication of contact
## pairs), GooWorld2D.MergeTransition (the timer that turns a contact between
## two equal blobs into a short pull-together before they are swapped for one),
## the overlap push (intrusion(): per-bead forces from the bead loops) and
## GooWorld2D.Untangler's impulse.

var queue: GooWorld2D.MergeQueue
var transition: GooWorld2D.MergeTransition

func before_each() -> void:
	queue = GooWorld2D.MergeQueue.new()
	transition = GooWorld2D.MergeTransition.new(3, 8)

func test_close_sizes_merge_conserving_area() -> void:
	assert_true(GooTuning.can_merge(28.0, 28.0))
	assert_true(GooTuning.can_merge(28.0, 32.0))
	assert_true(GooTuning.can_merge(61.5, 55.0))
	assert_almost_eq(GooTuning.merged_radius(28.0, 28.0), 39.6, 0.01)
	assert_almost_eq(GooTuning.merged_radius(30.0, 40.0), 50.0, 0.0001)

func test_different_sizes_do_not_merge() -> void:
	assert_false(GooTuning.can_merge(28.0, 40.0))
	assert_false(GooTuning.can_merge(80.0, 47.3))

func test_max_size_does_not_merge() -> void:
	assert_false(GooTuning.can_merge(GooTuning.MAX_RADIUS, GooTuning.MAX_RADIUS))
	assert_false(GooTuning.can_merge(150.0, 150.0))

func test_invalid_sizes_do_not_merge() -> void:
	assert_false(GooTuning.can_merge(-1.0, -1.0))
	assert_false(GooTuning.can_merge(0.0, 0.0))

func test_queue_starts_empty() -> void:
	assert_true(queue.is_empty())
	assert_eq(queue.drain(), [] as Array[Vector2i])

func test_queue_dedupes_reversed_pair() -> void:
	queue.request(5, 2)
	queue.request(2, 5)
	assert_eq(queue.drain(), [Vector2i(2, 5)] as Array[Vector2i])

func test_queue_id_in_at_most_one_pair() -> void:
	queue.request(1, 2)
	queue.request(1, 3)
	queue.request(3, 2)
	queue.request(4, 3)
	assert_eq(queue.drain(), [Vector2i(1, 2), Vector2i(3, 4)] as Array[Vector2i])

func test_queue_keeps_first_come_order() -> void:
	queue.request(30, 40)
	queue.request(10, 20)
	queue.request(60, 50)
	assert_eq(queue.drain(), [Vector2i(30, 40), Vector2i(10, 20), Vector2i(50, 60)] as Array[Vector2i])

func test_queue_drain_clears() -> void:
	queue.request(1, 2)
	assert_false(queue.is_empty())
	queue.drain()
	assert_true(queue.is_empty())
	assert_eq(queue.drain(), [] as Array[Vector2i])

func test_queue_clear() -> void:
	queue.request(1, 2)
	queue.clear()
	assert_true(queue.is_empty())

func test_queue_ignores_self_pair() -> void:
	queue.request(7, 7)
	assert_true(queue.is_empty())
	assert_eq(queue.drain(), [] as Array[Vector2i])

func test_queue_stores_a_repeated_pair_once() -> void:
	for _contact: int in 5:
		queue.request(4, 9)
		queue.request(9, 4)
	queue.request(1, 2)
	assert_eq(queue.size(), 2, "one entry per pair, however many contacts")
	assert_eq(queue.drain(), [Vector2i(4, 9), Vector2i(1, 2)] as Array[Vector2i])

func test_queue_has_a_waiting_pair_either_way_round() -> void:
	assert_false(queue.has(3, 8))
	queue.request(8, 3)
	assert_true(queue.has(3, 8))
	assert_true(queue.has(8, 3))
	assert_false(queue.has(3, 9))
	queue.drain()
	assert_false(queue.has(3, 8), "drained pairs are no longer waiting")

func test_queue_forgets_every_pair_of_an_id() -> void:
	queue.request(5, 8)
	queue.request(3, 8)
	queue.request(8, 9)
	queue.request(5, 6)
	queue.forget(8)
	assert_false(queue.has(3, 8))
	assert_false(queue.has(8, 9))
	assert_eq(queue.size(), 1)
	assert_eq(queue.drain(), [Vector2i(5, 6)] as Array[Vector2i],
		"a forgotten id no longer keeps its partners out of another pair")
	queue.request(3, 8)
	assert_true(queue.has(3, 8), "a forgotten pair may be requested again")

# --- shapes: which pairs stick, flat face to flat face -----------------------

const SQUARE_R: float = 40.0
const BEADS: int = 20
const BEAD: float = 5.0

# The bead loop of a square of SQUARE_R turned by `angle` (rad) about its centre
# and moved to `centre`, as { points, corners, normals } for flat_contact().
static func _square_ring(centre: Vector2, angle: float) -> Dictionary:
	var rest := GooShape.regular(4, SQUARE_R).bead_loop(BEADS, BEAD)
	var mean := GooLoop.centroid(rest)
	for i: int in rest.size():
		rest[i] -= mean
	var points := PackedVector2Array()
	for point: Vector2 in rest:
		points.append(centre + point.rotated(angle))
	return {
		"points": points,
		"corners": Goo2D.find_corners(rest),
		"normals": GooWorld2D.fitted_normals(rest, points),
	}

static func _flat(a: Dictionary, b: Dictionary) -> bool:
	return GooWorld2D.flat_contact(a["points"], a["corners"], a["normals"],
		b["points"], b["corners"], b["normals"], GooWorld2D.CONTACT_SLACK_BEADS * BEAD)

func test_fitted_normals_point_out_of_the_rest_edges_in_the_fitted_pose() -> void:
	var ring := _square_ring(Vector2(100.0, 200.0), PI / 2.0)
	var points: PackedVector2Array = ring["points"]
	var normals: PackedVector2Array = ring["normals"]
	var corners: PackedByteArray = ring["corners"]
	var centre := GooLoop.centroid(points)
	assert_eq(normals.size(), points.size())
	for i: int in points.size():
		assert_almost_eq(normals[i].length(), 1.0, 0.0001)
		assert_gt(normals[i].dot(points[i] - centre), 0.0, "normal %d points outward" % i)
		if corners[i] == 0:
			# A bead on a side of the square: its normal is an axis.
			var axis := maxf(absf(normals[i].x), absf(normals[i].y))
			assert_almost_eq(axis, 1.0, 0.0001, "bead %d lies on a side" % i)

func test_squares_face_to_face_are_a_flat_contact() -> void:
	var side := sqrt(PI) * SQUARE_R
	var a := _square_ring(Vector2(0.0, 0.0), 0.0)
	# Side by side, the collision outlines (bead loops grown by BEAD) touching,
	# the right one a little lower and turned a little.
	assert_true(_flat(a, _square_ring(Vector2(side, 0.0), 0.0)), "aligned, side by side")
	assert_true(_flat(a, _square_ring(Vector2(side + 4.0, 12.0), deg_to_rad(8.0))), "offset and turned 8°")
	assert_true(_flat(a, _square_ring(Vector2(10.0, -side), 0.0)), "stacked")

func test_a_corner_into_a_face_is_not_a_flat_contact() -> void:
	var side := sqrt(PI) * SQUARE_R
	var a := _square_ring(Vector2(0.0, 0.0), 0.0)
	# A diamond standing on its bottom corner on the square's top face: the
	# corner bead's circle touches the face beads' circles.
	var half_diagonal := (side / 2.0 - BEAD) * sqrt(2.0)
	var top := -(side / 2.0 - BEAD)
	var diamond := _square_ring(Vector2(0.0, top - 2.0 * BEAD - half_diagonal), PI / 4.0)
	assert_false(_flat(a, diamond), "corner first onto the top face")
	assert_false(_flat(diamond, a), "either way round")

func test_faces_at_60_degrees_are_not_a_flat_contact() -> void:
	# Two straight rows of side beads (no corners): the bottom one faces up, the
	# top one is tilted so its face meets the bottom one's at `tilt`, and its
	# lowest bead touches the middle of the bottom row.
	for tilt_deg: float in [20.0, 60.0]:
		var tilt := deg_to_rad(tilt_deg)
		var bottom := PackedVector2Array()
		var bottom_normals := PackedVector2Array()
		var top := PackedVector2Array()
		var top_normals := PackedVector2Array()
		for i: int in 9:
			bottom.append(Vector2((i - 4) * 8.0, 0.0))
			bottom_normals.append(Vector2.UP)
			top.append(Vector2(0.0, -2.0 * BEAD) + Vector2(i * 8.0, 0.0).rotated(-tilt))
			top_normals.append(Vector2.DOWN.rotated(-tilt))
		var flags := PackedByteArray()
		flags.resize(9)
		var flat := GooWorld2D.flat_contact(bottom, flags, bottom_normals, top, flags, top_normals, 0.0)
		if tilt_deg < rad_to_deg(GooWorld2D.FLAT_CONTACT_ANGLE):
			assert_true(flat, "faces at %.0f° stick" % tilt_deg)
		else:
			assert_false(flat, "faces at %.0f° do not stick" % tilt_deg)

func test_contact_range_is_two_beads_and_never_under_the_merged_bead_diameter() -> void:
	assert_almost_eq(GooWorld2D.contact_range(4.0, 6.0, 5.0), GooWorld2D.CONTACT_RANGE_BEADS * 6.0, 0.0001)
	assert_almost_eq(GooWorld2D.contact_range(4.0, 4.0, 7.0), 14.0, 0.0001, "one bead diameter of the merged ring")

# --- merge transition: the pull-together timer ------------------------------

func test_remembers_both_ids() -> void:
	assert_eq(transition.id_a, 3)
	assert_eq(transition.id_b, 8)
	assert_eq(transition.elapsed, 0.0)

func test_starts_at_zero_progress() -> void:
	assert_eq(transition.progress(), 0.0)
	assert_false(transition.done())
	assert_eq(transition.attraction(), 0.0)

func test_tick_accumulates_time() -> void:
	transition.tick(0.05)
	transition.tick(0.05)
	assert_almost_eq(transition.elapsed, 0.1, 0.00001)
	assert_almost_eq(transition.progress(), 0.1 / GooWorld2D.MergeTransition.DURATION, 0.00001)

func test_done_after_duration() -> void:
	transition.tick(GooWorld2D.MergeTransition.DURATION * 0.5)
	assert_false(transition.done())
	transition.tick(GooWorld2D.MergeTransition.DURATION * 0.5)
	assert_true(transition.done())
	assert_eq(transition.progress(), 1.0)

func test_progress_is_clamped() -> void:
	transition.tick(GooWorld2D.MergeTransition.DURATION * 3.0)
	assert_eq(transition.progress(), 1.0)
	transition = GooWorld2D.MergeTransition.new(0, 1)
	transition.tick(-1.0)
	assert_eq(transition.progress(), 0.0)

func test_attraction_ramps_up_then_holds() -> void:
	transition.tick(GooWorld2D.MergeTransition.RAMP * 0.5)
	assert_almost_eq(transition.attraction(), 0.5, 0.00001)
	transition.tick(GooWorld2D.MergeTransition.RAMP * 0.5)
	assert_almost_eq(transition.attraction(), 1.0, 0.00001)
	transition.tick(GooWorld2D.MergeTransition.DURATION)
	assert_eq(transition.attraction(), 1.0)

func test_ramp_is_shorter_than_duration() -> void:
	assert_lt(GooWorld2D.MergeTransition.RAMP, GooWorld2D.MergeTransition.DURATION)

func test_a_waiting_pair_is_checked_every_few_frames_until_it_expires() -> void:
	var step := 1.0 / 60.0
	var due: Array[int] = []
	var frame := 0
	while not transition.expired():
		transition.tick(step)
		frame += 1
		if transition.check_due():
			due.append(frame)
	var first := ceili(GooWorld2D.MergeTransition.DURATION / step - 0.001)
	print("    checked on frames %s, expired on frame %d" % [due, frame])
	assert_true(due.size() > 1, "checked more than once while it waits")
	if due.size() > 1:
		assert_true(absi(due[0] - first) <= 1, "first checked once done (frame %d)" % due[0])
		assert_eq(due[1] - due[0], GooWorld2D.MergeTransition.RECHECK_FRAMES)
	assert_almost_eq(transition.elapsed, GooWorld2D.MergeTransition.MAX_DURATION, step + 0.0001)
	assert_almost_eq(GooWorld2D.MergeTransition.MAX_DURATION, 3.0 * GooWorld2D.MergeTransition.DURATION, 0.0001)

# --- overlap push: each bead inside the other ring's bead loop, or within its
# margin of it, is pushed out along that loop's nearest edge normal; the edge's
# two beads take the reaction (GooWorld2D.intrusion()) -------------------------

const SIDE: float = 200.0
const STEP: float = 20.0
const FACE_BEAD: float = 12.0
const FACE_MASS: float = 0.4
const PROBE_MASS: float = 0.2

# A square bead loop of side SIDE centred on the origin, a bead every STEP px,
# counter-clockwise on screen: up the right side, along the top (y = -SIDE / 2),
# down the left side and back along the bottom.
static func _square() -> GooWorld2D.OverlapRing:
	var half := SIDE / 2.0
	var corners: Array[Vector2] = [Vector2(half, half), Vector2(half, -half), Vector2(-half, -half), Vector2(-half, half)]
	var points := PackedVector2Array()
	for k: int in 4:
		var from := corners[k]
		var to := corners[(k + 1) % 4]
		var steps := roundi(from.distance_to(to) / STEP)
		for s: int in steps:
			points.append(from.lerp(to, float(s) / steps))
	return GooWorld2D.OverlapRing.new(points, FACE_BEAD, FACE_MASS)

# A thin triangle "ring" whose first bead is at `tip` and whose other two are
# far above it: only the tip can reach the square.
static func _probe(tip: Vector2) -> GooWorld2D.OverlapRing:
	var points := PackedVector2Array([tip, tip + Vector2(30.0, -300.0), tip + Vector2(0.0, -300.0)])
	if not GooLoop.is_ccw(points):
		points.reverse()
		points = PackedVector2Array([points[2], points[0], points[1]])
	return GooWorld2D.OverlapRing.new(points, 1.0, PROBE_MASS)

static func _circle(centre: Vector2, radius: float, count: int) -> GooWorld2D.OverlapRing:
	return GooWorld2D.OverlapRing.new(GooLoop.circle_points(centre, radius, count),
		GooTuning.BEAD_RADIUS_RATIO * TAU * radius / count, 0.5)

# Index of the square's bead at `point` (exactly), or -1.
static func _bead_at(ring: GooWorld2D.OverlapRing, point: Vector2) -> int:
	for i: int in ring.points.size():
		if ring.points[i].distance_to(point) < 0.001:
			return i
	return -1

static func _sum(forces: PackedVector2Array) -> Vector2:
	var total := Vector2.ZERO
	for force: Vector2 in forces:
		total += force
	return total

func test_square_and_probe_fixtures() -> void:
	var square := _square()
	assert_true(GooLoop.is_ccw(square.points), "the square runs counter-clockwise on screen")
	assert_eq(square.points.size(), 40)
	assert_true(GooLoop.is_ccw(_probe(Vector2(50.0, -90.0)).points))
	assert_almost_eq(square.margin, GooWorld2D.INTRUSION_MARGIN_BEADS * FACE_BEAD, 0.0001)

func test_rings_apart_or_touching_are_not_pushed() -> void:
	var a := _circle(Vector2.ZERO, 50.0, 20)
	var far := GooWorld2D.intrusion(a, _circle(Vector2(300.0, 0.0), 50.0, 20))
	assert_false(far.pressed)
	assert_eq(far.forces_a.size(), 0)
	assert_eq(far.forces_b.size(), 0)
	# Bead 0 of `a` at (50, 0) and bead 10 of the other at its left, their
	# collision circles just touching: no bead centre comes near the other loop.
	var touching := GooWorld2D.intrusion(a, _circle(Vector2(100.0 + 2.0 * a.bead_radius, 0.0), 50.0, 20))
	assert_false(touching.pressed, "touching rings feel nothing")
	assert_eq(touching.inside_a, 0)
	assert_eq(touching.inside_b, 0)

func test_a_bead_inside_is_pushed_out_along_the_nearest_edge_normal() -> void:
	var square := _square()
	# 4 px inside the top face, off-centre: the centre line would push it up
	# and to the right, the face's normal pushes it straight up.
	var probe := _probe(Vector2(50.0, -SIDE / 2.0 + 4.0))
	var hit := GooWorld2D.intrusion(probe, square)
	assert_true(hit.pressed)
	assert_eq(hit.inside_a, 1, "the tip is inside the square")
	assert_eq(hit.inside_b, 0)
	assert_false(hit.deep(), "one bead through a face is not deep inside")
	assert_eq(hit.beads_in_a, PackedInt32Array([0]), "the tip is listed as inside")
	assert_eq(hit.reach_a, PackedInt32Array([0]), "and as pushed")
	var expected := GooWorld2D.push_stiffness(PROBE_MASS, FACE_MASS) * (4.0 + square.margin)
	assert_almost_eq(hit.forces_a[0].x, 0.0, 0.0001, "along the face's normal")
	assert_almost_eq(hit.forces_a[0].y, -expected, 0.0001, "out through the top face, by the depth past the margin")
	assert_eq(hit.forces_a[1], Vector2.ZERO, "beads outside the square feel nothing")
	assert_almost_eq((_sum(hit.forces_a) + _sum(hit.forces_b)).length(), 0.0, 0.0001, "equal and opposite")
	# Near the left face instead: pushed left, whatever the centre line says.
	var left := GooWorld2D.intrusion(_probe(Vector2(-SIDE / 2.0 + 3.0, -60.0)), square)
	assert_almost_eq(left.forces_a[0].normalized().x, -1.0, 0.0001, "out through the nearest (left) face")

func test_reaction_is_split_over_the_edge_by_where_the_bead_is() -> void:
	var square := _square()
	# Between the top-face beads at x = 60 and x = 40, a quarter of the way from 60.
	var hit := GooWorld2D.intrusion(_probe(Vector2(55.0, -SIDE / 2.0 + 2.0)), square)
	var at_60 := _bead_at(square, Vector2(60.0, -SIDE / 2.0))
	var at_40 := _bead_at(square, Vector2(40.0, -SIDE / 2.0))
	assert_true(at_60 >= 0 and at_40 >= 0, "the fixture has beads at x = 60 and 40 on the top face")
	var push := hit.forces_a[0]
	assert_almost_eq(hit.forces_b[at_60].y, -0.75 * push.y, 0.01, "the nearer bead takes three quarters")
	assert_almost_eq(hit.forces_b[at_40].y, -0.25 * push.y, 0.01)
	var others := _sum(hit.forces_b) - hit.forces_b[at_60] - hit.forces_b[at_40]
	assert_almost_eq(others.length(), 0.0, 0.01, "no other bead of the square is pushed")

func test_push_starts_at_the_margin_and_grows_with_depth() -> void:
	var square := _square()
	var stiffness := GooWorld2D.push_stiffness(PROBE_MASS, FACE_MASS)
	# Depth of the tip inside the top face (negative: outside it).
	for depth: float in [-square.margin - 1.0, -square.margin / 2.0, 0.5, 5.0, 20.0]:
		var hit := GooWorld2D.intrusion(_probe(Vector2(50.0, -SIDE / 2.0 + depth)), square)
		var wanted := maxf(depth + square.margin, 0.0) * stiffness
		var got := hit.forces_a[0].length() if hit.pressed else 0.0
		assert_almost_eq(got, wanted, 0.001, "push at %.1f px inside" % depth)
		assert_eq(hit.inside_a, 1 if depth > 0.0 else 0, "counted inside at %.1f px" % depth)
		assert_eq(hit.reach_a.size(), 1 if wanted > 0.0 else 0, "listed as pushed at %.1f px" % depth)

func test_stiffness_and_damping_use_the_reduced_mass() -> void:
	var f := GooWorld2D.INTRUSION_FREQUENCY
	assert_almost_eq(GooWorld2D.push_stiffness(1.0, 1.0), f * f * 0.5, 0.0001)
	assert_almost_eq(GooWorld2D.push_stiffness(1.0, 3.0), f * f * 0.75, 0.0001)
	assert_eq(GooWorld2D.push_stiffness(0.0, 0.0), 0.0)
	assert_almost_eq(GooWorld2D.push_damping(1.0, 3.0), 2.0 * f * 0.75, 0.0001)

func test_a_bead_still_sinking_in_is_damped() -> void:
	var square := _square()
	var tip := Vector2(50.0, -SIDE / 2.0 + 4.0)
	var at_rest := GooWorld2D.intrusion(_probe(tip), square).forces_a[0]
	var points := _probe(tip).points
	var damping := GooWorld2D.push_damping(PROBE_MASS, FACE_MASS)
	# Sinking at 100 px/s (down, into the square): the damping adds to the push.
	var sinking := GooWorld2D.intrusion(GooWorld2D.OverlapRing.new(points, 1.0, PROBE_MASS,
		PackedVector2Array([Vector2(0.0, 100.0), Vector2.ZERO, Vector2.ZERO])), square).forces_a[0]
	assert_almost_eq(sinking.y - at_rest.y, -damping * 100.0, 0.001, "damped while it sinks in")
	# Leaving at 100 px/s: the spring alone.
	var leaving := GooWorld2D.intrusion(GooWorld2D.OverlapRing.new(points, 1.0, PROBE_MASS,
		PackedVector2Array([Vector2(0.0, -100.0), Vector2.ZERO, Vector2.ZERO])), square).forces_a[0]
	assert_almost_eq(leaving.y, at_rest.y, 0.001, "not damped on the way out")
	# The face sinking onto a resting bead counts the same as the bead sinking.
	var face_velocities := PackedVector2Array()
	face_velocities.resize(square.points.size())
	face_velocities.fill(Vector2(0.0, -100.0))
	var moving_face := GooWorld2D.OverlapRing.new(square.points, FACE_BEAD, FACE_MASS, face_velocities)
	var pressed := GooWorld2D.intrusion(_probe(tip), moving_face).forces_a[0]
	assert_almost_eq(pressed.y, sinking.y, 0.001, "relative speed")

func test_crossed_skins_and_a_swallowed_ring() -> void:
	var a := _circle(Vector2.ZERO, 50.0, 20)
	var crossed := GooWorld2D.intrusion(a, _circle(Vector2(70.0, 0.0), 50.0, 20))
	assert_gt(crossed.inside_a, 0)
	assert_gt(crossed.inside_b, 0)
	assert_eq(crossed.beads_in_a.size(), crossed.inside_a)
	assert_eq(crossed.beads_in_b.size(), crossed.inside_b)
	assert_false(crossed.deep(), "skins crossing each other: each bead inside is pushed out on its own")
	# Every bead of `a` inside the other ring's loop pushes it back toward its
	# own centre, out of the other ring.
	for bead: int in crossed.beads_in_a:
		assert_lt(crossed.forces_a[bead].x, 0.0, "bead %d of a is pushed out of b, to the left" % bead)
	var swallowed := GooWorld2D.intrusion(_circle(Vector2(5.0, 0.0), 20.0, 16), _circle(Vector2.ZERO, 120.0, 30))
	assert_eq(swallowed.inside_a, 16)
	assert_eq(swallowed.inside_b, 0)
	assert_true(swallowed.deep(), "a ring wholly inside another")
	# Two rings whose centres are 20 px apart: each centre inside the other.
	var stacked := GooWorld2D.intrusion(a, _circle(Vector2(20.0, 0.0), 50.0, 20))
	assert_true(stacked.centre_in_a and stacked.centre_in_b)
	assert_true(stacked.deep(), "rings spawned almost on each other")

func test_empty_rings_are_never_pressed() -> void:
	var empty := GooWorld2D.OverlapRing.new(PackedVector2Array(), 5.0, 1.0)
	var hit := GooWorld2D.intrusion(empty, _circle(Vector2.ZERO, 50.0, 20))
	assert_false(hit.pressed)
	assert_false(hit.deep())

# --- untangler: the impulse that pushes a swallowed ring out ---------------

func test_push_splits_by_mass_along_the_centre_line() -> void:
	var delta := 0.05
	var impulses := GooWorld2D.Untangler.push(Vector2(0, 0), 30.0, 1.0, Vector2(40, 0), 30.0, 3.0, delta)
	assert_eq(impulses.size(), 2)
	assert_lt(impulses[0].x, 0.0, "a is pushed away from b")
	assert_gt(impulses[1].x, 0.0, "b is pushed away from a")
	assert_almost_eq(impulses[0].y, 0.0)
	assert_almost_eq(impulses[0].x + impulses[1].x, 0.0, 0.0001, "equal and opposite")
	# overlap 20 px, reduced mass 1 * 3 / 4: STRENGTH * 20 * delta * 0.75, under
	# the separation speed.
	var change := GooWorld2D.Untangler.STRENGTH * 20.0 * delta
	assert_lt(change, GooWorld2D.Untangler.SEPARATION_SPEED, "the fixture stays under the cap")
	assert_almost_eq(impulses[0].x, -change * 0.75, 0.0001)

func test_push_never_vanishes_while_inside() -> void:
	var impulses := GooWorld2D.Untangler.push(Vector2(0, 0), 10.0, 1.0, Vector2(50, 0), 10.0, 1.0, 1.0)
	assert_lt(impulses[0].x, 0.0, "threaded rings are pushed apart even past their nominal radii")

func test_push_stops_at_the_separation_speed() -> void:
	# Parting at 100 px/s short of SEPARATION_SPEED: the push only makes that up.
	var speed := GooWorld2D.Untangler.SEPARATION_SPEED - 100.0
	var impulses := GooWorld2D.Untangler.push(Vector2(0, 0), 30.0, 1.0, Vector2(40, 0), 30.0, 1.0, 1.0,
		Vector2(-speed / 2.0, 0.0), Vector2(speed / 2.0, 0.0))
	assert_almost_eq(impulses[0].x, -100.0 * 0.5, 0.0001, "the reduced mass times the speed left")
	# Already parting faster: no push.
	var fast := GooWorld2D.Untangler.push(Vector2(0, 0), 30.0, 1.0, Vector2(40, 0), 30.0, 1.0, 1.0,
		Vector2(-GooWorld2D.Untangler.SEPARATION_SPEED, 0.0), Vector2.ZERO)
	assert_eq(fast[0], Vector2.ZERO)

func test_coincident_centres_still_separate() -> void:
	var impulses := GooWorld2D.Untangler.push(Vector2(5, 5), 10.0, 1.0, Vector2(5, 5), 10.0, 1.0, 1.0)
	assert_ne(impulses[0], Vector2.ZERO)
