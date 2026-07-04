class_name CarController
extends VehicleBody3D

## VehicleBody3D-based car controller with simple arcade tuning.

## Emitted every physics frame with the current speed in km/h (mainly for the HUD).
signal speed_changed(speed_kmh: float)

## Emitted only when the active gear changes (e.g. -1 reverse, 0 neutral, 1..6).
## The HUD listens to this so it can show the current gear without polling.
signal gear_changed(gear: int)

## Emitted every physics frame with the running kudos total and the current combo
## multiplier. The HUD shows the player's style score from this.
signal kudos_changed(total: int, combo: float)

## Emitted when a discrete style moment or mistake happens (e.g. "DRIFT" +120,
## "CRASH" -90). The HUD flashes a popup from this. is_penalty marks mistakes so
## the HUD can colour them red.
signal kudos_event(label: String, amount: int, is_penalty: bool)

@export var max_speed: float = 55.0
@export var reverse_max_speed: float = 18.0
@export var engine_force_value: float = 3200.0
@export var reverse_engine_force: float = 1600.0
@export var brake_force_value: float = 65.0
@export var idle_brake_force: float = 8.0
@export var max_steer_angle: float = 0.32
@export var min_steer_angle: float = 0.05

## Locks the rear wheels when the handbrake (Space) is held. Much stronger than the
## regular brake so the rear axle stops rotating and breaks traction.
@export var handbrake_force_value: float = 200.0
## Rear-tyre grip while the handbrake is held. The lower this is relative to the normal
## wheel_friction_slip (2.0), the easier the back end steps out into a drift.
@export var handbrake_rear_friction: float = 0.6

## How aggressively the car resists rolling onto its side. 0 disables the assist.
@export var anti_roll_strength: float = 9000.0
## Roll angle (radians) past which the assist torque kicks in.
@export var anti_roll_deadzone: float = 0.12

## Body paint colour. Applied to the "Paintjob" surface of the car model at
## startup via CarPaint; the rest of the car (glass, chrome, lights, tyres) gets
## matching PBR materials so it reflects the sky/buildings under SSR. Change this
## to repaint the car.
@export var paint_color: Color = CarPaint.DEFAULT_PAINT_COLOR
## When off, the imported model's original materials are left as-is (A/B compare
## against the flat-shaded look, and a safety valve if a re-export changes names).
@export var apply_car_paint: bool = true

@onready var front_left_wheel: VehicleWheel3D = $FrontLeftWheel
@onready var front_right_wheel: VehicleWheel3D = $FrontRightWheel
@onready var rear_left_wheel: VehicleWheel3D = $RearLeftWheel
@onready var rear_right_wheel: VehicleWheel3D = $RearRightWheel

@onready var camera_pivot: Node3D = $CameraPivot
@onready var car_mesh: Node3D = $CarMesh
@onready var front_left_wheel_mesh: Node3D = $CarMesh/Wheel_Front_Right
@onready var front_right_wheel_mesh: Node3D = $CarMesh/Wheel_Front_Left
@onready var rear_left_wheel_mesh: Node3D = $CarMesh/Wheel_Rear_Right
@onready var rear_right_wheel_mesh: Node3D = $CarMesh/Wheel_Rear_Left

var _wheel_mesh_rotations: Dictionary[StringName, Basis] = {}

## Rear-tyre grip when the handbrake is not held, captured from _setup_wheels so the
## drift grip can be restored to whatever the wheels were originally tuned to.
var _rear_grip_normal: float = 2.0
## Tracks the current rear-grip state so we only write to the wheels on a change.
var _rear_grip_lowered: bool = false

## Gearbox helper. Maps the car's speed onto a gear for the HUD and drives the
## engine sound pitch. Purely cosmetic — the gear does not feed back into
## engine_force — but it gives the sound system a stable "what gear / RPM" answer.
var _transmission := Transmission.new()
## Last gear we emitted, so gear_changed only fires on an actual shift.
var _current_gear: int = Transmission.GEAR_NEUTRAL

## Engine audio: loops a single-gear sample and pitch-shifts it by RPM.
var _engine_sound := EngineSound.new()

## Surface detection: determines whether each wheel is on road or grass.
var _surface_detector := SurfaceDetector.new()
## Per-wheel particle emitters for off-road effects (grass spray).
var _wheel_particles: Array[WheelParticles] = []
## Cached surface per wheel (indexed same as _wheel_particles). Updated every
## _SURFACE_CHECK_INTERVAL physics frames to keep the cost down.
var _wheel_surfaces: Array[SurfaceDetector.Surface] = []
## Physics-frame counter for throttling surface detection (checking hundreds of
## road AABBs 4× per frame at 60 Hz is wasteful; every 3rd frame is plenty).
var _surface_tick: int = 0
const _SURFACE_CHECK_INTERVAL := 3

## Looping dirt/gravel sound that plays while any wheel is on grass above the
## particle speed threshold. A single non-3D player is enough because the car is
## always the listener's focus; volume and pitch scale with speed for feedback.
var _dirt_sound: AudioStreamPlayer = null
## Path to the looping gravel sample. Loaded once in _ready.
const _DIRT_SOUND_PATH := "res://sounds/dirt_driving.ogg"
## Volume (linear) floor/ceiling for the dirt sound so it blends gently.
const _DIRT_VOLUME_MIN_DB := -20.0
const _DIRT_VOLUME_MAX_DB := -6.0
## Pitch range: slow driving = lower rumble, fast = higher whir.
const _DIRT_PITCH_MIN := 0.7
const _DIRT_PITCH_MAX := 1.4

## Style scorer ("kudos"). Pure logic: every physics frame we hand it a snapshot
## of how the car is moving and it integrates a score, reporting drifts, crashes,
## near misses, etc. The HUD listens to the signals above; the car never embeds
## scoring numbers itself.
var _kudos := KudosTracker.new()
## Last kudos total we broadcast, so kudos_changed only fires on a real change
## (the running total is otherwise unchanged most frames once stationary).
var _last_kudos_total: int = -1
## How far ahead (m) to probe for obstacles when scoring near misses. Scaled by
## speed at query time so fast passes have a longer detection reach.
const _NEAR_MISS_PROBE_BASE := 6.0

## Silence or restore all car audio (engine loop and dirt driving sound).
## Called by the main scene when the pause menu opens / closes.
func set_engine_muted(muted: bool) -> void:
	_engine_sound.set_muted(muted)
	if _dirt_sound != null:
		if muted:
			_dirt_sound.stop()
		# Dirt sound restarts naturally via _update_dirt_sound() when un-muted.


func _ready() -> void:
	center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	# Drop the centre of mass well below the wheel mounts (wheels sit at ~Y 0.32).
	# A low COM is the single biggest factor in stopping arcade cars from flipping.
	center_of_mass = Vector3(0.0, -0.1, 0.0)
	# Make rolling about the long axis much harder than pitch/yaw. VehicleBody3D has
	# no built-in anti-roll bar, so a heavy roll inertia is the simplest stable fix.
	inertia = Vector3(2200.0, 1400.0, 900.0)
	_cache_wheel_mesh_rotations()
	_apply_car_paint()
	_setup_wheels()
	# Pre-compute the gear speed bands from this car's top speed so the very first
	# gear lookup is cheap and the HUD can show a gear immediately.
	_transmission.build_for_max_speed(max_speed * 3.6)
	_setup_wheel_particles()
	_setup_dirt_sound()
	add_child(_engine_sound)


func _cache_wheel_mesh_rotations() -> void:
	# Store the full rest global basis (orientation AND the parent CarMesh 0.6 scale).
	# We drive the meshes in global space, which bypasses the parent transform, so the
	# scale has to be carried here or the wheels render at full size (~2x too big).
	# The physics rotation is applied as an orthonormal basis on top of this.
	_wheel_mesh_rotations[front_left_wheel_mesh.name] = front_left_wheel_mesh.global_basis
	_wheel_mesh_rotations[front_right_wheel_mesh.name] = front_right_wheel_mesh.global_basis
	_wheel_mesh_rotations[rear_left_wheel_mesh.name] = rear_left_wheel_mesh.global_basis
	_wheel_mesh_rotations[rear_right_wheel_mesh.name] = rear_right_wheel_mesh.global_basis


## Swap the imported model's flat materials for PBR car-paint/glass/chrome/tyre
## materials so the car reads as a real vehicle and reflects the environment
## under SSR. Applied to the whole CarMesh subtree (body + wheels). Uses surface
## override materials, so the shared imported mesh resource is never mutated and
## other instances of the model (traffic cars) are unaffected.
func _apply_car_paint() -> void:
	if not apply_car_paint or car_mesh == null:
		return
	var painter := CarPaint.new()
	painter.apply_to(car_mesh, paint_color)


func _setup_wheels() -> void:
	for wheel in [front_left_wheel, front_right_wheel, rear_left_wheel, rear_right_wheel]:
		wheel.wheel_radius = 0.315
		wheel.wheel_rest_length = 0.2
		wheel.suspension_travel = 0.2
		wheel.suspension_stiffness = 30.0
		wheel.damping_compression = 2.5
		wheel.damping_relaxation = 3.5
		wheel.wheel_friction_slip = 2.0
		wheel.suspension_max_force = 12000.0
		# Roll influence transfers lateral grip into body roll torque. Near 0 keeps the
		# tyres planted instead of levering the chassis over in hard corners.
		wheel.wheel_roll_influence = 0.02

	front_left_wheel.use_as_steering = true
	front_right_wheel.use_as_steering = true
	front_left_wheel.use_as_traction = false
	front_right_wheel.use_as_traction = false

	rear_left_wheel.use_as_steering = false
	rear_right_wheel.use_as_steering = false
	rear_left_wheel.use_as_traction = true
	rear_right_wheel.use_as_traction = true

	# Remember the rear grip so the handbrake can drop it for a drift and restore it.
	_rear_grip_normal = rear_left_wheel.wheel_friction_slip


func _setup_wheel_particles() -> void:
	_surface_detector.init(get_tree())
	# Create one particle emitter per wheel, parented to the car so they move
	# with it but emit in world space (local_coords = false in WheelParticles).
	for wheel: VehicleWheel3D in [front_left_wheel, front_right_wheel,
			rear_left_wheel, rear_right_wheel]:
		var wp := WheelParticles.new()
		wp.name = "Particles_%s" % wheel.name
		add_child(wp)
		_wheel_particles.append(wp)
		_wheel_surfaces.append(SurfaceDetector.Surface.GRASS)


func _setup_dirt_sound() -> void:
	_dirt_sound = AudioStreamPlayer.new()
	_dirt_sound.name = "DirtDrivingSound"
	_dirt_sound.bus = &"Master"
	_dirt_sound.volume_db = _DIRT_VOLUME_MIN_DB
	# Stop the dirt sound when the scene tree is paused (pause menu).
	_dirt_sound.process_mode = Node.PROCESS_MODE_PAUSABLE
	var stream := load(_DIRT_SOUND_PATH)
	if stream is AudioStreamWAV:
		# Loop the sample seamlessly so it plays continuously while on grass.
		stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
		# loop_begin defaults to 0; loop_end = -1 tells the engine to loop to
		# the very last sample frame regardless of bit depth or channel count.
		stream.loop_end = -1
		_dirt_sound.stream = stream
	elif stream is AudioStream:
		_dirt_sound.stream = stream
	else:
		push_warning("CarController: could not load dirt sound at %s" % _DIRT_SOUND_PATH)
	add_child(_dirt_sound)


func _set_rear_friction(lowered: bool) -> void:
	if lowered == _rear_grip_lowered:
		return
	_rear_grip_lowered = lowered
	var grip := handbrake_rear_friction if lowered else _rear_grip_normal
	rear_left_wheel.wheel_friction_slip = grip
	rear_right_wheel.wheel_friction_slip = grip

func _physics_process(_delta: float) -> void:
	var forward_input := Input.get_action_strength("move_forward")
	var reverse_input := Input.get_action_strength("move_backward")
	var steer_input := Input.get_action_strength("steer_left") - Input.get_action_strength("steer_right")
	var handbrake_input := Input.get_action_strength("handbrake")
	var handbrake_active := handbrake_input > 0.0
	var forward_speed := linear_velocity.dot(global_transform.basis.z)
	var speed_ratio: float = clamp(abs(forward_speed) / max_speed, 0.0, 1.0)
	var steer_limit: float = lerp(max_steer_angle, min_steer_angle, speed_ratio)
	steer_limit *= clamp(1.0 - max(speed_ratio - 0.45, 0.0) * 1.3, 0.3, 1.0)

	var drive_force := 0.0
	var brake_force := idle_brake_force
	if forward_input > 0.0 and forward_speed < max_speed:
		drive_force = engine_force_value * forward_input
		brake_force = 0.0
	elif reverse_input > 0.0:
		if forward_speed > 1.0:
			brake_force = brake_force_value * reverse_input
		elif forward_speed > -reverse_max_speed:
			drive_force = -reverse_engine_force * reverse_input
			brake_force = 0.0

	if forward_speed > max_speed and drive_force > 0.0:
		drive_force = 0.0

	# Handbrake: lock the rear axle and break its grip so the back end can slide.
	# Cut engine force so the player can't power through the locked wheels, and apply
	# a strong brake to the rear only — the unbraked front wheels stay free to steer,
	# which is what lets the car rotate into a drift.
	var rear_brake := brake_force
	if handbrake_active:
		drive_force = 0.0
		rear_brake = handbrake_force_value * handbrake_input
	_set_rear_friction(handbrake_active)

	front_left_wheel.steering = steer_input * steer_limit
	front_right_wheel.steering = steer_input * steer_limit
	rear_left_wheel.engine_force = drive_force
	rear_right_wheel.engine_force = drive_force
	rear_left_wheel.brake = rear_brake
	rear_right_wheel.brake = rear_brake
	front_left_wheel.brake = brake_force * 0.35
	front_right_wheel.brake = brake_force * 0.35
	_apply_anti_roll(_delta)
	_sync_wheel_meshes()
	_update_camera_pivot(_delta)

	_update_wheel_particles()
	_broadcast_speed()
	_update_gear(forward_speed)
	_update_kudos(_delta, forward_speed)


func _apply_anti_roll(_delta: float) -> void:
	# Soft self-righting assist: once the chassis leans past the deadzone, push it back
	# toward upright. Scales with the lean so gentle cornering is untouched but a real
	# tip-over gets corrected before it becomes a flip.
	if anti_roll_strength <= 0.0:
		return
	# How far the car's right (local x) axis has tilted up/down relative to world up.
	# 0 = level, positive/negative = leaning to one side. This is the roll amount.
	var roll_amount := global_transform.basis.x.dot(Vector3.UP)
	if absf(roll_amount) <= anti_roll_deadzone:
		return
	var correction: float = (absf(roll_amount) - anti_roll_deadzone) * signf(roll_amount)
	# Torque about the forward axis opposes the lean; damp by angular velocity to avoid oscillation.
	var roll_rate := angular_velocity.dot(global_transform.basis.z)
	var torque := global_transform.basis.z * (-correction * anti_roll_strength - roll_rate * anti_roll_strength * 0.15)
	apply_torque(torque)


func _update_wheel_particles() -> void:
	var car_speed := linear_velocity.length()
	var wheels: Array[VehicleWheel3D] = [
		front_left_wheel, front_right_wheel,
		rear_left_wheel, rear_right_wheel,
	]
	# Throttle the expensive AABB scan: only re-detect surfaces every few frames.
	# The cached result is used in between, which is visually imperceptible since
	# particle lifetimes are ~0.6 s (much longer than the ~50 ms skip window).
	var do_detect := _surface_tick % _SURFACE_CHECK_INTERVAL == 0
	_surface_tick += 1
	for i: int in range(wheels.size()):
		var wheel := wheels[i]
		# Compute the wheel's world-space contact point: the bottom of the tyre.
		var wheel_global := global_transform * wheel.transform
		var contact_pos := wheel_global.origin - Vector3(0, wheel.wheel_radius, 0)
		if do_detect:
			_wheel_surfaces[i] = _surface_detector.detect(contact_pos)
		_wheel_particles[i].update_particles(contact_pos, _wheel_surfaces[i], car_speed)
	_update_dirt_sound(car_speed)


## Play or stop the dirt driving loop based on whether any wheel is on grass
## above the particle speed threshold. Volume and pitch scale with speed so
## the sound swells naturally with the particle spray.
func _update_dirt_sound(car_speed: float) -> void:
	if _dirt_sound == null or _dirt_sound.stream == null:
		return
	var any_on_grass := false
	for s: SurfaceDetector.Surface in _wheel_surfaces:
		if s == SurfaceDetector.Surface.GRASS:
			any_on_grass = true
			break
	var should_play: bool = any_on_grass and car_speed > WheelParticles.MIN_SPEED
	if should_play:
		var speed_factor := clampf(
			(car_speed - WheelParticles.MIN_SPEED) / 15.0, 0.0, 1.0
		)
		_dirt_sound.volume_db = lerpf(_DIRT_VOLUME_MIN_DB, _DIRT_VOLUME_MAX_DB, speed_factor)
		_dirt_sound.pitch_scale = lerpf(_DIRT_PITCH_MIN, _DIRT_PITCH_MAX, speed_factor)
		if not _dirt_sound.playing:
			_dirt_sound.play()
	else:
		if _dirt_sound.playing:
			_dirt_sound.stop()


func _sync_wheel_meshes() -> void:
	_sync_wheel_mesh(front_left_wheel, front_left_wheel_mesh)
	_sync_wheel_mesh(front_right_wheel, front_right_wheel_mesh)
	_sync_wheel_mesh(rear_left_wheel, rear_left_wheel_mesh)
	_sync_wheel_mesh(rear_right_wheel, rear_right_wheel_mesh)


func _sync_wheel_mesh(wheel: VehicleWheel3D, wheel_mesh: Node3D) -> void:
	# VehicleWheel3D.transform is expressed in the VehicleBody's local space and is
	# unscaled, while the mesh nodes live under CarMesh (scaled 0.6 + offset). Driving
	# them through global space avoids the parent-scale mismatch that made the wheels
	# float above the body and stick out the top.
	var wheel_global := global_transform * wheel.transform
	# spin carries the rest orientation + parent CarMesh scale; the physics basis is
	# orthonormalized so it only adds rotation (steering/roll) and never re-scales.
	var spin: Basis = _wheel_mesh_rotations.get(wheel_mesh.name, Basis.IDENTITY)
	wheel_mesh.global_position = wheel_global.origin
	wheel_mesh.global_basis = wheel_global.basis.orthonormalized() * spin


func _update_camera_pivot(delta: float) -> void:
	var flat_forward := Vector3(global_transform.basis.z.x, 0.0, global_transform.basis.z.z)
	if flat_forward.length_squared() < 0.001:
		return

	flat_forward = flat_forward.normalized()
	var target_basis := Basis.looking_at(flat_forward, Vector3.UP)
	camera_pivot.global_basis = camera_pivot.global_basis.slerp(target_basis, clamp(delta * 6.0, 0.0, 1.0))

func _broadcast_speed() -> void:
	var speed_kmh: float = linear_velocity.length() * 3.6
	speed_changed.emit(speed_kmh)


## Resolves the current gear from the signed forward speed, emits gear_changed
## on a real shift, and feeds the engine sound with the current gear/RPM.
## forward_speed is in m/s (the car's native unit); the transmission works in
## km/h, so both it and max_speed are converted with *3.6.
func _update_gear(forward_speed: float) -> void:
	var speed_kmh := forward_speed * 3.6
	var max_kmh := max_speed * 3.6
	var gear := _transmission.gear_for_speed(speed_kmh, max_kmh)
	if gear != _current_gear:
		_current_gear = gear
		gear_changed.emit(gear)
	var gear_ratio := _transmission.gear_ratio_for_speed(speed_kmh, max_kmh)
	_engine_sound.update_engine(absf(speed_kmh), gear, gear_ratio)


## Build a telemetry snapshot from the current physics state, feed it to the kudos
## tracker, and broadcast the result. forward_speed is the signed nose-direction
## speed already computed in _physics_process (m/s), reused here to avoid recomputing.
func _update_kudos(delta: float, forward_speed: float) -> void:
	var t := KudosTracker.Telemetry.new()
	t.forward_speed = forward_speed
	t.speed = linear_velocity.length()
	t.slip_angle = _compute_slip_angle()
	# Yaw rate is rotation about the car's local up axis (rad/s).
	t.yaw_rate = angular_velocity.dot(global_transform.basis.y)
	# Uprightness: 1 = level, 0 = on side, -1 = on roof.
	t.uprightness = global_transform.basis.y.dot(Vector3.UP)
	t.wheels_on_ground = _count_wheels_on_ground()
	t.on_road = _majority_on_road()
	t.nearest_obstacle_dist = _nearest_obstacle_distance(t.speed)

	var events := _kudos.update(t, delta)
	for ev: KudosTracker.KudosEvent in events:
		kudos_event.emit(ev.label, ev.amount, ev.is_penalty)

	var total := _kudos.get_kudos()
	if total != _last_kudos_total:
		_last_kudos_total = total
		kudos_changed.emit(total, _kudos.get_combo())


## Angle (radians) between where the nose points and where the car is actually
## travelling, on the horizontal plane. 0 = tracking straight, larger = sliding
## sideways (a drift). Returns 0 below a crawl so parking jitter doesn't register.
func _compute_slip_angle() -> float:
	var vel := linear_velocity
	vel.y = 0.0
	if vel.length() < 1.0:
		return 0.0
	# The car's forward axis is -basis.z in Godot's convention for a VehicleBody;
	# we only need the angle magnitude, so either sign of the forward axis works.
	var forward := global_transform.basis.z
	forward.y = 0.0
	if forward.length_squared() < 0.0001:
		return 0.0
	return absf(vel.normalized().angle_to(forward.normalized()))


## How many of the four wheels are currently touching the ground (0..4).
func _count_wheels_on_ground() -> int:
	var count := 0
	for wheel: VehicleWheel3D in [front_left_wheel, front_right_wheel,
			rear_left_wheel, rear_right_wheel]:
		if wheel.is_in_contact():
			count += 1
	return count


## True if at least three of the four wheels are over a road surface. Uses the
## cached per-wheel surfaces that _update_wheel_particles already maintains, so
## this is free — no extra AABB scans.
func _majority_on_road() -> bool:
	if _wheel_surfaces.is_empty():
		return true
	var on_road := 0
	for s: SurfaceDetector.Surface in _wheel_surfaces:
		if s == SurfaceDetector.Surface.ROAD:
			on_road += 1
	return on_road >= 3


## Cast a short ray out to each side of the car (perpendicular to travel) to find
## the nearest solid obstacle we're brushing past. Returns the closest hit
## distance, or a large sentinel when nothing is near. Only probes while moving so
## a parked car next to a wall does not farm near-miss points.
func _nearest_obstacle_distance(speed: float) -> float:
	const NO_HIT := 999.0
	if speed < 5.0:
		return NO_HIT
	var space := get_world_3d().direct_space_state
	# Probe from the car's centre out along its left and right axes. Reach grows
	# a little with speed so fast passes are easier to register as near misses.
	var reach: float = _NEAR_MISS_PROBE_BASE + clampf(speed * 0.1, 0.0, 4.0)
	var origin := global_position + Vector3(0.0, 0.4, 0.0)
	var right := global_transform.basis.x.normalized()
	var nearest := NO_HIT
	for dir: Vector3 in [right, -right]:
		var query := PhysicsRayQueryParameters3D.create(origin, origin + dir * reach)
		query.exclude = [get_rid()]
		# Only solid bodies count; ignore the road/terrain ribbon underfoot.
		var hit := space.intersect_ray(query)
		if not hit.is_empty():
			var d: float = origin.distance_to(hit.position)
			nearest = minf(nearest, d)
	return nearest
