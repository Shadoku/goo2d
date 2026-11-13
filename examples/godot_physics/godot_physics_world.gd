class_name GodotPhysicsWorld
extends GooWorld2D
## The godot_physics example's ring world: its bodies never merge, so the round blob, the
## square and the small blob stay apart as they are pushed about.

func may_merge(_a: Goo2D, _b: Goo2D) -> bool:
	return false
