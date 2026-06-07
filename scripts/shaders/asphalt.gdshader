shader_type spatial;

// Procedural asphalt surface for OSM roads.
//
// All detail is faked through lighting only: the geometry stays a flat,
// terrain-draped ribbon (collision-safe, no seams between segments), while
// value-noise drives albedo speckle, roughness variation, and a perturbed
// world-space normal that reads as a bumpy, grainy asphalt surface.
//
// Noise is sampled in WORLD-SPACE XZ (not UVs) so the pattern is seamless
// across adjacent road quads and keeps a constant real-world scale regardless
// of road width, orientation, or how the ribbon was triangulated. The road's
// per-highway-type tint is injected via the `base_color` uniform so all roads
// share this one shader while keeping their distinct colors.

render_mode cull_back, diffuse_burley, specular_schlick_ggx;

// Per-road tint (set from ROAD_COLORS by RoadMaterialFactory).
uniform vec4 base_color : source_color = vec4(0.5, 0.5, 0.5, 1.0);

// Size of one noise "tile" in meters. Smaller = finer grain.
uniform float grain_scale : hint_range(0.05, 5.0) = 0.35;
// Size of the larger blotchy patches (oil stains, wear) in meters.
uniform float patch_scale : hint_range(1.0, 40.0) = 8.0;

// How much the albedo darkens/lightens with the grain (0 = flat color).
// Kept low so the dark asphalt base stays cohesive (large swings on a dark
// base read as blotchy / washed-out and clamp at black).
uniform float albedo_variation : hint_range(0.0, 1.0) = 0.06;
// Base roughness and how much the noise modulates it. Asphalt is rough.
uniform float roughness_base : hint_range(0.0, 1.0) = 0.92;
uniform float roughness_variation : hint_range(0.0, 0.5) = 0.12;

// Strength of the faked bump (normal perturbation). 0 = perfectly smooth.
uniform float bump_strength : hint_range(0.0, 2.0) = 0.6;

// World-space XZ position of the fragment, passed from the vertex stage.
varying vec3 world_pos;

// --- Value noise (cheap, tileable-free in world space) ----------------------

float hash(vec2 p) {
	// Deterministic pseudo-random in [0,1) from a 2D cell.
	p = fract(p * vec2(123.34, 345.45));
	p += dot(p, p + 34.345);
	return fract(p.x * p.y);
}

float value_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	// Smoothstep interpolation for C1-continuous noise.
	vec2 u = f * f * (3.0 - 2.0 * f);
	float a = hash(i + vec2(0.0, 0.0));
	float b = hash(i + vec2(1.0, 0.0));
	float c = hash(i + vec2(0.0, 1.0));
	float d = hash(i + vec2(1.0, 1.0));
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

// Two-octave fractal noise: fine grain + coarse patches.
float fbm(vec2 p) {
	float n = value_noise(p);
	n += 0.5 * value_noise(p * 2.17 + 11.3);
	return n / 1.5;
}

void vertex() {
	// Capture world-space position so the fragment stage can sample noise in
	// meters regardless of the mesh's local coordinates.
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 grain_uv = world_pos.xz / grain_scale;
	vec2 patch_uv = world_pos.xz / patch_scale;

	float grain = fbm(grain_uv);
	float patch = value_noise(patch_uv);

	// Albedo: tint, darkened/lightened by grain, with subtle large blotches.
	float lum = (grain - 0.5) * albedo_variation + (patch - 0.5) * albedo_variation * 0.5;
	vec3 col = clamp(base_color.rgb + vec3(lum), vec3(0.0), vec3(1.0));
	ALBEDO = col;

	// Roughness: rough overall, slightly polished where patches are darker
	// (mimics oily/worn tire-track sheen).
	ROUGHNESS = clamp(roughness_base - (patch - 0.5) * roughness_variation * 2.0, 0.0, 1.0);
	METALLIC = 0.0;
	SPECULAR = 0.4;

	// Faked bump: derive a gradient of the grain noise in world XZ and tilt the
	// normal accordingly. Surface geometry is untouched (flat, collision-safe).
	float e = 0.5 * grain_scale; // sample offset in meters
	float hx = fbm((world_pos.xz + vec2(e, 0.0)) / grain_scale)
		- fbm((world_pos.xz - vec2(e, 0.0)) / grain_scale);
	float hz = fbm((world_pos.xz + vec2(0.0, e)) / grain_scale)
		- fbm((world_pos.xz - vec2(0.0, e)) / grain_scale);
	// Perturb in tangent space (Godot's NORMAL_MAP expects a [0,1] tangent normal).
	vec3 n = normalize(vec3(-hx * bump_strength, -hz * bump_strength, 1.0));
	NORMAL_MAP = n * 0.5 + 0.5;
	NORMAL_MAP_DEPTH = 1.0;
}
