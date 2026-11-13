class_name GooProxies
extends RefCounted
## The Godot bodies standing in for a goo world's bodies or creatures (docs/godot-physics.md),
## kept by GooWorld2D and GooCellWorld2D while their physics_proxies is on: one kinematic
## body per goo body, made directly in the PhysicsServer2D (no node, no CollisionShape2D:
## a proxy of 30 circles moved by 31 server calls a frame), in the world's space, on
## `layer` with `mask`, its object the goo's owner node (a Goo2D, or a creature's
## GooCellCreature.proxy_node()), so Area2D.body_entered, a ray's or a shape query's
## `collider`, a CharacterBody2D's get_collider() and a RigidBody2D's contacts all name
## that node. Its shapes are the goo's outline, either a circle per bead or boundary cell
## (Shape.CIRCLES, sharing one circle shape per radius) or one convex polygon, the
## outline's convex hull grown by the bead radius (Shape.HULL: one shape, solid inside,
## concavities filled in). Its transform is the goo's centre without rotation, the shapes
## placed about it, so Godot reports the centre's velocity as the proxy's (a kinematic
## body's velocity is its transform's change over the step): what a rigid body bounces
## off. It is moved after the goo's step and moves in Godot's step of the same frame.
##
## The goo never sees its proxies (they are no nodes, and never on GooTuning.LAYER_WALLS
## by default). A RigidBody2D the goo pushes itself (on LAYER_WALLS while the world's
## push_bodies is on, GooStatics.pushed_bodies()) is excepted from every proxy
## (except()), so the pair is solved once, by the goo.

## A proxy's shapes.
enum Shape {
	## A circle per bead (a ring) or boundary cell (a creature).
	CIRCLES,
	## One convex polygon: the outline's convex hull grown by the bead radius.
	HULL,
}

var layer: int = GooTuning.LAYER_PROXIES
var mask: int = 0
var shape: Shape = Shape.CIRCLES
## Shapes moved by the last frame's updates (a hull counts 1), for the bench.
var shapes_moved: int = 0

var _space: RID = RID()
# key -> { "rid", "owner" (instance id), "count" (shapes), "radii" (the radius keys of
# its circles), "raw" (the radii they were made from), "hull" (its polygon shape RID, or
# RID()), "seen" (the frame it was last updated on) }
var _proxies: Dictionary = {}
# Circle shapes by radius key (snapped to RADIUS_STEP px).
var _circles: Dictionary[int, RID] = {}
# Bodies every proxy is excepted from, by instance id -> RID.
var _excepted: Dictionary[int, RID] = {}
var _frame: int = 0

## Circle radii are snapped to this (px) so cells of nearly one size share a shape.
const RADIUS_STEP: float = 0.05

func _init(space: RID) -> void:
	_space = space

## The number of proxies.
func count() -> int:
	return _proxies.size()

## Whether `key` has a proxy.
func has(key: int) -> bool:
	return _proxies.has(key)

## The proxy body of `key` (RID() for none).
func rid_of(key: int) -> RID:
	return _proxies[key]["rid"] if _proxies.has(key) else RID()

## Every proxy body.
func rids() -> Array[RID]:
	var out: Array[RID] = []
	for entry: Dictionary in _proxies.values():
		out.append(entry["rid"])
	return out

## The shapes of `key`'s proxy now.
func shape_count(key: int) -> int:
	return PhysicsServer2D.body_get_shape_count(rid_of(key)) if _proxies.has(key) else 0

## Starts a frame of updates: proxies not updated before end_frame() are removed.
func begin_frame() -> void:
	_frame += 1
	shapes_moved = 0

## Removes the proxies no update named since begin_frame().
func end_frame() -> void:
	for key: int in _proxies.keys():
		if _proxies[key]["seen"] != _frame:
			remove(key)

## Moves (making it on first sight) the proxy of `key`, whose object is `owner`, to
## the circles of `centers` (global) with `radii` (one per centre, or a single entry for
## all), about `center`. With Shape.HULL, the convex hull of those circles instead.
## `moved` false: the goo did not move since the last update (a settled ring); only
## marks it seen.
func update(key: int, owner: Object, center: Vector2, centers: PackedVector2Array, radii: PackedFloat32Array, moved: bool = true) -> void:
	var entry: Dictionary = _proxies.get(key, {})
	if entry.is_empty():
		entry = _make(key, owner)
		moved = true
	entry["seen"] = _frame
	if not moved or centers.is_empty():
		return
	var rid: RID = entry["rid"]
	PhysicsServer2D.body_set_state(rid, PhysicsServer2D.BODY_STATE_TRANSFORM, Transform2D(0.0, center))
	if shape == Shape.HULL:
		_update_hull(entry, center, centers, radii)
		return
	var n := centers.size()
	if entry["count"] != n or entry["hull"].is_valid() or entry["raw"] != radii:
		_reshape(entry, radii, n)
		entry["raw"] = radii.duplicate()
	for i: int in n:
		PhysicsServer2D.body_set_shape_transform(rid, i, Transform2D(0.0, centers[i] - center))
	shapes_moved += n

## Removes `key`'s proxy.
func remove(key: int) -> void:
	if not _proxies.has(key):
		return
	var entry: Dictionary = _proxies[key]
	PhysicsServer2D.free_rid(entry["rid"])
	if entry["hull"].is_valid():
		PhysicsServer2D.free_rid(entry["hull"])
	_proxies.erase(key)

## Removes every proxy and frees the shared shapes.
func clear() -> void:
	for key: int in _proxies.keys():
		remove(key)
	for rid: RID in _circles.values():
		PhysicsServer2D.free_rid(rid)
	_circles.clear()
	_excepted.clear()

## Sets every proxy's layer and mask.
func set_layers(new_layer: int, new_mask: int) -> void:
	layer = new_layer
	mask = new_mask
	for entry: Dictionary in _proxies.values():
		PhysicsServer2D.body_set_collision_layer(entry["rid"], layer)
		PhysicsServer2D.body_set_collision_mask(entry["rid"], mask)

## Excepts every proxy (now and later) from colliding with each of `bodies` in Godot's
## solver (bodies the goo pushes itself); a body no longer listed is let back.
func except(bodies: Array) -> void:
	var now: Dictionary[int, RID] = {}
	for body: Variant in bodies:
		if is_instance_valid(body):
			now[(body as Object).get_instance_id()] = (body as CollisionObject2D).get_rid()
	for id: int in _excepted:
		if not now.has(id):
			for entry: Dictionary in _proxies.values():
				PhysicsServer2D.body_remove_collision_exception(entry["rid"], _excepted[id])
	for id: int in now:
		if not _excepted.has(id):
			for entry: Dictionary in _proxies.values():
				PhysicsServer2D.body_add_collision_exception(entry["rid"], now[id])
	_excepted = now

## The bodies every proxy is excepted from now (except()).
func excepted() -> Array[RID]:
	var out: Array[RID] = []
	out.assign(_excepted.values())
	return out

func _make(key: int, owner: Object) -> Dictionary:
	var rid := PhysicsServer2D.body_create()
	PhysicsServer2D.body_set_mode(rid, PhysicsServer2D.BODY_MODE_KINEMATIC)
	PhysicsServer2D.body_set_space(rid, _space)
	PhysicsServer2D.body_set_collision_layer(rid, layer)
	PhysicsServer2D.body_set_collision_mask(rid, mask)
	PhysicsServer2D.body_attach_object_instance_id(rid, owner.get_instance_id())
	for id: int in _excepted:
		PhysicsServer2D.body_add_collision_exception(rid, _excepted[id])
	var entry := { "rid": rid, "owner": owner.get_instance_id(), "count": 0, "radii": PackedFloat32Array(), "raw": PackedFloat32Array(), "hull": RID(), "seen": _frame }
	_proxies[key] = entry
	return entry

func _radius_key(radius: float) -> float:
	return snappedf(radius, RADIUS_STEP)

func _circle(radius_key: float) -> RID:
	var k := roundi(radius_key / RADIUS_STEP)
	if not _circles.has(k):
		var rid := PhysicsServer2D.circle_shape_create()
		PhysicsServer2D.shape_set_data(rid, maxf(radius_key, RADIUS_STEP))
		_circles[k] = rid
	return _circles[k]

# Gives `entry`'s body one circle per centre, of `radii` (one, or one each).
func _reshape(entry: Dictionary, radii: PackedFloat32Array, n: int) -> void:
	var rid: RID = entry["rid"]
	if entry["hull"].is_valid():
		PhysicsServer2D.body_clear_shapes(rid)
		PhysicsServer2D.free_rid(entry["hull"])
		entry["hull"] = RID()
		entry["count"] = 0
	var keys := PackedFloat32Array()
	keys.resize(n)
	for i: int in n:
		keys[i] = _radius_key(radii[0] if radii.size() == 1 else radii[i])
	var have: int = entry["count"]
	var old: PackedFloat32Array = entry["radii"]
	while have > n:
		have -= 1
		PhysicsServer2D.body_remove_shape(rid, have)
	for i: int in n:
		if i < have:
			if old[i] != keys[i]:
				PhysicsServer2D.body_set_shape(rid, i, _circle(keys[i]))
		else:
			PhysicsServer2D.body_add_shape(rid, _circle(keys[i]))
	entry["count"] = n
	entry["radii"] = keys

func _update_hull(entry: Dictionary, center: Vector2, centers: PackedVector2Array, radii: PackedFloat32Array) -> void:
	var rid: RID = entry["rid"]
	if not entry["hull"].is_valid():
		PhysicsServer2D.body_clear_shapes(rid)
		entry["hull"] = PhysicsServer2D.convex_polygon_shape_create()
		PhysicsServer2D.body_add_shape(rid, entry["hull"])
		entry["count"] = 1
		entry["radii"] = PackedFloat32Array()
		entry["raw"] = PackedFloat32Array()
		PhysicsServer2D.body_set_shape_transform(rid, 0, Transform2D.IDENTITY)
	var grow := 0.0
	for r: float in radii:
		grow = maxf(grow, r)
	var local := PackedVector2Array()
	local.resize(centers.size())
	for i: int in centers.size():
		local[i] = centers[i] - center
	var hull := Geometry2D.convex_hull(local)
	if hull.size() < 4:
		return
	hull.remove_at(hull.size() - 1)
	var grown := Geometry2D.offset_polygon(hull, grow, Geometry2D.JOIN_ROUND)
	if grown.is_empty():
		return
	PhysicsServer2D.shape_set_data(entry["hull"], grown[0])
	shapes_moved += 1
