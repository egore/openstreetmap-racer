shader_type spatial;

// Procedural asphalt for INTERSECTION CAPS.
//
// Visually identical to asphalt.gdshader — a junction must look like the roads
// feeding it — but with one critical difference: this one WRITES DEPTH.
//
// Why the split. Road ribbons use depth_draw_never because they are kept as
// overlapping coplanar strips and are resolved purely by render_priority draw
// order. That works for road-on-road. It fails for the junction cap, because
// render_priority only orders TRANSPARENT materials; opaque geometry is drawn
// front-to-back by distance. A cap that writes no depth therefore has no way to
// claim the pixels it covers, and whichever opaque surface happens to be drawn
// after it — the terrain, or a landuse area polygon — paints straight over the
// intersection. That is what left a grass-coloured hole where the junction
// should be, even though the cap mesh was built, present in the scene, marked
// visible, and sitting 24 mm above the ground.
//
// Writing depth makes the cap win that contest outright on geometry rather than
// on draw-order luck. It is safe here precisely because caps do NOT overlap each
// other: the solver gives every junction one owner (RoadNetworkContext), so
// there is no coplanar cap-on-cap fight for depth to make worse.
//
// Kept as a separate file rather than a uniform because render_mode is a compile
// time property of the shader and cannot be toggled per material.
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

// Per-junction tint (from the dominant arm's highway class).
uniform vec4 base_color : source_color = vec4(0.5, 0.5, 0.5, 1.0);

// Global wetness 0..1, driven by WeatherController exactly as for the roads so
// an intersection darkens and glosses with the street it belongs to.
global uniform float wetness;

uniform float grain_scale : hint_range(0.005, 0.1) = 0.02;
uniform float patch_scale : hint_range(1.0, 40.0) = 8.0;
uniform float albedo_variation : hint_range(0.0, 1.0) = 0.025;
uniform float roughness_base : hint_range(0.0, 1.0) = 0.92;
uniform float roughness_variation : hint_range(0.0, 0.5) = 0.04;
uniform float bump_strength : hint_range(0.0, 2.0) = 0.12;

varying vec3 world_pos;

// --- Value noise (identical to asphalt.gdshader so the surfaces match) ------

float hash(vec2 p) {
	uvec2 cell = uvec2(ivec2(p));
	uint h = cell.x * 1597334677u ^ cell.y * 3812015801u;
	h = (h ^ (h >> 16u)) * 2246822519u;
	h = (h ^ (h >> 13u)) * 3266489917u;
	h ^= h >> 16u;
	return float(h >> 8u) / 16777216.0;
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

float fbm(vec2 p, float footprint) {
	const mat2 rot = mat2(vec2(0.80, 0.60), vec2(-0.60, 0.80));
	float sum = 0.0;
	float amp = 0.5;
	for (int i = 0; i < 4; i++) {
		// Average away subpixel octaves rather than letting them shimmer.
		float visibility = 1.0 - smoothstep(0.25, 1.0, footprint);
		float sample_value = 0.5;
		if (visibility > 0.0) {
			sample_value = mix(0.5, value_noise(p), visibility);
		}
		sum += amp * sample_value;
		p = rot * p * 2.0 + 17.3;
		footprint *= 2.0;
		amp *= 0.5;
	}
	return sum / 0.9375;
}

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	// Integer hashing keeps centimetre cells decorrelated without wrap seams.
	vec2 grain_uv = world_pos.xz / grain_scale;
	vec2 patch_uv = world_pos.xz / patch_scale;

	float footprint = max(length(dFdx(grain_uv)), length(dFdy(grain_uv)));
	float grain = fbm(grain_uv, footprint);
	float patch = value_noise(patch_uv);

	float lum = (grain - 0.5) * albedo_variation + (patch - 0.5) * albedo_variation * 0.25;
	vec3 col = clamp(base_color.rgb + vec3(lum), vec3(0.0), vec3(1.0));
	ALBEDO = col;

	float rough = clamp(roughness_base - (patch - 0.5) * roughness_variation * 2.0, 0.0, 1.0);
	float spec = 0.4;

	float wet = clamp(wetness, 0.0, 1.0);
	if (wet > 0.001) {
		float puddle = wet * (0.6 + 0.4 * (1.0 - patch));
		ALBEDO = col * (1.0 - 0.45 * wet);
		rough = mix(rough, 0.08, puddle);
		spec = mix(spec, 0.85, wet);
	}

	ROUGHNESS = rough;
	METALLIC = 0.0;
	SPECULAR = spec;

	float bump = bump_strength * (1.0 - 0.85 * wet);
	float hx = fbm(grain_uv + vec2(0.5, 0.0), footprint)
		- fbm(grain_uv - vec2(0.5, 0.0), footprint);
	float hz = fbm(grain_uv + vec2(0.0, 0.5), footprint)
		- fbm(grain_uv - vec2(0.0, 0.5), footprint);
	vec3 n = normalize(vec3(-hx * bump, -hz * bump, 1.0));
	NORMAL_MAP = n * 0.5 + 0.5;
	NORMAL_MAP_DEPTH = 1.0;
}
