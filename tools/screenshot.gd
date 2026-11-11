extends SceneTree
## Renders the main scene with a few blobs in it (or another scene, such as an
## example, as it is) and saves one frame as a PNG, to look at the goo shader
## without a display. Needs a real renderer, so run it under Xvfb (it prints an
## error and quits on the headless dummy renderer):
##
##   xvfb-run -a -s "-screen 0 1920x1080x24" godot --path . --rendering-driver opengl3 \
##       --audio-driver Dummy -s tools/screenshot.gd -- out.png
##
## Options after `--`: the output path (default screenshot.png, relative to the
## working directory), `--frames=N` (frames to run before the capture,
## default 60), `--scene=res://path/to/scene.tscn` (render that scene instead of
## the main scene: it only runs its frames and is grabbed, as an example
## populates itself; the blobs and `--split` are the main scene's) and `--split`
## (main scene only): also saves the frame as <name>_before.png, then
## stops physics, cuts the biggest blob in two (top to bottom, GooWorld2D.cut())
## and saves the next frame as the output: the pieces exactly as cut, to compare
## their bubbles with the whole blob's.
##
## The game's scenes (under res://game/) render at the project's window size,
## their 960 × 528 canvas scaled up by whole numbers (run on its own, the title
## or the battle sets the game's goo unit itself). The main scene and the
## examples are laid out for 1920 × 1080 (each sets its canvas to that size
## while it is in the tree): the window is made LAYOUT_SIZE so they render 1:1.

const MAIN_SCENE := "res://scenes/main.tscn"
## The canvas size of the main scene and the examples.
const LAYOUT_SIZE := Vector2i(1920, 1080)

var _out_path: String = "screenshot.png"
var _scene_path: String = MAIN_SCENE
var _frames: int = 60
var _split: bool = false
var _frame: int = 0
var _main: Node
var _done: bool = false

func _initialize() -> void:
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--frames="):
			_frames = maxi(int(arg.get_slice("=", 1)), 1)
		elif arg.begins_with("--scene="):
			_scene_path = arg.trim_prefix("--scene=")
			if not _scene_path.contains("://"):
				_scene_path = "res://" + _scene_path.trim_prefix("/")
		elif arg == "--split":
			_split = true
		elif not arg.begins_with("--"):
			_out_path = arg
	if not _out_path.is_absolute_path():
		_out_path = OS.get_environment("PWD").path_join(_out_path) if OS.has_environment("PWD") else _out_path
	if _split and not _is_main():
		push_warning("screenshot: --split applies only to the main scene; ignored for %s" % _scene_path)
		_split = false
	var scene := load(_scene_path) as PackedScene
	if scene == null:
		push_error("screenshot: could not load the scene %s" % _scene_path)
		_done = true
		quit(1)
		return
	if not _scene_path.begins_with("res://game/"):
		# The window itself (Window.size set here does not reach it this early).
		DisplayServer.window_set_size(LAYOUT_SIZE)
	_main = scene.instantiate()
	root.add_child(_main)

func _process(_delta: float) -> bool:
	if _done:
		return false # _finish() quits once its frames are saved.
	_frame += 1
	# The blobs are the main scene's (its Game); any other scene populates itself.
	if _is_main() and _frame == 2:
		_spawn_blobs()
	if _is_main() and _frame == maxi(_frames - 14, 3):
		_throw_blob()
	if _frame >= _frames:
		_done = true
		_finish.call_deferred()
	return false

func _finish() -> void:
	var before: Image = null
	if _split:
		# Grab both frames before saving either, so they are one frame apart:
		# the bubbles keep drifting up with TIME.
		before = await _grab()
		if before == null:
			return
		# Frozen, the pieces show the instant of the cut: free, they slump
		# apart a pixel or so per step, their bubbles riding along. The goo
		# moves only when its world steps its kernel.
		(_main.get_node("Game") as Game).set_physics_process(false)
		_split_biggest()
	var image := await _grab()
	if image == null:
		return
	if before != null and not _save(before, _out_path.get_basename() + "_before." + _out_path.get_extension()):
		return
	if _save(image, _out_path):
		quit(0)

# Whether the scene rendered is the main scene (the one with a Game to fill).
func _is_main() -> bool:
	return _scene_path == MAIN_SCENE

# A spread of sizes across the middle of the screen.
func _spawn_blobs() -> void:
	var game := _main.get_node("Game") as Game
	var screen := root.get_visible_rect()
	var spots: Array[Vector3] = [
		Vector3(0.30, 0.62, GooTuning.radius_at(0.55)),
		Vector3(0.68, 0.60, GooTuning.radius_at(0.35)),
		Vector3(0.50, 0.40, GooTuning.radius_at(0.2)),
		Vector3(0.36, 0.30, GooTuning.MIN_RADIUS),
		Vector3(0.62, 0.25, GooTuning.radius_at(0.1)),
	]
	for spot: Vector3 in spots:
		game.spawn(spot.z, screen.position + Vector2(spot.x, spot.y) * screen.size)

# One blob thrown fast just before the capture, so it is caught in flight with
# the motion ripple showing.
func _throw_blob() -> void:
	var game := _main.get_node("Game") as Game
	var screen := root.get_visible_rect()
	var thrown := game.spawn(GooTuning.radius_at(0.25), screen.position + Vector2(0.35, 0.45) * screen.size)
	thrown.set_velocity(Vector2(420.0, -650.0))

# Cuts the biggest blob from its top bead to the one opposite along the ring.
func _split_biggest() -> void:
	var game := _main.get_node("Game") as Game
	var biggest: Goo2D = null
	for blob: Goo2D in game.bodies():
		if biggest == null or blob.radius > biggest.radius:
			biggest = blob
	if biggest == null:
		return
	var points := biggest.bead_points()
	var top := 0
	for i: int in points.size():
		if points[i].y < points[top].y:
			top = i
	var before := game.bodies().size()
	game.cut(biggest, top, (top + points.size() / 2) % points.size())
	print("screenshot: split the %.0f px blob: %s" % [biggest.radius,
		"cut" if game.bodies().size() > before else "not cut"])

# The next drawn frame, or null (after quitting with an error) if there is none.
func _grab() -> Image:
	await RenderingServer.frame_post_draw
	var image := root.get_viewport().get_texture().get_image()
	if image == null or image.is_empty():
		push_error("screenshot: no image (run with a real renderer, not --headless)")
		quit(1)
		return null
	return image

# Saves `image` to `path`. Quits with an error and returns false if it cannot.
func _save(image: Image, path: String) -> bool:
	var err := image.save_png(path)
	if err != OK:
		push_error("screenshot: could not save %s (error %d)" % [path, err])
		quit(1)
		return false
	print("screenshot: saved %s (%dx%d)" % [path, image.get_width(), image.get_height()])
	return true
