shader_type sky;

// Procedural sky with a gradient, a sun disk, and drifting clouds.
//
// Drives the whole atmosphere from a small set of uniforms so a single
// resource can express both day and night (and any blend between them).
// SkyController feeds the sun direction/colour and the day/night palette;
// everything here is computed per-pixel against the view ray (EYEDIR), so the
// horizon, sun glow and clouds stay correct as the camera turns.
//
// All colours are authored linearly and HDR (>1.0 for the sun/glow) so the
// environment's tonemapper rolls them off naturally instead of clipping.

// --- Sky gradient ----------------------------------------------------------
// Colour straight up, at the horizon, and just below it (ground haze). These
// are swapped between day and night palettes by SkyController.
uniform vec3 zenith_color : source_color = vec3(0.18, 0.35, 0.62);
uniform vec3 horizon_color : source_color = vec3(0.62, 0.74, 0.86);
uniform vec3 ground_color : source_color = vec3(0.30, 0.32, 0.34);
// How sharply zenith fades to horizon. Higher = tighter band near the horizon.
uniform float horizon_falloff : hint_range(1.0, 16.0) = 4.0;

// --- Sun -------------------------------------------------------------------
// Direction the sunlight travels TOWARD the sky (i.e. from the sun to us is
// -sun_direction). SkyController keeps this in sync with the DirectionalLight.
uniform vec3 sun_direction = vec3(0.0, -0.6, -0.8);
uniform vec3 sun_color : source_color = vec3(8.0, 7.2, 5.6);
// Angular radius of the bright disk and the soft glow around it (radians).
uniform float sun_size : hint_range(0.002, 0.2) = 0.03;
uniform float sun_glow_size : hint_range(0.02, 1.0) = 0.25;
// Overall sun brightness (0 hides the disk entirely, e.g. deep night).
uniform float sun_energy : hint_range(0.0, 20.0) = 1.0;

// --- Clouds ----------------------------------------------------------------
uniform vec3 cloud_color : source_color = vec3(1.0, 1.0, 1.0);
// Tint of cloud undersides / shadowed parts; darker at night.
uniform vec3 cloud_shadow_color : source_color = vec3(0.55, 0.6, 0.68);
// 0 = clear sky, 1 = heavy overcast. Raises coverage threshold.
uniform float cloud_coverage : hint_range(0.0, 1.0) = 0.5;
// Edge softness of the clouds.
uniform float cloud_softness : hint_range(0.01, 0.6) = 0.25;
// World scale of the cloud pattern. Larger = bigger, fewer clouds.
uniform float cloud_scale : hint_range(0.2, 8.0) = 2.0;
// How fast clouds drift, in pattern-units per second.
uniform vec2 cloud_wind = vec2(0.01, 0.006);
// Master opacity so clouds can fade out entirely.
uniform float cloud_opacity : hint_range(0.0, 1.0) = 1.0;

// --- Noise -----------------------------------------------------------------

float hash(vec2 p) {
	p = fract(p * vec2(123.34, 345.45));
	p += dot(p, p + 34.345);
	return fract(p.x * p.y);
}

float value_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	float a = hash(i + vec2(0.0, 0.0));
	float b = hash(i + vec2(1.0, 0.0));
	float c = hash(i + vec2(0.0, 1.0));
	float d = hash(i + vec2(1.0, 1.0));
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

// Fractal noise (4 octaves) for puffy, multi-scale cloud shapes.
float fbm(vec2 p) {
	float total = 0.0;
	float amp = 0.5;
	float freq = 1.0;
	for (int i = 0; i < 4; i++) {
		total += value_noise(p * freq) * amp;
		freq *= 2.13;
		amp *= 0.5;
	}
	return total;
}

void sky() {
	vec3 dir = normalize(EYEDIR);

	// --- Base gradient -----------------------------------------------------
	// up = 1 at the zenith, 0 at the horizon, negative below it.
	float up = dir.y;
	float t = pow(clamp(up, 0.0, 1.0), 1.0 / horizon_falloff);
	vec3 sky_col = mix(horizon_color, zenith_color, t);
	// Below the horizon, fade into the ground haze colour.
	float below = clamp(-up * 4.0, 0.0, 1.0);
	sky_col = mix(sky_col, ground_color, below);

	// --- Sun disk + glow ---------------------------------------------------
	// Cosine of the angle between the view ray and the sun.
	float sun_cos = dot(dir, normalize(-sun_direction));
	float sun_ang = acos(clamp(sun_cos, -1.0, 1.0));
	// Sharp core disk with a soft edge.
	float disk = 1.0 - smoothstep(sun_size, sun_size + 0.01, sun_ang);
	// Wide atmospheric glow falling off around the disk.
	float glow = pow(max(sun_cos, 0.0), 1.0 / max(sun_glow_size, 0.001) * 8.0);
	vec3 sun = sun_color * sun_energy * (disk + glow * 0.6);
	sky_col += sun;

	// --- Clouds ------------------------------------------------------------
	// Only render clouds in the upper hemisphere. Project the view ray onto a
	// virtual cloud plane: dividing xz by y "pushes" the pattern out to the
	// horizon, so clouds appear to recede and flatten realistically.
	float cloud_amount = 0.0;
	if (up > 0.02) {
		vec2 plane = dir.xz / max(dir.y, 0.08) * cloud_scale;
		plane += cloud_wind * TIME;
		float density = fbm(plane);
		// Coverage carves the noise field into distinct cloud bodies.
		float threshold = mix(0.75, 0.25, cloud_coverage);
		cloud_amount = smoothstep(threshold, threshold + cloud_softness, density);
		// Fade clouds out toward the horizon so they don't form a hard band.
		cloud_amount *= smoothstep(0.02, 0.25, up);
		cloud_amount *= cloud_opacity;

		// Shade clouds: a second, offset noise sample fakes self-shadowing so
		// the puffs have lit tops and darker bellies instead of flat blobs.
		float shade = fbm(plane * 1.7 + 4.0);
		vec3 cloud = mix(cloud_shadow_color, cloud_color, clamp(shade + 0.2, 0.0, 1.0));
		// Let the sun bleed through thin cloud edges for a silver lining.
		cloud += sun_color * sun_energy * glow * 0.15 * cloud_amount;

		sky_col = mix(sky_col, cloud, cloud_amount);
	}

	COLOR = sky_col;
}
