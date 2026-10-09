float surface_hash(vec2 p) {
	p = mod(p, 128.0);
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float surface_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(surface_hash(i), surface_hash(i + vec2(1.0, 0.0)), u.x),
		mix(surface_hash(i + vec2(0.0, 1.0)), surface_hash(i + vec2(1.0, 1.0)), u.x), u.y);
}

float surface_joint(float coordinate, float width, float pixel) {
	float distance = min(fract(coordinate), 1.0 - fract(coordinate));
	return 1.0 - smoothstep(width, width + pixel, distance);
}
