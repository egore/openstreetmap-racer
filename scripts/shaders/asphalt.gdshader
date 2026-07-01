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

// depth_draw_never: roads are kept FULL-LENGTH and overlap at junctions (the
// Mapnik model — connected roads share a common surface rather than being
// trimmed apart, so there are no gaps). Coplanar overlapping asphalt would
// z-fight if each quad wrote depth, so roads do not write depth at all; the
// depth TEST still runs (terrain/buildings written earlier still occlude them),
// but road-on-road overlap is resolved purely by draw order. RoadMaterialFactory
// sets render_priority per highway class so the bigger road always paints last
// (on top), mirroring Mapnik's "all casings, then all fills" layering.
render_mode cull_back, diffuse_burley, specular_schlick_ggx, depth_draw_never;

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

// --- Lane markings ----------------------------------------------------------
// Painted markings are derived from OSM lane tags (see RoadLaneSpec) and drawn
// procedurally from the ribbon UVs: UV.x = metres travelled ALONG the road,
// UV.y = fraction ACROSS the road (0 = left edge, 1 = right edge). This keeps
// the lines glued to the carriageway on curves and needs no marking geometry.

// Master switch: 0 disables all markings (unpaved/soft ways).
uniform float markings_enabled : hint_range(0.0, 1.0) = 0.0;
// Carriageway width in metres (edge to edge), so line widths stay real-world.
uniform float road_width : hint_range(0.5, 60.0) = 5.0;
// Total number of lanes and how many run in the forward (UV +x) direction.
uniform float lane_count : hint_range(1.0, 16.0) = 2.0;
uniform float forward_lanes : hint_range(0.0, 16.0) = 1.0;
// 1.0 when the road is one-way (no centre line), else 0.0.
uniform float one_way : hint_range(0.0, 1.0) = 0.0;
// Paint colour and geometry (metres) of the markings.
uniform vec3 marking_color : source_color = vec3(0.85, 0.82, 0.62);
uniform float line_width : hint_range(0.02, 0.6) = 0.12;
uniform float dash_length : hint_range(0.2, 8.0) = 3.0;
uniform float dash_gap : hint_range(0.2, 8.0) = 5.0;
// How far the markings fade out approaching a road end (metres). Lets junction
// trimming hide markings right at the mouth of an intersection.
uniform float end_fade : hint_range(0.0, 8.0) = 1.5;
// Total road length in metres (UV.x runs 0..road_length). 0 disables end fade.
uniform float road_length : hint_range(0.0, 100000.0) = 0.0;

// World-space XZ position of the fragment, passed from the vertex stage.
varying vec3 world_pos;

// Coverage of a painted line centred at `center` (in metres across the road),
// evaluated at across-position `pos_m`, using a half-texel-antialiased edge.
float line_coverage(float pos_m, float center, float half_w, float aa) {
	float d = abs(pos_m - center);
	return 1.0 - smoothstep(half_w - aa, half_w + aa, d);
}

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

	// --- Painted lane markings ---------------------------------------------
	if (markings_enabled > 0.5 && road_width > 0.01) {
		// Position across the road in metres (0 at centre, ±half_w at edges).
		float half_w = road_width * 0.5;
		float across = (UV.y - 0.5) * road_width;   // -half_w .. +half_w
		float along = UV.x;                          // metres travelled

		// Antialias width ~= half a screen-projected metre of the across axis.
		float aa = fwidth(across) * 0.75 + 0.0005;
		float half_line = line_width * 0.5;

		float paint = 0.0;   // accumulated marking coverage 0..1

		// Outer edge lines: solid, just inside each kerb so they read as the
		// carriageway boundary rather than sitting on the very edge.
		float edge_inset = min(half_line + 0.10, half_w);
		paint = max(paint, line_coverage(across, -(half_w - edge_inset), half_line, aa));
		paint = max(paint, line_coverage(across,  (half_w - edge_inset), half_line, aa));

		// Dashed cadence along the road (shared by every same-direction divider).
		float period = max(dash_length + dash_gap, 0.001);
		float dash_phase = fract(along / period) * period;
		float dash_aa = fwidth(along) + 0.01;
		float dash_on = 1.0 - smoothstep(dash_length - dash_aa, dash_length + dash_aa, dash_phase);

		// Lane boundaries are evenly spaced across the carriageway. Boundary i
		// (1..lane_count-1) sits at the border between lane i-1 and lane i.
		float lane_w = road_width / max(lane_count, 1.0);
		int lanes_i = int(lane_count + 0.5);
		int fwd_i = int(forward_lanes + 0.5);
		bool two_way = one_way < 0.5 && fwd_i > 0 && fwd_i < lanes_i;

		for (int i = 1; i < lanes_i; i++) {
			float center = -half_w + float(i) * lane_w;
			float cov = line_coverage(across, center, half_line, aa);
			if (cov <= 0.0) {
				continue;
			}
			if (two_way && i == fwd_i) {
				// Direction divider: solid centre line (double look via a small
				// twin stroke) — always painted, never dashed.
				float dbl = max(
					line_coverage(across, center - half_line * 1.6, half_line * 0.7, aa),
					line_coverage(across, center + half_line * 1.6, half_line * 0.7, aa));
				paint = max(paint, dbl);
			} else {
				// Same-direction lane divider: dashed.
				paint = max(paint, cov * dash_on);
			}
		}

		// Fade markings out near either end of the road so a trimmed junction
		// mouth doesn't show paint running into the cross street.
		float fade = 1.0;
		if (road_length > 0.01 && end_fade > 0.001) {
			float d_end = min(along, road_length - along);
			fade = clamp(d_end / end_fade, 0.0, 1.0);
		}
		paint *= fade;

		ALBEDO = mix(ALBEDO, marking_color, clamp(paint, 0.0, 1.0));
		// Fresh paint is smoother/brighter than the surrounding asphalt.
		ROUGHNESS = mix(ROUGHNESS, 0.55, clamp(paint, 0.0, 1.0));
	}
}
