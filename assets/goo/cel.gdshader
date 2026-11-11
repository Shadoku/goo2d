// Cel-shaded goo for a Goo2D skin: solid body colour (COLOR, no screen texture)
// lit in three flat bands, a hard specular dot, a dark ink outline at the rim
// and a soft shadow band on the side away from the light. The band edges
// wobble faintly with TIME and the body's velocity, so it reads as goo rather
// than plastic.
//
// The normal is the goo shader's pseudo-3D rim normal (the same signed-distance
// block as addons/goo2d/goo.gdshader), rolled off over a rim that scales with
// the body so the whole body is a soft pillow, plus a faint dome from the
// centre. Uses the skin's uniforms point_count, points, center, radius,
// velocity and seed, and a two-tone body's rotation, second_color,
// division_axis and division_offset, mixed as goo.gdshader mixes them (see the
// contract at the top of goo.gdshader). The
// polygon's antialiased edge is the silhouette; the shader never cuts alpha.
shader_type canvas_item;

// Per body (GooSkin.update()).
uniform int point_count = 0;
uniform vec2 points[32];
uniform vec2 center = vec2(0.0);
uniform float radius = 32.0;
uniform vec2 velocity = vec2(0.0);
uniform float seed = 0.0;
// How far the body has turned from its rest pose (Goo2D.ring_rotation()): a
// two-tone body's division is fixed in the rest pose and turned by this.
uniform float rotation = 0.0;
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
// How far in from the outline the pillow rolls flat, as a share of the radius.
uniform float pillow : hint_range(0.1, 1.0) = 0.62;
// Diffuse thresholds between shadow / mid and mid / lit.
uniform float shadow_threshold : hint_range(0.0, 1.0) = 0.42;
uniform float lit_threshold : hint_range(0.0, 1.0) = 0.82;
// The three bands' brightness against the body colour.
uniform float shadow_level : hint_range(0.0, 1.0) = 0.52;
uniform float mid_level : hint_range(0.0, 1.5) = 0.86;
uniform float lit_level : hint_range(0.5, 2.0) = 1.16;
// Cool hue the shadows lean toward.
uniform vec3 shadow_hue : source_color = vec3(0.28, 0.2, 0.55);
// Ink outline: width in px and colour against the body colour.
uniform float outline_px : hint_range(0.0, 12.0) = 3.5;
uniform float outline_level : hint_range(0.0, 1.0) = 0.16;
// Soft shadow band along the rim away from the light: width in px and depth.
uniform float rim_shadow_px : hint_range(0.0, 64.0) = 16.0;
uniform float rim_shadow_strength : hint_range(0.0, 1.0) = 0.4;
// Hard specular dot: how tight it is (closer to 1 is smaller).
uniform float specular_size : hint_range(0.8, 1.0) = 0.965;
// Band edge wobble: at rest, and added at full speed (600 px/s).
uniform float wobble : hint_range(0.0, 0.2) = 0.025;
uniform float motion_wobble : hint_range(0.0, 0.3) = 0.08;

varying vec2 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy;
}

// A step from 0 to 1 at `edge`, antialiased over about one pixel of `x`.
float band(float edge, float x) {
	float w = max(fwidth(x) * 0.75, 1e-4);
	return smoothstep(edge - w, edge + w, x);
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

	// Pillow normal: edge-on at the outline, flat a share of the radius in,
	// tilted a little by a dome from the centre so the middle is not one flat tone.
	float r = max(radius, 1.0);
	vec2 q = (p - center) / r;
	float t = clamp(sd / max(r * pillow, 4.0), 0.0, 1.0);
	float e = 1.0 - t;
	e = e * e * (3.0 - 2.0 * e) * 0.92 + e * 0.08;
	vec3 n = normalize(vec3(outward * e + q * 0.32 * t, sqrt(max(1.0 - e * e, 0.0))));
	vec3 L = normalize(light_dir);
	vec3 H = normalize(L + vec3(0.0, 0.0, 1.0));

	// The band edges wobble: a slow ripple around the body, quicker and stronger
	// while it moves, its phase per body.
	float speed = length(velocity);
	float motion = clamp(speed / 600.0, 0.0, 1.0);
	float angle = atan(q.y, q.x);
	float w = sin(angle * 5.0 + TIME * 2.3 + seed * 1.7) * 0.6
		+ sin(dot(q, vec2(3.1, -2.4)) * 2.5 - TIME * (3.0 + 6.0 * motion) + seed) * 0.4;
	w *= wobble + motion_wobble * motion;

	float diffuse = dot(n, L) + w;
	float to_mid = band(shadow_threshold, diffuse);
	float to_lit = band(lit_threshold, diffuse);
	float level = mix(mix(shadow_level, mid_level, to_mid), lit_level, to_lit);

	vec3 tint = two_tone(p, COLOR.rgb);
	vec3 shadow_colour = mix(tint, tint * shadow_hue * 2.2, 0.45);
	vec3 col = tint * level;
	col = mix(shadow_colour * shadow_level, col, to_mid);
	// The lit band pales a little toward white, like a painted highlight tone.
	col = mix(col, mix(col, vec3(1.0), 0.18), to_lit);

	// Soft shadow along the rim on the far side from the light.
	float away = clamp(dot(outward, -normalize(L.xy)), 0.0, 1.0);
	float rim_shadow = (1.0 - smoothstep(0.0, rim_shadow_px, sd)) * smoothstep(0.1, 0.9, away);
	col = mix(col, shadow_colour * shadow_level * 0.8, rim_shadow * rim_shadow_strength);

	// Hard specular dot where the normal meets the half vector, plus a small
	// second dot beside it.
	float spec = band(specular_size, dot(n, H) + w * 0.3);
	vec2 dot_at = vec2(-0.42, -0.5) * r * 0.62;
	float dot2 = 1.0 - band(max(r * 0.07, 2.0), length(p - center - dot_at - vec2(r * 0.17, r * 0.05)));
	col = mix(col, vec3(1.0), max(spec, dot2 * (1.0 - spec)) * 0.95);

	// Ink outline at the rim.
	float ink = 1.0 - band(outline_px, sd + w * 4.0);
	col = mix(col, tint * outline_level, ink);

	COLOR = vec4(col, COLOR.a);
}
