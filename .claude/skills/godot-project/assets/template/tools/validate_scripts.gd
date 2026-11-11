extends SceneTree
## Compiles every .gd script in the project and reports the ones with errors.
##
##   godot --headless --path . -s tools/validate_scripts.gd [-- --include-addons]
##
## Faster than running `--check-only` per file because it uses a single Godot process.
## Skips vendored addons: a directory directly under res://addons/ that holds a
## VENDORED.md or a .gdignore; the project's own addons are always checked.
## --include-addons checks the VENDORED.md ones too (a directory with a .gdignore,
## anywhere, is invisible to Godot and never checked).
## Parse and type errors are printed by the engine as SCRIPT ERROR lines above the summary.

func _initialize() -> void:
	var include_addons := "--include-addons" in OS.get_cmdline_user_args()
	var paths := _find_scripts("res://", include_addons)
	paths.sort()
	var bad: Array[String] = []
	for path in paths:
		var script = ResourceLoader.load(path, "GDScript", ResourceLoader.CACHE_MODE_REPLACE)
		var ok: bool = script != null and script is GDScript and (script.can_instantiate() or (script.has_method("is_abstract") and script.is_abstract()))
		if not ok:
			bad.append(path)
			print("[FAIL] %s" % path.trim_prefix("res://"))
	print("")
	print("SCRIPTS: %d checked, %d with errors" % [paths.size(), bad.size()])
	print("RESULT: %s" % ("PASS" if bad.is_empty() else "FAIL"))
	quit(0 if bad.is_empty() else 1)

func _find_scripts(dir_path: String, include_addons: bool) -> Array[String]:
	var found: Array[String] = []
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return found
	if dir.file_exists(".gdignore"):
		return found
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		var full := dir_path.path_join(entry)
		if dir.current_is_dir():
			if entry.begins_with("."):
				pass
			elif dir_path == "res://addons" and not include_addons and _is_vendored(full):
				pass
			else:
				found.append_array(_find_scripts(full, include_addons))
		elif entry.ends_with(".gd"):
			found.append(full)
		entry = dir.get_next()
	dir.list_dir_end()
	return found

# True for an addon directory that holds a VENDORED.md or a .gdignore: third-party
# code the project does not maintain.
func _is_vendored(addon_path: String) -> bool:
	return FileAccess.file_exists(addon_path.path_join("VENDORED.md")) \
		or FileAccess.file_exists(addon_path.path_join(".gdignore"))
