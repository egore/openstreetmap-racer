class_name CarController
extends CharacterBody3D

## Simple car controller for driving around the OSM world.
## Uses CharacterBody3D for movement (no physics sim yet).

@export var max_speed: float = 30.0        # m/s (~108 km/h)
@export var acceleration: float = 12.0     # m/s²
@export var braking: float = 20.0          # m/s²
@export var friction: float = 5.0          # m/s² passive slowdown
@export var steering_speed: float = 2.5    # rad/s at low speed
@export var min_steering_speed: float = 0.8 # rad/s at max speed

var _speed: float = 0.0
var _steer_angle: float = 0.0

@onready var camera_pivot: Node3D = $CameraPivot
@onready var camera: Camera3D = $CameraPivot/Camera3D
@onready var car_mesh: Node3D = $CarMesh

func _ready() -> void:
	# Start slightly above ground
	position.y = 0.5

func _physics_process(delta: float) -> void:
	# Acceleration / braking
	var input_accel := Input.get_action_strength("move_forward") - Input.get_action_strength("move_backward")

	if input_accel > 0.0:
		_speed += acceleration * delta * input_accel
	elif input_accel < 0.0:
		_speed += braking * delta * input_accel  # input_accel is negative
	else:
		# Friction
		if _speed > 0.0:
			_speed = max(0.0, _speed - friction * delta)
		elif _speed < 0.0:
			_speed = min(0.0, _speed + friction * delta)

	_speed = clamp(_speed, -max_speed * 0.3, max_speed)

	# Steering (less responsive at high speed)
	var speed_factor: float = 1.0 - (abs(_speed) / max_speed) * 0.7
	var current_steering: float = lerp(min_steering_speed, steering_speed, speed_factor)

	var steer_input := Input.get_action_strength("steer_left") - Input.get_action_strength("steer_right")
	if abs(_speed) > 0.5:
		var steer_amount: float = steer_input * current_steering * delta
		rotate_y(steer_amount * sign(_speed))

	# Apply movement
	var forward := -transform.basis.z
	velocity = forward * _speed
	velocity.y -= 9.8 * delta  # gravity

	move_and_slide()

	# HUD info (speed display)
	_update_hud()

func _update_hud() -> void:
	var speed_kmh: float = abs(_speed) * 3.6
	var hud := get_node_or_null("/root/Main/HUD/SpeedLabel")
	if hud and hud is Label:
		(hud as Label).text = "%d km/h" % int(speed_kmh)
