// Wet, translucent goo for a blob's Skin (Polygon2D), driven by GooSkin.
//
// The polygon is the blob's smoothed outline; GooSkin also pushes the raw
// collision outline (`points`, global space), the centre, radius, a smoothed
// velocity and the bubble field (`seed`, `bubble_origin`, `bubble_cell`,
// `bubble_turn`): state the blob carries and hands on to the pieces of a split,
// so the bubbles live in a field that moves and turns with the blob (fixed in
// its rest pose) but is not tied to its current centre or size. Per fragment: signed distance to that outline -> a pseudo-3D normal
// that is flat in the middle and rolls off over `rim_width` like a drop's edge
// -> refraction of the screen behind (lens at the rim plus a travelling ripple
// while moving), fresnel rim, specular hotspot, soft sheen and two layers of
// procedural bubbles drifting up inside. The polygon's antialiased edge does the
// silhouette; the shader never cuts alpha (that would draw a second edge).
//
// The skin's uniform contract. This is the default skin shader; Goo2D.skin_shader
// (or GooWorld2D.skin_shader for a whole world) draws a body with any other
// canvas_item shader instead. GooSkin pushes these uniforms to whichever shader
// draws the skin, every frame the body moves; a replacement may declare any
// subset of them under these names and types (a value for one it does not
// declare is dropped silently):
//   uniform int point_count;     // how many of points[] are the outline (<= 32)
//   uniform vec2 points[32];     // the collision outline, global space, a closed
//                                // loop (resampled to 32 if longer), padded with
//                                // its last point
//   uniform vec2 center;         // the body's centre, global space
//   uniform float radius;        // px: sqrt(target area / PI), so it grows while a
//                                // merged or cut body inflates
//   uniform vec2 velocity;       // its velocity, smoothed over ~0.1 s, px/s
//   uniform float rotation;      // radians the ring has turned from its rest pose
//                                // (Goo2D.ring_rotation(): a round body as it
//                                // rolls, a shape as it tips), to turn a pattern
//                                // with the body
//   uniform float seed;          // per-body random value (1..98), kept by its pieces
//   uniform vec2 bubble_origin;  // a point that moves and turns with the body
//                                // about its centre, global space
//   uniform float bubble_cell;   // a length in px, fixed at the body's birth
//   uniform float bubble_turn;   // radians: the bubble field is fixed in the rest
//                                // pose, turned by rotation + bubble_turn (the
//                                // turn it was inherited with)
//   uniform vec4 second_color;   // a two-tone body's second colour (source_color);
//                                // transparent black (alpha 0) for a body of one
//                                // colour: read it as "the same as COLOR", so a
//                                // shader that mixes it in blindly still works
//   uniform vec2 division_axis;  // unit vector in the body's REST space (rest =
//                                // (world - center) turned by -rotation),
//                                // pointing toward second_color's side
//   uniform float division_offset; // px along division_axis from the rest
//                                // centroid to where the division crosses it
//                                // (0: half and half; > 0: COLOR owns more)
// COLOR is the body's tint (the Skin Polygon2D's colour, Goo2D.set_tint(): the
// body's colour, flashed and blended during merges; a two-tone body's primary
// colour, second_color on the far side of its division, two_tone() below shows
// the mix, faded over the look uniform division_fade); TIME is free to use. The
// polygon drawn is the smoothed skin outline in the Skin's local space; world_pos
// below shows how to get a fragment's global position to compare with points[]
// and center. A settled body stops pushing until it wakes.
shader_type canvas_item;

uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap, repeat_disable;

// Per blob (GooSkin.update()).
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
uniform vec2 bubble_origin = vec2(0.0);
uniform float bubble_cell = 16.0;
// The turn the bubble field was inherited with (radians): the field is fixed
// in the body's rest pose, turned by rotation + bubble_turn.
uniform float bubble_turn = 0.0;
// Seconds of the body's velocity the bubble field trails behind by (0: the
// bubbles stay put in the body as it moves).
uniform float bubble_lag : hint_range(0.0, 0.5) = 0.05;

// Look.
// Width, in px, over which a two-tone body's colours fade into each other.
uniform float division_fade : hint_range(0.0, 64.0) = 10.0;
uniform float rim_width : hint_range(1.0, 64.0) = 16.0;
uniform float rim_strength : hint_range(0.0, 2.0) = 0.85;
uniform float fresnel_power : hint_range(0.5, 8.0) = 2.2;
uniform float specular_power : hint_range(1.0, 512.0) = 90.0;
uniform float refraction_px : hint_range(0.0, 64.0) = 18.0;
uniform float motion_distortion_px : hint_range(0.0, 32.0) = 10.0;
uniform float goo_opacity : hint_range(0.0, 1.0) = 0.3;
uniform float bubble_density : hint_range(0.0, 1.0) = 0.55;
uniform float bubble_speed : hint_range(0.0, 200.0) = 16.0;
uniform vec3 light_dir = vec3(-0.55, -0.7, 0.75);

varying vec2 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy;
}

// Hashes without sin() (Dave Hoskins), stable on GLES3 / llvmpipe.
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

// One layer of bubbles: one per cell of `cell` px (where the cell's hash says
// so), drifting up with a sideways wobble. x = ring, y = interior, z = glint,
// w = bubble radius in px (0 where there is none).
vec4 bubble_layer(vec2 p, float cell, float layer_seed, float density, float sd, vec2 glint_dir) {
	vec2 uv = p / cell + vec2(seed * 3.731 + layer_seed * 17.0, seed * 1.913 + layer_seed * 5.0);
	vec2 id = floor(uv);
	vec2 f = fract(uv);
	float present = step(hash12(id + seed + layer_seed), density);
	vec2 rnd = hash22(id * 1.37 + seed);
	float phase = hash12(id + 91.7) * 6.2831;
	float br = mix(0.07, 0.2, rnd.x) * (1.0 + 0.08 * sin(TIME * 3.0 + phase));
	// Keep the bubble (and its wobble) inside its own cell: no neighbour search.
	float room = 0.5 - br - 0.08;
	vec2 pos = vec2(0.5) + (rnd - 0.5) * 2.0 * room;
	pos.x += sin(TIME * 1.7 + phase) * 0.07;
	vec2 dp = (f - pos) * cell;
	float rpx = br * cell;
	float dist = length(dp);
	float ring = 1.0 - smoothstep(0.0, 1.3, abs(dist - rpx));
	float inner = 1.0 - smoothstep(rpx - 1.2, rpx, dist);
	float glint = 1.0 - smoothstep(0.0, max(rpx * 0.32, 0.8), length(dp + glint_dir * rpx));
	// Only fully inside the goo: fades out as it reaches the rim.
	float inside = smoothstep(rpx + 1.0, rpx + 6.0, sd) * present;
	return vec4(ring * inside, inner * inside, glint * inside, rpx * inside);
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
	// (ab.y, -ab.x) points outward for a loop with positive shoelace sum.
	vec2 outward = normal_sum * (area2 >= 0.0 ? 1.0 : -1.0);
	outward = length(outward) > 1e-5 ? normalize(outward) : vec2(0.0, -1.0);
	float sd = point_count >= 3 ? (inside ? d_min : -d_min) : radius;

	// Pseudo-3D normal: flat in the middle, rolling off to edge-on at the rim,
	// with a faint dome so the middle catches a soft sheen.
	vec2 q = (p - center) / max(radius, 1.0);
	float t = clamp(sd / rim_width, 0.0, 1.0);
	float e = 1.0 - t;
	vec3 n = normalize(vec3(outward * e, sqrt(max(1.0 - e * e, 0.0))));
	vec3 n_dome = normalize(vec3(q * 0.55, 1.0));
	vec3 L = normalize(light_dir);
	vec3 H = normalize(L + vec3(0.0, 0.0, 1.0));

	// Refraction: a lens at the rim plus a travelling ripple while moving.
	float speed = length(velocity);
	vec2 dir = speed > 1e-3 ? velocity / speed : vec2(0.0, 1.0);
	float motion = clamp(speed / 600.0, 0.0, 1.0);
	float k = 6.2831 / max(radius * 0.7, 10.0);
	float along = dot(p - center, dir);
	float across = dot(p - center, vec2(-dir.y, dir.x));
	float ripple = sin(along * k - TIME * 16.0);
	float sway = sin(across * k * 1.3 - TIME * 11.0 + along * k * 0.5);
	vec2 offset = -n.xy * refraction_px * (1.0 - n.z);
	offset += (dir * ripple + vec2(-dir.y, dir.x) * sway * 0.6) * motion * motion_distortion_px;
	offset -= q * refraction_px * 0.35;
	vec3 bg = textureLod(screen_tex, SCREEN_UV + offset * SCREEN_PIXEL_SIZE, 0.35).rgb;

	// Bubbles, in the blob's bubble field lagging behind the motion. The field
	// is fixed in the body's rest pose (turned by rotation + bubble_turn about
	// bubble_origin), so the bubbles ride its turn; the rise is world-up, added
	// before the turn; the glint keeps facing the light.
	float bc = cos(rotation + bubble_turn);
	float bs = sin(rotation + bubble_turn);
	vec2 bd = p - bubble_origin + vec2(0.0, TIME * bubble_speed) - velocity * bubble_lag;
	vec2 lp = vec2(bc * bd.x + bs * bd.y, bc * bd.y - bs * bd.x);
	vec2 glint_dir = vec2(bc * 0.38 + bs * 0.42, bc * 0.42 - bs * 0.38);
	float cell = bubble_cell;
	vec4 b1 = bubble_layer(lp, cell, 0.0, bubble_density, sd, glint_dir);
	vec4 b2 = bubble_layer(lp, cell * 0.6, 1.0, bubble_density * 0.4, sd, glint_dir);
	float bubble_inner = max(b1.y, b2.y);
	if (bubble_inner > 0.0) {
		// A bubble is a little lens of its own: look through it at a shifted spot.
		vec2 bubble_shift = vec2(3.0, 3.0) * bubble_inner;
		bg = mix(bg, textureLod(screen_tex, SCREEN_UV + (offset + bubble_shift) * SCREEN_PIXEL_SIZE, 0.0).rgb, bubble_inner);
	}

	vec3 tint = two_tone(p, COLOR.rgb);
	// Light through the goo is tinted like coloured glass, then mixed with the
	// goo's own scattered colour.
	vec3 transmitted = bg * mix(vec3(1.0), tint, 0.4) * 1.6;
	vec3 body = mix(transmitted, tint, goo_opacity);
	// Thicker goo toward the rim reads darker and more saturated.
	body = mix(body, tint * 0.55, 0.35 * pow(e, 1.5));
	body = mix(body, mix(body, vec3(1.0), 0.35) + tint * 0.1, bubble_inner * 0.45);

	vec3 rim_colour = mix(tint, vec3(1.0), 0.65);
	float fresnel = pow(1.0 - n.z, fresnel_power) * rim_strength;
	float spec = pow(max(dot(n, H), 0.0), specular_power) * 1.4;
	float sheen = pow(max(dot(n_dome, H), 0.0), 12.0) * 0.22;
	float bubble_light = max(b1.x, b2.x) * 0.55 + max(b1.z, b2.z) * 0.9;

	vec3 col = body + rim_colour * fresnel + vec3(spec) + vec3(sheen) * mix(tint, vec3(1.0), 0.6)
		+ mix(tint, vec3(1.0), 0.75) * bubble_light;
	COLOR = vec4(col, COLOR.a);
}
