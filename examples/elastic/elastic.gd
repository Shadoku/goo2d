class_name ElasticExample
extends Node2D
## Elastic bodies and head-led turning (docs/cells.md, "Elastic bodies", "Head-led turning"),
## top-down, in four lanes of one world at elasticity 0.65:
## - a 37-cell blob (its own elasticity 0.8) thrown at the left wall again and again: it flattens where it hits and
##   rounds out;
## - a worm struck amidships by a small stiff blob: it bends round the blow and straightens;
## - two ships of 10 × 5 cells turning 180° back and forth by the spin servo, the one
##   head-led (set_turn_lead(1)) on the left, the other turned as a stick (lead 0);
## - a blob of jelly (its own elasticity 1) pushed through a gap 0.8 of its width, and
##   brought back each time it is through.
## At GooTuning.unit 1 with 14 px cells: the fluid game's creatures twice as large. R rebuilds.

## Cell radius (px).
const RADIUS: float = 14.0
## The world's elasticity, the thrown blob's own, the jelly's own (the hammer's is 0).
const ELASTICITY: float = 0.65
const SOFT: float = 0.8
const JELLY: float = 1.0
## Lane A: the blob's start, the speed it is thrown at the wall with, how often.
const BLOB_AT := Vector2(340.0, 300.0)
const BLOB_SPEED: float = 900.0
const BLOB_EVERY: float = 2.5
## Lane B: the worm, the hammer's start and speed, how often.
const WORM_AT := Vector2(1420.0, 400.0)
const HAMMER_AT := Vector2(1420.0, 150.0)
const HAMMER_SPEED: float = 600.0
const HAMMER_EVERY: float = 3.0
## Lane C: the two ships and how long each half turn is given (s); the servo at the fluid
## game's profile for a 280 px creature (its half turn 0.42 s).
const LED_AT := Vector2(270.0, 790.0)
const STICK_AT := Vector2(700.0, 790.0)
const TURN_EVERY: float = 1.6
const TURN_SPIN: float = 9.3
const TURN_ACCELERATION: float = 365.0
## Lane D: the jelly's start, the gap's walls (x, the gap 0.8 of its width), its push.
const JELLY_AT := Vector2(1150.0, 790.0)
const GAP_X: float = 1450.0
const GAP_RATIO: float = 0.8
const JELLY_PUSH: float = 2400.0

@onready var _world: GooCellWorld2D = $World

var plain: GooCellType
var hammer_type: GooCellType
var thruster_type: GooCellType
var blob: GooCellCreature = null
var worm: GooCellCreature = null
var hammer: GooCellCreature = null
var led: GooCellCreature = null
var stick: GooCellCreature = null
var jelly: GooCellCreature = null
var time: float = 0.0
## When each lane's last event began (s of `time`): what tools/elastic_shot.gd follows.
var blob_thrown: float = 0.0
var hammer_thrown: float = 0.0
var turn_began: float = 0.0
var jelly_began: float = 0.0
## The ships' heading goals (rad against their spawn) and the half turns made.
var goal: float = 0.0
var turns: int = 0
var _led_turn: Array[float] = [0.0, 0.0]
var _stick_turn: Array[float] = [0.0, 0.0]

func _ready() -> void:
	plain = GooCellType.new()
	plain.name = &"plain"
	hammer_type = GooCellType.new()
	hammer_type.name = &"hammer"
	hammer_type.color = Color(0.85, 0.82, 0.7)
	hammer_type.mass_factor = 6.0
	thruster_type = GooCellType.new()
	thruster_type.name = &"thruster"
	thruster_type.color = Color(0.98, 0.55, 0.25)
	_world.elasticity = ELASTICITY
	_gap_walls()
	build()

## The world the creatures live in.
func world() -> GooCellWorld2D:
	return _world

## The 10 × 5 ship: the fluid game's thruster ship's layout (its rearmost cells orange).
func ship_design() -> GooCellDesign:
	var d := GooCellDesign.hex_worm(10, 5, RADIUS)
	d.types = [plain, thruster_type]
	var rear := {}
	for i: int in d.cell_count():
		var row := roundi(d.positions[i].y / RADIUS)
		if not rear.has(row) or d.positions[i].x < d.positions[rear[row]].x:
			rear[row] = i
	for row: int in rear:
		d.cell_types[rear[row]] = 1
	return d

func _gap_walls() -> void:
	var width := GooCellDesign.hex_blob(2, RADIUS).bounds().size.y
	var gap := width * GAP_RATIO
	var y := JELLY_AT.y
	for r: Rect2 in [Rect2(GAP_X, 560.0, 40.0, y - 0.5 * gap - 560.0), Rect2(GAP_X, y + 0.5 * gap, 40.0, 1020.0 - y - 0.5 * gap)]:
		var body := StaticBody2D.new()
		body.collision_mask = 0
		var poly := CollisionPolygon2D.new()
		poly.polygon = PackedVector2Array([r.position, Vector2(r.end.x, r.position.y), r.end, Vector2(r.position.x, r.end.y)])
		body.add_child(poly)
		var look := Polygon2D.new()
		look.polygon = poly.polygon
		look.color = Color(0.2, 0.24, 0.3)
		body.add_child(look)
		$Walls.add_child(body)

func build() -> void:
	_world.clear()
	time = 0.0
	blob = _world.spawn(_typed(GooCellDesign.hex_blob(3, RADIUS), plain), Transform2D(0.0, BLOB_AT))
	blob.set_elasticity(SOFT)
	worm = _world.spawn(_typed(GooCellDesign.hex_worm(16, 5, RADIUS), plain), Transform2D(0.0, WORM_AT))
	_spawn_hammer()
	led = _world.spawn(ship_design(), Transform2D(0.0, LED_AT))
	stick = _world.spawn(ship_design(), Transform2D(0.0, STICK_AT))
	led.set_turn_lead(1.0)
	for s: GooCellCreature in [led, stick]:
		s.set_spin_servo(0.0, TURN_ACCELERATION)
		s.set_damping(3.0, 0.0)
	_led_turn = [led.turn(), 0.0]
	_stick_turn = [stick.turn(), 0.0]
	goal = 0.0
	turns = 0
	_spawn_jelly()
	blob_thrown = 0.5
	hammer_thrown = 0.8
	turn_began = 0.5
	jelly_began = 0.5
	_throw_blob()

static func _typed(d: GooCellDesign, t: GooCellType) -> GooCellDesign:
	d.types = [t]
	return d

func _spawn_hammer() -> void:
	if hammer != null and hammer.is_alive():
		_world.despawn(hammer)
	hammer = _world.spawn(_typed(GooCellDesign.hex_blob(1, RADIUS), hammer_type), Transform2D(0.0, HAMMER_AT))
	hammer.set_elasticity(0.0)

func _spawn_jelly() -> void:
	if jelly != null and jelly.is_alive():
		_world.despawn(jelly)
	jelly = _world.spawn(_typed(GooCellDesign.hex_blob(2, RADIUS), plain), Transform2D(0.0, JELLY_AT))
	jelly.set_elasticity(JELLY)

func _throw_blob() -> void:
	# Back where it began, still, then at the wall.
	blob.translate(BLOB_AT - blob.center())
	blob.set_velocity(Vector2(-BLOB_SPEED, 0.0))

## A heading kept continuous across the wrap: [the last turn read, the turn so far].
static func _follow(cr: GooCellCreature, state: Array[float]) -> float:
	state[1] += wrapf(cr.turn() - state[0], -PI, PI)
	state[0] = cr.turn()
	return state[1]

func _physics_process(delta: float) -> void:
	time += delta
	if blob.is_alive() and time - blob_thrown >= BLOB_EVERY:
		blob_thrown = time
		_throw_blob()
	if time - hammer_thrown >= HAMMER_EVERY:
		hammer_thrown = time
		_spawn_hammer()
		worm.translate(WORM_AT - worm.center())
		hammer.set_velocity(Vector2(0.0, HAMMER_SPEED))
	if time - turn_began >= TURN_EVERY:
		turn_began = time
		turns += 1
		goal = PI * turns
	for pair: Array in [[led, _led_turn], [stick, _stick_turn]]:
		var cr: GooCellCreature = pair[0]
		if cr.is_alive():
			var err := goal - _follow(cr, pair[1])
			cr.set_spin_target(GooCellCreature.spin_toward(err, TURN_SPIN, 0.8 * TURN_ACCELERATION, delta))
	if jelly.is_alive():
		jelly.push(Vector2(JELLY_PUSH, 0.0))
		if jelly.center().x > GAP_X + 230.0:
			jelly_began = time
			_spawn_jelly()

func _unhandled_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key != null and key.pressed and key.keycode == KEY_R:
		build()
