shader_type spatial;

// Procedural PBR detail for building walls.
//
// Like the asphalt shader, all detail is faked through lighting on flat,
// UV-less wall geometry — no texture files. Everything is driven from
// WORLD-SPACE position so the pattern is seamless across a building's wall
// segments and keeps a constant real-world scale regardless of wall length or
// orientation. The per-building tint arrives in `base_color`; a `surface_kind`
// selects how the wall reads:
//
//   0 = smooth   (plaster / render / stucco): faint mottling, matte.
//   1 = masonry  (brick / stone): running-bond courses with recessed mortar
//                 lines cut into the normal + darker mortar albedo.
//   2 = panel    (concrete / metal / glass): large vertical panel joints, a
//                 touch glossier so SSR gives it a subtle sheen.
//
// The mortar/panel joints are cut into NORMAL_MAP (not geometry) so they catch
// light at grazing angles the way real recessed joints do, which is most of
// what sells masonry at a distance.

render_mode cull_back, diffuse_burley, specular_schlick_ggx;

// Per-building tint (from BUILDING/MATERIAL colour tables).
uniform vec4 base_color : source_color = vec4(0.7, 0.68, 0.62, 1.0);

// Which wall treatment to draw (see header). Float so it can be a uniform.
uniform float surface_kind : hint_range(0.0, 2.0) = 0.0;

// Brick course height and brick length in metres (masonry only).
uniform float course_height : hint_range(0.05, 1.5) = 0.24;
uniform float brick_length : hint_range(0.1, 3.0) = 0.52;
// Panel size in metres (panel only): width across, height up.
uniform float panel_width : hint_range(0.5, 8.0) = 3.0;
uniform float panel_height : hint_range(0.5, 8.0) = 3.5;

// How deep the mortar / panel joints read in the faked normal.
uniform float joint_depth : hint_range(0.0, 2.0) = 0.8;
// Fine surface grain (albedo + micro-normal), like the asphalt speckle.
uniform float grain_scale : hint_range(0.02, 2.0) = 0.18;
uniform float albedo_variation : hint_range(0.0, 0.6) = 0.10;

// Base roughness; masonry is rough, panels a little smoother.
uniform float roughness_base : hint_range(0.0, 1.0) = 0.85;

varying vec3 world_pos;
varying vec3 world_normal;

// --- Value noise (shared idiom with asphalt.gdshader) -----------------------
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

// Horizontal position along the wall, in metres, derived from world XZ. Using
// (x + z) gives a single monotonic coordinate that runs along any wall
// orientation without needing per-face UVs — good enough for a repeating
// brick/panel pattern that only has to look plausible, not registered.
float wall_u(vec3 wp) {
	return wp.x + wp.z;
}

// Soft "line" coverage: 1 near a joint (fractional coord close to 0), fading to
// 0 across `soft`. Used to darken mortar and to cut the normal.
float joint_line(float coord, float soft) {
	float d = min(fract(coord), 1.0 - fract(coord));
	return 1.0 - smoothstep(0.0, soft, d);
}

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	// Wrap into a SMALL window before dividing by the fine grain_scale. Dividing
	// a large world coordinate (walls can be hundreds of metres from the dataset
	// origin) by ~0.18 pushes the noise input into the thousands, where the hash
	// loses precision and the grain degrades into coarse multi-metre blocks. A
	// 64 m window is far larger than any wall face on screen, so its seam is
	// never visible, but keeps the noise input small and the grain fine.
	vec2 wrapped = mod(vec2(wall_u(world_pos), world_pos.y), 64.0);
	// Joints also use a wrapped coordinate: fract() of a large world value loses
	// precision and makes the courses drift/blur far from the origin. The 64 m
	// window holds a whole-number count only for scales that divide it, but the
	// small residual seam sits off any single wall face and is imperceptible.
	float u = wrapped.x;
	float v = wrapped.y;

	float grain = fbm(wrapped / grain_scale);

	vec3 col = base_color.rgb;
	float rough = roughness_base;
	float metallic = 0.0;
	float spec = 0.5;

	// Joint mask (in the horizontal, jh, and vertical, jv, directions) plus a
	// mortar darkening term. Filled per surface kind below.
	float jh = 0.0;
	float jv = 0.0;
	float mortar = 0.0;

	if (surface_kind < 0.5) {
		// Smooth plaster/render: just gentle mottling, no joints.
		rough = clamp(roughness_base, 0.6, 1.0);
	} else if (surface_kind < 1.5) {
		// Masonry: running-bond courses. Every other course is offset by half a
		// brick so the vertical joints stagger like real brickwork.
		float course = v / course_height;
		float row = floor(course);
		float offset = mod(row, 2.0) * 0.5;
		float along = u / brick_length + offset;
		jv = joint_line(course, 0.12);            // horizontal mortar lines
		jh = joint_line(along, 0.06);             // vertical (staggered) joints
		mortar = max(jv, jh);
		// Mortar is a lighter grey and rougher than the brick face.
		col = mix(col, col * 0.75 + vec3(0.12), mortar * 0.8);
		rough = mix(roughness_base, 1.0, mortar);
	} else {
		// Panels: large rectangular joints, slightly glossier face for SSR.
		jh = joint_line(u / panel_width, 0.03);
		jv = joint_line(v / panel_height, 0.03);
		mortar = max(jh, jv);
		col = mix(col, col * 0.7, mortar);
		rough = clamp(roughness_base - 0.25, 0.15, 1.0);
		spec = 0.6;
	}

	// Fine grain on the albedo (kept subtle so light walls don't look noisy).
	col = clamp(col + vec3((grain - 0.5) * albedo_variation), vec3(0.0), vec3(1.0));

	ALBEDO = col;
	ROUGHNESS = clamp(rough, 0.0, 1.0);
	METALLIC = metallic;
	SPECULAR = spec;

	// Faked bump. The wall meshes carry no UVs or tangents (they are extruded
	// footprints), so we can't use NORMAL_MAP — instead we build a tangent frame
	// on the fly from screen-space derivatives of world position and tilt the
	// interpolated NORMAL by a height field (grain + joint valleys). This is
	// UV/tangent-free and works on any geometry.
	float e = 0.5 * grain_scale;
	float gx = fbm((wrapped + vec2(e, 0.0)) / grain_scale)
		- fbm((wrapped - vec2(e, 0.0)) / grain_scale);
	float gy = fbm((wrapped + vec2(0.0, e)) / grain_scale)
		- fbm((wrapped - vec2(0.0, e)) / grain_scale);
	// Joint gradients: sign follows which side of the joint we're on so the
	// valley has two facing slopes rather than one flat step.
	float jx = (fract(u / max(brick_length, 0.001)) - 0.5) * jh;
	float jy = (fract(v / max(course_height, 0.001)) - 0.5) * jv;
	// Height-field gradient: gu runs horizontally along the wall, gv vertically.
	float gu = gx + jx * joint_depth;
	float gv = gy + jy * joint_depth;

	// Build a tangent frame around the geometric world normal without UVs:
	// the vertical tangent is world-up projected into the wall plane; the
	// horizontal tangent is perpendicular to both. Tilting N by the gradient
	// along these two axes gives a stable bump on vertical walls.
	vec3 N = normalize(world_normal);
	vec3 up = vec3(0.0, 1.0, 0.0);
	vec3 Tv = up - N * dot(N, up);           // vertical in-plane direction
	if (length(Tv) < 0.001) {
		Tv = vec3(1.0, 0.0, 0.0);            // wall is horizontal; pick any axis
	}
	Tv = normalize(Tv);
	vec3 Tu = normalize(cross(N, Tv));       // horizontal in-plane direction
	NORMAL = normalize(N - (Tu * gu + Tv * gv));
}
