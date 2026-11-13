class_name GooCellCreature
extends RefCounted
## A creature of a GooCellWorld2D (docs/cells.md): a light handle a game holds. Creatures
## are not nodes: their cells live in the world's GooCells. A handle stays valid while its
## creature lives (is_alive()): a creature merged into another at a retopology, or
## despawned, is gone (GooCellWorld2D.creatures_merged / creature_despawned), and a part
## that split off is a new creature (GooCellWorld2D.creature_split). Cells are named by uid
## (stable for a cell's life; cell indices change at every topology change):
## cell_index(uid) finds one's index now.
##
## Angles and directions are on screen (y down): a positive turn is clockwise.

## The world it lives in.
var world: GooCellWorld2D
## Its slot in the world's GooCells.
var id: int = -1
## The design it was spawned from (a split's part keeps its parent's).
var design: GooCellDesign
## Its head direction in the kernel's design frame (the world's frame at its spawn: the
## design's forward turned by the spawn's rotation); heading() turns it with the creature.
var axis: Vector2 = Vector2.RIGHT
## What a game keeps on it.
var data: Dictionary = {}

## The metadata name under which a creature's proxy node holds its handle.
const PROXY_META: StringName = &"goo_creature"

## What a cell touched (contacts()): a wall (a static shape), a moving obstacle (an
## AnimatableBody2D, CharacterBody2D or RigidBody2D the world's push_bodies mirrors), a ring
## of the coupled GooWorld2D, another creature.
enum Touch { WALL, OBSTACLE, RING, CREATURE }

var _proxy: Node2D = null

func _init(owner: GooCellWorld2D, slot: int, from: GooCellDesign, design_axis: Vector2) -> void:
	world = owner
	id = slot
	design = from
	axis = design_axis.normalized() if design_axis != Vector2.ZERO else Vector2.RIGHT

## The node that stands for it in Godot's physics while its world has physics_proxies
## on (docs/godot-physics.md): an internal Node2D child of the world kept at its centre, its
## proxy body's object, so Area2D.body_entered and a query's collider name it;
## GooCellWorld2D.creature_of() maps it back. Made on first use.
func proxy_node() -> Node2D:
	if _proxy == null or not is_instance_valid(_proxy):
		_proxy = Node2D.new()
		_proxy.name = "Proxy%d" % id
		_proxy.set_meta(PROXY_META, self)
		world.add_child(_proxy, false, Node.INTERNAL_MODE_BACK)
	return _proxy

## Frees its proxy node (the world despawned it).
func free_proxy_node() -> void:
	if _proxy != null and is_instance_valid(_proxy):
		_proxy.queue_free()
	_proxy = null

## Whether it still lives in its world.
func is_alive() -> bool:
	return world != null and is_instance_valid(world) and id >= 0 and world.cells().alive(id)

func _c() -> GooCells:
	return world.cells()

## Its centre of mass (global).
func center() -> Vector2:
	return _c().creature_center(id)

## Its mean velocity (px/s).
func velocity() -> Vector2:
	return _c().creature_velocity(id)

## How far it has turned since its spawn (rad, the cells' best fit against its design).
func turn() -> float:
	return _c().creature_turn(id)

## Its head direction now (unit).
func heading() -> Vector2:
	return axis.rotated(turn())

## Its spin about its centre (rad/s, from the cells' orbits).
func spin() -> float:
	return _c().creature_spin(id)

func mass() -> float:
	return _c().creature_mass(id)

func cell_count() -> int:
	return _c().cell_count(id)

## Every cell's centre (global), by index.
func positions() -> PackedVector2Array:
	return _c().centers(id)

func velocities() -> PackedVector2Array:
	return _c().velocities(id)

## Every cell's radius now (muscles and a new cell's ease included).
func radii() -> PackedFloat32Array:
	return _c().radii(id)

## Every cell's uid, by index.
func uids() -> PackedInt32Array:
	return _c().uids(id)

## Every cell's kernel type slot (world.type_of_slot() maps it to its GooCellType).
func type_slots() -> PackedInt32Array:
	return _c().types(id)

## The outline: cell indices around it.
func outline() -> PackedInt32Array:
	return _c().outline(id)

## The index of the cell of `uid` now (-1: not in this creature).
func cell_index(uid: int) -> int:
	var u := uids()
	for i: int in u.size():
		if u[i] == uid:
			return i
	return -1

func cell_position(index: int) -> Vector2:
	return positions()[index]

## Cell `index`'s heading (rad): its own frame's angle plus its design angle.
func cell_angle(index: int) -> float:
	return _c().angles(id)[index] + _c().thrust_angles(id)[index]

func cell_type(index: int) -> GooCellType:
	return world.type_of_slot(type_slots()[index])

## Whether cell `index` is on the outline.
func is_boundary(index: int) -> bool:
	return _c().boundary(id)[index] != 0

## The index of its cell nearest `point` within `reach` px of its disc (-1: none).
func cell_at(point: Vector2, reach: float = 0.0) -> int:
	return _c().cell_at(id, point, reach)

## A uniform acceleration (px/s²) of every cell, kept until set again.
func push(acceleration: Vector2) -> void:
	_c().push_creature(id, acceleration)

## An angular acceleration (rad/s², clockwise positive) about its centre, kept until set
## again: forces of a rigid turn, no net force.
func twist(angular_acceleration: float) -> void:
	_c().twist(id, angular_acceleration)

## The swim drive, kept until set again (or stop_swim()): every cell pushed along its own
## forward (the creature's forward turned by the cell's angle now), so the push follows the
## body's curve and a bent body steers itself. The forces' magnitudes sum to
## `acceleration` (px/s²; negative swims backward) × mass(), shared by each cell's mass ×
## its type's swim_weight, and ripple head to tail by ± `pulse` (0..1) in step with the
## pose wave's phase at each cell (steady without a pose wave). docs/cells.md, "Swimming".
func set_swim(acceleration: float, pulse: float = 0.3) -> void:
	_c().set_swim(id, acceleration, pulse, axis)

## Stops the swim drive.
func stop_swim() -> void:
	_c().set_swim(id, 0.0, 0.0, axis)

## push() for the next step only, on top of the kept push (calls before a step add up).
func push_once(acceleration: Vector2) -> void:
	_c().push_once(id, acceleration)

## twist() for the next step only, on top of the kept twist (calls before a step add up).
func twist_once(angular_acceleration: float) -> void:
	_c().twist_once(id, angular_acceleration)

## A force on each cell (by index; fewer: the rest none) for the next step only, on top of
## set_cell_force()'s (calls before a step add up). Counts as outside the creature for the
## break test.
func add_cell_forces_once(forces: PackedVector2Array) -> void:
	_c().add_cell_forces_once(id, forces)

## Damping of its mean velocity (`linear`) and of its rigid spin about its centre
## (`angular`), both 1/s and relative to the water at its cells, kept until set again:
## each decays by exp(−rate × time), exactly (no overshoot at any rate); its cells' motion
## relative to that (the stroke) is left alone. A brake against the glide when a swimmer
## lets go (2-3 /s stops a fast worm within about 1.5 s); 0, the default, none. It damps
## its own swimming too while set.
func set_damping(linear: float, angular: float) -> void:
	_c().set_damping(id, linear, angular)

## Cell `index` pushes `force` along its heading (cell_angle()), kept until set again.
func set_cell_thrust(index: int, force: float) -> void:
	_c().set_thrust_one(id, index, force)

## A force on cell `index`, kept until set again. Counts as outside the creature for the
## break test (as a crash does).
func set_cell_force(index: int, force: Vector2) -> void:
	_c().set_cell_force(id, index, force)

## Radius muscles: each cell's radius × its scale (1 at rest), kept until set again; the
## links' rest lengths follow.
func set_muscles(scales: PackedFloat32Array) -> void:
	_c().set_cell_scales(id, scales)

## The pose wave (the swimmer's muscle): the design bent along a curvature wave running
## from head to tail. `slope` the wave's slope (amplitude × wavenumber; 1 is a strong
## stroke), `wavelength` px (a body length swims well), `frequency` Hz, `bias` a constant
## curvature (1/px; positive turns it clockwise), `envelope` how much the amplitude grows
## from head to tail (0..1). Set it every frame to steer; the phase carries on.
func set_pose_wave(slope: float, wavelength: float, frequency: float, bias: float = 0.0, envelope: float = 0.6) -> void:
	_c().set_wave(id, GooCells.WAVE_POSE, slope, wavelength, frequency, axis, 0.0, bias, envelope)

## Stops any wave; the design's pose comes back.
func stop_wave() -> void:
	_c().set_wave(id, GooCells.WAVE_OFF, 0.0, 1.0, 0.0, axis, 0.0, 0.0, 0.0)

## Bends the joint between the region of `type_a` / `group_a` and that of `type_b` /
## `group_b` by `angle` (rad: the second turned clockwise against the first about the
## joint), kept until set again; 0 straightens it.
func set_joint_angle(type_a: GooCellType, group_a: int, type_b: GooCellType, group_b: int, angle: float) -> void:
	_c().set_joint_angle(id, world.region_key(type_a, group_a), world.region_key(type_b, group_b), angle)

## The water's velocity at its cells: empty (its current, else the world's), one value for
## all, or one per cell (by index). GooCellWorld2D.water_source does this for every
## creature each frame.
func set_water(water: PackedVector2Array) -> void:
	_c().set_water(id, water)

## A current for this creature alone.
func set_current(current: Vector2) -> void:
	_c().set_creature_current(id, current, true)

func translate(by: Vector2) -> void:
	_c().translate(id, by)

## Every cell's velocity set to `velocity`, spins stopped.
func set_velocity(velocity: Vector2) -> void:
	_c().set_velocity(id, velocity)

## Adds a cell at `at` (global) linked to the cells it would touch at full size; it grows
## in over half a second. Returns its uid.
func add_cell(at: Vector2, radius: float, type: GooCellType = null, group: int = 0) -> int:
	return world.add_cell(self, at, radius, type, group)

## Removes the cell of `uid` (its links' cells_parted; a creature that falls apart splits).
func remove_cell(uid: int) -> void:
	world.remove_cell(self, uid)

# ---- The spin servo (docs/cells.md, "Turning by the spin servo") ----

## Turns the creature by the solver's spin servo, kept until stopped: every substep its
## spin about its centre (spin(), rad/s, clockwise positive; the world's frame) is driven
## toward `target_spin` by a rigid turn of its cells about the centre of mass (no net
## force), changing at most `max_angular_acceleration` rad/s². `max_tip_speed` (px/s; INF
## none) caps the target so its farthest cell's centre moves at most that fast about the
## centre. `contact_yield` (0..1; 1 none): while one of its cells touches a wall, a moving
## obstacle, a ring or another creature and the commanded turn would move that cell into
## it, the servo holds only a share of its target and drives toward it with that share of
## its acceleration (a faster spin braked at the full acceleration): the share falls toward
## `contact_yield` by how squarely the turn meets the contact, at once, and comes back over
## 0.1 s once it is gone. So a turning creature slows and leans on what it meets instead of
## batting it away. A target of 0 stops the spin and holds it. Its angular damping
## (set_damping()) is not applied while the servo is on. Tame: a yield of 0.1-0.3 and a
## tip speed the game can live with; full power: yield 1, no tip cap.
func set_spin_servo(target_spin: float, max_angular_acceleration: float, max_tip_speed: float = INF, contact_yield: float = 1.0) -> void:
	_c().set_spin_servo(id, target_spin, max_angular_acceleration, max_tip_speed, contact_yield)

## The spin servo's target alone (rad/s), cheap enough every frame; nothing while it is off.
func set_spin_target(target_spin: float) -> void:
	_c().set_spin_target(id, target_spin)

## Stops the spin servo (the creature keeps the spin it has).
func stop_spin_servo() -> void:
	_c().stop_spin_servo(id)

## The spin servo as its last substep left it: on, target, max_acceleration, max_tip_speed,
## contact_yield, spin (measured), capped (the target after the tip cap), scale (what the
## yield left of its change: 1 none), hold (the contact share it yields to, 0..1).
func spin_servo() -> Dictionary:
	var s := _c().spin_servo_state(id)
	return { "on": s[0] != 0.0, "target": s[1], "max_acceleration": s[2], "max_tip_speed": s[3], "contact_yield": s[4], "spin": s[5], "capped": s[6], "scale": s[7], "hold": s[8] }

## The spin that turns through `angle_error` (rad, clockwise positive) fastest without
## overshoot at `max_angular_acceleration`: sign × min(max_spin, sqrt(2 a |error|)), the
## braking curve of a bang-bang turn, and with `delta` (the frame, s) at most |error| /
## delta, so a target set once a frame never carries the turn past the heading within the
## frame. Feed it to set_spin_target() every frame with the heading error for a heading
## servo; brake at a little under the servo's acceleration (0.8 of it: docs/cells.md has
## the numbers it reaches).
static func spin_toward(angle_error: float, max_spin: float, max_angular_acceleration: float, delta: float = 0.0) -> float:
	var s := minf(max_spin, sqrt(2.0 * maxf(max_angular_acceleration, 0.0) * absf(angle_error)))
	if delta > 0.0:
		s = minf(s, absf(angle_error) / delta)
	return s * signf(angle_error)

# ---- Contacts ----

## Records its cells' contacts every step (contacts()), or stops. The spin servo records
## them while it is on, whatever this says. Off by default (nothing recorded, no cost).
func set_contact_tracking(on: bool) -> void:
	_c().set_contact_tracking(id, on)

func contact_tracking() -> bool:
	return _c().contact_tracking(id)

## What its cells touched in the last step, one entry per cell and thing touched (sorted by
## cell, kind, id): { "cell": index, "uid", "kind": Touch, "id": the kernel's id (the static
## shape's, the ring's key, the other creature's slot), "what": that thing (the PhysicsBody2D
## or TileMapLayer, the Goo2D, the GooCellCreature; null if gone), "normal": unit, pushing the
## cell out }. Recorded only while tracked or servoed: a first call turns tracking on and
## returns what the last step recorded (nothing, if it was off).
func contacts() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if not contact_tracking():
		set_contact_tracking(true)
	var got := _c().creature_contacts(id)
	var ints: PackedInt64Array = got[0]
	var normals: PackedVector2Array = got[1]
	for k: int in normals.size():
		var kind := int(ints[4 * k + 2])
		var thing_id := int(ints[4 * k + 3])
		out.append({ "cell": int(ints[4 * k]), "uid": int(ints[4 * k + 1]), "kind": kind, "id": thing_id, "what": world.touched_thing(kind, thing_id), "normal": normals[k] })
	return out

## The last step's contacts counted by kind (cell-thing pairs), indexed by Touch: [walls,
## moving obstacles, rings, creatures]. Cheap: no dictionaries.
func contact_counts() -> PackedInt32Array:
	return _c().contact_counts(id)

## Whether a cell touched a wall in the last step (needs tracking or the servo).
func touching_walls() -> bool:
	return _c().contact_counts(id)[Touch.WALL] > 0

## Whether a cell touched anything of `kind` (a Touch) in the last step.
func touching(kind: int) -> bool:
	return _c().contact_counts(id)[kind] > 0
