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

// Tile length along the course direction (metres): sets where the vertical
// gaps between neighbouring tiles in a row fall.
uniform float tile_length : hint_range(0.1, 1.5) = 0.42;

uniform float relief_depth : hint_range(0.0, 2.0) = 0.9;
// Fine grain noise-lattice spacing IN METRES. Keep small (~5 cm) so the grain
// reads as tile grit, not rolling half-metre lumps (see building_wall.gdshader).
uniform float grain_scale : hint_range(0.01, 0.4) = 0.05;
uniform float albedo_variation : hint_range(0.0, 0.6) = 0.08;
// Fraction of the grain fed into the normal — a micro-tooth, not visible hills.
uniform float grain_bump : hint_range(0.0, 1.0) = 0.15;
uniform float roughness_base : hint_range(0.0, 1.0) = 0.8;

// --- Weathering ------------------------------------------------------------
// Roofs age faster than walls: tiles fade unevenly, moss/algae grows in the
// damp shaded gaps between courses, and per-tile colour varies a lot (kiln
// batches, replacements). These add that without textures.

// Overall strength of tile fade + moss (0 = new roof, 1 = old & weathered).
uniform float weathering : hint_range(0.0, 1.0) = 0.4;
// Greenish moss/algae tint that collects in the shaded course gaps.
uniform vec4 moss_color : source_color = vec4(0.18, 0.24, 0.12, 1.0);
// Per-tile tonal spread so a roof reads as thousands of individual tiles.
uniform float unit_tone_variation : hint_range(0.0, 0.5) = 0.14;

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

// Signed [-1,1] per-cell random keyed on integer grid cell. Gives each tile /
// seam panel its own slight tonal offset.
float cell_tone(vec2 cell) {
	return hash(floor(cell) + 0.5) * 2.0 - 1.0;
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
	// Fine grain gets a tight wrap sized to a whole multiple of grain_scale, then
	// divided. Wrapping to 64 m and THEN dividing by ~0.22 pushed the noise
	// lattice input to ~291, where the hash loses precision and the grain
	// collapses into coarse ~half-metre blobs. Wrapping to grain_scale*64 keeps
	// the lattice input in the low tens and the speckle fine, and tiles cleanly.
	vec2 grain_uv = mod(world_pos.xz, grain_scale * 64.0) / grain_scale;
	float grain = fbm(grain_uv);

	vec3 col = base_color.rgb;
	float rough = roughness_base;
	float metallic = 0.0;
	float spec = 0.5;
	float ridge = 0.0;   // signed relief gradient fed into the normal

	float gap_shade = 0.0;   // course-gap darkness, drives where moss collects

	if (surface_kind < 0.5) {
		// Tiles: rows running along X, gaps between courses along Z.
		float course = wrapped.y / tile_course;
		float row = floor(course);
		// Alternate rows shift by half a tile so tiles interlock like real ones.
		float along = wrapped.x / tile_length + mod(row, 2.0) * 0.5;
		float gap = joint_line(course, 0.18);          // horizontal course gaps
		float side = joint_line(along, 0.05);          // vertical gaps between tiles
		gap_shade = max(gap, side * 0.6);
		// Per-tile tone: each tile (row, column) gets a shade so the roof reads
		// as thousands of individually-fired tiles, some faded/replaced.
		float tile_tone = cell_tone(vec2(floor(along), row));
		col = clamp(col * (1.0 + tile_tone * unit_tone_variation), vec3(0.0), vec3(1.0));
		// A rounded tile face: darker in the gap, lifting toward the row centre.
		col = mix(col, col * 0.7, gap_shade * 0.8);
		rough = mix(roughness_base, 1.0, gap_shade);
		// Relief: each course bulges (a half-cylinder tile), so the normal tips
		// across the course direction.
		ridge = (fract(course) - 0.5);
	} else if (surface_kind < 1.5) {
		// Flat membrane/gravel/grass: matte, just mottled by grain.
		rough = clamp(roughness_base, 0.7, 1.0);
		// Broad uneven fade so a flat roof isn't one dead-flat colour.
		gap_shade = clamp(fbm(wrapped * 0.15) * 0.5, 0.0, 1.0);
	} else {
		// Standing-seam metal: vertical ribs spaced along X.
		float seam = wrapped.x / seam_spacing;
		float rib = joint_line(seam, 0.05);
		gap_shade = rib;
		// Per-panel tone between seams (subtle — metal is fairly uniform).
		float panel_tone = cell_tone(vec2(floor(seam), 0.0));
		col = clamp(col * (1.0 + panel_tone * unit_tone_variation * 0.4), vec3(0.0), vec3(1.0));
		col = mix(col, col * 0.85, rib);
		rough = clamp(roughness_base - 0.45, 0.1, 1.0);
		metallic = 0.6;
		spec = 0.7;
		ridge = (fract(seam) - 0.5) * 0.6;
	}

	col = clamp(col + vec3((grain - 0.5) * albedo_variation), vec3(0.0), vec3(1.0));

	// Weathering: uneven sun-fade over the whole roof plus moss/algae that
	// collects in the damp, shaded course gaps. Metal roofs barely take moss, so
	// scale it down when metallic. Texture-free — all from world-space noise.
	float fade = fbm(wrapped * 0.08 + vec2(23.0, 5.0));
	col = mix(col, col * 0.82, fade * weathering * 0.5);
	float moss_amt = fbm(wrapped * 0.3 + vec2(60.0, 12.0));
	moss_amt = clamp(moss_amt * 1.4 - 0.4, 0.0, 1.0) * gap_shade;
	moss_amt *= weathering * (1.0 - metallic * 0.8);
	col = mix(col, moss_color.rgb, moss_amt * 0.6);
	rough = clamp(rough + moss_amt * 0.3, 0.0, 1.0);

	ALBEDO = col;
	ROUGHNESS = clamp(rough, 0.0, 1.0);
	METALLIC = metallic;
	SPECULAR = spec;

	// Derivative step in noise-lattice space (grain_uv is already divided by
	// grain_scale, so 0.5 here is half a lattice cell). Grain is a micro-texture,
	// so scale its normal contribution right down by grain_bump.
	float e = 0.5;
	float gx = (fbm(grain_uv + vec2(e, 0.0)) - fbm(grain_uv - vec2(e, 0.0))) * grain_bump;
	float gz = (fbm(grain_uv + vec2(0.0, e)) - fbm(grain_uv - vec2(0.0, e))) * grain_bump;
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
