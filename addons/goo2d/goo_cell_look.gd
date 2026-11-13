class_name GooCellLook
extends RefCounted
## The look of GooCellWorld2D's goo skin (addons/goo2d/goo_honeycomb.gdshader) as named
## uniform sets: presets of one shader, so a look is a handful of numbers (lengths in px at
## GooTuning.unit 1). GooCellWorld2D.skin_preset applies one to its default material;
## apply() puts one (and any overrides) on any material of that shader.

enum Preset {
	## The goo with barely-there cell walls, soft thickness shading, one soft highlight.
	FAINT,
	## The walls a little more present, each cell a small dome that catches the light.
	CELLULAR,
	## A thicker outer membrane, the walls faint, the inside slightly clouded.
	MEMBRANE,
	## Nothing applied: the shader's own defaults, or what a game set itself.
	CUSTOM,
}

## The shader the presets are for.
const SHADER_PATH := "res://addons/goo2d/goo_honeycomb.gdshader"

## Each preset's uniforms (only what differs from the shader's defaults is needed; every
## preset names the same keys so switching one replaces the other's numbers).
const PRESETS: Dictionary = {
	Preset.FAINT: {
		"goo_opacity": 0.3, "rim_width": 16.0, "rim_strength": 0.85, "rim_density": 0.35,
		"refraction_px": 18.0, "cell_refraction_px": 1.5,
		"wall_width": 1.5, "wall_strength": 0.16, "wall_softness": 1.0, "wall_highlight": 0.0, "wall_rim_fade": 0.6,
		"border_sharpness": 3.0, "membrane_width": 0.0, "membrane_strength": 0.0, "cloud": 0.0,
		"bubble_density": 0.12, "bubble_strength": 0.6,
		"shade_depth": 40.0, "shade_strength": 0.18, "side_light": 0.18,
		"specular_power": 90.0, "specular_strength": 1.4, "sheen_strength": 0.22,
		"dome_strength": 0.15, "dome_highlight": 0.06, "dome_power": 18.0,
	},
	Preset.CELLULAR: {
		"goo_opacity": 0.32, "rim_width": 14.0, "rim_strength": 0.8, "rim_density": 0.3,
		"refraction_px": 16.0, "cell_refraction_px": 4.0,
		"wall_width": 2.0, "wall_strength": 0.34, "wall_softness": 1.2, "wall_highlight": 0.25, "wall_rim_fade": 0.4,
		"border_sharpness": 4.0, "membrane_width": 0.0, "membrane_strength": 0.0, "cloud": 0.0,
		"bubble_density": 0.1, "bubble_strength": 0.5,
		"shade_depth": 40.0, "shade_strength": 0.15, "side_light": 0.15,
		"specular_power": 90.0, "specular_strength": 1.2, "sheen_strength": 0.15,
		"dome_strength": 0.6, "dome_highlight": 0.32, "dome_power": 22.0,
	},
	Preset.MEMBRANE: {
		"goo_opacity": 0.34, "rim_width": 24.0, "rim_strength": 1.0, "rim_density": 0.3,
		"refraction_px": 22.0, "cell_refraction_px": 1.0,
		"wall_width": 1.5, "wall_strength": 0.12, "wall_softness": 1.5, "wall_highlight": 0.0, "wall_rim_fade": 1.0,
		"border_sharpness": 2.5, "membrane_width": 7.0, "membrane_strength": 0.55, "cloud": 0.35,
		"bubble_density": 0.15, "bubble_strength": 0.7,
		"shade_depth": 50.0, "shade_strength": 0.12, "side_light": 0.25,
		"specular_power": 70.0, "specular_strength": 1.6, "sheen_strength": 0.3,
		"dome_strength": 0.1, "dome_highlight": 0.04, "dome_power": 16.0,
	},
}

## The preset named `preset_name` ("faint", "cellular", "membrane"; case ignored), or -1.
static func preset_named(preset_name: String) -> int:
	match preset_name.to_lower():
		"faint", "a":
			return Preset.FAINT
		"cellular", "b":
			return Preset.CELLULAR
		"membrane", "c":
			return Preset.MEMBRANE
		"custom":
			return Preset.CUSTOM
	return -1

## Puts `preset`'s uniforms, then `overrides` (uniform name -> value), on `material` (a
## ShaderMaterial; anything else is left alone). CUSTOM puts only the overrides.
static func apply(material: Material, preset: Preset, overrides: Dictionary = {}) -> void:
	var m := material as ShaderMaterial
	if m == null:
		return
	if PRESETS.has(preset):
		var values: Dictionary = PRESETS[preset]
		for key: String in values:
			m.set_shader_parameter(key, values[key])
	for key: String in overrides:
		m.set_shader_parameter(key, overrides[key])
