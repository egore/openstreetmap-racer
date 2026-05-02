class_name CarController
extends VehicleBody3D

## VehicleBody3D-based car controller with simple arcade tuning.

@export var max_speed: float = 55.0
@export var reverse_max_speed: float = 18.0
@export var engine_force_value: float = 3200.0
@export var reverse_engine_force: float = 1600.0
@export var brake_force_value: float = 65.0
@export var idle_brake_force: float = 8.0
@export var max_steer_angle: float = 0.32
@export var min_steer_angle: float = 0.05

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
	center_of_mass = Vector3(0.0, -0.95, 0.0)
	_align_wheels_to_meshes()
	_cache_wheel_mesh_rotations()
	_setup_wheels()


func _align_wheels_to_meshes() -> void:
	front_left_wheel.position = front_left_wheel_mesh.position
	front_right_wheel.position = front_right_wheel_mesh.position
	rear_left_wheel.position = rear_left_wheel_mesh.position
	rear_right_wheel.position = rear_right_wheel_mesh.position


func _cache_wheel_mesh_rotations() -> void:
	_wheel_mesh_rotations[front_left_wheel_mesh.name] = front_left_wheel_mesh.basis
	_wheel_mesh_rotations[front_right_wheel_mesh.name] = front_right_wheel_mesh.basis
	_wheel_mesh_rotations[rear_left_wheel_mesh.name] = rear_left_wheel_mesh.basis
	_wheel_mesh_rotations[rear_right_wheel_mesh.name] = rear_right_wheel_mesh.basis


func _setup_wheels() -> void:
	for wheel in [front_left_wheel, front_right_wheel, rear_left_wheel, rear_right_wheel]:
		wheel.wheel_radius = 0.38
		wheel.wheel_rest_length = 0.14
		wheel.suspension_travel = 0.12
		wheel.suspension_stiffness = 70.0
		wheel.damping_compression = 0.55
		wheel.damping_relaxation = 0.9
		wheel.wheel_friction_slip = 2.2
		wheel.suspension_max_force = 18000.0
		wheel.wheel_roll_influence = 1.0

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
	_sync_wheel_meshes()
	_update_camera_pivot(_delta)

	_update_hud()


func _sync_wheel_meshes() -> void:
	_sync_wheel_mesh(front_left_wheel, front_left_wheel_mesh)
	_sync_wheel_mesh(front_right_wheel, front_right_wheel_mesh)
	_sync_wheel_mesh(rear_left_wheel, rear_left_wheel_mesh)
	_sync_wheel_mesh(rear_right_wheel, rear_right_wheel_mesh)


func _sync_wheel_mesh(wheel: VehicleWheel3D, wheel_mesh: Node3D) -> void:
	wheel_mesh.position = wheel.position
	wheel_mesh.basis = wheel.basis * _wheel_mesh_rotations.get(wheel_mesh.name, Basis.IDENTITY)


func _update_camera_pivot(delta: float) -> void:
	var flat_forward := Vector3(global_transform.basis.z.x, 0.0, global_transform.basis.z.z)
	if flat_forward.length_squared() < 0.001:
		return

	flat_forward = flat_forward.normalized()
	var target_basis := Basis.looking_at(flat_forward, Vector3.UP)
	camera_pivot.global_basis = camera_pivot.global_basis.slerp(target_basis, clamp(delta * 6.0, 0.0, 1.0))

func _update_hud() -> void:
	var speed_kmh: float = linear_velocity.length() * 3.6
	var hud := get_node_or_null("/root/Main/HUD/SpeedLabel")
	if hud and hud is Label:
		(hud as Label).text = "%d km/h" % int(speed_kmh)
