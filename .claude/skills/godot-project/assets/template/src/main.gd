extends __MAIN_NODE__
## Entry scene. Keep this thin: instance scenes and connect signals here, and put
## game logic in plain classes under src/ so it can be unit tested headless.

func _ready() -> void:
	print("%s ready" % ProjectSettings.get_setting("application/config/name"))
