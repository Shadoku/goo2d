extends TestCase
## Scene-level test: the main scene instantiates, enters the tree, and survives a
## few frames without errors. Any ERROR / SCRIPT ERROR printed during the test fails it.

const MAIN_SCENE := preload("res://scenes/main.tscn")

func test_main_scene_boots() -> void:
	var main := MAIN_SCENE.instantiate()
	add_child(main)
	await wait_frames(3)
	assert_true(main.is_inside_tree())
	assert_eq(main.name, "Main")
