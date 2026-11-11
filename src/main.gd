extends Node2D
## Entry scene. Keep this thin: instance scenes and connect signals here, and put
## game logic in plain classes under src/ so it can be unit tested headless.

## The canvas size this scene is laid out for: it gives the window's canvas
## this size while it is in the tree (the project's own, the game's, is
## 960 × 528).
const LAYOUT_SIZE := Vector2i(1920, 1080)

@onready var _arena: Arena = $Arena
@onready var _game: Game = $Game
@onready var _dropper: Dropper = $Dropper

var _previous_size: Vector2i
var _previous_stretch: Window.ContentScaleStretch

# Lays the window's canvas out at LAYOUT_SIZE, fitted to the window (not by
# whole numbers: 1080 does not go into the default 1056 px window), while the
# scene is in the tree; the window's settings come back when it leaves.
func _enter_tree() -> void:
	var window := get_window()
	_previous_size = window.content_scale_size
	_previous_stretch = window.content_scale_stretch
	window.content_scale_size = LAYOUT_SIZE
	window.content_scale_stretch = Window.CONTENT_SCALE_STRETCH_FRACTIONAL

func _exit_tree() -> void:
	var window := get_window()
	window.content_scale_size = _previous_size
	window.content_scale_stretch = _previous_stretch

func _ready() -> void:
	_game.arena = _arena
	_dropper.game = _game
	_dropper.arena = _arena
	GooSkin.warm_up(self)
	print("%s ready" % ProjectSettings.get_setting("application/config/name"))
