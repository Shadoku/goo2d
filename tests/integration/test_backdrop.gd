extends TestCase
## The main scene's Backdrop: a full-screen ColorRect drawn first (under the
## arena and the blobs) with the backdrop shader, giving the goo's refraction
## something to bend, and never eating mouse input.

const MAIN_SCENE := preload("res://scenes/main.tscn")
const BACKDROP_SHADER := "res://assets/shaders/backdrop.gdshader"

func test_backdrop_is_the_first_child_and_covers_the_viewport() -> void:
	var main := MAIN_SCENE.instantiate()
	add_child(main)
	await wait_frames(2)
	var backdrop := main.get_node_or_null("Backdrop") as ColorRect
	assert_not_null(backdrop, "Main should have a Backdrop ColorRect")
	if backdrop == null:
		return
	assert_eq(backdrop.get_index(), 0, "the backdrop draws first, under everything")
	assert_eq(backdrop.mouse_filter, Control.MOUSE_FILTER_IGNORE)
	var material := backdrop.material as ShaderMaterial
	assert_not_null(material)
	if material != null:
		assert_eq(material.shader.resource_path, BACKDROP_SHADER)
	var screen := backdrop.get_viewport().get_visible_rect()
	var rect := backdrop.get_global_rect()
	assert_true(rect.encloses(screen), "backdrop %s should cover the viewport %s" % [rect, screen])
