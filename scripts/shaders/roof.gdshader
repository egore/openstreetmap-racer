shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

#include "building_surface.gdshaderinc"

uniform vec4 base_color : source_color = vec4(0.55, 0.35, 0.25, 1.0);
uniform float surface_kind : hint_range(0.0, 2.0) = 0.0;
uniform float tile_course = 0.33;
uniform float tile_length = 0.24;
uniform float seam_spacing = 0.55;
uniform float relief_depth = 0.38;
uniform float grain_scale = 0.05;
uniform float albedo_variation = 0.035;
uniform float grain_bump = 0.025;
uniform float roughness_base = 0.82;
uniform float weathering = 0.3;
uniform vec4 moss_color : source_color = vec4(0.18, 0.24, 0.12, 1.0);
uniform float unit_tone_variation = 0.14;

void fragment() {
	float detail = 1.0 - smoothstep(55.0, 140.0, length(VERTEX));
	vec3 color = base_color.rgb;
	vec2 bump = vec2(0.0);
	float gap = 0.0;
	float rough = roughness_base;
	if (surface_kind < 0.5) {
		vec2 grid = UV / vec2(tile_length, tile_course);
		vec2 pixel = max(fwidth(grid), vec2(0.001));
		grid.x += mod(floor(grid.y), 2.0) * 0.5;
		vec2 coverage = 1.0 - smoothstep(vec2(0.2), vec2(0.85), pixel);
		float course_gap = surface_joint(grid.y, 0.055, pixel.y) * coverage.y;
		float side_gap = surface_joint(grid.x, 0.025, pixel.x) * coverage.x;
		gap = max(course_gap, side_gap * 0.65);
		float tone = surface_hash(floor(grid)) * 2.0 - 1.0;
		color *= 1.0 + tone * unit_tone_variation * min(coverage.x, coverage.y);
		color *= 1.0 - gap * 0.4;
		bump.x = sin(grid.x * 6.283185) * relief_depth * coverage.x * detail;
		bump.y = sign(0.5 - fract(grid.y)) * course_gap * relief_depth * detail;
	} else if (surface_kind > 1.5) {
		float grid = UV.x / seam_spacing;
		float pixel = max(fwidth(grid), 0.001);
		gap = surface_joint(grid, 0.025, pixel) * (1.0 - smoothstep(0.2, 0.85, pixel));
		color *= 1.0 - gap * 0.2;
		bump.x = sign(0.5 - fract(grid)) * gap * relief_depth * detail;
		rough = 0.38;
	}
	float fade = surface_noise(UV * 0.12);
	float moss = max(surface_noise(UV * 0.35 + 8.0) - 0.45, 0.0) * gap * weathering;
	color *= 1.0 - fade * weathering * 0.18;
	color = mix(color, moss_color.rgb, moss);
	if (detail > 0.0) {
		vec2 grain_uv = mod(UV, grain_scale * 64.0) / grain_scale;
		float grain = surface_noise(grain_uv) - 0.5;
		color += grain * albedo_variation * detail;
		bump += vec2(grain, surface_noise(grain_uv + 13.7) - 0.5) * grain_bump * detail;
	}
	ALBEDO = clamp(color, vec3(0.0), vec3(1.0));
	ROUGHNESS = clamp(rough + gap * 0.12 + moss * 0.2, 0.0, 1.0);
	METALLIC = surface_kind > 1.5 ? 0.65 : 0.0;
	SPECULAR = 0.45;
	NORMAL = normalize(NORMAL - TANGENT * bump.x - BINORMAL * bump.y);
}
