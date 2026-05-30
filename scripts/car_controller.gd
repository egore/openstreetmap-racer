class_name CarController
extends VehicleBody3D

## VehicleBody3D-based car controller with simple arcade tuning.

## Emitted every physics frame with the current speed in km/h (mainly for the HUD).
signal speed_changed(speed_kmh: float)

@export var max_speed: float = 55.0
@export var reverse_max_speed: float = 18.0
@export var engine_force_value: float = 3200.0
@export var reverse_engine_force: float = 1600.0
@export var brake_force_value: float = 65.0
@export var idle_brake_force: float = 8.0
@export var max_steer_angle: float = 0.32
@export var min_steer_angle: float = 0.05

## How aggressively the car resists rolling onto its side. 0 disables the assist.
@export var anti_roll_strength: float = 9000.0
## Roll angle (radians) past which the assist torque kicks in.
@export var anti_roll_deadzone: float = 0.12

@onready var front_left_wheel: VehicleWheel3D = $FrontLeftWheel
@onready var front_right_wheel: VehicleWheel3D = $FrontRightWheel
@onready var rear_left_wheel: VehicleWheel3D = $RearLeftWheel
@onready var rear_right_wheel: VehicleWheel3D = $RearRightWheel

@onready var camera_pivot: Node3D = $CameraPivot
@onready var camera: Camera3D = $CameraPivot/Camera3D
@onready var car_mesh: Node3D = $CarMesh
@onready var front_left_wheel_mesh: Node3D = $CarMesh/Wheel_Front_Right
@onready var front_right_wheel_mesh: Node3D = $CarMesh/Wheel_Front_Left
@onready var rear_left_wheel_mesh: Node3D = $CarMesh/Wheel_Rear_Right
@onready var rear_right_wheel_mesh: Node3D = $CarMesh/Wheel_Rear_Left

var _wheel_mesh_rotations: Dictionary[StringName, Basis] = {}

func _ready() -> void:
	center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	# Drop the centre of mass well below the wheel mounts (wheels sit at ~Y 0.32).
	# A low COM is the single biggest factor in stopping arcade cars from flipping.
	center_of_mass = Vector3(0.0, -0.1, 0.0)
	# Make rolling about the long axis much harder than pitch/yaw. VehicleBody3D has
	# no built-in anti-roll bar, so a heavy roll inertia is the simplest stable fix.
	inertia = Vector3(2200.0, 1400.0, 900.0)
	_cache_wheel_mesh_rotations()
	_setup_wheels()


func _cache_wheel_mesh_rotations() -> void:
	# Store the full rest global basis (orientation AND the parent CarMesh 0.6 scale).
	# We drive the meshes in global space, which bypasses the parent transform, so the
	# scale has to be carried here or the wheels render at full size (~2x too big).
	# The physics rotation is applied as an orthonormal basis on top of this.
	_wheel_mesh_rotations[front_left_wheel_mesh.name] = front_left_wheel_mesh.global_basis
	_wheel_mesh_rotations[front_right_wheel_mesh.name] = front_right_wheel_mesh.global_basis
	_wheel_mesh_rotations[rear_left_wheel_mesh.name] = rear_left_wheel_mesh.global_basis
	_wheel_mesh_rotations[rear_right_wheel_mesh.name] = rear_right_wheel_mesh.global_basis


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

func _physics_process(_delta: float) -> void:
	var forward_input := Input.get_action_strength("move_forward")
	var reverse_input := Input.get_action_strength("move_backward")
	var steer_input := Input.get_action_strength("steer_left") - Input.get_action_strength("steer_right")
	var forward_speed := linear_velocity.dot(global_transform.basis.z)
	var speed_ratio: float = clamp(abs(forward_speed) / max_speed, 0.0, 1.0)
	var steer_limit: float = lerp(max_steer_angle, min_steer_angle, speed_ratio)
	steer_limit *= clamp(1.0 - max(speed_ratio - 0.45, 0.0) * 1.3, 0.3, 1.0)

	var engine_force := 0.0
	var brake_force := idle_brake_force
	if forward_input > 0.0 and forward_speed < max_speed:
		engine_force = engine_force_value * forward_input
		brake_force = 0.0
	elif reverse_input > 0.0:
		if forward_speed > 1.0:
			brake_force = brake_force_value * reverse_input
		elif forward_speed > -reverse_max_speed:
			engine_force = -reverse_engine_force * reverse_input
			brake_force = 0.0

	if forward_speed > max_speed and engine_force > 0.0:
		engine_force = 0.0

	front_left_wheel.steering = steer_input * steer_limit
	front_right_wheel.steering = steer_input * steer_limit
	rear_left_wheel.engine_force = engine_force
	rear_right_wheel.engine_force = engine_force
	rear_left_wheel.brake = brake_force
	rear_right_wheel.brake = brake_force
	front_left_wheel.brake = brake_force * 0.35
	front_right_wheel.brake = brake_force * 0.35
	_apply_anti_roll(_delta)
	_sync_wheel_meshes()
	_update_camera_pivot(_delta)

	_broadcast_speed()


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
