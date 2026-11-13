extends SceneTree
## Contact sheets of examples/elastic (docs/cells.md, "Elastic bodies"): eight frames each, in
## two rows of four, left to right, top to bottom:
##   blob_wall.png    the blob thrown at the wall: from just before it touches to rounded out
##   worm_struck.png  the worm struck amidships: from the blow to straight again
##   ship_turn.png    a half turn of both ships: head-led (left in each frame) and as a stick
##   gap.png          the jelly squeezing through the gap 0.8 of its width
## Run under xvfb-run with the real renderer, at fixed fps:
##   xvfb-run -a -s "-screen 0 1920x1080x24" godot --path . --rendering-driver opengl3
##     --audio-driver Dummy --fixed-fps 60 -s tools/elastic_shot.gd -- OUT_DIR

const SCENE := "res://examples/elastic/elastic.tscn"
const LAYOUT_SIZE := Vector2i(1920, 1080)
## Each lane's crop (canvas px).
const LANE_A := Rect2i(20, 170, 460, 260)
const LANE_B := Rect2i(970, 120, 890, 410)
const LANE_C := Rect2i(60, 560, 890, 460)
const LANE_D := Rect2i(970, 560, 890, 460)
## Frames after each lane's trigger.
const AFTER_A: Array[int] = [-3, 0, 2, 4, 6, 9, 14, 24]
const AFTER_B: Array[int] = [-2, 2, 6, 10, 16, 24, 34, 50]
const AFTER_C: Array[int] = [0, 4, 8, 12, 16, 20, 26, 36]
const AFTER_D: Array[int] = [24, 30, 34, 37, 40, 43, 46, 50]

var _out := "."
var _scene: ElasticExample
var _frame := 0
var _trigger := { "a": -1, "b": -1, "c": -1, "d": 0 }
var _shots := { "a": [], "b": [], "c": [], "d": [] }
var _history: Array[Image] = []
var _done := false

func _initialize() -> void:
	for arg: String in OS.get_cmdline_user_args():
		if not arg.begins_with("--"):
			_out = arg
	DirAccess.make_dir_recursive_absolute(_out)
	DisplayServer.window_set_size(LAYOUT_SIZE)
	_scene = (load(SCENE) as PackedScene).instantiate() as ElasticExample
	root.add_child(_scene)

func _process(_delta: float) -> bool:
	if _done:
		return false
	_frame += 1
	_step.call_deferred()
	return false

func _step() -> void:
	var image := await _grab()
	if image == null:
		return
	# The last few frames, for the shots taken before a trigger.
	_history.append(image)
	if _history.size() > 6:
		_history.pop_front()
	var s := _scene
	var t := s.time
	if _trigger["a"] < 0 and t > 2.9:
		for p: Vector2 in s.blob.positions():
			if p.x < 60.0 + ElasticExample.RADIUS + 1.5:
				_trigger["a"] = _frame
				break
	if _trigger["b"] < 0 and t > ElasticExample.HAMMER_EVERY + 0.85:
		var top := INF
		for p: Vector2 in s.worm.positions():
			top = minf(top, p.y)
		var low := -INF
		for p: Vector2 in s.hammer.positions():
			low = maxf(low, p.y)
		if low > top - 2.0 * ElasticExample.RADIUS - 1.0:
			_trigger["b"] = _frame
	if _trigger["c"] < 0 and s.turns == 2:
		_trigger["c"] = _frame
	_take("a", AFTER_A, LANE_A)
	_take("b", AFTER_B, LANE_B)
	_take("c", AFTER_C, LANE_C)
	_take("d", AFTER_D, LANE_D)
	var all := true
	for k: String in _shots:
		if (_shots[k] as Array).size() < 8:
			all = false
	if all or _frame > 900:
		_done = true
		_sheet("a", "blob_wall.png")
		_sheet("b", "worm_struck.png")
		_sheet("c", "ship_turn.png")
		_sheet("d", "gap.png")
		quit(0)

func _take(lane: String, after: Array[int], rect: Rect2i) -> void:
	var at: int = _trigger[lane]
	if at < 0:
		return
	var shots: Array = _shots[lane]
	while shots.size() < after.size() and at + after[shots.size()] <= _frame:
		var back := _frame - (at + after[shots.size()])
		var src: Image = _history[maxi(_history.size() - 1 - back, 0)]
		shots.append(src.get_region(rect))

func _sheet(lane: String, name: String) -> void:
	var shots: Array = _shots[lane]
	if shots.is_empty():
		push_error("elastic_shot: no frames for %s" % name)
		return
	var w: int = (shots[0] as Image).get_width()
	var h: int = (shots[0] as Image).get_height()
	var gap := 6
	var sheet := Image.create(4 * w + 3 * gap, 2 * h + gap, false, Image.FORMAT_RGBA8)
	sheet.fill(Color(0.6, 0.6, 0.6))
	for k: int in shots.size():
		var img: Image = shots[k]
		img.convert(Image.FORMAT_RGBA8)
		sheet.blit_rect(img, Rect2i(Vector2i.ZERO, img.get_size()), Vector2i((k % 4) * (w + gap), (k / 4) * (h + gap)))
	var path := _out.path_join(name)
	sheet.save_png(path)
	print("elastic_shot: saved %s (%d frames)" % [path, shots.size()])

func _grab() -> Image:
	await RenderingServer.frame_post_draw
	var image := root.get_viewport().get_texture().get_image()
	if image == null or image.is_empty():
		push_error("elastic_shot: no image (run with a real renderer, not --headless)")
		_done = true
		quit(1)
		return null
	return image
