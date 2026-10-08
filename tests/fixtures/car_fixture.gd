extends RefCounted

## A bare CarController with the wheels and child nodes its _ready resolves,
## without the imported model, audio files or the rest of main.tscn.

const CarControllerScript := preload("res://scripts/car_controller.gd")


static func make_car() -> CarController:
	var car: CarController = CarControllerScript.new()
	car.name = "Car"
	car.apply_car_paint = false
	for spec: Array in [
		["FrontLeftWheel", 0.83, 1.234, true, false],
		["FrontRightWheel", -0.83, 1.234, true, false],
		["RearLeftWheel", 0.83, -1.353, false, true],
		["RearRightWheel", -0.83, -1.353, false, true],
	]:
		var wheel := VehicleWheel3D.new()
		wheel.name = spec[0]
		wheel.position = Vector3(spec[1], 0.321, spec[2])
		wheel.use_as_steering = spec[3]
		wheel.use_as_traction = spec[4]
		car.add_child(wheel)
	var mesh := Node3D.new()
	mesh.name = "CarMesh"
	for wheel_mesh_name: String in [
		"Wheel_Front_Right", "Wheel_Front_Left", "Wheel_Rear_Right", "Wheel_Rear_Left"
	]:
		var wm := Node3D.new()
		wm.name = wheel_mesh_name
		mesh.add_child(wm)
	car.add_child(mesh)
	var pivot := Node3D.new()
	pivot.name = "CameraPivot"
	var cam := Camera3D.new()
	cam.name = "Camera3D"
	pivot.add_child(cam)
	car.add_child(pivot)
	return car
