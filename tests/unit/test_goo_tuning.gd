extends TestCase
## Unit tests for GooTuning: the log size scale, colours and merge window;
## the bead physics by size (mass, joint springs, damping, bounce, materials
## cached per whole pixel of radius); and the size-dependent bead counts,
## masses, spring constants and pressure gain of the pressure ring, for round
## rings (tuning()) and for rings of any GooShape (tuning_for()); and the
## length unit (GooTuning.unit): at 0.5 every absolute pixel is halved and
## everything else (counts, masses, times, frequencies, ratios) is kept.

const TUNING_KEYS: Array[String] = ["radius", "bead_count", "blob_mass", "bead_mass",
	"spacing", "bead_radius", "ring_radius", "target_area", "pressure_k", "skin_stiffness", "skin_damping",
	"bending_stiffness", "bending_damping", "shape_match_k", "internal_damp", "linear_damp",
	"bounce", "friction", "settle_speed", "settle_time", "inflate_time", "split_neck", "splat_area_ratio"]

## Radii of the old fixed sizes 0..7 (28 × 1.3^n), where size_t() is n / 7.
var radii: Array[float] = []

func before_each() -> void:
	GooTuning.unit = 1.0
	radii.clear()
	for i: int in 8:
		radii.append(GooTuning.radius_at(i / 7.0))

func after_each() -> void:
	GooTuning.unit = 1.0

func test_bead_count_grows_from_12_to_22() -> void:
	assert_eq(GooTuning.bead_count(GooTuning.MIN_RADIUS), 12)
	assert_eq(GooTuning.bead_count(GooTuning.MAX_RADIUS), 22)
	assert_eq(GooTuning.bead_count(10.0), 12, "clamped under the smallest size")
	assert_eq(GooTuning.bead_count(400.0), 22, "clamped over the largest size")
	var expected: Array[int] = [12, 13, 15, 16, 18, 19, 21, 22]
	for i: int in range(1, radii.size()):
		assert_eq(GooTuning.bead_count(radii[i]), expected[i], "the old sizes' bead counts")
		assert_true(GooTuning.bead_count(radii[i]) >= GooTuning.bead_count(radii[i - 1]),
			"bead_count(%.1f) shrank" % radii[i])

func test_beads_close_the_ring() -> void:
	for radius: float in radii:
		var spacing := TAU * radius / GooTuning.bead_count(radius)
		assert_almost_eq(GooTuning.spacing(radius), spacing, 0.0001)
		assert_true(GooTuning.bead_radius(radius) >= 0.5 * spacing, "radius %.1f ring has gaps" % radius)

func test_ring_radius_puts_the_collision_outline_on_the_drawn_circle() -> void:
	for radius: float in radii:
		var ring := GooTuning.ring_radius(radius)
		var bead := GooTuning.bead_radius(radius)
		var rest := GooLoop.circle_points(Vector2.ZERO, ring, GooTuning.bead_count(radius))
		assert_almost_eq(GooTuning.outline_area(rest, bead), GooTuning.target_area(radius), 0.01,
			"radius %.1f rest outline area" % radius)
		assert_almost_eq(ring + bead, radius, 0.02 * radius,
			"radius %.1f bead centres + bead radius" % radius)

func test_outline_area_of_a_square() -> void:
	var square := PackedVector2Array([Vector2(0, 0), Vector2(0, 10), Vector2(10, 10), Vector2(10, 0)])
	assert_almost_eq(GooTuning.outline_area(square, 1.0), 100.0 + 40.0 + PI, 0.0001)

func test_masses() -> void:
	assert_almost_eq(GooTuning.blob_mass(GooTuning.MIN_RADIUS), 2.6, 0.0001)
	for radius: float in radii:
		assert_almost_eq(GooTuning.blob_mass(radius), GooTuning.particle_mass(radius) * 13.0, 0.0001)
		assert_almost_eq(GooTuning.bead_mass(radius) * GooTuning.bead_count(radius),
			GooTuning.blob_mass(radius), 0.0001)

func test_target_area_is_the_drawn_circle() -> void:
	for radius: float in radii:
		assert_almost_eq(GooTuning.target_area(radius), PI * radius * radius, 0.01)

func test_springs_have_the_joint_frequency_and_damping() -> void:
	for radius: float in radii:
		var m := GooTuning.bead_mass(radius)
		var k := GooTuning.skin_stiffness(radius)
		var c := GooTuning.skin_damping(radius)
		assert_almost_eq(sqrt(k / m), GooTuning.SKIN_FREQUENCY_RATIO * GooTuning.joint_frequency(radius), 0.001,
			"frequency at radius %.1f" % radius)
		assert_almost_eq(c / (2.0 * sqrt(k * m)), GooTuning.joint_damping_ratio(radius), 0.0001,
			"damping ratio at radius %.1f" % radius)
		assert_almost_eq(GooTuning.bending_stiffness(radius), GooTuning.BENDING_RATIO * k, 0.0001)
		assert_almost_eq(GooTuning.bending_damping(radius), GooTuning.BENDING_RATIO * c, 0.0001)

func test_gravity_is_the_project_default_gravity() -> void:
	var project: float = ProjectSettings.get_setting("physics/2d/default_gravity", 980.0)
	assert_eq(GooTuning.gravity(), project)
	assert_eq(GooTuning.gravity(), 980.0, "this project keeps Godot's default, the gravity the goo is tuned for")

func test_pressure_k_scales_with_gravity() -> void:
	var radius := GooTuning.MIN_RADIUS
	assert_almost_eq(GooTuning.pressure_k(radius),
		GooTuning.PRESSURE_GAIN * GooTuning.blob_mass(radius) * GooTuning.gravity() / (TAU * radius), 0.0001,
		"the rest perimeter's total pressure force is PRESSURE_GAIN times the weight")

func test_pressure_k_is_positive_and_finite() -> void:
	for radius: float in radii:
		var k := GooTuning.pressure_k(radius)
		assert_gt(k, 0.0, "pressure_k(%.1f)" % radius)
		assert_true(is_finite(k), "pressure_k(%.1f) not finite" % radius)

func test_shape_matching_softens_with_size() -> void:
	for i: int in range(1, radii.size()):
		assert_lt(GooTuning.shape_match_k(radii[i]), GooTuning.shape_match_k(radii[i - 1]),
			"shape_match_k(%.1f) should be below shape_match_k(%.1f)" % [radii[i], radii[i - 1]])

func test_constants() -> void:
	assert_almost_eq(GooTuning.shape_match_k(GooTuning.MIN_RADIUS), GooTuning.SHAPE_MATCH_K)
	assert_almost_eq(GooTuning.internal_damp(GooTuning.MIN_RADIUS), GooTuning.INTERNAL_DAMP_SMALL)
	assert_almost_eq(GooTuning.internal_damp(GooTuning.MAX_RADIUS), GooTuning.INTERNAL_DAMP_LARGE)
	assert_almost_eq(GooTuning.settle_speed(), 4.0)
	assert_almost_eq(GooTuning.settle_time(), 0.5)
	assert_almost_eq(GooTuning.inflate_time(), 0.3)

func test_tuning_bundles_every_value() -> void:
	for radius: float in radii:
		var tuning := GooTuning.tuning(radius)
		for key: String in TUNING_KEYS:
			assert_has(tuning, key, "tuning(%.1f)" % radius)
		assert_eq(tuning.size(), TUNING_KEYS.size(), "tuning(%.1f) has unexpected keys" % radius)
		assert_eq(tuning["bead_count"], GooTuning.bead_count(radius))
		assert_almost_eq(tuning["pressure_k"], GooTuning.pressure_k(radius))
		assert_almost_eq(tuning["skin_stiffness"], GooTuning.skin_stiffness(radius))

func test_big_rings_split_at_a_wider_neck() -> void:
	var small := GooTuning.MIN_RADIUS
	var large := GooTuning.MAX_RADIUS
	assert_almost_eq(GooTuning.split_neck(small),
		GooTuning.SPLIT_NECK_SMALL * 2.0 * GooTuning.ring_radius(small), 0.0001)
	assert_almost_eq(GooTuning.split_neck(large),
		GooTuning.SPLIT_NECK_LARGE * 2.0 * GooTuning.ring_radius(large), 0.0001)
	for i: int in range(1, radii.size()):
		var before := GooTuning.split_neck(radii[i - 1]) / GooTuning.ring_radius(radii[i - 1])
		var now := GooTuning.split_neck(radii[i]) / GooTuning.ring_radius(radii[i])
		assert_gt(now, before, "radius %.1f splits at a wider neck, relative to its size" % radii[i])

func test_splat_area_ratio_runs_from_small_to_large() -> void:
	assert_almost_eq(GooTuning.splat_area_ratio(GooTuning.MIN_RADIUS), GooTuning.SPLAT_AREA_SMALL, 0.0001)
	assert_almost_eq(GooTuning.splat_area_ratio(GooTuning.MAX_RADIUS), GooTuning.SPLAT_AREA_LARGE, 0.0001)
	var tuning := GooTuning.tuning(GooTuning.radius_at(0.5))
	assert_almost_eq(tuning["splat_area_ratio"], lerpf(GooTuning.SPLAT_AREA_SMALL, GooTuning.SPLAT_AREA_LARGE, 0.5), 0.0001)
	assert_lt(GooTuning.SPLIT_HOLD, GooTuning.SPLIT_LOCK)

func test_tuning_for_a_round_shape_is_tuning() -> void:
	for radius: float in radii:
		var round_tuning := GooTuning.tuning_for(GooShape.round(radius))
		var expected := GooTuning.tuning(radius)
		assert_eq(round_tuning.keys(), expected.keys(), "radius %.1f keys" % radius)
		for key: String in TUNING_KEYS:
			assert_eq(round_tuning[key], expected[key], "radius %.1f %s" % [radius, key])

func test_tuning_for_a_polygon_has_every_key() -> void:
	for sides: int in [3, 4]:
		var tuning := GooTuning.tuning_for(GooShape.regular(sides, 40.0))
		for key: String in TUNING_KEYS:
			assert_has(tuning, key, "%d-gon" % sides)
		assert_eq(tuning.size(), TUNING_KEYS.size(), "%d-gon has unexpected keys" % sides)

func test_tuning_for_a_polygon_spaces_beads_around_its_outline() -> void:
	for radius: float in [DropController.DROP_MIN_RADIUS, DropController.DROP_MAX_RADIUS, GooTuning.MAX_RADIUS]:
		for sides: int in [3, 4]:
			var shape := GooShape.regular(sides, radius)
			var label := "%d-gon of radius %.1f" % [sides, radius]
			var tuning := GooTuning.tuning_for(shape)
			var count: int = tuning["bead_count"]
			assert_eq(count, clampi(roundi(shape.perimeter() / GooTuning.spacing(radius)),
				GooTuning.MIN_BEADS, GooTuning.MAX_POLYGON_BEADS), label + " bead count")
			assert_gt(count, GooTuning.bead_count(radius), label + ": a polygon is longer around than its circle")
			var bead: float = tuning["bead_radius"]
			var spacing: float = tuning["spacing"]
			assert_almost_eq(bead, GooTuning.BEAD_RADIUS_RATIO * spacing, 0.0001, label + " bead radius")
			var rest := shape.bead_loop(count, bead)
			assert_eq(rest.size(), count)
			assert_almost_eq(spacing, GooLoop.perimeter(rest) / count, 0.01 * spacing,
				label + ": spacing is the rest loop's perimeter over the bead count")
			assert_almost_eq(tuning["target_area"], GooTuning.outline_area(rest, bead), 0.001 * shape.area(),
				label + ": the rest ring's collision outline encloses its target area")
			# Within 4%: a launch-size triangle's beads (12 to 22 per round ring of its
			# size) round its corners off by 3.4% of its area.
			assert_almost_eq(tuning["target_area"], shape.area(), 0.04 * shape.area(),
				label + ": the target is the outline's area less its rounded corners")
			assert_eq(tuning["radius"], shape.radius())

func test_tuning_for_a_polygon_keeps_mass_and_spring_frequency() -> void:
	var radius := 40.0
	var tuning := GooTuning.tuning_for(GooShape.regular(4, radius))
	var count: int = tuning["bead_count"]
	var m: float = tuning["bead_mass"]
	assert_almost_eq(tuning["blob_mass"], GooTuning.blob_mass(radius), 0.0001)
	assert_almost_eq(m * count, GooTuning.blob_mass(radius), 0.0001, "the beads share the blob's mass")
	var k: float = tuning["skin_stiffness"]
	var c: float = tuning["skin_damping"]
	assert_almost_eq(sqrt(k / m), GooTuning.SKIN_FREQUENCY_RATIO * GooTuning.joint_frequency(radius), 0.001)
	assert_almost_eq(c / (2.0 * sqrt(k * m)), GooTuning.joint_damping_ratio(radius), 0.0001)
	assert_almost_eq(tuning["bending_stiffness"], GooTuning.BENDING_RATIO * k, 0.0001)
	assert_almost_eq(tuning["bending_damping"], GooTuning.BENDING_RATIO * c, 0.0001)
	assert_almost_eq(tuning["pressure_k"],
		GooTuning.PRESSURE_GAIN * GooTuning.blob_mass(radius) * GooTuning.gravity()
		/ GooShape.regular(4, radius).perimeter(), 0.0001, "pressure spread over the outline's perimeter")
	assert_almost_eq(tuning["shape_match_k"],
		GooTuning.shape_match_k(radius) * GooTuning.POLYGON_SHAPE_MATCH_RATIO, 0.0001)
	for key: String in ["internal_damp", "linear_damp", "bounce", "friction", "settle_speed",
			"settle_time", "inflate_time", "split_neck", "splat_area_ratio", "ring_radius"]:
		var expected: float = GooTuning.tuning(radius)[key]
		assert_almost_eq(tuning[key], expected, 0.000001 * absf(expected), "%s follows the equivalent radius" % key)

func test_tuning_for_a_long_polygon_caps_its_bead_count() -> void:
	var bar := GooShape.polygon(PackedVector2Array([Vector2(0, 60), Vector2(900, 60), Vector2(900, 0), Vector2(0, 0)]))
	var tuning := GooTuning.tuning_for(bar)
	assert_eq(tuning["bead_count"], GooTuning.MAX_POLYGON_BEADS)
	assert_gt(GooTuning.MAX_POLYGON_BEADS, GooTuning.MAX_BEADS)
	assert_lt(2.0 * float(tuning["bead_radius"]), 60.0, "the beads still fit across the bar")

# ---- Sizes ----

func test_size_t_spans_min_to_max() -> void:
	assert_almost_eq(GooTuning.size_t(GooTuning.MIN_RADIUS), 0.0, 0.00001)
	assert_almost_eq(GooTuning.size_t(GooTuning.MAX_RADIUS), 1.0, 0.00001)

func test_size_t_matches_the_old_sizes() -> void:
	# The old fixed sizes were 28 × 1.3^n; 61.5 was n = 3 of 0..7.
	assert_almost_eq(GooTuning.size_t(61.5), 3.0 / 7.0, 0.01)

func test_size_t_clamps_outside_the_range() -> void:
	assert_almost_eq(GooTuning.size_t(10.0), 0.0, 0.00001)
	assert_almost_eq(GooTuning.size_t(0.0), 0.0, 0.00001)
	assert_almost_eq(GooTuning.size_t(500.0), 1.0, 0.00001)

func test_radius_at_inverts_size_t() -> void:
	assert_almost_eq(GooTuning.radius_at(0.0), GooTuning.MIN_RADIUS, 0.0001)
	assert_almost_eq(GooTuning.radius_at(1.0), GooTuning.MAX_RADIUS, 0.0001)
	for i: int in 11:
		var t := i / 10.0
		assert_almost_eq(GooTuning.size_t(GooTuning.radius_at(t)), t, 0.00001, "t = %.1f" % t)
	for radius: float in [30.0, 61.5, 100.0, 150.0]:
		assert_almost_eq(GooTuning.radius_at(GooTuning.size_t(radius)), radius, 0.001)

func test_colour_hue_runs_from_red_to_blue() -> void:
	var previous := -1.0
	for i: int in 8:
		var colour := GooTuning.color(GooTuning.radius_at(i / 7.0))
		assert_almost_eq(colour.a, 1.0)
		assert_gt(colour.h, previous, "hue of sample %d should increase" % i)
		previous = colour.h
	assert_almost_eq(GooTuning.color(GooTuning.MIN_RADIUS).h, 0.0, 0.001)
	assert_almost_eq(GooTuning.color(GooTuning.MAX_RADIUS).h, 2.0 / 3.0, 0.001)

func test_close_sizes_merge() -> void:
	assert_true(GooTuning.can_merge(28.0, 28.0))
	assert_true(GooTuning.can_merge(28.0, 32.0))
	assert_true(GooTuning.can_merge(32.0, 28.0))

func test_sizes_outside_the_window_do_not_merge() -> void:
	# 33 > 28 / 0.85 = 32.94.
	assert_false(GooTuning.can_merge(28.0, 33.0))
	assert_false(GooTuning.can_merge(33.0, 28.0))
	assert_false(GooTuning.can_merge(28.0, 40.0))

func test_merges_conserve_area() -> void:
	assert_true(GooTuning.can_merge(100.0, 100.0))
	assert_almost_eq(GooTuning.merged_radius(100.0, 100.0), 141.42, 0.01)
	assert_almost_eq(GooTuning.merged_radius(28.0, 28.0), 39.6, 0.01)

func test_merges_past_the_max_are_refused() -> void:
	assert_false(GooTuning.can_merge(150.0, 150.0))
	assert_false(GooTuning.can_merge(GooTuning.MAX_RADIUS, GooTuning.MAX_RADIUS))

func test_non_positive_sizes_do_not_merge() -> void:
	assert_false(GooTuning.can_merge(0.0, 0.0))
	assert_false(GooTuning.can_merge(-28.0, -28.0))

# ---- Bead physics by size ----

func test_constants_are_the_chosen_tuning() -> void:
	assert_almost_eq(GooTuning.JOINT_FREQUENCY_SMALL, 20.0)
	assert_almost_eq(GooTuning.JOINT_FREQUENCY_LARGE, 1.0)
	assert_almost_eq(GooTuning.JOINT_DAMPING_SMALL, 0.05)
	assert_almost_eq(GooTuning.JOINT_DAMPING_LARGE, 0.25)
	assert_almost_eq(GooTuning.BLOB_FRICTION, 0.2)
	assert_almost_eq(GooTuning.WALL_GRIP_DAMP, 3.0)

func test_particle_mass_grows_with_size() -> void:
	assert_almost_eq(GooTuning.particle_mass(GooTuning.MIN_RADIUS), 0.2)
	assert_almost_eq(GooTuning.particle_mass(radii[3]), 0.8)
	assert_almost_eq(GooTuning.particle_mass(GooTuning.MAX_RADIUS), 1.6)
	for i: int in range(1, radii.size()):
		assert_gt(GooTuning.particle_mass(radii[i]), GooTuning.particle_mass(radii[i - 1]))

func test_joints_soften_and_damp_more_with_size() -> void:
	assert_almost_eq(GooTuning.joint_frequency(GooTuning.MIN_RADIUS), GooTuning.JOINT_FREQUENCY_SMALL)
	assert_almost_eq(GooTuning.joint_frequency(GooTuning.MAX_RADIUS), GooTuning.JOINT_FREQUENCY_LARGE)
	assert_almost_eq(GooTuning.joint_damping_ratio(GooTuning.MIN_RADIUS), GooTuning.JOINT_DAMPING_SMALL)
	assert_almost_eq(GooTuning.joint_damping_ratio(GooTuning.MAX_RADIUS), GooTuning.JOINT_DAMPING_LARGE)
	for i: int in range(1, radii.size()):
		assert_lt(GooTuning.joint_frequency(radii[i]), GooTuning.joint_frequency(radii[i - 1]))
		assert_gt(GooTuning.joint_damping_ratio(radii[i]), GooTuning.joint_damping_ratio(radii[i - 1]))

func test_linear_damp_falls_to_floor() -> void:
	assert_almost_eq(GooTuning.linear_damp(GooTuning.MIN_RADIUS), 0.5)
	assert_almost_eq(GooTuning.linear_damp(radii[1]), 0.44)
	assert_almost_eq(GooTuning.linear_damp(radii[6]), 0.14)
	assert_almost_eq(GooTuning.linear_damp(GooTuning.MAX_RADIUS), 0.1)
	for radius: float in radii:
		assert_true(GooTuning.linear_damp(radius) >= 0.1, "damp(%.1f) under the floor" % radius)

func test_small_blobs_bounce_more() -> void:
	# A contact sums the bounce of both bodies (the kernel's solver's rule),
	# so two of the smallest blobs must stay under 1.0
	# together (a perfectly elastic contact).
	assert_almost_eq(GooTuning.bounce(GooTuning.MIN_RADIUS), 0.45)
	assert_almost_eq(GooTuning.bounce(GooTuning.MAX_RADIUS), 0.1)
	assert_lt(2.0 * GooTuning.bounce(GooTuning.MIN_RADIUS), 0.95)
	for i: int in range(1, radii.size()):
		assert_lt(GooTuning.bounce(radii[i]), GooTuning.bounce(radii[i - 1]))

func test_solver_settings_are_the_tuning() -> void:
	var settings := GooTuning.solver_settings()
	assert_eq(settings["substeps"], GooTuning.SUBSTEPS)
	assert_eq(settings["max_substeps"], GooTuning.MAX_SUBSTEPS)
	assert_gt(GooTuning.MAX_SUBSTEPS, GooTuning.SUBSTEPS)
	assert_eq(settings["gravity"], Vector2(0.0, GooTuning.gravity()), "the project's default gravity, down")
	assert_almost_eq(settings["grip_damp"], GooTuning.WALL_GRIP_DAMP)
	assert_almost_eq(settings["max_bead_speed"], GooTuning.MAX_BEAD_SPEED)
	assert_almost_eq(settings["touch_slop"], GooTuning.TOUCH_SLOP)
	assert_almost_eq(settings["wake_depth"], GooTuning.WAKE_DEPTH)
	assert_almost_eq(settings["wake_speed"], GooTuning.WAKE_SPEED)
	assert_almost_eq(settings["untangle_strength"], GooWorld2D.Untangler.STRENGTH)
	assert_almost_eq(settings["untangle_separation_speed"], GooWorld2D.Untangler.SEPARATION_SPEED)
	assert_gt(GooTuning.MAX_BEAD_SPEED, DropController.MAX_LAUNCH_SPEED, "a throw is never capped")
	assert_almost_eq(float(GooKernel.new().solver()["max_bead_speed"]), GooTuning.MAX_BEAD_SPEED, 0.001,
		"a kernel made without the settings caps at the same speed")
	var kernel := GooTuning.make_kernel()
	var applied := kernel.solver()
	for key: String in settings:
		assert_almost_eq(float(applied[key]) if not settings[key] is Vector2 else 0.0,
			float(settings[key]) if not settings[key] is Vector2 else 0.0, 0.0001, key)
	assert_eq(applied["gravity"], settings["gravity"])

# ---- The length unit ----

# Every value of tuning() that is a length in px; target_area is an area, and
# settle_speed a speed (px/s). The rest are counts, masses, times, frequencies,
# stiffnesses per unit mass and ratios, which the unit leaves alone.
const UNIT_LENGTH_KEYS: Array[String] = ["radius", "spacing", "bead_radius", "ring_radius", "split_neck", "settle_speed"]

func test_unit_is_one_by_default() -> void:
	assert_eq(GooTuning.unit, 1.0)
	assert_eq(GooTuning.min_radius(), GooTuning.MIN_RADIUS)
	assert_eq(GooTuning.max_radius(), GooTuning.MAX_RADIUS)

func test_half_unit_halves_the_size_range() -> void:
	var t56 := GooTuning.size_t(56.0)
	GooTuning.unit = 0.5
	assert_almost_eq(GooTuning.min_radius(), 14.0, 0.000001)
	assert_almost_eq(GooTuning.max_radius(), 88.0, 0.000001)
	assert_almost_eq(GooTuning.size_t(14.0), 0.0, 0.000001)
	assert_almost_eq(GooTuning.size_t(88.0), 1.0, 0.000001)
	assert_almost_eq(GooTuning.size_t(28.0), t56, 0.000001, "a 28 px body is tuned as a 56 px one at unit 1")
	assert_almost_eq(GooTuning.radius_at(0.0), 14.0, 0.0001)
	assert_almost_eq(GooTuning.radius_at(1.0), 88.0, 0.0001)
	assert_eq(GooTuning.color(14.0), _at_unit_one(func() -> Color: return GooTuning.color(28.0)))

func test_half_unit_merges_as_at_unit_one_scaled() -> void:
	var pairs: Array[Vector2] = [Vector2(28.0, 30.0), Vector2(40.0, 50.0), Vector2(120.0, 124.0), Vector2(125.0, 125.0),
		Vector2(150.0, 150.0)]
	var want: Array[bool] = []
	for pair: Vector2 in pairs:
		want.append(GooTuning.can_merge(pair.x, pair.y))
	GooTuning.unit = 0.5
	for i: int in pairs.size():
		assert_eq(GooTuning.can_merge(pairs[i].x * 0.5, pairs[i].y * 0.5), want[i], "%s halved" % pairs[i])

func test_half_unit_halves_gravity() -> void:
	GooTuning.unit = 0.5
	assert_almost_eq(GooTuning.gravity(), 490.0, 0.0001)
	assert_eq(float(ProjectSettings.get_setting("physics/2d/default_gravity")), 980.0, "the project setting stays")

func test_half_unit_bead_radius_is_half() -> void:
	var at_one := GooTuning.bead_radius(28.0)
	GooTuning.unit = 0.5
	assert_almost_eq(GooTuning.bead_radius(14.0), 0.5 * at_one, 0.000001)
	assert_eq(GooTuning.bead_count(14.0), 12)

func test_half_unit_scales_a_round_tuning() -> void:
	for radius: float in [28.0, 36.0, 60.0, 120.0, 176.0]:
		_assert_tuning_scaled(GooTuning.tuning(radius),
			func() -> Dictionary: return GooTuning.tuning(radius * 0.5), "round %.0f" % radius)

func test_half_unit_scales_a_polygon_tuning() -> void:
	for sides: int in [3, 4]:
		for radius: float in [28.0, 48.0]:
			_assert_tuning_scaled(GooTuning.tuning_for(GooShape.regular(sides, radius)),
				func() -> Dictionary: return GooTuning.tuning_for(GooShape.regular(sides, radius * 0.5)),
				"%d-gon %.0f" % [sides, radius])

func test_half_unit_halves_the_solver_lengths_and_speeds() -> void:
	var at_one := GooTuning.solver_settings()
	GooTuning.unit = 0.5
	var settings := GooTuning.solver_settings()
	assert_eq(settings.keys(), at_one.keys())
	assert_almost_eq((settings["gravity"] as Vector2).y, 490.0, 0.0001)
	assert_almost_eq((settings["gravity"] as Vector2).x, 0.0, 0.0001)
	for key: String in ["touch_slop", "wake_depth", "wake_speed", "max_bead_speed", "untangle_separation_speed"]:
		assert_almost_eq(float(settings[key]), 0.5 * float(at_one[key]), 0.000001, key + " halves")
	# Untangler.STRENGTH is an acceleration per pixel of overlap (1/s²): the
	# overlap halves with the bodies, so the push halves without it changing.
	for key: String in ["substeps", "max_substeps", "base_damp", "grip_damp", "untangle_strength"]:
		assert_almost_eq(float(settings[key]), float(at_one[key]), 0.000001, key + " is kept")
	var applied := GooTuning.make_kernel().solver()
	for key: String in settings:
		if settings[key] is Vector2:
			assert_eq(applied[key], settings[key], key)
		else:
			assert_almost_eq(float(applied[key]), float(settings[key]), 0.0001, key + " reaches the kernel")

# `make` called at unit 1, whatever the unit is now (restored after).
func _at_unit_one(make: Callable) -> Variant:
	var unit := GooTuning.unit
	GooTuning.unit = 1.0
	var value: Variant = make.call()
	GooTuning.unit = unit
	return value

# `half` (a tuning dictionary made by the callable at unit 0.5 for half the
# size) is `at_one` with every length halved, the area quartered and every other
# value kept.
func _assert_tuning_scaled(at_one: Dictionary, half: Callable, label: String) -> void:
	GooTuning.unit = 0.5
	var scaled: Dictionary = half.call()
	GooTuning.unit = 1.0
	assert_eq(scaled.keys(), at_one.keys(), label + " keys")
	for key: String in at_one:
		var factor := 0.5 if key in UNIT_LENGTH_KEYS else (0.25 if key == "target_area" else 1.0)
		var want := float(at_one[key]) * factor
		assert_almost_eq(float(scaled[key]), want, 0.00001 * maxf(absf(want), 1.0), "%s %s" % [label, key])
