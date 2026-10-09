shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

#include "building_surface.gdshaderinc"

uniform vec4 base_color : source_color = vec4(0.7, 0.68, 0.62, 1.0);
uniform float surface_kind : hint_range(0.0, 2.0) = 0.0;
uniform float course_height = 0.075;
uniform float brick_length = 0.23;
uniform float panel_width = 3.0;
uniform float panel_height = 3.0;
uniform float joint_depth = 0.28;
uniform float grain_scale = 0.04;
uniform float albedo_variation = 0.025;
uniform float grain_bump = 0.025;
uniform float roughness_base = 0.85;
uniform float weathering = 0.25;
uniform float base_grime = 0.18;
uniform float base_grime_height = 1.2;
uniform float unit_tone_variation = 0.12;

void fragment() {
	float detail = 1.0 - smoothstep(45.0, 100.0, length(VERTEX));
	vec3 color = base_color.rgb;
	float rough = roughness_base;
	vec2 bump = vec2(0.0);
	float joint = 0.0;
	if (surface_kind > 0.5) {
		vec2 unit = surface_kind < 1.5 ? vec2(brick_length, course_height) : vec2(panel_width, panel_height);
		vec2 grid = UV / unit;
		vec2 pixel = max(fwidth(grid), vec2(0.001));
		if (surface_kind < 1.5) {
			grid.x += mod(floor(grid.y), 2.0) * 0.5;
		} else {
			rough = 0.65;
		}
		vec2 coverage = 1.0 - smoothstep(vec2(0.2), vec2(0.8), pixel);
		float resolved = min(coverage.x, coverage.y);
		float horizontal = surface_joint(grid.y, 0.045, pixel.y) * resolved;
		float vertical = surface_joint(grid.x, 0.025, pixel.x) * resolved;
		joint = max(horizontal, vertical);
		float tone = surface_hash(floor(grid)) * 2.0 - 1.0;
		color *= 1.0 + tone * unit_tone_variation * min(coverage.x, coverage.y);
		vec3 mortar = surface_kind < 1.5 ? vec3(0.48, 0.46, 0.41) : base_color.rgb * 0.65;
		color = mix(color, mortar, joint * 0.65);
		bump = sign(vec2(0.5) - fract(grid)) * vec2(vertical, horizontal) * joint_depth * detail;
	}
	float streak = surface_noise(UV * vec2(0.65, 0.08));
	float damp = (1.0 - smoothstep(0.0, base_grime_height, UV.y)) * base_grime;
	float grime = damp + max(streak - 0.4, 0.0) * weathering;
	color *= 1.0 - grime * 0.45;
	if (detail > 0.0) {
		vec2 grain_uv = mod(UV, grain_scale * 64.0) / grain_scale;
		float grain = surface_noise(grain_uv) - 0.5;
		color += grain * albedo_variation * detail;
		bump += vec2(grain, surface_noise(grain_uv + 13.7) - 0.5) * grain_bump * detail;
	}
	ALBEDO = clamp(color, vec3(0.0), vec3(1.0));
	ROUGHNESS = clamp(rough + joint * 0.1 + grime * 0.2, 0.0, 1.0);
	SPECULAR = 0.35;
	// Godot supplies the tangent frame in view space, like fragment NORMAL.
	NORMAL = normalize(NORMAL - TANGENT * bump.x - BINORMAL * bump.y);
}
