// The goo skin of GooCellWorld2D's creatures (docs/cells.md, "Drawing"): the same wet,
// translucent goo as the ring bodies' addons/goo2d/goo.gdshader (its tint handling, rim,
// fresnel, refraction of what is behind it), faintly honeycombed by the cells' walls, the
// types' colours blended softly where they meet, then a light stage on top (thickness,
// light from one side, a soft specular highlight, a faint dome per cell). Everything is
// fixed in the creature's material: it rides the cells as they bend, turn and swim.
//
// Two stages in one pass. base() is the goo (what the ring goo draws, made of the
// fields below); lit() adds the light. They are two functions, not two draws: the light
// needs only the per-fragment fields (the normal, the thickness, the cell), which this
// pass already has, so a second draw would hand the whole mesh over twice and need a
// back buffer copy for nothing. GooCellLook's presets are uniform sets of this shader.
//
// The mesh's contract (cells_draw.rs, creature_mesh_goo(); GooCellWorld2D draws it when
// skin_mesh is GOO, the default):
//   each triangle names three cells, the same on its three corners:
//     COLOR.xyz = their indices into `cell_table` (global over the world's creatures);
//                 a rim fan's third index is −(index + 1): its types blend along the two
//                 links from its first cell (a projection) instead of barycentrically
//     COLOR.w   = the distance to the creature's outline, px (0 on the skin)
//     UV        = the outward direction (toward the outline's nearest point; the skin
//                 curve's normal on it), not normalised after interpolation
//   the vertices are the mesh's own coordinates (the cells' positions, global px).
// Uniforms the world sets (a replacement may declare any of them):
//   uniform sampler2D cell_table;   // RGBA float, TABLE_COLUMNS cells a row, two texels
//                                   // a cell: (x, y, radius, turn), (type slot, seed
//                                   // 0..1 (from the cell's uid), distance to the outline
//                                   // px, 1 on the outline)
//   uniform vec4 type_color[16];    // each slot's GooCellType.color
//   uniform vec4 type_wall[16];     // each slot's wall_color (alpha 0: the tint, darker)
//   uniform vec4 type_look[16];     // each slot's (wall_strength, dome, gloss, opacity)
//   uniform float length_unit;      // GooTuning.unit: the look's lengths are px at unit 1
// Every other uniform is the look (GooCellLook.PRESETS; lengths in px at unit 1).
shader_type canvas_item;

uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap, repeat_disable;
uniform sampler2D cell_table : filter_nearest, repeat_disable;
const int TABLE_COLUMNS = 512;

uniform vec4 type_color[16];
uniform vec4 type_wall[16];
uniform vec4 type_look[16];
uniform float length_unit = 1.0;

// --- The goo (base) ---
// The goo's own colour over what is seen through it (goo.gdshader's goo_opacity).
uniform float goo_opacity : hint_range(0.0, 1.0) = 0.3;
// The rim: px over which the surface rolls off to edge-on, its fresnel glow.
uniform float rim_width : hint_range(1.0, 64.0) = 16.0;
uniform float rim_strength : hint_range(0.0, 2.0) = 0.85;
uniform float fresnel_power : hint_range(0.5, 8.0) = 2.2;
// How much darker and denser the goo is toward the rim (goo.gdshader's 0.35).
uniform float rim_density : hint_range(0.0, 1.0) = 0.35;
// The background seen through the goo: displaced at the rim (screen px at unit 1), and
// through each cell's dome a little.
uniform float refraction_px : hint_range(0.0, 64.0) = 18.0;
uniform float cell_refraction_px : hint_range(0.0, 16.0) = 2.0;
// The cell walls: width (px), how dark (0 none), their soft edge (px).
uniform float wall_width : hint_range(0.0, 8.0) = 1.5;
uniform float wall_strength : hint_range(0.0, 1.0) = 0.2;
uniform float wall_softness : hint_range(0.0, 8.0) = 1.0;
// A wall's light side: a thin bright line beside it toward the light (0 none).
uniform float wall_highlight : hint_range(0.0, 1.0) = 0.0;
// Walls fade out within the rim (0: they reach the skin, 1: gone at the skin).
uniform float wall_rim_fade : hint_range(0.0, 1.0) = 0.5;
// Two types' colours blend over their border: 1 a gradient across a whole triangle of
// cells, higher sharper (the border stays a smooth curve).
uniform float border_sharpness : hint_range(1.0, 12.0) = 3.0;
// An outer membrane: a denser band of this width (px) inside the skin (0 none).
uniform float membrane_width : hint_range(0.0, 32.0) = 0.0;
uniform float membrane_strength : hint_range(0.0, 1.0) = 0.0;
// The inside clouded (milky) with depth, each cell a little different (0 clear).
uniform float cloud : hint_range(0.0, 1.0) = 0.0;
// Bubbles fixed in the cells: a share of cells holding one (0 none).
uniform float bubble_density : hint_range(0.0, 1.0) = 0.12;
uniform float bubble_strength : hint_range(0.0, 2.0) = 0.6;

// --- The light (lit) ---
uniform vec3 light_dir = vec3(-0.55, -0.7, 0.75);
// Depth (px) over which the creature thickens from its skin; how much darker and denser
// it gets there; how strongly that thickness is lit from the light's side.
uniform float shade_depth : hint_range(1.0, 200.0) = 40.0;
uniform float shade_strength : hint_range(0.0, 1.0) = 0.2;
uniform float side_light : hint_range(0.0, 1.0) = 0.2;
// The surface's specular highlight (goo.gdshader's) and a broad sheen.
uniform float specular_power : hint_range(1.0, 512.0) = 90.0;
uniform float specular_strength : hint_range(0.0, 3.0) = 1.4;
uniform float sheen_strength : hint_range(0.0, 1.0) = 0.22;
// Each cell a faint dome: how far its surface tilts (bending the light and the rim's
// normal), and the small highlight it catches.
uniform float dome_strength : hint_range(0.0, 2.0) = 0.2;
uniform float dome_highlight : hint_range(0.0, 1.0) = 0.08;
uniform float dome_power : hint_range(1.0, 128.0) = 18.0;

varying vec2 v_pos;
varying flat vec3 v_cells;
varying float v_dist;
varying vec2 v_out;

void vertex() {
	v_pos = VERTEX;
	v_cells = COLOR.xyz;
	v_dist = COLOR.w;
	v_out = UV;
}

float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

vec2 hash22(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * vec3(0.1031, 0.1030, 0.0973));
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.xx + p3.yz) * p3.zy);
}

ivec2 texel(int i, int k) {
	return ivec2((i % TABLE_COLUMNS) * 2 + k, i / TABLE_COLUMNS);
}

// What a fragment knows of its cells (cells_at()).
struct Cells {
	int owner;         // 0..2: the cell it lies in
	float wall;        // px to that cell's nearest wall among the other two
	float wall_lit;    // the same, the light's side of the wall (wall_highlight)
	vec3 weight;       // the three cells' share of the types' blend (sharpened)
	vec2 local;        // its place in the owner cell, turned with the cell, / radius
	vec2 offset;       // the same unturned (for the light), / radius
	float seed;        // the owner's seed
	float radius;      // the owner's radius px
	ivec3 type;        // the three cells' type slots
};

Cells cells_at(vec2 p, vec2 light2) {
	bool rim = v_cells.z < 0.0;
	ivec3 id = ivec3(int(round(v_cells.x)), int(round(v_cells.y)), int(round(rim ? -v_cells.z - 1.0 : v_cells.z)));
	vec2 c[3];
	float r[3];
	float th[3];
	float sd[3];
	ivec3 ty;
	for (int k = 0; k < 3; k++) {
		vec4 a = texelFetch(cell_table, texel(id[k], 0), 0);
		vec4 b = texelFetch(cell_table, texel(id[k], 1), 0);
		c[k] = a.xy;
		r[k] = a.z;
		th[k] = a.w;
		ty[k] = int(round(b.x));
		sd[k] = b.y;
	}
	Cells o;
	o.type = ty;
	// The power diagram: the fragment is in the cell of least |p − c|² − r².
	float pw[3];
	for (int k = 0; k < 3; k++) {
		vec2 d = p - c[k];
		pw[k] = dot(d, d) - r[k] * r[k];
	}
	int w = 0;
	if (pw[1] < pw[w]) { w = 1; }
	if (pw[2] < pw[w]) { w = 2; }
	o.owner = w;
	o.wall = 1e6;
	o.wall_lit = 1e6;
	for (int k = 0; k < 3; k++) {
		vec2 e = c[k] - c[w];
		float l = length(e);
		if (k == w || l < 1e-3) {
			continue;
		}
		float dist = (pw[k] - pw[w]) / (2.0 * l);
		o.wall = min(o.wall, dist);
		// The wall's lit face: the side of the wall facing the light, inside the owner.
		if (dot(e / l, light2) > 0.0) {
			o.wall_lit = min(o.wall_lit, dist);
		}
	}
	// The types' blend: barycentric among the three cells; a rim fan along its links.
	vec3 lam;
	if (!rim) {
		vec2 v0 = c[1] - c[0];
		vec2 v1 = c[2] - c[0];
		vec2 v2 = p - c[0];
		float den = v0.x * v1.y - v1.x * v0.y;
		if (abs(den) < 1e-6) {
			lam = vec3(1.0, 0.0, 0.0);
		} else {
			float l1 = (v2.x * v1.y - v1.x * v2.y) / den;
			float l2 = (v0.x * v2.y - v2.x * v0.y) / den;
			lam = max(vec3(1.0 - l1 - l2, l1, l2), vec3(0.0));
		}
	} else {
		vec2 q = p - c[0];
		vec2 eb = c[1] - c[0];
		vec2 ec = c[2] - c[0];
		float sb = id[1] == id[0] ? 0.0 : clamp(dot(q, eb) / max(dot(eb, eb), 1e-6), 0.0, 1.0);
		float sc = id[2] == id[0] || id[2] == id[1] ? 0.0 : clamp(dot(q, ec) / max(dot(ec, ec), 1e-6), 0.0, 1.0);
		lam = vec3(max(1.0 - sb - sc, 0.0), sb, sc);
	}
	lam /= max(lam.x + lam.y + lam.z, 1e-6);
	// One share per distinct type, sharpened, so the border is a smooth curve whose
	// softness border_sharpness sets.
	if (ty.y == ty.x) { lam.x += lam.y; lam.y = 0.0; }
	if (ty.z == ty.x) { lam.x += lam.z; lam.z = 0.0; }
	else if (ty.z == ty.y) { lam.y += lam.z; lam.z = 0.0; }
	lam = pow(lam, vec3(border_sharpness));
	o.weight = lam / max(lam.x + lam.y + lam.z, 1e-9);
	vec2 d = (p - c[w]) / max(r[w], 1e-3);
	o.offset = d;
	float cs = cos(th[w]);
	float sn = sin(th[w]);
	o.local = vec2(cs * d.x + sn * d.y, cs * d.y - sn * d.x);
	o.seed = sd[w];
	o.radius = r[w];
	return o;
}

// The base: what the ring goo draws, from the fields.
vec3 base(vec3 bg, vec3 tint, vec3 wall_colour, vec4 look, Cells cl, float d, float e, float wall_mask, vec4 bubble) {
	vec3 transmitted = bg * mix(vec3(1.0), tint, 0.4) * 1.6;
	vec3 body = mix(transmitted, tint, clamp(goo_opacity * look.w, 0.0, 1.0));
	// Thicker goo toward the rim reads darker and more saturated.
	body = mix(body, tint * 0.55, rim_density * pow(e, 1.5));
	// The membrane: a denser band just inside the skin.
	float mw = membrane_width * length_unit;
	if (mw > 0.0) {
		float band = 1.0 - smoothstep(mw * 0.5, mw, d);
		body = mix(body, tint * 0.5 + bg * 0.15, membrane_strength * band);
	}
	// Clouded inside: milky with depth, each cell its own a little.
	if (cloud > 0.0) {
		float depth = smoothstep(0.0, shade_depth * length_unit, d);
		float own = 0.75 + 0.5 * cl.seed;
		body = mix(body, mix(tint, vec3(1.0), 0.3), cloud * depth * own * (1.0 - 0.35 * dot(cl.offset, cl.offset)));
	}
	// The walls.
	body = mix(body, wall_colour, clamp(wall_strength * look.x * wall_mask, 0.0, 1.0));
	// A bubble: a lens of its own, lighter inside.
	body = mix(body, mix(body, vec3(1.0), 0.35) + tint * 0.1, bubble.y * 0.45 * bubble_strength);
	return body;
}

// The light stage, over the base.
vec3 lit(vec3 body, vec3 tint, vec4 look, Cells cl, vec3 n, vec3 n_body, vec3 n_cell, float thick, float wall_lit_mask, vec4 bubble) {
	vec3 L = normalize(light_dir);
	vec3 H = normalize(L + vec3(0.0, 0.0, 1.0));
	// Thickness: darker and denser toward the middle, lit from the light's side.
	body *= 1.0 - shade_strength * thick;
	float side = dot(n_body, L) - L.z;
	body *= 1.0 + side_light * 2.0 * side;
	// Each cell's dome: its lit side a little lighter, its far side a little darker.
	body *= 1.0 + 0.8 * (dot(n_cell, L) - L.z);
	vec3 rim_colour = mix(tint, vec3(1.0), 0.65);
	float fresnel = pow(1.0 - clamp(n.z, 0.0, 1.0), fresnel_power) * rim_strength;
	float gloss = look.z;
	float spec = pow(max(dot(n, H), 0.0), specular_power) * specular_strength * gloss;
	float sheen = pow(max(dot(n_body, H), 0.0), 12.0) * sheen_strength;
	float dome = pow(max(dot(n_cell, H), 0.0), dome_power) * dome_highlight * look.y * gloss;
	float bubble_light = (bubble.x * 0.55 + bubble.z * 0.9) * bubble_strength;
	return body + rim_colour * fresnel + vec3(spec) + vec3(sheen) * mix(tint, vec3(1.0), 0.6)
		+ mix(tint, vec3(1.0), 0.7) * (dome + wall_highlight * wall_lit_mask)
		+ mix(tint, vec3(1.0), 0.75) * bubble_light;
}

// A cell's bubble, fixed in it: x = ring, y = inside, z = glint.
vec4 bubble_in(Cells cl, float d, vec2 glint_dir) {
	if (bubble_density <= 0.0 || hash12(vec2(cl.seed * 917.0, 3.1)) > bubble_density) {
		return vec4(0.0);
	}
	vec2 rnd = hash22(vec2(cl.seed * 613.0, 9.7));
	float br = mix(0.16, 0.3, rnd.x);
	vec2 at = (hash22(vec2(cl.seed * 271.0, 1.3)) - 0.5) * 2.0 * (0.7 - br);
	vec2 dp = (cl.local - at) * cl.radius;
	float rpx = br * cl.radius;
	float dist = length(dp);
	float ring = 1.0 - smoothstep(0.0, 1.0, abs(dist - rpx));
	float inner = 1.0 - smoothstep(rpx - 1.0, rpx, dist);
	float glint = 1.0 - smoothstep(0.0, max(rpx * 0.35, 0.7), length(dp + glint_dir * rpx * 0.5));
	float inside = smoothstep(rpx + 1.0, rpx + 4.0, d);
	return vec4(ring, inner, glint, 0.0) * inside;
}

void fragment() {
	vec2 p = v_pos;
	vec3 L = normalize(light_dir);
	vec2 light2 = length(L.xy) > 1e-4 ? normalize(L.xy) : vec2(0.0, -1.0);
	Cells cl = cells_at(p, light2);
	vec3 wt = cl.weight;
	vec4 tint4 = type_color[cl.type.x] * wt.x + type_color[cl.type.y] * wt.y + type_color[cl.type.z] * wt.z;
	vec4 look = type_look[cl.type.x] * wt.x + type_look[cl.type.y] * wt.y + type_look[cl.type.z] * wt.z;
	vec3 tint = tint4.rgb;
	vec4 wall_set = type_wall[cl.type.x] * wt.x + type_wall[cl.type.y] * wt.y + type_wall[cl.type.z] * wt.z;
	vec3 wall_colour = mix(tint * 0.45, wall_set.rgb / max(wall_set.a, 1e-4), clamp(wall_set.a, 0.0, 1.0));

	float d = max(v_dist, 0.0);
	vec2 outward = length(v_out) > 1e-5 ? normalize(v_out) : vec2(0.0, -1.0);
	float rim_w = max(rim_width * length_unit, 0.5);
	float e = 1.0 - clamp(d / rim_w, 0.0, 1.0);
	vec3 n_rim = normalize(vec3(outward * e, sqrt(max(1.0 - e * e, 0.0))));
	// Each cell's dome: its surface tilted away from its centre.
	// (The surface's own highlight and fresnel stay on the rim's normal: a dome tilt there
	// breaks the highlight into one dash per cell.)
	float tilt = dome_strength * look.y;
	vec3 n_cell = normalize(vec3(cl.offset * tilt, 1.0));
	vec3 n = n_rim;
	// The body's thickness and its broad normal.
	float thick = smoothstep(0.0, shade_depth * length_unit, d);
	vec3 n_body = normalize(vec3(outward * (1.0 - thick) * 0.8, 1.0));

	// Refraction: the rim's lens, the body's, and each cell's dome a little.
	vec2 offset = -n_rim.xy * refraction_px * length_unit * (1.0 - n_rim.z);
	offset -= outward * refraction_px * length_unit * 0.35 * (1.0 - thick);
	offset -= cl.offset * cell_refraction_px * length_unit;
	vec2 glint_dir = -light2 * 0.6;
	vec4 bubble = bubble_in(cl, d, glint_dir);
	vec3 bg = textureLod(screen_tex, SCREEN_UV + offset * SCREEN_PIXEL_SIZE, 0.35).rgb;
	if (bubble.y > 0.0) {
		bg = mix(bg, textureLod(screen_tex, SCREEN_UV + (offset + vec2(2.0) * length_unit) * SCREEN_PIXEL_SIZE, 0.0).rgb, bubble.y);
	}

	// The walls, a constant width in px, fading within the rim.
	float half_w = 0.5 * wall_width * length_unit;
	float aa = max(fwidth(cl.wall), 1e-3);
	float soft = max(wall_softness * length_unit, aa);
	float wall_mask = 1.0 - smoothstep(half_w, half_w + soft, cl.wall);
	wall_mask *= 1.0 - wall_rim_fade * e;
	float lit_mask = 0.0;
	if (wall_highlight > 0.0) {
		float x = cl.wall_lit - half_w - soft;
		lit_mask = (1.0 - smoothstep(0.0, soft + aa, abs(x - soft))) * (1.0 - wall_rim_fade * e);
	}

	vec3 body = base(bg, tint, wall_colour, look, cl, d, e, wall_mask, bubble);
	vec3 col = lit(body, tint, look, cl, n, n_body, n_cell, thick, lit_mask, bubble);
	// The silhouette: a pixel's antialiased fade at the skin (the triangles have none).
	float edge = clamp(d / max(fwidth(d), 1e-3), 0.0, 1.0);
	COLOR = vec4(col, tint4.a * edge);
}
