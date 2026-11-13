// The default skin of GooCellWorld2D's creatures (docs/cells.md, "Drawing"): flat, each
// type's colour, a darker band along the skin and a little shading toward it.
//
// The contract a replacement may use (GooCellWorld2D.skin_material): the mesh is
// triangles; COLOR is the cell type's colour (GooCellType.color); UV.x is 1 at the cells'
// centres and everywhere inside the outline cells, falling to 0 on the skin (about one
// cell radius); UV.y is the type's kernel slot / 16.
shader_type canvas_item;

// The skin's edge.
uniform vec4 edge_color : source_color = vec4(0.04, 0.07, 0.06, 1.0);
// The edge band, in UV.x (a fraction of an outline cell's radius).
uniform float edge_width : hint_range(0.0, 1.0) = 0.22;
// How much darker the body gets toward the skin.
uniform float shade : hint_range(0.0, 1.0) = 0.25;

void fragment() {
	float inside = clamp(UV.x, 0.0, 1.0);
	vec3 body = COLOR.rgb * (1.0 - shade * (1.0 - inside));
	float band = smoothstep(edge_width * 0.5, edge_width, inside);
	COLOR = vec4(mix(edge_color.rgb, body, band), COLOR.a);
}
