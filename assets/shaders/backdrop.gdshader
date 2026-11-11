// Backdrop behind the playfield: a dark vertical gradient with a vignette and a
// faint dot grid, so the goo shader's refraction has detail to bend. Drawn by
// the Backdrop ColorRect, the first child of scenes/main.tscn.
shader_type canvas_item;

uniform vec3 top_colour : source_color = vec3(0.10, 0.10, 0.17);
uniform vec3 bottom_colour : source_color = vec3(0.04, 0.035, 0.07);
uniform vec3 dot_colour : source_color = vec3(0.42, 0.45, 0.62);
uniform vec3 line_colour : source_color = vec3(0.30, 0.32, 0.46);
// Grid spacing in px, dot radius in px, and how much they show.
uniform float spacing : hint_range(4.0, 128.0) = 28.0;
uniform float dot_radius : hint_range(0.5, 16.0) = 2.4;
uniform float dot_strength : hint_range(0.0, 1.0) = 0.7;
uniform float line_strength : hint_range(0.0, 1.0) = 0.22;
uniform float vignette : hint_range(0.0, 2.0) = 0.85;

varying vec2 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy;
}

void fragment() {
	vec3 col = mix(top_colour, bottom_colour, UV.y);
	// Grid in world pixels, so it stays square whatever the rect's aspect.
	vec2 cell = world_pos / spacing;
	vec2 f = fract(cell) - 0.5;
	float d = length(f) * spacing;
	float dots = 1.0 - smoothstep(dot_radius - 0.75, dot_radius + 0.75, d);
	// Grid lines run along the cell borders, between the dots.
	vec2 to_line = (0.5 - abs(f)) * spacing;
	float lines = 1.0 - smoothstep(0.0, 1.0, min(to_line.x, to_line.y));
	// Every fourth line a little brighter, for some larger-scale structure.
	vec2 major = (0.5 - abs(fract(cell / 4.0) - 0.5)) * spacing * 4.0;
	float major_lines = 1.0 - smoothstep(0.0, 1.2, min(major.x, major.y));
	col = mix(col, line_colour, lines * line_strength + major_lines * line_strength * 0.8);
	col = mix(col, dot_colour, dots * dot_strength);
	vec2 v = UV - 0.5;
	col *= clamp(1.0 - dot(v, v) * vignette * 1.6, 0.0, 1.0);
	COLOR = vec4(col, 1.0);
}
