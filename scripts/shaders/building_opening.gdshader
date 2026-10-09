shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

global uniform float building_night;
uniform vec4 frame_color : source_color = vec4(0.8, 0.78, 0.72, 1.0);
uniform vec4 door_color : source_color = vec4(0.12, 0.2, 0.16, 1.0);

float line(float distance, float half_width, float pixel) {
	return 1.0 - smoothstep(half_width, half_width + pixel, abs(distance));
}

void fragment() {
	vec2 metres = UV * UV2;
	vec2 edge = min(metres, UV2 - metres);
	float pixel = max(length(fwidth(metres)), 0.002);
	float border = 1.0 - smoothstep(0.065, 0.065 + pixel, min(edge.x, edge.y));
	float seed = COLOR.r;
	float kind = COLOR.g * 2.0;
	vec3 color;
	float rough = 0.22;
	vec3 glow = vec3(0.0);
	if (kind > 0.5) {
		float panel = line(metres.x - UV2.x * 0.5, UV2.x * 0.31, pixel)
			* line(metres.y - UV2.y * 0.5, UV2.y * 0.34, pixel);
		color = door_color.rgb * mix(0.7, 1.1, panel);
		if (kind > 1.5) {
			float rib = line(fract(metres.y / 0.16) - 0.5, 0.035, pixel / 0.16);
			color = mix(door_color.rgb, frame_color.rgb * 0.5, 0.65) * (1.0 - rib * 0.25);
		}
		float handle = line(metres.x - UV2.x * 0.82, 0.025, pixel) * line(metres.y - 1.05, 0.10, pixel);
		color = mix(color, vec3(0.65), handle);
		rough = 0.65;
	} else {
		float mullion = line(metres.x - UV2.x * 0.5, 0.025, pixel);
		float transom = line(metres.y - UV2.y * 0.72, 0.025, pixel);
		border = max(border, max(mullion, transom));
		float curtain = smoothstep(0.24 + seed * 0.18, 0.29 + seed * 0.18, abs(UV.x - 0.5));
		float pleat = 0.85 + 0.15 * sin(UV.x * 65.0);
		color = mix(vec3(0.045, 0.075, 0.09), vec3(0.33, 0.31, 0.26) * pleat, curtain * 0.8);
		color *= 0.65 + 0.35 * smoothstep(0.04, 0.25, min(edge.x, edge.y));
		float lit = step(0.58, seed) * building_night;
		glow = vec3(1.0, 0.66 + seed * 0.15, 0.34) * lit * (1.0 - curtain * 0.45) * 1.7;
	}
	ALBEDO = mix(color, frame_color.rgb, border);
	ROUGHNESS = mix(rough, 0.75, border);
	SPECULAR = 0.65;
	EMISSION = glow * (1.0 - border);
}
