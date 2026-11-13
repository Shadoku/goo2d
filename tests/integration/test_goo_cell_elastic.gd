extends TestCase
## Elastic bodies (GooCellWorld2D.elasticity, docs/cells.md "Elastic bodies") at the fluid
## game's sizes and unit (0.5: 7 px cells; a 37-cell blob, the 24 × 5 worm of 345 px, the
## 10 × 5 thruster ship of 152 px), the world's drag, in physics frames: a blob pressed into a
## wall and struck by a 28 px ring (the dent, the area, the time to round out), the worm and
## the ship struck amidships by the game's crate and run nose first into a rock's corner
## (the bend, the time to straighten), squeezing through gaps narrower than the body,
## swimming 10 s (speed, shape error after), the ship's thrusters carrying through a soft
## body, and a crash at 600 px/s each. Every case at elasticity 0 (as before) and the
## settings around the recommended one. Prints what it measures.

const R: float = 7.0
const LEVELS: Array[float] = [0.0, 0.5, 0.65, 0.8]

var walls: Array[Node] = []

func before_each() -> void:
	GooTuning.unit = 0.5

func after_each() -> void:
	GooTuning.unit = 1.0
	walls.clear()

func _world(e: float) -> GooCellWorld2D:
	var w := GooCellWorld2D.new()
	w.gravity_scale = 0.0
	w.draw_skins = false
	w.elasticity = e
	add_child(w)
	return w

func _frames(n: int) -> void:
	for _f: int in n:
		await get_tree().physics_frame

func _poly(points: PackedVector2Array) -> StaticBody2D:
	var body := StaticBody2D.new()
	body.collision_layer = GooTuning.LAYER_WALLS
	var poly := CollisionPolygon2D.new()
	poly.polygon = points
	body.add_child(poly)
	add_child(body)
	walls.append(body)
	return body

func _wall(rect: Rect2) -> StaticBody2D:
	return _poly(PackedVector2Array([rect.position, Vector2(rect.end.x, rect.position.y), rect.end, Vector2(rect.position.x, rect.end.y)]))

func _clear(nodes: Array) -> void:
	for n: Node in nodes:
		if is_instance_valid(n):
			n.queue_free()
	for w: Node in walls:
		w.queue_free()
	walls.clear()
	await _frames(2)

## The ship: a 10 × 5 hex worm whose rearmost cell of each row is a thruster facing forward
## (the game's thruster_ship(), without its side thrusters).
static func ship() -> GooCellDesign:
	var d := GooCellDesign.hex_worm(10, 5, R)
	var thruster := GooCellType.new()
	thruster.name = &"thruster"
	thruster.max_thrust = 9600.0
	d.types = [GooCellType.new(), thruster]
	var rear := {}
	for i: int in d.cell_count():
		var row := roundi(d.positions[i].y / R)
		if not rear.has(row) or d.positions[i].x < d.positions[rear[row]].x:
			rear[row] = i
	for row: int in rear:
		d.cell_types[rear[row]] = 1
	return d

## Where the design puts each cell (centred), from positions taken at spawn.
static func rest_of(cr: GooCellCreature) -> PackedVector2Array:
	var p := cr.positions()
	var c := Vector2.ZERO
	for q: Vector2 in p:
		c += q
	c /= p.size()
	var out := PackedVector2Array()
	for q: Vector2 in p:
		out.append(q - c)
	return out

## [the deepest cell behind its place in the rigid fit of the design along `dir` (px; 0
## for any direction: the largest distance), the RMS distance from it].
static func dent(cr: GooCellCreature, rest: PackedVector2Array, dir: Vector2 = Vector2.ZERO) -> Vector2:
	var p := cr.positions()
	if p.size() != rest.size():
		return Vector2(-1, -1)
	var c := Vector2.ZERO
	for q: Vector2 in p:
		c += q
	c /= p.size()
	var sc := 0.0
	var ss := 0.0
	for i: int in p.size():
		var q := p[i] - c
		sc += rest[i].dot(q)
		ss += rest[i].cross(q)
	var t := atan2(ss, sc)
	var deep := 0.0
	var rms := 0.0
	for i: int in p.size():
		var g := c + rest[i].rotated(t)
		deep = maxf(deep, (g - p[i]).dot(dir) if dir != Vector2.ZERO else (g - p[i]).length())
		rms += (g - p[i]).length_squared()
	return Vector2(deep, sqrt(rms / p.size()))

## The angle between the line through the front and middle thirds and the line through the
## middle and back thirds (by the design's x; rad, signed).
static func bend(cr: GooCellCreature, rest: PackedVector2Array) -> float:
	var p := cr.positions()
	var lo := INF
	var hi := -INF
	for q: Vector2 in rest:
		lo = minf(lo, q.x)
		hi = maxf(hi, q.x)
	var c: Array[Vector2] = [Vector2.ZERO, Vector2.ZERO, Vector2.ZERO]
	var m: Array[float] = [0.0, 0.0, 0.0]
	for i: int in p.size():
		var k := clampi(int(floor((rest[i].x - lo) / (hi - lo) * 3.0)), 0, 2)
		c[k] += p[i]
		m[k] += 1.0
	for k: int in 3:
		c[k] /= m[k]
	var a := c[1] - c[0]
	var b := c[2] - c[1]
	return atan2(a.cross(b), a.dot(b))

## The outline's area (cell centres).
static func area(cr: GooCellCreature) -> float:
	var p := cr.positions()
	var o := cr.outline()
	var s := 0.0
	for k: int in o.size():
		s += p[o[k]].cross(p[o[(k + 1) % o.size()]])
	return absf(0.5 * s)

static func health(w: GooCellWorld2D) -> PackedFloat32Array:
	return w.cells().health()

func test_a_blob_pressed_into_a_wall_dents_and_rounds_out() -> void:
	var rows: Array[String] = []
	var dents: Dictionary = {}
	for e: float in LEVELS:
		var w := _world(e)
		_wall(Rect2(900, 200, 200, 600))
		var cr := w.spawn(GooCellDesign.hex_blob(3, R), Transform2D(0.0, Vector2(840, 500)))
		var rest := rest_of(cr)
		var a0 := area(cr)
		var line := "elasticity %.2f:" % e
		var peak := 0.0
		for acc: float in [1000.0, 3000.0]:
			cr.push(Vector2(acc, 0))
			await _frames(120)
			var d := dent(cr, rest, Vector2.RIGHT)
			peak = d.x
			dents[[e, acc]] = d.x
			line += " %.0f px/s²: dent %.2f px, area %+.1f %%;" % [acc, d.x, (area(cr) / a0 - 1.0) * 100.0]
		cr.push(Vector2.ZERO)
		var back := INF
		for f: int in 180:
			await get_tree().physics_frame
			if back == INF and dent(cr, rest, Vector2.RIGHT).x <= maxf(0.05 * peak, 0.05):
				back = (f + 1) / 60.0
		var h := health(w)
		line += " round again (within 5 %% of the dent) %s; wall overlap %.2f px" % [("in %.2f s" % back) if back < INF else "not in 3 s", h[6]]
		rows.append(line)
		assert_lt(h[6], 1.0, "no cell in the wall at %.2f" % e)
		assert_lt(back, 3.0, "rounds out at %.2f" % e)
		await _clear([w])
	for r: String in rows:
		print("    " + r)
	assert_gt(dents[[0.65, 3000.0]], 8.0 * dents[[0.0, 3000.0]], "an elastic blob dents where a stiff one does not")

class NoMergeWorld extends GooWorld2D:
	func may_merge(_a: Goo2D, _b: Goo2D) -> bool:
		return false

func test_a_blob_struck_by_a_ring_dents_and_rounds_out() -> void:
	var rows: Array[String] = []
	var peaks: Dictionary = {}
	for e: float in LEVELS:
		var rings := NoMergeWorld.new()
		rings.gravity_scale = 0.0
		add_child(rings)
		var w := _world(e)
		w.couple(rings)
		var cr := w.spawn(GooCellDesign.hex_blob(3, R), Transform2D(0.0, Vector2(900, 500)))
		var rest := rest_of(cr)
		var a0 := area(cr)
		var ring := rings.spawn(28.0, Vector2(760, 500))
		await _frames(2)
		ring.set_velocity(Vector2(300, 0))
		var peak := 0.0
		var t_peak := 0.0
		var amin := 1.0
		var back := INF
		var inside := 0.0
		var fastest := 0.0
		for f: int in 240:
			await get_tree().physics_frame
			fastest = maxf(fastest, cr.velocity().length())
			var d := dent(cr, rest, Vector2.RIGHT * -1.0)
			var t := (f + 1) / 60.0
			if d.x > peak:
				peak = d.x
				t_peak = t
			amin = minf(amin, area(cr) / a0)
			inside = maxf(inside, health(w)[1])
			if peak > 0.2 and t > t_peak and back == INF and d.x <= 0.05 * peak:
				back = t - t_peak
		peaks[e] = peak
		rows.append("elasticity %.2f: the 28 px ring at 300 px/s dents the blob %.2f px (%.0f %% of a cell) at %.2f s, area at least %+.1f %%, round again (within 5 %% of the dent) %s after; the blob knocked to %.0f px/s" % [e, peak, peak / (2.0 * R) * 100.0, t_peak, (amin - 1.0) * 100.0, ("%.2f s" % back) if back < INF else "not in 4 s", fastest])
		assert_eq(inside, 0.0, "no cell centre inside another creature")
		await _clear([w, rings])
	for r: String in rows:
		print("    " + r)
	assert_gt(peaks[0.65], 2.0 * peaks[0.0], "the elastic blob dents more")

func _crate(at: Vector2, v: Vector2) -> RigidBody2D:
	var crate := RigidBody2D.new()
	crate.collision_layer = GooTuning.LAYER_WALLS
	crate.collision_mask = GooTuning.LAYER_WALLS
	crate.gravity_scale = 0.0
	crate.mass = 10.0
	crate.linear_damp_mode = RigidBody2D.DAMP_MODE_REPLACE
	crate.angular_damp_mode = RigidBody2D.DAMP_MODE_REPLACE
	crate.linear_damp = 1.5
	crate.angular_damp = 3.0
	crate.position = at
	crate.linear_velocity = v
	var shape := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = Vector2(60, 60)
	shape.shape = rect
	crate.add_child(shape)
	add_child(crate)
	return crate

## [the peak bend (rad), when, the time from the peak to under 5 % of it (INF: not in the
## time), the area's least share, the worst strain, the worst wall overlap]
func _watch_bend(w: GooCellWorld2D, cr: GooCellCreature, rest: PackedVector2Array, frames: int) -> Array:
	var a0 := area(cr)
	var peak := 0.0
	var t_peak := 0.0
	var back := INF
	var amin := 1.0
	var strain := 0.0
	var wall := 0.0
	for f: int in frames:
		await get_tree().physics_frame
		var t := (f + 1) / 60.0
		var b := absf(bend(cr, rest))
		if b > peak:
			peak = b
			t_peak = t
		amin = minf(amin, area(cr) / a0)
		var h := health(w)
		strain = maxf(strain, h[3])
		wall = maxf(wall, h[6])
		if peak > deg_to_rad(1.0) and t > t_peak and back == INF and b <= maxf(0.05 * peak, deg_to_rad(0.5)):
			back = t - t_peak
	return [peak, t_peak, back, amin, strain, wall]

func test_a_worm_and_the_ship_struck_amidships_by_a_crate_bend_and_straighten() -> void:
	var rows: Array[String] = []
	var bends: Dictionary = {}
	for name: String in ["worm 24 × 5", "ship 10 × 5"]:
		for e: float in LEVELS:
			var w := _world(e)
			w.push_bodies = true
			w.body_mass_scale = 1000.0
			var d := GooCellDesign.hex_worm(24, 5, R) if name.begins_with("worm") else ship()
			var cr := w.spawn(d, Transform2D(0.0, Vector2(900, 500)))
			var rest := rest_of(cr)
			var crate := _crate(Vector2(900, 380), Vector2(0, 300))
			var got := await _watch_bend(w, cr, rest, 240)
			bends[[name, e]] = got[0]
			rows.append("%s, elasticity %.2f: the crate at 300 px/s bends it %.1f° at %.2f s, straight again (5 %%) %s after; area at least %+.1f %%, strain at most %.3f" % [name, e, rad_to_deg(got[0]), got[1], ("%.2f s" % got[2]) if got[2] < INF else "not in 4 s", (got[3] - 1.0) * 100.0, got[4]])
			assert_lt(got[2], 4.0, "%s straightens at %.2f" % [name, e])
			await _clear([w, crate])
	for r: String in rows:
		print("    " + r)
	assert_gt(bends[["worm 24 × 5", 0.65]], 2.0 * bends[["worm 24 × 5", 0.0]], "the elastic worm bends more")

func test_a_worm_and_the_ship_run_nose_first_into_a_rock_corner() -> void:
	var rows: Array[String] = []
	var bends: Dictionary = {}
	for name: String in ["worm 24 × 5", "ship 10 × 5"]:
		for speed: float in [300.0, 600.0]:
			for e: float in LEVELS:
				var w := _world(e)
				var d := GooCellDesign.hex_worm(24, 5, R) if name.begins_with("worm") else ship()
				var cr := w.spawn(d, Transform2D(0.0, Vector2(700, 500)))
				var rest := rest_of(cr)
				# A rock's corner, its point 12 px off the creature's line, 40 px ahead of its nose.
				var nose := 700.0 + rest[0].x
				for q: Vector2 in rest:
					nose = maxf(nose, 700.0 + q.x)
				var tip := Vector2(nose + R + 40.0, 512.0)
				_poly(PackedVector2Array([tip, tip + Vector2(300, -260), tip + Vector2(300, 260)]))
				await _frames(2)
				cr.set_velocity(Vector2(speed, 0))
				var got := await _watch_bend(w, cr, rest, 180)
				bends[[name, speed, e]] = got[0]
				rows.append("%s at %.0f px/s, elasticity %.2f: bent %.1f° at %.2f s, straight again %s after; area at least %+.1f %%, strain at most %.3f, wall overlap at most %.2f px" % [name, speed, e, rad_to_deg(got[0]), got[1], ("%.2f s" % got[2]) if got[2] < INF else "not in 3 s", (got[3] - 1.0) * 100.0, got[4], got[5]])
				assert_lt(got[5], 2.0, "no cell deep in the rock")
				assert_true(is_finite(cr.center().x), "sound")
				await _clear([w])
	for r: String in rows:
		print("    " + r)
	assert_gt(bends[["worm 24 × 5", 300.0, 0.65]], bends[["worm 24 × 5", 300.0, 0.0]], "the elastic worm bends more")

## A creature pushed at `acc` toward a gap of `ratio` × its width between two walls: the
## time its every cell is through (INF: not in `seconds`), and its worst cells-inside.
func _gap(d: GooCellDesign, e: float, ratio: float, acc: float, seconds: float, thrust: bool = false) -> Vector2:
	var w := _world(e)
	var cr := w.spawn(d, Transform2D(0.0, Vector2(700, 500)))
	var p := cr.positions()
	var top := INF
	var bottom := -INF
	var right := -INF
	for q: Vector2 in p:
		top = minf(top, q.y - R)
		bottom = maxf(bottom, q.y + R)
		right = maxf(right, q.x + R)
	var width := bottom - top
	var g := width * ratio
	var x0 := right + 20.0
	_wall(Rect2(x0, 100, 30, 500 - 0.5 * g - 100))
	_wall(Rect2(x0, 500 + 0.5 * g, 30, 400))
	await _frames(1)
	if thrust:
		var levels := PackedFloat32Array()
		levels.resize(cr.cell_count())
		levels.fill(acc)
		cr.set_thrust_levels(levels)
	else:
		cr.push(Vector2(acc, 0))
	var through := INF
	var worst := 0.0
	for f: int in int(seconds * 60.0):
		await get_tree().physics_frame
		var all := true
		for q: Vector2 in cr.positions():
			if q.x < x0 + 30.0 + R:
				all = false
				break
		worst = maxf(worst, health(w)[6])
		if all:
			through = (f + 1) / 60.0
			break
	await _clear([w])
	return Vector2(through, worst)

func test_squeezing_through_a_gap_narrower_than_the_body() -> void:
	var rows: Array[String] = []
	var got: Dictionary = {}
	for e: float in [0.0, 0.65, 0.8, 1.0]:
		var line := "elasticity %.2f: 37-cell blob pushed at 1000 / 3000 px/s²:" % e
		for ratio: float in [1.0, 0.9, 0.8, 0.7, 0.6]:
			var a := await _gap(GooCellDesign.hex_blob(3, R), e, ratio, 1000.0, 4.0)
			var b := await _gap(GooCellDesign.hex_blob(3, R), e, ratio, 3000.0, 4.0)
			got[[e, ratio]] = minf(a.x, b.x)
			line += " %.1f: %s / %s;" % [ratio, ("%.2f s" % a.x) if a.x < INF else "stuck", ("%.2f s" % b.x) if b.x < INF else "stuck"]
			assert_lt(maxf(a.y, b.y), 2.0, "no cell deep in a wall")
		var s := await _gap(ship(), e, 0.8, 1.0, 4.0, true)
		line += " the ship at full thrust through 0.8: %s" % (("%.2f s" % s.x) if s.x < INF else "stuck")
		rows.append(line)
	for r: String in rows:
		print("    " + r)
	assert_true(got[[0.0, 1.0]] < INF, "a gap as wide as the body is passed")
	assert_true(got[[0.0, 0.8]] == INF, "a stiff blob jams at 0.8")
	assert_true(got[[0.8, 0.8]] < INF, "a soft blob squeezes through 0.8")

func test_swimming_holds_the_shape_and_the_speed() -> void:
	var rows: Array[String] = []
	var speed: Dictionary = {}
	for e: float in LEVELS:
		# The worm: a gentle stroke and the drive (docs/cells.md's minimal use).
		var w := _world(e)
		var d := GooCellDesign.hex_worm(24, 5, R)
		var cr := w.spawn(d, Transform2D(0.0, Vector2(300, 500)))
		var rest := rest_of(cr)
		cr.set_pose_wave(0.3, d.length(), 1.0)
		cr.set_swim(110.0, 0.3)
		await _frames(120)
		var x0 := cr.center().x
		var worst := 0.0
		for f: int in 480:
			await get_tree().physics_frame
			worst = maxf(worst, health(w)[3])
		var v := (cr.center().x - x0) / 8.0
		cr.stop_swim()
		cr.stop_wave()
		cr.set_damping(3.0, 3.0)
		await _frames(90)
		var after := dent(cr, rest)
		await _frames(150)
		var later := dent(cr, rest)
		speed[["worm", e]] = v
		rows.append("worm, elasticity %.2f: %.1f px/s (%.2f body lengths a second), strain at most %.3f; after it stops, %.2f px from its design at most (%.2f px RMS) at 1.5 s, %.2f px at 4 s" % [e, v, v / d.length(), worst, after.x, after.y, later.x])
		assert_lt(later.x, 0.5 * R, "the worm's design held at %.2f" % e)
		await _clear([w])
		# The ship on its rear thrusters at full level.
		var w2 := _world(e)
		var s := ship()
		var cs := w2.spawn(s, Transform2D(0.0, Vector2(300, 500)))
		var rest2 := rest_of(cs)
		var levels := PackedFloat32Array()
		levels.resize(cs.cell_count())
		levels.fill(1.0)
		cs.set_thrust_levels(levels)
		await _frames(120)
		var y0 := cs.center()
		var during := Vector2.ZERO
		for f: int in 120:
			await get_tree().physics_frame
			var dd := dent(cs, rest2)
			during = Vector2(maxf(during.x, dd.x), maxf(during.y, dd.y))
		var sv := (cs.center() - y0).length() / 2.0
		levels.fill(0.0)
		cs.set_thrust_levels(levels)
		cs.set_damping(3.0, 3.0)
		await _frames(90)
		var after2 := dent(cs, rest2)
		speed[["ship", e]] = sv
		rows.append("ship, elasticity %.2f: %.1f px/s on its rear thrusters (%.2f body lengths a second), %.2f px from its design at most while thrusting; 1.5 s after, %.2f px" % [e, sv, sv / s.length(), during.x, after2.x])
		assert_lt(after2.x, 0.5 * R, "the ship's design held at %.2f" % e)
		await _clear([w2])
	for r: String in rows:
		print("    " + r)
	for e: float in LEVELS:
		assert_gt(speed[["worm", e]], 0.75 * speed[["worm", 0.0]], "the worm swims within a quarter of its stiff speed at %.2f" % e)
		assert_gt(speed[["ship", e]], 0.9 * speed[["ship", 0.0]], "the thrusters carry the ship at %.2f" % e)

func test_a_crash_at_600_px_s_each_stays_sound() -> void:
	var rows: Array[String] = []
	for e: float in LEVELS:
		var w := _world(e)
		var a := w.spawn(GooCellDesign.hex_blob(3, R), Transform2D(0.0, Vector2(800, 500)))
		var b := w.spawn(GooCellDesign.hex_worm(24, 5, R), Transform2D(PI / 2.0, Vector2(1000, 500)))
		var rest := rest_of(a)
		var a0 := area(a)
		await _frames(1)
		a.set_velocity(Vector2(600, 0))
		b.set_velocity(Vector2(-600, 0))
		var deep := 0.0
		var amin := 1.0
		var worst := PackedFloat32Array([0, 0, 0, 0, 0, 0, 0, 0])
		for f: int in 120:
			await get_tree().physics_frame
			deep = maxf(deep, dent(a, rest).x)
			amin = minf(amin, area(a) / a0)
			var h := health(w)
			for k: int in 8:
				worst[k] = maxf(worst[k], h[k])
		var after := dent(a, rest)
		rows.append("elasticity %.2f: the blob dented %.1f px by the worm broadside (both at 600 px/s), area at least %+.1f %%, after 2 s %.2f px; worst overlap between creatures %.1f px, cells inside the other %d, own overlap %.1f px, strain %.3f, not finite %d" % [e, deep, (amin - 1.0) * 100.0, after.x, worst[0], int(worst[1]), worst[2], worst[3], int(worst[7])])
		assert_eq(worst[7], 0.0, "finite")
		assert_eq(worst[1], 0.0, "no cell inside the other creature")
		assert_lt(after.x, 0.5 * R, "rounds out")
		await _clear([w])
	for r: String in rows:
		print("    " + r)

## A blob whose front rim is spikes, thrown at 600 px/s at a resting 37-cell blob: whether an
## elastic body still carries the blow through its spikes (the closing speed of the first tip
## hit, the target's speed after it, the spiked blob's own dent behind its spikes).
func test_spike_hits_carry_through_an_elastic_body() -> void:
	var rows: Array[String] = []
	var knocked: Dictionary = {}
	for e: float in LEVELS:
		var w := _world(e)
		var spike := GooCellType.new()
		spike.tip_length = 2.0
		spike.tip_radius = 0.3
		var d := GooCellDesign.hex_blob(3, R)
		d.types = [GooCellType.new(), spike]
		d.angles.resize(d.cell_count())
		for i: int in d.cell_count():
			if d.positions[i].x > 2.5 * R and absf(d.positions[i].y) < 2.0 * R:
				d.cell_types[i] = 1
				d.angles[i] = 0.0
		var a := w.spawn(d, Transform2D(0.0, Vector2(700, 500)))
		var b := w.spawn(GooCellDesign.hex_blob(3, R), Transform2D(0.0, Vector2(930, 500)))
		var rest := rest_of(a)
		a.set_contact_tracking(true)
		await _frames(1)
		a.set_velocity(Vector2(600, 0))
		var hit := -1.0
		var fastest := 0.0
		var deep := 0.0
		for f: int in 60:
			await get_tree().physics_frame
			for c: Dictionary in a.contacts():
				if c["tip"] and hit < 0.0:
					hit = c["speed"]
			fastest = maxf(fastest, b.velocity().x)
			deep = maxf(deep, dent(a, rest).x)
		knocked[e] = fastest
		rows.append("elasticity %.2f: the spikes first hit at %.0f px/s closing, the target knocked to %.0f px/s, the spiked blob %.1f px off its design at most" % [e, hit, fastest, deep])
		assert_gt(hit, 0.0, "a tip made the hit")
		await _clear([w])
	for r: String in rows:
		print("    " + r)
	assert_gt(knocked[0.65], 0.7 * knocked[0.0], "an elastic spiked body carries most of the blow")
