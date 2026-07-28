shader_type canvas_item;

// Radial speed blur: smears the frame outward from a focal point, leaving the
// centre sharp and blurring progressively toward the edges.
//
// This is the "sense of speed" effect every racing game uses. Godot 4 has no
// built-in per-object motion blur, and a true velocity-buffer implementation is
// both expensive and overkill here: when you are driving forward, the screen-space
// motion of the world genuinely IS radial, streaming outward from the vanishing
// point. Sampling along the vector away from that point reproduces the effect
// convincingly for a fraction of the cost.
//
// The effect is applied by a full-screen ColorRect that reads the rendered frame
// through SCREEN_TEXTURE. It must therefore draw *after* the 3D scene and sit
// under the HUD, so the instruments stay razor sharp — blurring the player's own
// dials would just look like a mistake.
//
// SpeedBlur (scripts/speed_blur.gd) drives `strength` from the car's speed.

// The rendered frame beneath this overlay. In Godot 4 the screen texture must be
// declared as a hinted uniform (the old global SCREEN_TEXTURE was removed).
// Linear mipmap filtering keeps the smear smooth when samples land between texels.
uniform sampler2D screen_texture : hint_screen_texture, filter_linear_mipmap;

// How strong the smear is, 0..1. Driven from car speed; 0 disables the effect
// entirely (and the shader early-outs, so there is no cost at a standstill).
uniform float strength : hint_range(0.0, 1.0) = 0.0;

// How far from the focal point the blur starts, as a fraction of the distance to
// the corner. Inside this radius the image is untouched, which keeps the road
// ahead — and the car itself — crisp. Blurring the centre would read as motion
// sickness rather than speed.
uniform float clear_radius : hint_range(0.0, 1.0) = 0.18;

// Maximum smear length at the screen edge, in UV units. Small: a long smear
// destroys the image, while a short one reads as speed without hurting clarity.
uniform float max_blur : hint_range(0.0, 0.2) = 0.035;

// Where the blur radiates from, in UV space. Screen centre by default; the
// controller nudges it toward the vanishing point when cornering, so the smear
// follows where the car is actually heading.
uniform vec2 focal_point = vec2(0.5, 0.5);

// Number of samples taken along the smear. Each is a texture fetch, so this is
// the effect's main cost. 8 is enough for a smooth streak at these blur lengths;
// visible banding only appears with far longer smears.
const int SAMPLE_COUNT = 8;

void fragment() {
	vec4 original = texture(screen_texture, SCREEN_UV);

	// No blur requested (stationary or effect disabled): pass the frame through
	// untouched and skip every sample.
	if (strength <= 0.001) {
		COLOR = original;
	} else {
		// Vector from the focal point out to this pixel. The blur runs along it,
		// which is the direction the world appears to move when driving forward.
		vec2 offset = SCREEN_UV - focal_point;
		float dist = length(offset);

		// Fade the effect in from the clear radius out to the corner, so there is
		// no visible ring where the blur switches on.
		float falloff = smoothstep(clear_radius, 1.0, dist / 0.7071);

		if (falloff <= 0.0) {
			COLOR = original;
		} else {
			// Smear length grows with both distance from centre and current speed.
			// Direction is normalised so the streak length is controlled purely by
			// the terms above, not by how far out the pixel happens to be.
			vec2 direction = dist > 0.0001 ? offset / dist : vec2(0.0);
			float blur_length = max_blur * falloff * strength;

			// Walk back toward the focal point, accumulating samples. Sampling
			// inward (rather than symmetrically) mimics the trailing streak that
			// real motion blur leaves behind a moving feature.
			vec4 accum = original;
			for (int i = 1; i < SAMPLE_COUNT; i++) {
				float t = float(i) / float(SAMPLE_COUNT - 1);
				vec2 sample_uv = SCREEN_UV - direction * blur_length * t;
				accum += texture(screen_texture, clamp(sample_uv, vec2(0.0), vec2(1.0)));
			}
			COLOR = accum / float(SAMPLE_COUNT);
		}
	}
}
