@tool
@icon("res://addons/goo2d/icon_goo_link_2d.svg")
class_name GooLink2D
extends Node2D
## A link placed in the editor: a child of a GooWorld2D naming two of its
## Goo2D children (`body_a`, `body_b`), which the world links (GooWorld2D.link())
## once both are registered, at `strength` and `rest_angle`, the patches facing
## each other as the bodies were placed. In the editor it draws a line between
## the two bodies with a waist at the middle, as wide as the neck would be.
## Changing `strength` or `rest_angle` on a running link changes the link;
## freeing the node unlinks it. A link the world released (a body split,
## merged, trimmed or despawned) is not made again: `handle` is -1 then.

## The first body (a Goo2D sibling).
@export var body_a: NodePath = NodePath():
	set(value):
		body_a = value
		queue_redraw()
## The second body (a Goo2D sibling).
@export var body_b: NodePath = NodePath():
	set(value):
		body_b = value
		queue_redraw()
## 0..1: how wide the neck is (GooWorld2D.link()).
@export_range(0.0, 1.0, 0.01) var strength: float = 1.0:
	set(value):
		strength = clampf(value, 0.0, 1.0)
		queue_redraw()
		if handle >= 0 and _world() != null:
			_world().set_link_strength(handle, strength)
## Radians the second body turns relative to the first at rest
## (GooWorld2D.set_link_rest_angle()).
@export_range(-3.1416, 3.1416, 0.01, "radians_as_degrees") var rest_angle: float = 0.0:
	set(value):
		rest_angle = value
		if handle >= 0 and _world() != null:
			_world().set_link_rest_angle(handle, rest_angle)

## Line colour of the editor preview.
const PREVIEW_COLOR := Color(0.55, 0.65, 0.95, 0.8)

## The world's handle of the link made; -1 before it is made or after it was
## released.
var handle: int = -1
# True once the link was asked for (made or refused): it is not made again.
var _made: bool = false

func _ready() -> void:
	if Engine.is_editor_hint():
		set_process(true)
		return
	set_process(false)
	var world := _world()
	if world == null:
		push_error("GooLink2D %s: its parent is not a GooWorld2D" % name)
		return
	world.body_spawned.connect(_on_body_spawned)
	world.bodies_unlinked.connect(_on_unlinked)
	_try_link.call_deferred()

func _exit_tree() -> void:
	if Engine.is_editor_hint():
		return
	var world := _world()
	if handle >= 0 and world != null:
		world.unlink(handle)
	handle = -1

## The two bodies, null where a path does not name a Goo2D.
func bodies() -> Array[Goo2D]:
	var result: Array[Goo2D] = [get_node_or_null(body_a) as Goo2D, get_node_or_null(body_b) as Goo2D]
	return result

func _world() -> GooWorld2D:
	return get_parent() as GooWorld2D

# Links the bodies once both are registered with the world (it registers
# placed bodies at the end of the frame they were added in).
func _try_link() -> void:
	if handle >= 0 or not is_inside_tree() or _made:
		return
	var pair := bodies()
	if pair[0] == null or pair[1] == null:
		push_error("GooLink2D %s: body_a and body_b must name two Goo2D nodes" % name)
		_made = true
		return
	if pair[0].id < 0 or pair[1].id < 0:
		return
	_made = true
	handle = _world().link(pair[0], pair[1], strength)
	if handle >= 0 and rest_angle != 0.0:
		_world().set_link_rest_angle(handle, rest_angle)


func _on_body_spawned(_body: Goo2D) -> void:
	if handle < 0 and not _made:
		_try_link.call_deferred()

func _on_unlinked(released: int, _a_id: int, _b_id: int) -> void:
	if released == handle:
		handle = -1

func _process(_delta: float) -> void:
	queue_redraw()

func _draw() -> void:
	if not Engine.is_editor_hint():
		return
	var pair := bodies()
	if pair[0] == null or pair[1] == null:
		return
	var from := to_local(pair[0].global_position)
	var to := to_local(pair[1].global_position)
	var width := maxf(strength * GooTuning.LINK_PATCH_RATIO * minf(pair[0].radius, pair[1].radius), 2.0)
	var middle := (from + to) * 0.5
	var across := (to - from).orthogonal().normalized()
	draw_line(from, to, PREVIEW_COLOR, 2.0)
	draw_line(middle - across * width * 0.5, middle + across * width * 0.5, PREVIEW_COLOR, 2.0)
	draw_circle(from, 3.0, PREVIEW_COLOR)
	draw_circle(to, 3.0, PREVIEW_COLOR)
