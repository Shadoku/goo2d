extends TestCase
## Two touching blobs of close sizes merge into one holding both their areas;
## blobs of different sizes, or whose merge would pass GooTuning.MAX_RADIUS, do
## not. Merges take GooWorld2D.MergeTransition.DURATION, pull the blobs
## together and keep their momentum.

## Time a merge may take: physics settling plus the longest merge transition.
const MERGE_TIMEOUT: float = 3.0 + GooWorld2D.MergeTransition.MAX_DURATION

var arena: Arena
var game: Game
var merges: Array[float] = []

func before_each() -> void:
	arena = (load("res://scenes/arena.tscn") as PackedScene).instantiate() as Arena
	add_child(arena)
	game = Game.new()
	game.arena = arena
	add_child(game)
	merges.clear()
	game.merged.connect(func(radius: float, _position: Vector2) -> void: merges.append(radius))

## Spawns blobs of radius `ra` and `rb` resting on the floor, touching each other.
func _spawn_pair(ra: float, rb: float) -> Array[Goo2D]:
	var gap := ra + rb - 4.0
	var x := Arena.INNER_LEFT + Arena.INNER_WIDTH / 2.0
	var a := game.spawn(ra, Vector2(x - gap / 2.0, Arena.FLOOR_Y - ra))
	var b := game.spawn(rb, Vector2(x + gap / 2.0, Arena.FLOOR_Y - rb))
	return [a, b] as Array[Goo2D]

func _in_play(blob: Goo2D) -> bool:
	return is_instance_valid(blob) and blob.is_inside_tree() and not blob.is_queued_for_deletion()

func test_two_equal_blobs_merge() -> void:
	_spawn_pair(28.0, 28.0)
	assert_eq(game.bodies().size(), 2)
	var counts: Array[int] = []
	game.count_changed.connect(func(count: int) -> void: counts.append(count))
	var fired := await await_signal(game.merged, MERGE_TIMEOUT)
	assert_true(fired, "touching 28 px blobs should merge within %.2f s" % MERGE_TIMEOUT)
	await wait_frames(2)
	assert_eq(game.bodies().size(), 1)
	assert_false(counts.is_empty(), "count_changed fires on a merge")
	if not counts.is_empty():
		assert_eq(counts[-1], 1, "the last count_changed after a merge reports the one body left (got %s)" % [counts])
	if game.bodies().size() == 1:
		assert_almost_eq(game.bodies()[0].radius, 39.6, 0.01, "the merged blob holds both areas")
	assert_eq(merges.size(), 1)
	if merges.size() == 1:
		assert_almost_eq(merges[0], 39.6, 0.01)

func test_different_sizes_do_not_merge() -> void:
	_spawn_pair(28.0, 40.0)
	await wait_seconds(1.5)
	assert_eq(game.bodies().size(), 2)
	assert_eq(merges.size(), 0)

func test_max_size_blobs_do_not_merge() -> void:
	# Two max-size blobs side by side cover the floor from x ≈ 550 to the
	# wedge, the floor blade included, which would cut one (test_blade.gd).
	# Only merging is tested here, so the blades go.
	for blade: Blade in arena.blades():
		arena.remove_child(blade)
		blade.queue_free()
	_spawn_pair(GooTuning.MAX_RADIUS, GooTuning.MAX_RADIUS)
	await wait_seconds(1.5)
	assert_eq(game.bodies().size(), 2)
	assert_eq(merges.size(), 0)

func test_many_touching_particles_merge_once() -> void:
	_spawn_pair(28.0, 28.0)
	var fired := await await_signal(game.merged, MERGE_TIMEOUT)
	assert_true(fired)
	await wait_seconds(1.0)
	assert_eq(merges.size(), 1, "one pair of blobs should merge exactly once")
	assert_eq(game.bodies().size(), 1)

func test_merged_signal_reports_the_merged_blob_inside_the_arena() -> void:
	_spawn_pair(28.0, 28.0)
	var spawned: Array[Vector2] = []
	var centres: Array[Vector2] = []
	game.merged.connect(func(_radius: float, position: Vector2) -> void:
		spawned.append(position)
		centres.append(game.bodies()[-1].center()))
	await await_signal(game.merged, MERGE_TIMEOUT)
	assert_eq(spawned.size(), 1)
	if spawned.size() != 1:
		return
	assert_eq(spawned[0], centres[0], "the signal reports the merged blob's centre")
	assert_lt(spawned[0].y, Arena.FLOOR_Y, "merged blob should not be built through the floor: %s" % spawned[0])
	assert_gt(spawned[0].x, Arena.INNER_LEFT, "merged blob should be inside the left wall: %s" % spawned[0])
	assert_lt(spawned[0].x, Arena.INNER_LEFT + Arena.INNER_WIDTH,
		"merged blob should be inside the right wall: %s" % spawned[0])

func test_reset_removes_every_blob() -> void:
	_spawn_pair(28.0, 40.0)
	var counts: Array[int] = []
	game.count_changed.connect(func(count: int) -> void: counts.append(count))
	game.reset()
	assert_eq(game.bodies().size(), 0)
	assert_eq(counts, [0] as Array[int])
	await wait_frames(2)
	assert_eq(game.get_child_count(), 0)

func test_merge_waits_for_the_transition_and_pulls_blobs_together() -> void:
	var pair := _spawn_pair(28.0, 28.0)
	var a := pair[0]
	var b := pair[1]
	# Lambdas capture locals by value, so the touch is recorded in a dictionary.
	var contact := {"frame": -1, "distance": 0.0}
	var frame := [0]
	var on_touch := func(_other: Goo2D) -> void:
		if contact["frame"] < 0:
			contact["frame"] = frame[0]
			contact["distance"] = a.center().distance_to(b.center())
	a.touched.connect(on_touch)
	b.touched.connect(on_touch)
	var last_distance := INF
	var limit := int(MERGE_TIMEOUT * Engine.physics_ticks_per_second)
	while merges.is_empty() and frame[0] < limit:
		if _in_play(a) and _in_play(b):
			last_distance = a.center().distance_to(b.center())
		await get_tree().physics_frame
		frame[0] += 1
	assert_eq(merges.size(), 1, "the pair should merge")
	assert_true(contact["frame"] >= 0, "the pair should touch")
	if merges.size() != 1 or contact["frame"] < 0:
		return
	var delay := float(frame[0] - int(contact["frame"])) / Engine.physics_ticks_per_second
	print("merge delay after first contact: %.3f s; centre distance %.2f -> %.2f px"
		% [delay, contact["distance"], last_distance])
	# Contact and merge are sampled once per physics frame: allow one frame of slack.
	var slack := 1.0 / Engine.physics_ticks_per_second
	assert_true(delay >= GooWorld2D.MergeTransition.DURATION - slack,
		"merge after %.3f s should not beat the %.2f s transition" % [delay, GooWorld2D.MergeTransition.DURATION])
	assert_lt(last_distance, contact["distance"], "the transition should pull the blobs together")

func test_merge_keeps_the_momentum_of_the_pair() -> void:
	var radius := GooTuning.MIN_RADIUS
	var x := Arena.INNER_LEFT + Arena.INNER_WIDTH / 2.0
	var y := Arena.FLOOR_Y - radius
	var resting := game.spawn(radius, Vector2(x, y))
	var moving := game.spawn(radius, Vector2(x - 3.0 * radius, y))
	moving.set_velocity(Vector2(300, 0))
	# Lossless: the pair's momentum over its mass (the resting blob is still).
	var expected := Vector2(300, 0) * moving.body_mass() / (resting.body_mass() + moving.body_mass())
	var fired := await await_signal(game.merged, MERGE_TIMEOUT)
	assert_true(fired, "the thrown blob should merge with the resting one")
	await get_tree().physics_frame
	assert_eq(game.bodies().size(), 1)
	if game.bodies().size() != 1:
		return
	var vx := game.bodies()[0].average_velocity().x
	print("merged blob velocity: %.1f px/s (lossless %.1f px/s, %.0f%%)"
		% [vx, expected.x, 100.0 * vx / expected.x])
	assert_gt(vx, 0.0, "the merged blob should keep moving the way the thrown one did")
	assert_true(vx >= 0.25 * expected.x,
		"merged blob kept %.1f of %.1f px/s; at least 25%% expected" % [vx, expected.x])

func test_reset_during_a_transition_cancels_it() -> void:
	var pair := _spawn_pair(28.0, 28.0)
	var waited := 0
	while not (pair[0].merging or pair[1].merging) and waited < 120:
		await get_tree().physics_frame
		waited += 1
	assert_true(pair[0].merging and pair[1].merging, "the pair should start merging")
	game.reset()
	assert_eq(game.bodies().size(), 0)
	await wait_seconds(GooWorld2D.MergeTransition.DURATION + 0.1)
	assert_eq(game.bodies().size(), 0, "a cancelled transition must not spawn a merged blob")
	assert_eq(merges.size(), 0)
	_spawn_pair(28.0, 28.0)
	var fired := await await_signal(game.merged, MERGE_TIMEOUT)
	assert_true(fired, "blobs should still merge after a reset")
	await wait_frames(2)
	assert_eq(game.bodies().size(), 1)

func test_the_merge_lock_lasts_as_many_frames_whatever_frame_it_began_on() -> void:
	# The lock ends on the frame grid (GooWorld2D._physics_time_in()): begun
	# on 24 successive frames, it lasts MERGE_LOCK × the tick rate physics
	# frames every time. A lock of now + MERGE_LOCK seconds ended a frame late
	# on about one start frame in five, by a rounding error that depends on how
	# long the engine has run, so a game replayed on another frame count
	# merged a frame apart (docs/loose-ends-plan.md, B3).
	var blob := game.spawn(20.0, Vector2(Arena.INNER_LEFT + Arena.INNER_WIDTH / 2.0, Arena.FLOOR_Y - 20.0))
	var span := roundi(GooWorld2D.MERGE_LOCK * Engine.physics_ticks_per_second)
	var lengths: Array[int] = []
	for trial: int in 24:
		game._lock_merging(blob)
		var frames := 0
		while game.merge_locked(blob) and frames < span + 5:
			await get_tree().physics_frame
			frames += 1
		lengths.append(frames)
		await get_tree().physics_frame
	print("    the merge lock's length in frames, begun on 24 frames: %s" % [lengths])
	for length: int in lengths:
		assert_eq(length, span, "%d frames every time: %s" % [span, lengths])
		if length != span:
			break

func test_merged_blob_cannot_merge_again_within_the_merge_lock() -> void:
	timeout_sec = 15.0
	_spawn_pair(28.0, 28.0)
	var fired := await await_signal(game.merged, MERGE_TIMEOUT)
	assert_true(fired, "the pair should merge")
	assert_eq(game.bodies().size(), 1)
	if game.bodies().size() != 1:
		return
	var merged_blob := game.bodies()[0]
	assert_true(game.merge_locked(merged_blob), "a merged blob starts merge-locked")
	# A third blob of the merged size dropped onto it right away: it touches the
	# merged blob within a few frames, while the lock runs.
	var third_radius := merged_blob.radius
	var top := merged_blob.center().y - 28.0
	var third := game.spawn(third_radius, Vector2(merged_blob.center().x, top - third_radius - 2.0))
	assert_false(game.merge_locked(third), "a freshly spawned blob is not merge-locked")
	var first_touch: Array[int] = [-1]
	merged_blob.touched.connect(func(other: Goo2D) -> void:
		if other == third and first_touch[0] < 0:
			first_touch[0] = Engine.get_physics_frames())
	third.touched.connect(func(other: Goo2D) -> void:
		if other == merged_blob and first_touch[0] < 0:
			first_touch[0] = Engine.get_physics_frames())
	var start := Engine.get_physics_frames()
	var started := -1
	for frame: int in roundi(2.0 * Engine.physics_ticks_per_second):
		await get_tree().physics_frame
		if _in_play(merged_blob) and merged_blob.merging:
			started = Engine.get_physics_frames()
			break
	var ticks := float(Engine.physics_ticks_per_second)
	var touch_s: float = (first_touch[0] - start) / ticks if first_touch[0] >= 0 else -1.0
	var start_s: float = (started - start) / ticks if started >= 0 else -1.0
	print("    merged blob %.1f px: third blob first touched it %.3f s after the merge, transition started %.3f s after (lock %.2f s)"
		% [merged_blob.radius, touch_s, start_s, GooWorld2D.MERGE_LOCK])
	assert_true(first_touch[0] >= 0 and touch_s < GooWorld2D.MERGE_LOCK, "the third blob touches it while the lock runs")
	assert_true(started >= 0, "the merge starts once the lock has run out")
	var slack := 1.0 / ticks
	assert_true(start_s >= GooWorld2D.MERGE_LOCK - slack,
		"no transition within the %.2f s merge lock (started after %.3f s)" % [GooWorld2D.MERGE_LOCK, start_s])

# Follows `merged` (just built, not stepped yet) for `frames` physics frames:
# returns [smallest and largest area() over its birth area, fastest bead in px/s].
func _watch_birth(merged: Goo2D, frames: int) -> Array[float]:
	var birth := merged.area()
	var low := 1.0
	var high := 1.0
	var fastest := 0.0
	for frame: int in frames:
		await get_tree().physics_frame
		if not _in_play(merged):
			break
		low = minf(low, merged.area() / birth)
		high = maxf(high, merged.area() / birth)
		for velocity: Vector2 in merged.bead_velocities():
			fastest = maxf(fastest, velocity.length())
	return [low, high, fastest] as Array[float]

func test_a_ring_merged_from_a_peanut_holds_its_area_and_stays_calm() -> void:
	# Round 40 and 44 resting on the floor, their centres 97% of the sum of
	# their radii apart, merged straight away (the world would pull them closer
	# first): their collision outlines barely overlap, a peanut longer around
	# than the merged circle, with a waist. A ring placed on it used to have its
	# skin snap to the circle's rest lengths and the beads across the waist
	# thrown apart by their self-collision in one step (tools/births.gd seed 3,
	# frame 732: 42% of the area lost, 2291 px/s; here 85% kept, 1916 px/s).
	await get_tree().physics_frame
	var ra := 40.0
	var rb := 44.0
	var x := Arena.INNER_LEFT + 900.0
	var gap := 0.97 * (ra + rb)
	var a := game.spawn(ra, Vector2(x, Arena.FLOOR_Y - ra))
	var b := game.spawn(rb, Vector2(x + gap, Arena.FLOOR_Y - rb))
	var fit := GooWorld2D.merge_fit(a, b)
	var merged := Goo2D.make_merged(GooTuning.merged_radius(ra, rb), game, [a, b] as Array[Goo2D])
	for body: Goo2D in [a, b]:
		game.remove_child(body)
		body.queue_free()
	assert_not_null(merged)
	if merged == null:
		return
	var seen := await _watch_birth(merged, 5)
	print("    ring merged from a peanut (fit %.2f): area %.0f%% .. %.0f%% of its birth area over 5 frames, fastest bead %.0f px/s"
		% [fit, 100.0 * seen[0], 100.0 * seen[1], seen[2]])
	assert_gt(seen[0], 0.7, "the merged ring keeps its area")
	assert_lt(seen[1], 1.3, "the merged ring does not blow up")
	assert_lt(seen[2], 1500.0, "the merged ring's beads stay calm")

func test_a_merge_waits_until_the_pair_is_compact() -> void:
	# The same peanut, merged by the world: it swaps the pair only once the
	# loop the merged ring would be placed on fits within MERGE_FIT, and the
	# ring is born calm.
	await get_tree().physics_frame
	var ra := 40.0
	var rb := 44.0
	var x := Arena.INNER_LEFT + 900.0
	var a := game.spawn(ra, Vector2(x, Arena.FLOOR_Y - ra))
	var b := game.spawn(rb, Vector2(x + 0.97 * (ra + rb), Arena.FLOOR_Y - rb))
	var fits: Array[float] = []
	var frame := 0
	while merges.is_empty() and frame < roundi(MERGE_TIMEOUT * Engine.physics_ticks_per_second):
		if _in_play(a) and _in_play(b) and a.merging:
			fits.append(GooWorld2D.merge_fit(a, b))
		await get_tree().physics_frame
		frame += 1
	assert_eq(merges.size(), 1, "the pair merges")
	if merges.size() != 1 or fits.is_empty():
		return
	var merged := game.bodies()[-1]
	var seen := await _watch_birth(merged, 5)
	print("    peanut merged after %d frames of transition, fit %.2f at the start and %.2f at the swap; area %.0f%% .. %.0f%%, fastest bead %.0f px/s"
		% [fits.size(), fits[0], fits[-1], 100.0 * seen[0], 100.0 * seen[1], seen[2]])
	assert_lt(fits[-1], GooWorld2D.MERGE_FIT, "swapped only once compact")
	assert_gt(seen[0], 0.7, "the merged ring keeps its area")
	assert_lt(seen[2], 1500.0, "the merged ring's beads stay calm")

func test_a_pair_that_never_gets_compact_is_let_go() -> void:
	# A transition started between two blobs far apart (judge_contact() judges
	# round pairs by size alone): the pull cannot bring them together within
	# MergeTransition.MAX_DURATION, so the merge is cancelled rather than forced
	# (which would build the merged ring around the lowest of them alone), and
	# neither may merge for MERGE_LOCK.
	await get_tree().physics_frame
	# High up and 1200 px apart: they fall freely for the whole transition.
	var a := game.spawn(30.0, Vector2(Arena.INNER_LEFT + 200.0, 250.0))
	var b := game.spawn(30.0, Vector2(Arena.INNER_RIGHT - 200.0, 250.0))
	game.judge_contact(b, a)
	var frames := 0
	while not a.merging and frames < 5:
		await get_tree().physics_frame
		frames += 1
	assert_true(a.merging and b.merging, "the transition starts")
	await wait_seconds(GooWorld2D.MergeTransition.MAX_DURATION + 0.1)
	assert_eq(merges.size(), 0, "a pair still apart is not merged")
	assert_eq(game.bodies().size(), 2)
	assert_false(a.merging or b.merging, "the transition was cancelled")
	assert_true(game.merge_locked(a) and game.merge_locked(b), "and the pair may not merge again straight away")
