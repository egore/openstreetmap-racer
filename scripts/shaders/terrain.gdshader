shader_type spatial;

// Procedural PBR detail for the ground / terrain.
//
// Replaces the flat grass-green StandardMaterial3D with multi-scale world-space
// noise so the ground reads as varied vegetation rather than a solid colour.
// Same no-texture idiom as the asphalt/wall/roof shaders. Everything is sampled
// in WORLD XZ, so it tiles seamlessly across tile boundaries (each tile's mesh
// is built in world space) and holds a constant real-world scale.
//
// Two noise scales blend two grass tints (a broad "meadow" patchiness) and a
// fine blade-grain drives a soft micro-normal so low sun rakes across it. The
// base tint arrives in `base_color` so a caller could theme it (e.g. drier
// grass) without editing the shader.

render_mode cull_back, diffuse_burley, specular_schlick_ggx;

uniform vec4 base_color : source_color = vec4(0.35, 0.55, 0.25, 1.0);
// Secondary tint mixed in over large patches (drier / darker grass).
uniform vec4 patch_color : source_color = vec4(0.30, 0.45, 0.20, 1.0);

// Large patch scale (metres) and fine blade-grain scale (metres).
uniform float patch_scale : hint_range(2.0, 60.0) = 14.0;
uniform float grain_scale : hint_range(0.05, 2.0) = 0.4;

uniform float albedo_variation : hint_range(0.0, 0.8) = 0.16;
uniform float roughness_base : hint_range(0.0, 1.0) = 0.95;
uniform float bump_strength : hint_range(0.0, 2.0) = 0.5;

// Global wetness 0..1, shared with the asphalt shader (set by WeatherController).
// Wet ground darkens and gains a damp sheen, but far less mirror-like than a
// road — grass and soil scatter, they don't pool into a reflective film.
global uniform float wetness;

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
	for (int i = 0; i < 4; i++) {
		sum += amp * value_noise(p);
		p = rot * p * 2.0 + 17.3;
		amp *= 0.5;
	}
	return sum / 0.9375;
}

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	// Patch noise (metres-scale meadow variation) can use the wide window, but
	// the fine grain must be sampled from a tightly-wrapped coordinate or its
	// input grows into the thousands and the hash degrades into coarse blocks.
	vec2 patch_wrapped = mod(world_pos.xz, 1024.0);
	vec2 grain_wrapped = mod(world_pos.xz, 64.0);
	float patch = value_noise(patch_wrapped / patch_scale);
	float grain = fbm(grain_wrapped / grain_scale);

	// Broad patchiness selects between the two grass tints; the fine grain then
	// lightens/darkens on top for blade-level variation.
	vec3 col = mix(base_color.rgb, patch_color.rgb, clamp(patch, 0.0, 1.0));
	col = clamp(col + vec3((grain - 0.5) * albedo_variation), vec3(0.0), vec3(1.0));

	// Grass is rough; slightly rougher in the darker (shadier) patches.
	float rough = clamp(roughness_base - (patch - 0.5) * 0.06, 0.0, 1.0);
	float spec = 0.3;

	// Wet ground: darken and add a modest damp sheen. Capped well short of the
	// road's near-mirror so the grass reads as wet, not glazed.
	float wet = clamp(wetness, 0.0, 1.0);
	if (wet > 0.001) {
		col *= (1.0 - 0.35 * wet);
		rough = mix(rough, 0.45, wet);
		spec = mix(spec, 0.55, wet);
	}

	ALBEDO = col;
	ROUGHNESS = rough;
	METALLIC = 0.0;
	SPECULAR = spec;

	// Soft micro-normal from the blade grain. The ground mesh has no UVs/tangents
	// (it is a plane or a DEM grid with generated normals), so we tilt the
	// geometric normal directly using a tangent frame built from world X/Z.
	float e = 0.5 * grain_scale;
	float hx = fbm((grain_wrapped + vec2(e, 0.0)) / grain_scale)
		- fbm((grain_wrapped - vec2(e, 0.0)) / grain_scale);
	float hz = fbm((grain_wrapped + vec2(0.0, e)) / grain_scale)
		- fbm((grain_wrapped - vec2(0.0, e)) / grain_scale);
	vec3 N = normalize(world_normal);
	vec3 ax = vec3(1.0, 0.0, 0.0);
	vec3 Tu = ax - N * dot(N, ax);
	if (length(Tu) < 0.001) {
		Tu = vec3(0.0, 0.0, 1.0);
	}
	Tu = normalize(Tu);
	vec3 Tv = normalize(cross(N, Tu));
	NORMAL = normalize(N - (Tu * hx + Tv * hz) * bump_strength);
}
