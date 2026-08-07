class_name TopDownCamera
extends Camera3D

## A fixed isometric camera that follows a target from above.
##
## This is the alternative to the car's chase camera ($Car/CameraPivot/Camera3D).
## The two differ in more than framing:
##
##   chase      perspective, parented to a pivot that yaws to follow the car's
##              heading, so the world appears to rotate around a static car.
##   this one   ORTHOGONAL, parented to the scene root and world-aligned, so the
##              car rotates within a static world.
##
## World alignment is the whole point of the isometric look — a top-down view
## that spun with the car would read as a map that never settles, and the long
## straight lines of streets and buildings would shear about constantly. So this
## camera deliberately does NOT inherit the car's rotation, which is also why it
## hangs off the scene root rather than off the car: parenting it to the car
## would inherit that rotation before any script could undo it.
##
## Orthogonal projection is what makes it isometric rather than merely high up:
## with no perspective divide, two buildings of equal height are drawn the same
## size regardless of distance, and verticals stay parallel.

## The node this camera follows, usually the car. A NodePath rather than a direct
## reference so the scene wires it up without any code reaching across the tree.
@export var target_path: NodePath

## Compass direction the camera looks FROM, in degrees around Y. 45 gives the
## classic isometric three-quarter view where streets running north-south and
## east-west both present a visible face.
@export var yaw_degrees: float = 45.0

## Angle above the horizon, in degrees. 35.264 (atan(1/sqrt(2))) is TRUE
## isometric: at that pitch the three world axes project to exactly 120 degrees
## apart on screen. Steeper reads more top-down, shallower more like a chase cam.
@export var pitch_degrees: float = 35.264

## How far the camera sits from its target along the view direction, in metres.
## With an orthogonal projection this does NOT affect how big anything appears —
## it only decides how much of the world sits in front of the near plane, so it
## needs to be large enough to clear tall buildings.
@export var view_distance: float = 120.0

## Half the vertical extent of the view, in metres — the orthogonal equivalent of
## FOV. 40 shows roughly an 80 m tall slice of world, enough to read a junction
## and its approaches without the car becoming a speck.
@export var ortho_size: float = 40.0

## Follow smoothing, in units of 1/second. The camera eases toward the target
## rather than being welded to it, so kerb strikes and suspension judder don't
## transfer straight to the view. Higher is tighter; 0 disables smoothing.
@export var follow_lerp: float = 8.0

var _target: Node3D = null


func _ready() -> void:
	projection = PROJECTION_ORTHOGONAL
	size = ortho_size
	if not target_path.is_empty():
		_target = get_node_or_null(target_path) as Node3D
	# Start already framed on the target. Without this the camera would spend its
	# first visible frames sliding in from wherever the scene left it, which on a
	# toggle looks like a glitch rather than a cut.
	if _target != null:
		_snap_to_target()


func _process(delta: float) -> void:
	# Nothing to follow, or not the camera being rendered: do no work. The tile
	# streamer picks the ACTIVE camera to centre on, so an idle camera that kept
	# updating would still be harmless — but a camera that costs nothing while
	# hidden is one less thing to explain when profiling.
	if _target == null or not current:
		return
	var desired := desired_position(
		_target.global_position, yaw_degrees, pitch_degrees, view_distance)
	var t := 1.0 if follow_lerp <= 0.0 else clampf(delta * follow_lerp, 0.0, 1.0)
	global_position = global_position.lerp(desired, t)
	_apply_orientation()


## Frame the target immediately, with no easing. Used on activation so switching
## to this camera is a cut rather than a swoop from the last place it was left.
func snap_to_target() -> void:
	if _target == null and not target_path.is_empty():
		_target = get_node_or_null(target_path) as Node3D
	if _target != null:
		_snap_to_target()


func _snap_to_target() -> void:
	global_position = desired_position(
		_target.global_position, yaw_degrees, pitch_degrees, view_distance)
	_apply_orientation()


## Point the camera from the angles rather than with look_at().
##
## look_at() is subtly wrong here: because the position is smoothed, the target
## sits slightly off-centre while the camera catches up, and look_at() rolls the
## camera to re-centre it — turning a small positional lag into a rotation of the
## entire world. Deriving the basis from the same angles that produced the
## position keeps the framing rock steady and lets the car drift off-centre,
## which is what the smoothing was for.
##
## It also has no answer at all at 90 degrees of pitch, where the view direction
## is parallel to the up vector it needs to build a basis from.
func _apply_orientation() -> void:
	global_basis = desired_basis(yaw_degrees, pitch_degrees)


## The camera orientation matching the angles used by desired_position.
##
## Pure function, like desired_position, so the orientation can be checked by
## arithmetic rather than inferred from a rendered picture.
##
## Columns are built so that:
##   +X (screen right)  is horizontal at every pitch, so the horizon never tilts.
##   +Z (behind the eye) is the same unit offset desired_position uses, so the
##                       camera looks exactly where it was placed to look.
##   +Y (screen up)     follows from the other two.
static func desired_basis(yaw_deg: float, pitch_deg: float) -> Basis:
	var yaw := deg_to_rad(yaw_deg)
	var pitch := deg_to_rad(pitch_deg)
	var sy := sin(yaw)
	var cy := cos(yaw)
	var sp := sin(pitch)
	var cp := cos(pitch)
	var z_axis := Vector3(sy * cp, sp, cy * cp)
	var x_axis := Vector3(cy, 0.0, -sy)
	# y = z cross x completes a right-handed frame. Its Y component works out to
	# cos(pitch), which is non-negative for any pitch up to straight down, so the
	# camera can never end up filming upside down.
	var y_axis := z_axis.cross(x_axis)
	return Basis(x_axis, y_axis, z_axis)


## Where the camera should sit to view `target` from the given angles.
##
## Pure function of its inputs — no node state, no scene tree — so the framing
## maths can be tested exactly rather than inferred from a rendered picture.
##
## Yaw is measured from +Z toward +X so that 0 looks from due south in Godot's
## right-handed, Y-up frame; pitch lifts the camera above the horizon. The result
## is the target displaced along that direction by `distance`, which keeps the
## camera the same distance out whatever the angles, so changing pitch alone
## doesn't also dolly the view.
static func desired_position(
		target: Vector3, yaw_deg: float, pitch_deg: float,
		distance: float) -> Vector3:
	var yaw := deg_to_rad(yaw_deg)
	var pitch := deg_to_rad(pitch_deg)
	var horizontal := cos(pitch)
	var offset := Vector3(
		sin(yaw) * horizontal,
		sin(pitch),
		cos(yaw) * horizontal) * distance
	return target + offset
