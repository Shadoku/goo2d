extends SceneTree
## Golden trace: plays a fixed game headless and prints where every body ends
## up, so a refactoring can be checked for unchanged behaviour by diffing the
## output before and after (byte-identical output: same simulation).
##
##   godot --headless --fixed-fps 60 --path . -s tools/trace.gd > trace.txt
##
## Loads the main scene, gives Game a DropController with a fixed seed, launches
## LAUNCHES (physics frame, velocity) from the arena's launch point so blobs land
## on the wedge, hit both blades and merge, and after FRAMES physics frames prints
## one summary line (merge and split counts) and then one line per body of
## Game.bodies(): its radius and every bead position, rounded to 0.01 px.
## The goo's kernel is deterministic for a fixed build; frames are counted in
## _physics_process, so the schedule does not depend on the frame rate.

const MAIN_SCENE := "res://scenes/main.tscn"
## Seed of the DropController's RNG (the sizes and shapes of the drops).
const SEED := 20261014
## Physics frames to run before printing.
const FRAMES := 400
## Launches as Vector3(physics frame, velocity x, velocity y), px/s. The
## controller's 0.5 s cooldown needs 30+ frames between them.
const LAUNCHES: Array[Vector3] = [
	Vector3(5, -370.0, 0.0), # onto the wedge's apex: split
	Vector3(40, -1000.0, 0.0), # onto FloorBlade's tip: split
	Vector3(75, -1700.0, 0.0), # into WallBlade along the left wall: split
	Vector3(110, -500.0, 0.0), # these three pile up on the floor, where two merges happen
	Vector3(145, -500.0, 0.0),
	Vector3(180, -300.0, 0.0),
]

var _game: Game
var _frame: int = 0
var _merges: int = 0
var _splits: int = 0

func _initialize() -> void:
	var main := (load(MAIN_SCENE) as PackedScene).instantiate()
	root.add_child(main)
	_game = main.get_node("Game") as Game
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED
	_game.controller = DropController.new(0.5, rng)
	_game.merged.connect(func(_r: float, _p: Vector2) -> void: _merges += 1)
	_game.split.connect(func(_a: float, _b: float, _p: Vector2) -> void: _splits += 1)

func _physics_process(_delta: float) -> bool:
	_frame += 1
	for launch: Vector3 in LAUNCHES:
		if int(launch.x) == _frame and _game.launch(Vector2(launch.y, launch.z)) == null:
			push_error("trace: launch at frame %d refused (cooldown)" % _frame)
	if _frame == FRAMES:
		_print_bodies()
		quit(0)
	return false

func _print_bodies() -> void:
	var bodies := _game.bodies()
	print("trace: %d bodies, %d merges, %d splits" % [bodies.size(), _merges, _splits])
	for blob: Goo2D in bodies:
		var line := "%.2f" % blob.radius
		for point: Vector2 in blob.bead_points():
			line += " %.2f,%.2f" % [point.x, point.y]
		print(line)
