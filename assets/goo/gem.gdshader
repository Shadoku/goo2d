// A faceted gem for a Goo2D skin. The body is cut into facets: a hashed
// Voronoi pattern in polar coordinates around `center`, scaled by `radius`
// (a ring of crown facets about `facet_size` of the radius each, around an
// octagonal table cut the same way at its own scale). Every facet is a flat plane with its own random tilt,
// lit by `light_dir` with a sharp specular and a fresnel edge; the body colour
// (COLOR) deepens toward the rim; each facet shows the screen behind it through
// its own refraction offset, so neighbouring facets show different slices of
// the backdrop; and a facet whose reflection lines up with the light sparkles,
// which happens as the body moves: its `velocity` nudges every tilt.
//
// Uses the skin's uniforms point_count, points, center, radius, velocity, rotation and
// seed, and a two-tone body's second_color, division_axis and division_offset,
// mixed as goo.gdshader mixes them (see the contract at the top of
// addons/goo2d/goo.gdshader); its
// signed-distance block is the goo shader's. The polygon's antialiased edge is
// the silhouette; the shader never cuts alpha.
shader_type canvas_item;

uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap, repeat_disable;

// Per body (GooSkin.update()).
uniform int point_count = 0;
uniform vec2 points[32];
uniform vec2 center = vec2(0.0);
uniform float radius = 32.0;
uniform vec2 velocity = vec2(0.0);
// How far the body has turned from its rest pose (Goo2D.ring_rotation()):
// the facets are laid out in the rest pose and turned by this, so they ride
// with a rolling or tipping body instead of staying fixed around its centre.
uniform float rotation = 0.0;
uniform float seed = 0.0;
// A two-tone body's second colour (transparent black: none) and its division,
// fixed in the body's rest space (GooSkin.set_two_tone()).
uniform vec4 second_color : source_color = vec4(0.0);
uniform vec2 division_axis = vec2(1.0, 0.0);
uniform float division_offset = 0.0;

// Look.
// Width, in px, over which a two-tone body's colours fade into each other.
uniform float division_fade : hint_range(0.0, 64.0) = 10.0;
// Light direction in screen space (y down) with z toward the viewer.
uniform vec3 light_dir = vec3(-0.55, -0.7, 0.75);
// A facet's size as a share of the radius, about: the pattern fits a whole
// number of facets around the body, so every gem has the same cut.
uniform float facet_size : hint_range(0.08, 0.8) = 0.36;
// The flat table in the middle, as a share of the radius.
uniform float table_size : hint_range(0.0, 0.8) = 0.34;
// How much the facets tilt: outward (the crown's slope) and at random.
uniform float crown_slope : hint_range(0.0, 2.0) = 0.9;
uniform float tilt_jitter : hint_range(0.0, 1.0) = 0.45;
// How far the velocity (at 600 px/s) and time turn the tilts.
uniform float motion_tilt : hint_range(0.0, 1.0) = 0.4;
uniform float shimmer : hint_range(0.0, 0.3) = 0.07;
uniform float specular_power : hint_range(4.0, 512.0) = 60.0;
uniform float fresnel_power : hint_range(0.5, 8.0) = 3.0;
// Screen refraction per facet, px.
uniform float refraction_px : hint_range(0.0, 64.0) = 14.0;
// How much of the stone's own colour covers what shows through.
uniform float opacity : hint_range(0.0, 1.0) = 0.64;
// How much more saturated than the body colour the stone is.
uniform float saturation : hint_range(0.0, 3.0) = 1.6;
// Width of the lines between facets, in cell units.
uniform float edge_width : hint_range(0.0, 0.2) = 0.012;
// How close to the light a facet's reflection must turn to sparkle.
uniform float sparkle_threshold : hint_range(0.9, 1.0) = 0.98;

// Rings of pavilion facets seen through the table.
const float TABLE_RINGS = 1.2;

varying vec2 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy;
}

// Hashes without sin() (Dave Hoskins), stable on GLES3 / llvmpipe (copied from
// goo.gdshader).
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

// Where the facet site of cell `id` sits, in cell units; the x of the cell id
// wraps around the body every `around` cells. `layer` tells the table's cells
// from the crown's.
vec2 site(vec2 id, float around, float layer) {
	vec2 key = vec2(mod(id.x, around), id.y + layer);
	return id + 0.5 + (hash22(key + seed * 7.13) - 0.5) * 0.8;
}

// The facet `uv` (cell units) lies in: xy the facet's site (its cell is
// floor(site)), z the distance to the facet's border, in cell units.
vec3 facet(vec2 uv, float around, float layer) {
	vec2 cell = floor(uv);
	vec2 nearest = vec2(0.0);
	float best = 1e9;
	for (int gy = -1; gy <= 1; gy++) {
		for (int gx = -1; gx <= 1; gx++) {
			vec2 s = site(cell + vec2(float(gx), float(gy)), around, layer);
			float dd = dot(s - uv, s - uv);
			if (dd < best) {
				best = dd;
				nearest = s;
			}
		}
	}
	float border = 1e9;
	for (int gy = -2; gy <= 2; gy++) {
		for (int gx = -2; gx <= 2; gx++) {
			vec2 s = site(cell + vec2(float(gx), float(gy)), around, layer);
			vec2 diff = s - nearest;
			if (dot(diff, diff) > 1e-6) {
				border = min(border, dot((nearest + s) * 0.5 - uv, normalize(diff)));
			}
		}
	}
	return vec3(nearest, border);
}

// The body's colour at `p` (global px): `primary` (COLOR), or for a two-tone
// body (second_color's alpha above 0) `primary` on one side of the division
// and second_color on the other, faded into each other over division_fade px.
// The division is a straight line in the body's rest space: `p` is turned back
// by `rotation` about `center`, then measured along division_axis (toward the
// second colour's side) from division_offset.
vec3 two_tone(vec2 p, vec3 primary) {
	if (second_color.a <= 0.0) {
		return primary;
	}
	vec2 d = p - center;
	float rc = cos(rotation);
	float rs = sin(rotation);
	vec2 rest = vec2(rc * d.x + rs * d.y, rc * d.y - rs * d.x);
	float across = dot(rest, division_axis) - division_offset;
	float half_fade = max(division_fade, 0.001) * 0.5;
	return mix(primary, second_color.rgb, smoothstep(-half_fade, half_fade, across));
}

void fragment() {
	vec2 p = world_pos;

	// Signed distance to the outline (positive inside) and a smoothed outward
	// normal: each edge's normal weighted by how close it is (online soft-min).
	// The same block as goo.gdshader's.
	float d_min = 1e9;
	float area2 = 0.0;
	bool inside = false;
	vec2 normal_sum = vec2(0.0);
	const float SOFT = 3.0;
	for (int i = 0; i < 32; i++) {
		if (i >= point_count) {
			break;
		}
		int j = (i + 1 == point_count) ? 0 : i + 1;
		vec2 a = points[i];
		vec2 b = points[j];
		vec2 ab = b - a;
		vec2 ap = p - a;
		float h = clamp(dot(ap, ab) / max(dot(ab, ab), 1e-6), 0.0, 1.0);
		float dist = length(ap - ab * h);
		vec2 edge_normal = normalize(vec2(ab.y, -ab.x) + vec2(1e-6));
		if (dist < d_min) {
			normal_sum *= exp((dist - d_min) / SOFT);
			d_min = dist;
		}
		normal_sum += edge_normal * exp((d_min - dist) / SOFT);
		area2 += a.x * b.y - b.x * a.y;
		if ((a.y > p.y) != (b.y > p.y)) {
			float x = a.x + (p.y - a.y) * ab.x / ab.y;
			if (p.x < x) {
				inside = !inside;
			}
		}
	}
	vec2 outward = normal_sum * (area2 >= 0.0 ? 1.0 : -1.0);
	outward = length(outward) > 1e-5 ? normalize(outward) : vec2(0.0, -1.0);
	float sd = point_count >= 3 ? (inside ? d_min : -d_min) : radius;

	// Polar cell coordinates around the centre. The crown: x around the body
	// (a whole number of facets, so the pattern closes), y outward from the
	// table's edge, both in facets. The table, an octagon in the middle, is cut
	// the same way at its own scale: the pavilion's facets seen through it.
	float r = max(radius, 1.0);
	// Into the body's rest pose: the cut is fixed there and turns with it.
	float rc = cos(rotation);
	float rs = sin(rotation);
	vec2 d = p - center;
	vec2 rel = vec2(rc * d.x + rs * d.y, rc * d.y - rs * d.x);
	float rho = length(rel) / r;
	float theta = atan(rel.y, rel.x);
	float oct_theta = floor(theta / 0.7854 + 0.5) * 0.7854;
	float oct_rho = rho * cos(theta - oct_theta) / cos(0.3927);
	bool on_table = oct_rho < table_size;
	float around = on_table ? 8.0 : max(floor(6.2831 * 0.62 / facet_size + 0.5), 5.0);
	vec2 uv = on_table
		? vec2((theta / 6.2831 + 0.5) * around, oct_rho / max(table_size, 1e-3) * TABLE_RINGS)
		: vec2((theta / 6.2831 + 0.5) * around, (oct_rho - table_size) / facet_size);
	float layer = on_table ? 101.0 : 0.0;
	vec3 f = facet(uv, around, layer);
	vec2 cell = floor(f.xy);
	vec2 facet_key = vec2(mod(cell.x, around), cell.y + layer) + seed * 3.7;
	// Border with the other part (crown / table), in the same cell units.
	float table_border = abs(oct_rho - table_size) / (on_table ? max(table_size, 1e-3) / TABLE_RINGS : facet_size);
	float border = min(f.z, table_border);

	// The facet's site and its plane: a crown facet slopes outward, a pavilion
	// facet seen through the table inward; both tilted at random and turned by
	// the motion and a slow shimmer.
	float site_theta = (f.x / around - 0.5) * 6.2831;
	float site_rho = on_table ? f.y / TABLE_RINGS * table_size : table_size + f.y * facet_size;
	// The site's direction back in world space (lighting and the glint are
	// world-space; only the cut is in the rest pose).
	vec2 site_dir = vec2(cos(site_theta + rotation), sin(site_theta + rotation));
	vec2 rnd = hash22(facet_key) - 0.5;
	float phase = hash12(facet_key + 4.2) * 6.2831;
	vec2 tilt = on_table
		? -site_dir * 0.35 + rnd * 2.0 * tilt_jitter
		: site_dir * crown_slope * clamp(site_rho, 0.0, 1.2) + rnd * 2.0 * tilt_jitter;
	vec2 v = velocity / 600.0;
	tilt += (v + vec2(-v.y, v.x) * rnd.x * 2.0) * motion_tilt;
	tilt += vec2(sin(TIME * 0.9 + phase), cos(TIME * 0.7 + phase * 1.3)) * shimmer;
	vec3 n = normalize(vec3(tilt, 1.0));
	vec3 L = normalize(light_dir);
	vec3 H = normalize(L + vec3(0.0, 0.0, 1.0));

	// What shows through: the backdrop, one offset per facet.
	vec2 offset = (rnd * 2.0 + n.xy * 0.5) * refraction_px;
	vec3 bg = textureLod(screen_tex, SCREEN_UV + offset * SCREEN_PIXEL_SIZE, 0.0).rgb;

	// The stone's colour: the body colour, more saturated, deepening toward the
	// rim (thicker stone seen at a slant).
	vec3 tint = two_tone(p, COLOR.rgb);
	float luma = dot(tint, vec3(0.299, 0.587, 0.114));
	vec3 stone = clamp(mix(vec3(luma), tint, saturation), 0.0, 1.0);
	float depth = 1.0 - clamp(sd / (r * 0.75), 0.0, 1.0);
	vec3 deep = stone * mix(1.15, 0.5, depth * depth);
	vec3 transmitted = bg * mix(vec3(1.0), stone, 0.8) * 1.5;

	// Each facet lit flat: diffuse (with a little light bouncing inside that
	// differs from facet to facet), a sharp specular, a fresnel edge.
	float diffuse = clamp(dot(n, L), 0.0, 1.0);
	float inner = hash12(facet_key + 9.1);
	float facing = dot(n, H);
	float spec = pow(max(facing, 0.0), specular_power);
	float fresnel = pow(1.0 - n.z, fresnel_power);
	float lit = 0.06 + 1.5 * diffuse * diffuse + 0.3 * inner;
	vec3 col = mix(transmitted, deep * lit, opacity);
	col += mix(stone, vec3(1.0), 0.6) * fresnel * 0.8;
	col += vec3(spec) * 0.85;

	// Lines between facets: a pale ridge where the edge faces the light, a
	// dark groove otherwise, a little under a pixel soft.
	float aa = max(fwidth(border), 1e-4);
	float ridge = 1.0 - smoothstep(edge_width, edge_width + aa, border);
	float ridge_light = clamp(dot(site_dir, -normalize(L.xy)) * (on_table ? -0.5 : 0.5) + 0.5, 0.0, 1.0);
	col = mix(col, mix(deep * 0.2, mix(stone, vec3(1.0), 0.7), ridge_light), ridge * 0.55);

	// Sparkle: the facet flares when its reflection lines up with the light,
	// with a four-pointed glint on its site.
	float flare = smoothstep(sparkle_threshold, 1.0, facing);
	vec2 site_px = center + site_dir * site_rho * r;
	vec2 g = (p - site_px) / max(facet_size * r * 0.55, 4.0);
	float star = max(0.0, 1.0 - abs(g.x) * 9.0 - abs(g.y) * 0.9)
		+ max(0.0, 1.0 - abs(g.y) * 9.0 - abs(g.x) * 0.9);
	star += max(0.0, 1.0 - length(g) * 3.0);
	col += vec3(1.0) * flare * (0.35 + 1.3 * min(star, 1.0));

	// A bright, thin fresnel line just inside the outline.
	float edge = 1.0 - smoothstep(0.0, 3.0, sd);
	col = mix(col, mix(stone, vec3(1.0), 0.75), edge * 0.65);

	COLOR = vec4(col, COLOR.a);
}
