class_name WheelParticles
extends Node3D

## Manages off-road particle effects for one wheel. Spawns green grass-leaf
## particles when the wheel is driving on grass and the car is moving above a
## minimum speed. The emitter follows the wheel's world position each physics
## frame and the emission rate scales with speed so a parked car on grass does
## not spray confetti.
##
## Usage: create one WheelParticles per wheel, parent it to the car, and call
## update_particles() every physics frame with the wheel's contact point and
## the current surface type.
##
## Uses CPUParticles3D rather than GPUParticles3D. The GPU emitter allocates a
## ParticlesShaderRD in the RenderingServer whose lifetime outlives the scene
## tree, so it is reported as "leaked at exit" on quit (and the GPU compute path
## has crashed the renderer on some macOS/Metal drivers — see ImpactParticles).
## The per-wheel counts here are tiny (<= MAX_PARTICLES), so CPU simulation is
## cheap and the visual result is identical.

## Minimum car speed (m/s) before particles start. Avoids particles when
## idling on grass.
const MIN_SPEED := 2.0

## Maximum number of particles alive at once per wheel.
const MAX_PARTICLES := 24

## Base particle lifetime (seconds). Shorter = snappier.
const LIFETIME := 0.6

## How quickly the amount ramps with speed (particles per m/s above threshold).
const AMOUNT_PER_SPEED := 3.0

## Particle spread cone (radians) from the upward direction.
const SPREAD_ANGLE := 35.0

## Initial upward velocity range for the leaf particles.
const INITIAL_VELOCITY_MIN := 1.0
const INITIAL_VELOCITY_MAX := 3.0

## Scale range of leaf particles (tiny flat quads).
const SCALE_MIN := 0.03
const SCALE_MAX := 0.08

## Gravity pulling particles back down.
const GRAVITY := Vector3(0.0, -6.0, 0.0)

var _particles: CPUParticles3D = null


func _ready() -> void:
	_particles = CPUParticles3D.new()
	_particles.name = "GrassParticles"
	_particles.amount = MAX_PARTICLES
	_particles.lifetime = LIFETIME
	_particles.emitting = false
	# One-shot false: continuous emission while driving on grass.
	_particles.one_shot = false
	# Particles live in world space so they don't follow the car after emission.
	_particles.local_coords = false
	_particles.draw_order = CPUParticles3D.DRAW_ORDER_VIEW_DEPTH
	# Don't cast shadows — the quads are tiny and shadow maps waste fill on them.
	_particles.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_configure_emission()
	# Flat colored quad for each particle — a tiny green rectangle that reads
	# as a leaf / grass blade without needing a texture.
	_particles.mesh = _create_particle_mesh()
	add_child(_particles)


## Call every physics frame. Moves the emitter to the wheel contact point and
## enables/disables emission based on the surface type and speed.
##
## - wheel_global_pos: world-space position of the wheel (contact patch).
## - surface: SurfaceDetector.Surface enum value under this wheel.
## - car_speed: absolute speed of the car in m/s (linear_velocity.length()).
func update_particles(wheel_global_pos: Vector3, surface: SurfaceDetector.Surface,
		car_speed: float) -> void:
	# Place emitter at wheel contact (slightly above ground to avoid z-fight).
	global_position = wheel_global_pos + Vector3(0, 0.05, 0)

	var should_emit: bool = surface == SurfaceDetector.Surface.GRASS \
			and car_speed > MIN_SPEED
	_particles.emitting = should_emit

	if should_emit:
		# Scale emission rate with speed: more particles the faster you go.
		var speed_factor := clampf((car_speed - MIN_SPEED) / 15.0, 0.0, 1.0)
		_particles.amount = clampi(int(speed_factor * MAX_PARTICLES), 1, MAX_PARTICLES)
		# Scale initial velocity with speed so the spray is more dramatic.
		_particles.initial_velocity_min = INITIAL_VELOCITY_MIN + car_speed * 0.15
		_particles.initial_velocity_max = INITIAL_VELOCITY_MAX + car_speed * 0.25


## Set the emission shape, spray cone, gravity, scale, colour ramp and tumble
## directly on the CPUParticles3D (the CPU emitter carries these fields itself
## rather than delegating to a ParticleProcessMaterial).
func _configure_emission() -> void:
	# Emit from a point (the wheel contact).
	_particles.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	_particles.emission_sphere_radius = 0.15
	# Spray upward in a cone.
	_particles.direction = Vector3(0, 1, 0)
	_particles.spread = SPREAD_ANGLE
	_particles.initial_velocity_min = INITIAL_VELOCITY_MIN
	_particles.initial_velocity_max = INITIAL_VELOCITY_MAX
	# Gravity pulls particles down after the initial spray.
	_particles.gravity = GRAVITY
	# Randomise scale for organic variation.
	_particles.scale_amount_min = SCALE_MIN
	_particles.scale_amount_max = SCALE_MAX
	# Fade out over the lifetime (alpha curve).
	_particles.color = Color(0.3, 0.6, 0.15, 0.9)  # grass green, slightly transparent
	var gradient := Gradient.new()
	gradient.set_color(0, Color(0.35, 0.65, 0.18, 1.0))  # bright green start
	gradient.add_point(0.5, Color(0.3, 0.55, 0.15, 0.8))
	gradient.set_color(1, Color(0.25, 0.45, 0.1, 0.0))  # fade to transparent
	_particles.color_ramp = gradient
	# Slight angular velocity for tumbling leaves.
	_particles.angular_velocity_min = -180.0
	_particles.angular_velocity_max = 180.0
	# Damping so particles slow down in the air.
	_particles.damping_min = 2.0
	_particles.damping_max = 5.0


func _create_particle_mesh() -> Mesh:
	# A tiny quad (leaf shape). Using a QuadMesh gives each particle a flat
	# rectangle that, when tinted green, reads as a leaf or grass blade.
	var quad := QuadMesh.new()
	quad.size = Vector2(0.06, 0.04)
	var leaf_mat := StandardMaterial3D.new()
	leaf_mat.albedo_color = Color(0.3, 0.6, 0.15)
	leaf_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	# Use vertex color so the particle process material's color/ramp is applied.
	leaf_mat.vertex_color_use_as_albedo = true
	# Billboard so the tiny quads always face the camera (more visible).
	leaf_mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	leaf_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	quad.material = leaf_mat
	return quad
