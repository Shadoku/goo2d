extends TestCase
## The cells' spin servo (GooCellCreature.set_spin_servo(), docs/cells.md "Turning by the
## spin servo") at the fluid game's sizes and unit (0.5: 14 px cells; a 24 × 5 worm and
## blobs of 7, 19 and 37 cells), the world's drag, in real physics frames: half turns in
## open water against the game's turn times (0.25 s for an 84 px creature to 1 s for a
## 690 px one), a worm spun into a wall (the head's speed off it at yields 1, 0.3, 0.1), turns
## begun with the tail against a wall and lying along one, and a worm turning into a crate
## (RigidBody2D, push_bodies, mass 10 × body_mass_scale 1000: the game's level) and into a
## coupled ring, tame against full power; the contact query on the way. Prints what it
## measures.

const R: float = 14.0
## The heading servo's braking, a share of the servo's acceleration (margin for the lag).
const BRAKE: float = 0.8
## The game's turn times by size (src/game_settings.gd: CELL_TURN_*).
const TIME_MIN: float = 0.25
const SIZE_MIN: float = 84.0
const TIME_MAX: float = 1.0
const SIZE_MAX: float = 690.0

var walls: Array[Node] = []

func before_each() -> void:
	GooTuning.unit = 0.5

func after_each() -> void:
	GooTuning.unit = 1.0
	walls.clear()

func _world() -> GooCellWorld2D:
	var w := GooCellWorld2D.new()
	w.gravity_scale = 0.0
	w.draw_skins = false
	add_child(w)
	return w

func _frames(n: int) -> void:
	for _f: int in n:
		await get_tree().physics_frame

func _wall(rect: Rect2) -> StaticBody2D:
	var body := StaticBody2D.new()
	body.collision_layer = GooTuning.LAYER_WALLS
	var poly := CollisionPolygon2D.new()
	poly.polygon = PackedVector2Array([rect.position, Vector2(rect.end.x, rect.position.y), rect.end, Vector2(rect.position.x, rect.end.y)])
	body.add_child(poly)
	add_child(body)
	walls.append(body)
	return body

func _clear(nodes: Array) -> void:
	for n: Node in nodes:
		n.queue_free()
	for w: Node in walls:
		w.queue_free()
	walls.clear()
	await _frames(2)

## The design's longest extent, edge to edge (the game's CellTurning.size_of()).
static func size_of(d: GooCellDesign) -> float:
	var best := 0.0
	for i: int in d.positions.size():
		for j: int in range(i, d.positions.size()):
			best = maxf(best, d.positions[i].distance_to(d.positions[j]) + d.radii[i] + d.radii[j])
	return best

## The game's half-turn time for a creature of `size` px.
static func turn_time(size: float) -> float:
	return lerpf(TIME_MIN, TIME_MAX, clampf((size - SIZE_MIN) / (SIZE_MAX - SIZE_MIN), 0.0, 1.0))

## [max spin, max acceleration] of a trapezoid half turn of `time` s: cruising at 1.5 π /
## time, braking at BRAKE of the acceleration.
static func turn_profile(time: float) -> Vector2:
	var spin := 1.5 * PI / time
	# time = π / spin + spin / 2 × (1 / a + 1 / (BRAKE a)).
	var a := spin * (1.0 + 1.0 / BRAKE) / (2.0 * (time - PI / spin))
	return Vector2(spin, a)

static func designs() -> Dictionary:
	return { "blob 7": GooCellDesign.hex_blob(1, R), "blob 19": GooCellDesign.hex_blob(2, R), "blob 37": GooCellDesign.hex_blob(3, R), "worm 24 × 5": GooCellDesign.hex_worm(24, 5, R) }

## The farthest cell's speed about the centre (px/s).
static func tip_speed(cr: GooCellCreature) -> float:
	var c := cr.center()
	var v := cr.velocity()
	var best := 0.0
	var vel := cr.velocities()
	var pos := cr.positions()
	var far := 0.0
	for i: int in pos.size():
		var d := pos[i].distance_to(c)
		if d > far:
			far = d
			best = (vel[i] - v).length()
	return best

## Steers `cr` toward heading turn `goal` (rad, against its spawn) with the servo's target,
## the braking curve of GooCellCreature.spin_toward().
static func steer(cr: GooCellCreature, goal: float, spin: float, acc: float) -> float:
	var err := wrapf(goal - cr.turn(), -PI, PI)
	cr.set_spin_target(GooCellCreature.spin_toward(err, spin, BRAKE * acc, 1.0 / 60.0))
	return err

## A half turn from rest: [time to within 3° of it (s; INF: not within 4 s), overshoot past
## it (rad), the peak spin, the peak tip speed, the error after 1 s more].
func _half_turn(cr: GooCellCreature, spin: float, acc: float, tip: float = INF, y: float = 1.0) -> Array:
	# Just short of π, so wrapf() never reads it as the other way round: clockwise.
	var goal := cr.turn() + PI - 0.001
	cr.set_spin_servo(0.0, acc, tip, y)
	var reached := INF
	var over := 0.0
	var peak := 0.0
	var tip_peak := 0.0
	var t := 0.0
	var after := 0.0
	for f: int in 300:
		var err := steer(cr, goal, spin, acc)
		await get_tree().physics_frame
		t += 1.0 / 60.0
		err = wrapf(goal - cr.turn(), -PI, PI)
		peak = maxf(peak, absf(cr.spin()))
		tip_peak = maxf(tip_peak, tip_speed(cr))
		if reached == INF and absf(err) < deg_to_rad(3.0):
			reached = t
		if reached < INF:
			over = maxf(over, -err)
			if t <= reached + 1.0:
				after = err
	cr.stop_spin_servo()
	return [reached, over, peak, tip_peak, after]

func test_half_turns_in_open_water_meet_the_game_s_times() -> void:
	var rows: Array[String] = []
	for name: String in designs():
		var d: GooCellDesign = designs()[name]
		var size := size_of(d)
		var time := turn_time(size)
		var prof := turn_profile(time)
		var w := _world()
		var cr := w.spawn(d, Transform2D(0.0, Vector2(800, 500)))
		await _frames(5)
		var got := await _half_turn(cr, prof.x, prof.y)
		# Faster: the acceleration doubled.
		w.queue_free()
		var w2 := _world()
		var cr2 := w2.spawn(d, Transform2D(0.0, Vector2(800, 500)))
		await _frames(5)
		var fast := await _half_turn(cr2, 2.0 * prof.x, 3.0 * prof.y)
		w2.queue_free()
		rows.append("%s: %d px, the game's %.2f s; servo %.1f rad/s, %.0f rad/s²: %.3f s, overshoot %.1f°, peak spin %.2f rad/s, tip %.0f px/s, 1 s later %.2f°; ×2 spin, ×3 acceleration: %.3f s, overshoot %.1f°, tip %.0f px/s" % [name, size, time, prof.x, prof.y, got[0], rad_to_deg(got[1]), got[2], got[3], rad_to_deg(got[4]), fast[0], rad_to_deg(fast[1]), fast[3]])
		await _frames(2)
		assert_lt(got[0], 1.3 * time, "%s within 30%% of the game's time" % name)
		assert_lt(got[1], deg_to_rad(10.0), "%s overshoot under 10°" % name)
		assert_lt(absf(got[4]), deg_to_rad(5.0), "%s holds the heading" % name)
	for r: String in rows:
		print("    " + r)

## The worm's turn profile (the game's 1 s half turn).
static func worm_profile() -> Vector2:
	return turn_profile(turn_time(size_of(GooCellDesign.hex_worm(24, 5, R))))

## The uid of `cr`'s cell farthest along +x (its head as spawned facing +x).
static func head_uid(cr: GooCellCreature) -> int:
	var pos := cr.positions()
	var best := 0
	for i: int in pos.size():
		if pos[i].x > pos[best].x:
			best = i
	return cr.uids()[best]

## A worm at (900, 500) facing +x half-turned clockwise for `seconds` with the servo at the
## game's 1 s profile, `tip` and `y`, among `walls` (rects): [the turn made (rad), the time
## it reached within 3° of the half turn (INF: never), the speed of the first cell to touch a
## wall the frame before it does, that cell's fastest speed away from the wall within 0.25 s after, the
## things its contacts named (thing -> kind), the centre's fastest speed away from the wall
## within 1 s after (the creature flung off it)].
func _worm_turn(rects: Array, tip: float, y: float, seconds: float = 3.0) -> Array:
	var bodies: Array[StaticBody2D] = []
	for r: Rect2 in rects:
		bodies.append(_wall(r))
	var w := _world()
	var cr := w.spawn(GooCellDesign.hex_worm(24, 5, R), Transform2D(0.0, Vector2(900, 500)))
	await _frames(3)
	var head := head_uid(cr)
	var prof := worm_profile()
	var start := cr.turn()
	var goal := start + PI - 0.001
	cr.set_spin_servo(0.0, prof.y, tip, y)
	var reached := INF
	var hit_speed := -1.0
	var hit_at := -1.0
	var hit_normal := Vector2.ZERO
	var away := 0.0
	var flung := 0.0
	var before := PackedVector2Array()
	var t := 0.0
	var turned := 0.0
	var last := start
	var seen: Dictionary = {}
	for f: int in int(seconds * 60.0):
		steer(cr, goal, prof.x, prof.y)
		await get_tree().physics_frame
		t += 1.0 / 60.0
		turned += wrapf(cr.turn() - last, -PI, PI)
		last = cr.turn()
		if reached == INF and absf(PI - turned) < deg_to_rad(3.0):
			reached = t
		var vel := cr.velocities()
		for c: Dictionary in cr.contacts():
			seen[c["what"]] = c["kind"]
			if c["kind"] == GooCellCreature.Touch.WALL and hit_at < 0.0:
				hit_at = t
				head = int(c["uid"])
				# Its speed in the frame before (this frame's contact has stopped it).
				var ci := int(c["cell"])
				hit_speed = (before[ci] if ci < before.size() else vel[ci]).length()
				hit_normal = c["normal"]
		if hit_at >= 0.0 and t <= hit_at + 1.0:
			var hi := cr.cell_index(head)
			if hi >= 0 and t <= hit_at + 0.25:
				away = maxf(away, vel[hi].dot(hit_normal))
			flung = maxf(flung, cr.velocity().dot(hit_normal))
		before = vel
	w.queue_free()
	for b: Node in bodies:
		b.queue_free()
	walls.clear()
	await _frames(2)
	return [turned, reached, hit_speed, away, seen, flung]

func test_a_worm_spun_into_a_floor_leans_on_it_when_tame() -> void:
	# The floor 160 px below the worm's line: its head swings into it a third of the way
	# round, at the game's 1 s half turn (4.7 rad/s, the head near 1500 px/s).
	var floor := Rect2(0, 660, 1920, 200)
	var rows: Array[String] = []
	var flung: Dictionary = {}
	for setting: Vector2 in [Vector2(1.0, INF), Vector2(0.3, INF), Vector2(0.1, INF), Vector2(0.1, 600.0), Vector2(0.1, 300.0)]:
		var got := await _worm_turn([floor], setting.y, setting.x, 2.5)
		flung[setting] = got[5]
		rows.append("yield %.1f, tip %s px/s: the first cell hits at %.0f px/s, off the floor at up to %.0f px/s within 0.25 s; the worm flung off at up to %.0f px/s; the half turn %s" % [setting.x, "INF" if setting.y == INF else "%.0f" % setting.y, got[2], got[3], got[5], ("in %.2f s" % got[1]) if got[1] < INF else "not made (%.0f°)" % rad_to_deg(got[0])])
		var kinds: Dictionary = got[4]
		assert_true(kinds.values().has(GooCellCreature.Touch.WALL), "the wall is reported")
		assert_true(kinds.has(null) == false, "the wall resolves to its node")
	for r: String in rows:
		print("    " + r)
	assert_lt(flung[Vector2(0.1, INF)], flung[Vector2(1.0, INF)], "tame is flung off less than full power")
	assert_lt(flung[Vector2(0.1, 300.0)], 0.5 * flung[Vector2(1.0, INF)], "a tip cap tames it most")

func test_turns_begun_against_a_wall_complete() -> void:
	var rows: Array[String] = []
	var open := await _worm_turn([], INF, 1.0)
	rows.append("open water: a half turn in %.2f s" % open[1])
	# Its tail end on a wall behind it (the worm's left end, x ≈ 900 − 345).
	var behind := Rect2(900 - 345 - 1 - 200, 200, 200, 600)
	# Lying on a floor (its lower side 62 px below its line): turning clockwise drives its
	# right half into the floor.
	var under := Rect2(0, 500 + 64, 1920, 200)
	for y: float in [1.0, 0.3, 0.1]:
		var tail := await _worm_turn([behind], INF, y)
		var lying := await _worm_turn([under], INF, y)
		rows.append("yield %.1f: tail against a wall %s, lying along a floor %s (turned %.0f° in 3 s)" % [y, ("%.2f s" % tail[1]) if tail[1] < INF else "never", ("%.2f s" % lying[1]) if lying[1] < INF else "never", rad_to_deg(lying[0])])
		assert_lt(tail[1], 2.0 * open[1], "tail against a wall: completes within twice the open-water time at yield %.1f" % y)
	for r: String in rows:
		print("    " + r)

## Rings that never merge (the ring world beside the cells).
class NoMergeWorld extends GooWorld2D:
	func may_merge(_a: Goo2D, _b: Goo2D) -> bool:
		return false

## Where the worm's turn sweeps: 250 px from its centre, 50° clockwise of its heading.
const TARGET_AT := Vector2(1060.7, 691.5)

## The worm half-turning clockwise (the game's 1 s profile, `tip`, `y`) into `thing` (a
## crate or a ring, whose velocity `speed_of` reads) for 2.5 s: [its fastest speed, its speed
## 1 s after the first contact, the worm's contacts with it (a kind seen, its node)].
func _turn_into(w: GooCellWorld2D, speed_of: Callable, tip: float, y: float) -> Array:
	var cr := w.spawn(GooCellDesign.hex_worm(24, 5, R), Transform2D(0.0, Vector2(900, 500)))
	await _frames(3)
	var prof := worm_profile()
	var goal := cr.turn() + PI - 0.001
	cr.set_spin_servo(0.0, prof.y, tip, y)
	var fastest := 0.0
	var first := -1.0
	var later := -1.0
	var t := 0.0
	var kind := -1
	var what: Object = null
	for f: int in 150:
		steer(cr, goal, prof.x, prof.y)
		await get_tree().physics_frame
		t += 1.0 / 60.0
		var v: float = speed_of.call()
		fastest = maxf(fastest, v)
		for c: Dictionary in cr.contacts():
			if c["kind"] != GooCellCreature.Touch.CREATURE:
				kind = c["kind"]
				what = c["what"]
				if first < 0.0:
					first = t
		if first >= 0.0 and later < 0.0 and t >= first + 1.0:
			later = v
	return [fastest, later, kind, what]

const SETTINGS := [Vector2(1.0, INF), Vector2(0.3, INF), Vector2(0.1, INF), Vector2(0.1, 600.0), Vector2(0.1, 300.0)]

static func _setting_name(s: Vector2) -> String:
	return "yield %.1f, tip %s" % [s.x, "INF" if s.y == INF else "%.0f px/s" % s.y]

func test_a_worm_turning_into_a_crate_tame_and_at_full_power() -> void:
	var rows: Array[String] = []
	var fastest: Dictionary = {}
	for setting: Vector2 in SETTINGS:
		var w := _world()
		w.push_bodies = true
		w.body_mass_scale = 1000.0
		# The game's crate: 60 px, mass 10 (10 000 in the cells' units), damped 1.5 / 3.
		var crate := RigidBody2D.new()
		crate.collision_layer = GooTuning.LAYER_WALLS
		crate.collision_mask = GooTuning.LAYER_WALLS
		crate.gravity_scale = 0.0
		crate.mass = 10.0
		crate.linear_damp_mode = RigidBody2D.DAMP_MODE_REPLACE
		crate.angular_damp_mode = RigidBody2D.DAMP_MODE_REPLACE
		crate.linear_damp = 1.5
		crate.angular_damp = 3.0
		crate.position = TARGET_AT
		var shape := CollisionShape2D.new()
		var rect := RectangleShape2D.new()
		rect.size = Vector2(60, 60)
		shape.shape = rect
		crate.add_child(shape)
		add_child(crate)
		var got := await _turn_into(w, func() -> float: return crate.linear_velocity.length(), setting.y, setting.x)
		fastest[setting] = got[0]
		rows.append("%s: the crate at up to %.0f px/s, %.0f px/s 1 s after the first contact" % [_setting_name(setting), got[0], got[1]])
		assert_eq(got[2], GooCellCreature.Touch.OBSTACLE, "the crate is reported as a moving obstacle")
		assert_eq(got[3], crate, "and resolves to the crate")
		await _clear([w, crate])
	for r: String in rows:
		print("    " + r)
	assert_lt(fastest[Vector2(0.1, INF)], fastest[Vector2(1.0, INF)], "tame bats the crate less than full power")

func test_a_worm_turning_into_a_coupled_ring_tame_and_at_full_power() -> void:
	var rows: Array[String] = []
	var fastest: Dictionary = {}
	for setting: Vector2 in SETTINGS:
		var rings := NoMergeWorld.new()
		rings.gravity_scale = 0.0
		add_child(rings)
		var w := _world()
		w.couple(rings)
		var ring := rings.spawn(28.0, TARGET_AT)
		var got := await _turn_into(w, func() -> float: return ring.average_velocity().length() if is_instance_valid(ring) else 0.0, setting.y, setting.x)
		fastest[setting] = got[0]
		rows.append("%s: the 28 px ring at up to %.0f px/s, %.0f px/s 1 s after the first contact" % [_setting_name(setting), got[0], got[1]])
		assert_eq(got[2], GooCellCreature.Touch.RING, "the ring is reported")
		assert_eq(got[3], ring, "and resolves to its Goo2D")
		await _clear([w, rings])
	for r: String in rows:
		print("    " + r)
	assert_lt(fastest[Vector2(0.1, INF)], fastest[Vector2(1.0, INF)], "tame bats the ring less than full power")

func test_the_contact_query() -> void:
	var floor := _wall(Rect2(0, 600, 1920, 100))
	var w := _world()
	w.gravity_scale = 1.0
	var a := w.spawn(GooCellDesign.hex_blob(2, R), Transform2D(0.0, Vector2(700, 520)))
	var b := w.spawn(GooCellDesign.hex_blob(2, R), Transform2D(0.0, Vector2(860, 520)))
	b.push(Vector2(-600, 0))
	await _frames(2)
	assert_false(a.contact_tracking(), "off by default")
	assert_eq(a.contacts().size(), 0, "nothing recorded while off")
	assert_true(a.contact_tracking(), "contacts() turned it on")
	await _frames(90)
	var got := a.contacts()
	var kinds := {}
	for c: Dictionary in got:
		kinds[c["kind"]] = kinds.get(c["kind"], 0) + 1
		if c["kind"] == GooCellCreature.Touch.WALL:
			assert_eq(c["what"], floor, "the wall resolves to its StaticBody2D")
			assert_lt(c["normal"].y, -0.9, "pushed up off the floor")
		elif c["kind"] == GooCellCreature.Touch.CREATURE:
			assert_eq(c["what"], b, "the other creature resolves to its handle")
			assert_lt(c["normal"].x, 0.0, "pushed away from it")
		assert_eq(a.uids()[c["cell"]], c["uid"])
	var counts := a.contact_counts()
	print("    a blob on a floor pressed by another: %d contacts, counts by kind %s; b (not tracked) %s" % [got.size(), counts, b.contact_counts()])
	assert_eq(counts[GooCellCreature.Touch.WALL], kinds.get(GooCellCreature.Touch.WALL, 0))
	assert_gt(counts[GooCellCreature.Touch.CREATURE], 0)
	assert_true(a.touching_walls())
	assert_true(a.touching(GooCellCreature.Touch.CREATURE))
	assert_false(a.touching(GooCellCreature.Touch.RING))
	assert_eq(b.contact_counts(), PackedInt32Array([0, 0, 0, 0]), "an untracked creature records nothing")
	a.set_contact_tracking(false)
	await _frames(1)
	assert_eq(a.contact_counts(), PackedInt32Array([0, 0, 0, 0]), "off again: nothing")
	await _clear([w])
