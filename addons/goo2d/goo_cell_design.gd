@tool
class_name GooCellDesign
extends Resource
## A creature's design for GooCellWorld2D (docs/cells.md): its cells (a position in the
## design's own frame, a radius, a type from `types`, a group, an angle), saved as a .tres
## and edited in the inspector (the parallel arrays) or built in code (add_cell(), the
## hex builders). The creature's links are not stored: GooCellWorld2D links every two
## cells closer than (r_a + r_b) × link_tolerance when it spawns the design, crossing links
## dropped (links() shows them). Radii are canvas px as drawn (a type's radius_factor
## applies on top); `forward` is the creature's head direction (its heading, the pose
## wave's axis).
##
## Groups: cells of one type and one group joined by links form a region. A shape-matched
## region holds its shape as a whole; the links between two regions are a joint, which
## GooCellCreature.set_joint_angle() bends. Give two parts of one type different groups to
## joint them.

## The cell types the design uses; a cell's type is an index into this (an index out of
## range, or a null entry, is the world's default type).
@export var types: Array[GooCellType] = []
## Each cell's centre in the design's frame (px).
@export var positions: PackedVector2Array = PackedVector2Array()
## Each cell's radius (px).
@export var radii: PackedFloat32Array = PackedFloat32Array()
## Each cell's type: an index into `types`.
@export var cell_types: PackedInt32Array = PackedInt32Array()
## Each cell's group (0..65535): see the class description.
@export var groups: PackedInt32Array = PackedInt32Array()
## Each cell's angle (rad) in the design's frame: the direction its own heading points
## (a thruster pushes along it). Missing entries: 0 (along +x).
@export var angles: PackedFloat32Array = PackedFloat32Array()
## The creature's head direction in the design's frame.
@export var forward: Vector2 = Vector2.RIGHT
## Two cells closer than (r_a + r_b) × this are linked.
@export_range(1.0, 1.5, 0.001) var link_tolerance: float = 1.08

## Cells in the design.
func cell_count() -> int:
	return positions.size()

## Adds a cell; returns its index.
func add_cell(at: Vector2, radius: float, type: int = 0, group: int = 0, angle: float = 0.0) -> int:
	_fill()
	positions.append(at)
	radii.append(radius)
	cell_types.append(type)
	groups.append(group)
	angles.append(angle)
	emit_changed()
	return positions.size() - 1

## Removes cell `index`.
func remove_cell(index: int) -> void:
	_fill()
	if index < 0 or index >= positions.size():
		return
	positions.remove_at(index)
	radii.remove_at(index)
	cell_types.remove_at(index)
	groups.remove_at(index)
	angles.remove_at(index)
	emit_changed()

## Removes every cell (the types stay).
func clear() -> void:
	positions = PackedVector2Array()
	radii = PackedFloat32Array()
	cell_types = PackedInt32Array()
	groups = PackedInt32Array()
	angles = PackedFloat32Array()
	emit_changed()

## The type of cell `index` (null: the world's default).
func type_of(index: int) -> GooCellType:
	var t := cell_types[index] if index < cell_types.size() else 0
	return types[t] if t >= 0 and t < types.size() else null

## The radius cell `index` gets in a world (its type's radius_factor applied).
func radius_of(index: int) -> float:
	var t := type_of(index)
	return radii[index] * (t.radius_factor if t != null else 1.0)

func group_of(index: int) -> int:
	return groups[index] if index < groups.size() else 0

func angle_of(index: int) -> float:
	return angles[index] if index < angles.size() else 0.0

## The links the creature gets (pairs of cell indices, flat): GooCells.design_links().
func links() -> PackedInt32Array:
	var r := PackedFloat32Array()
	for i: int in cell_count():
		r.append(radius_of(i))
	return GooCells.design_links(positions, r, link_tolerance)

## The design's box, cells' discs included.
func bounds() -> Rect2:
	if positions.is_empty():
		return Rect2()
	var box := Rect2(positions[0], Vector2.ZERO)
	for i: int in cell_count():
		var r := radius_of(i)
		box = box.merge(Rect2(positions[i] - Vector2(r, r), Vector2(2 * r, 2 * r)))
	return box

## Its length along `forward` (edge to edge).
func length() -> float:
	var axis := forward.normalized()
	var lo := INF
	var hi := -INF
	for i: int in cell_count():
		var u := positions[i].dot(axis)
		lo = minf(lo, u - radius_of(i))
		hi = maxf(hi, u + radius_of(i))
	return hi - lo if hi > lo else 0.0

## The cells' mean position (a creature spawned at a transform has this at its origin
## when it is the origin of the design: builders centre their designs).
func centroid() -> Vector2:
	var c := Vector2.ZERO
	for p: Vector2 in positions:
		c += p
	return c / maxf(1.0, positions.size())

## Problems that would make a creature from it misbehave, one line each (empty: none):
## arrays of different lengths, radii not positive, cells overlapping by more than a
## tenth of the smaller radius, cells that link to nothing while others do.
func problems() -> PackedStringArray:
	var out := PackedStringArray()
	var n := positions.size()
	if radii.size() != n or cell_types.size() > n or groups.size() > n or angles.size() > n:
		out.append("arrays of different lengths: %d positions, %d radii, %d types, %d groups, %d angles" % [n, radii.size(), cell_types.size(), groups.size(), angles.size()])
		return out
	for i: int in n:
		if radii[i] <= 0.0:
			out.append("cell %d: radius %.2f" % [i, radii[i]])
		for j: int in range(i + 1, n):
			var overlap := radius_of(i) + radius_of(j) - positions[i].distance_to(positions[j])
			if overlap > 0.1 * minf(radius_of(i), radius_of(j)):
				out.append("cells %d and %d overlap by %.1f px" % [i, j, overlap])
	if n > 1:
		var linked := PackedByteArray()
		linked.resize(n)
		var l := links()
		for k: int in l.size():
			linked[l[k]] = 1
		for i: int in n:
			if linked[i] == 0:
				out.append("cell %d links to nothing" % i)
	return out

func _fill() -> void:
	var n := positions.size()
	radii.resize(n)
	if cell_types.size() < n:
		cell_types.resize(n)
	if groups.size() < n:
		groups.resize(n)
	if angles.size() < n:
		angles.resize(n)

## A hex worm `long` cells along `forward` (+x) by `wide` rows, of radius `radius`, its
## cells of `type`, centred on the origin.
static func hex_worm(long: int, wide: int, radius: float, type: int = 0) -> GooCellDesign:
	var d := GooCellDesign.new()
	for row: int in wide:
		var y := (row - (wide - 1) * 0.5) * 2.0 * radius * 0.8660254
		var shift := radius if row % 2 == 1 else 0.0
		for k: int in long:
			d.add_cell(Vector2((k - (long - 1) * 0.5) * 2.0 * radius + shift, y), radius, type)
	d._centre()
	return d

## A hex blob of `rings` rings around one cell (1 + 3 rings (rings + 1) cells).
static func hex_blob(rings: int, radius: float, type: int = 0) -> GooCellDesign:
	var d := GooCellDesign.new()
	for q: int in range(-rings, rings + 1):
		for s: int in range(-rings, rings + 1):
			if absi(-q - s) > rings:
				continue
			d.add_cell(Vector2(2.0 * radius * (q + s * 0.5), 2.0 * radius * s * 0.8660254), radius, type)
	d._centre()
	return d

## Cells moved so their mean is the origin.
func _centre() -> void:
	var c := centroid()
	for i: int in positions.size():
		positions[i] -= c
