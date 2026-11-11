extends SceneTree
## Loads the native kernel the way the game will and quits 0 if it works, 1 if
## not: the GDExtension registered GooKernel, one can be made, its constants
## read and a ring stepped. kernel.yml runs this with the real Godot on every
## platform it builds for, after the build, so a library that cannot be
## loaded (an incremental link on a stale output, a missing runtime) fails the
## build instead of the next player's game.
##
##   godot --headless --path . -s tools/kernel_smoke.gd

func _initialize() -> void:
	if not ClassDB.class_exists("GooKernel"):
		push_error("kernel_smoke: GooKernel is not registered: the GDExtension did not load")
		quit(1)
		return
	var kernel: RefCounted = ClassDB.instantiate("GooKernel")
	if kernel == null:
		push_error("kernel_smoke: GooKernel could not be instantiated")
		quit(1)
		return
	var constants: Dictionary = kernel.call("constants")
	if constants.is_empty():
		push_error("kernel_smoke: GooKernel.constants() is empty")
		quit(1)
		return
	var world := GooWorld2D.new()
	root.add_child(world)
	var body := world.spawn(40.0, Vector2(300.0, 300.0))
	for _step: int in 3:
		world.kernel().step(1.0 / 60.0)
	if body.particle_count() == 0 or not body.center().is_finite():
		push_error("kernel_smoke: the kernel did not step a ring")
		quit(1)
		return
	print("kernel_smoke: GooKernel loaded, %d constants, a ring of %d beads stepped" % [constants.size(), body.particle_count()])
	quit(0)
