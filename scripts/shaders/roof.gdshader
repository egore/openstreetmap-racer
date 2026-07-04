shader_type spatial;

// Procedural PBR detail for building roofs.
//
// Same approach as the wall/asphalt shaders: no textures, all detail faked from
// WORLD-SPACE position so it tiles seamlessly across a roof's facets. The per-
// roof tint arrives in `base_color`; `surface_kind` picks the look:
//
//   0 = tiles  (roof_tiles / tile / thatch): repeating course rows with a
//               rounded, slightly glossy tile face and darker gaps between rows.
//   1 = flat   (tar_paper / gravel / concrete / grass): matte, mottled, no rows.
//   2 = metal  (metal / zinc / tin / copper): standing-seam vertical ribs, low
//               roughness + some metallic so it reflects the sky under SSR.
//
// Rows/seams are cut into the normal so they self-shade at grazing angles, which
// is what reads as a tiled or ribbed roof from the car.

render_mode cull_back, diffuse_burley, specular_schlick_ggx;

uniform vec4 base_color : source_color = vec4(0.7, 0.35, 0.25, 1.0);
uniform float surface_kind : hint_range(0.0, 2.0) = 0.0;

// Tile course spacing (metres) and metal seam spacing (metres).
uniform float tile_course : hint_range(0.1, 1.5) = 0.33;
uniform float seam_spacing : hint_range(0.1, 2.0) = 0.55;

uniform float relief_depth : hint_range(0.0, 2.0) = 0.9;
uniform float grain_scale : hint_range(0.02, 2.0) = 0.22;
uniform float albedo_variation : hint_range(0.0, 0.6) = 0.10;
uniform float roughness_base : hint_range(0.0, 1.0) = 0.8;

varying vec3 world_pos;
varying vec3 world_normal;

float hash(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float value_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
	float a = hash(i + vec2(0.0, 0.0));
	float b = hash(i + vec2(1.0, 0.0));
	float c = hash(i + vec2(0.0, 1.0));
	float d = hash(i + vec2(1.0, 1.0));
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

float fbm(vec2 p) {
	const mat2 rot = mat2(vec2(0.80, 0.60), vec2(-0.60, 0.80));
	float sum = 0.0;
	float amp = 0.5;
	for (int i = 0; i < 3; i++) {
		sum += amp * value_noise(p);
		p = rot * p * 2.0 + 17.3;
		amp *= 0.5;
	}
	return sum / 0.875;
}

float joint_line(float coord, float soft) {
	float d = min(fract(coord), 1.0 - fract(coord));
	return 1.0 - smoothstep(0.0, soft, d);
}

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	// Use world XZ for the repeating pattern; roofs are mostly near-horizontal
	// facets, so XZ gives a stable in-plane coordinate without per-facet UVs.
	// The rows/seams use the wide window; the fine grain uses a tight one so its
	// noise input stays small and precise (see the wall/terrain shaders).
	vec2 wrapped = mod(world_pos.xz, 512.0);
	vec2 grain_wrapped = mod(world_pos.xz, 64.0);
	float grain = fbm(grain_wrapped / grain_scale);

	vec3 col = base_color.rgb;
	float rough = roughness_base;
	float metallic = 0.0;
	float spec = 0.5;
	float ridge = 0.0;   // signed relief gradient fed into the normal

	if (surface_kind < 0.5) {
		// Tiles: rows running along X, gaps between courses along Z.
		float course = wrapped.y / tile_course;
		float gap = joint_line(course, 0.18);
		// A rounded tile face: darker in the gap, lifting toward the row centre.
		col = mix(col, col * 0.7, gap * 0.8);
		rough = mix(roughness_base, 1.0, gap);
		// Relief: each course bulges (a half-cylinder tile), so the normal tips
		// across the course direction.
		ridge = (fract(course) - 0.5);
	} else if (surface_kind < 1.5) {
		// Flat membrane/gravel/grass: matte, just mottled by grain.
		rough = clamp(roughness_base, 0.7, 1.0);
	} else {
		// Standing-seam metal: vertical ribs spaced along X.
		float seam = wrapped.x / seam_spacing;
		float rib = joint_line(seam, 0.05);
		col = mix(col, col * 0.85, rib);
		rough = clamp(roughness_base - 0.45, 0.1, 1.0);
		metallic = 0.6;
		spec = 0.7;
		ridge = (fract(seam) - 0.5) * 0.6;
	}

	col = clamp(col + vec3((grain - 0.5) * albedo_variation), vec3(0.0), vec3(1.0));

	ALBEDO = col;
	ROUGHNESS = clamp(rough, 0.0, 1.0);
	METALLIC = metallic;
	SPECULAR = spec;

	float e = 0.5 * grain_scale;
	float gx = fbm((grain_wrapped + vec2(e, 0.0)) / grain_scale)
		- fbm((grain_wrapped - vec2(e, 0.0)) / grain_scale);
	float gz = fbm((grain_wrapped + vec2(0.0, e)) / grain_scale)
		- fbm((grain_wrapped - vec2(0.0, e)) / grain_scale);
	// Metal ribs run along X (relief across X); tile courses run along Z.
	float ru = gx + ((surface_kind >= 1.5) ? ridge * relief_depth : 0.0);
	float rv = gz + ((surface_kind < 0.5) ? ridge * relief_depth : 0.0);

	// Tangent-free bump: roofs are near-horizontal facets, so map the height
	// gradient onto world X (Tu) and Z (Tv) projected into the facet plane and
	// tilt the geometric normal. Works on flat and pitched facets alike.
	vec3 N = normalize(world_normal);
	vec3 ax = vec3(1.0, 0.0, 0.0);
	vec3 Tu = ax - N * dot(N, ax);
	if (length(Tu) < 0.001) {
		Tu = vec3(0.0, 0.0, 1.0);
	}
	Tu = normalize(Tu);
	vec3 Tv = normalize(cross(N, Tu));
	NORMAL = normalize(N - (Tu * ru + Tv * rv));
}
