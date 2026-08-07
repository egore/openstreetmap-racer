class_name TopDownCamera
extends Camera3D

## An orthogonal camera that follows a target from above.
##
## Two of the game's three camera modes are instances of this script; the third
## is the car's perspective chase camera ($Car/CameraPivot/Camera3D):
##
##   chase       perspective, parented to a pivot that yaws to follow the car's
##               heading, so the world appears to rotate around a static car.
##   isometric   this script at pitch 35.264 with follow_heading OFF: a fixed
##               three-quarter view, world-aligned, so the car turns beneath a
##               map that never moves.
##   top-down    this script at pitch 90 with follow_heading ON: straight down
##               with the car's nose locked to screen-up, the classic top-down
##               racer framing where the world sweeps around the car.
##
## Both overhead modes are parented to the scene root rather than to the car,
## because a child would inherit the car's rotation before any script could undo
## it — and the isometric mode's whole point is NOT inheriting it. The top-down
## mode does want the car's heading, but takes it as a number (see
## heading_yaw_degrees) rather than by parenting, so both modes run the same
## code path and only the exported angles differ.
##
## Orthogonal projection is what makes these read as map views rather than merely
## high camera angles: with no perspective divide, two buildings of equal height
## are drawn the same size regardless of distance, and verticals stay parallel.

## The node this camera follows, usually the car. A NodePath rather than a direct
## reference so the scene wires it up without any code reaching across the tree.
@export var target_path: NodePath

## Compass direction the camera looks FROM, in degrees around Y. 45 gives the
## classic isometric three-quarter view where streets running north-south and
## east-west both present a visible face.
##
## When follow_heading is on this is an OFFSET applied on top of the target's
## heading rather than an absolute bearing, so 0 sits directly behind the car.
@export var yaw_degrees: float = 45.0

## Angle above the horizon, in degrees. 35.264 (atan(1/sqrt(2))) is TRUE
## isometric: at that pitch the three world axes project to exactly 120 degrees
## apart on screen. 90 is straight down. Steeper reads more top-down, shallower
## more like a chase cam.
@export_range(0.0, 90.0, 0.001) var pitch_degrees: float = 35.264

## Whether the camera yaws with the target's heading (top-down racer framing, car
## nose locked to screen-up) or stays world-aligned (isometric map framing).
##
## This is the single flag that separates the two overhead modes, and it is a
## genuine trade rather than a preference: following the heading keeps the road
## ahead pointing up the screen so steering maps directly to left/right, but the
## whole world counter-rotates, which at 90 degrees of pitch is the only way to
## tell a straight-down view which way "forward" is. Leaving it off keeps north
## up so streets and buildings hold still, at the cost of the player having to
## re-map the controls mentally every time the car turns a corner.
@export var follow_heading: bool = false

## How fast the camera's yaw catches up to the target's heading, in units of
## 1/second, when follow_heading is on. Deliberately slower than the position
## follow: rotation is far more nauseating than translation, so a hard-locked
## yaw makes every twitch of the steering wheel spin the entire world. Easing it
## lets small corrections wash out and only sustained turns swing the view.
@export var heading_lerp: float = 4.0

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

## The yaw actually in use this frame, in degrees. Kept as state because with
## follow_heading on it EASES toward the target's heading rather than snapping to
## it, so each frame's value depends on the previous one. With follow_heading off
## it simply tracks yaw_degrees.
var _yaw_deg: float = 0.0


func _ready() -> void:
	projection = PROJECTION_ORTHOGONAL
	size = ortho_size
	if not target_path.is_empty():
		_target = get_node_or_null(target_path) as Node3D
	# Seed the eased yaw with the authored one so the first frame starts from a
	# sane angle rather than from 0, which for a heading-following camera would
	# otherwise swing the world round on startup.
	_yaw_deg = yaw_degrees
	# Start already framed on the target. Without this the camera would spend its
	# first visible frames sliding in from wherever the scene left it, which on a
	# mode switch looks like a glitch rather than a cut.
	if _target != null:
		_snap_to_target()


func _process(delta: float) -> void:
	# Nothing to follow, or not the camera being rendered: do no work. The tile
	# streamer picks the ACTIVE camera to centre on, so an idle camera that kept
	# updating would still be harmless — but a camera that costs nothing while
	# hidden is one less thing to explain when profiling.
	if _target == null or not current:
		return
	# Yaw first, position second: the position is DERIVED from the yaw, so easing
	# the angle and then placing the camera keeps the two agreeing within a single
	# frame. Placing first would orbit the camera to last frame's angle and then
	# orient it to this frame's, which shows up as a persistent lag in the framing
	# whenever the car is turning.
	var yaw_t := 1.0 if heading_lerp <= 0.0 else clampf(delta * heading_lerp, 0.0, 1.0)
	# lerp_angle rather than lerpf: yaw wraps, and a plain lerp from 179 to -179
	# takes the long way round, spinning the whole world through half a turn for
	# what is really a 2 degree correction.
	_yaw_deg = rad_to_deg(lerp_angle(
		deg_to_rad(_yaw_deg), deg_to_rad(_resolve_target_yaw()), yaw_t))
	var desired := desired_position(
		_target.global_position, _yaw_deg, pitch_degrees, view_distance)
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
	_yaw_deg = _resolve_target_yaw()
	global_position = desired_position(
		_target.global_position, _yaw_deg, pitch_degrees, view_distance)
	_apply_orientation()


## The yaw this camera wants to be at right now, before smoothing.
##
## World-aligned modes answer with the authored yaw and never move. Heading-
## following modes add the authored yaw as an OFFSET on top of the target's
## current heading, so yaw_degrees keeps meaning "rotate the view by this much"
## in both cases rather than switching between absolute and relative.
func _resolve_target_yaw() -> float:
	if not follow_heading or _target == null:
		return yaw_degrees
	# basis.z is forward for a VehicleBody3D (see car_controller.gd), which is the
	# opposite of the usual Node3D -Z convention. Reading it here rather than
	# taking a heading from the car keeps the camera usable with any Node3D.
	return heading_yaw_degrees(_target.global_basis.z, _yaw_deg - yaw_degrees) + yaw_degrees


## The yaw that puts `forward` pointing up the screen.
##
## Pure function, so the "car's nose points up" claim is arithmetic rather than
## something to squint at in a screenshot.
##
## `forward` is taken in world space and flattened; its Y is discarded because a
## car cresting a hill or landing nose-down must not roll the camera. A forward
## vector with no horizontal component (car perfectly nose-up, or a caller
## passing Vector3.ZERO) has no meaningful heading at all, so `fallback_deg` is
## returned rather than a value derived from atan2(0, 0) — otherwise a wheelie
## would snap the whole view to due south for the duration.
static func heading_yaw_degrees(forward: Vector3, fallback_deg: float) -> float:
	var flat := Vector2(forward.x, forward.z)
	if flat.length_squared() < 0.000001:
		return fallback_deg
	# desired_position places the camera at +yaw and it looks back along -yaw, so
	# the direction INTO the screen is the negated yaw axis. Negating here is what
	# puts the camera behind the car rather than in front of it staring back.
	return rad_to_deg(atan2(-flat.x, -flat.y))


## The camera orientation matching the angles used by desired_position.
##
## Returned as an explicit basis rather than left to look_at() because look_at()
## has no answer at 90 degrees of pitch: straight down, the view direction is
## parallel to the up vector it needs to build the basis from, and it degenerates.
## Since the top-down mode is defined by that exact angle, the one case that must
## work is the one look_at() cannot do.
##
## Columns are built so that:
##   +X (screen right)  is horizontal at every pitch, so the horizon never tilts.
##   +Z (behind the eye) is the same unit offset desired_position uses, so the
##                       camera looks exactly where it was placed to look.
##   +Y (screen up)     follows, and at pitch 90 lands on the ground-plane
##                      direction the camera is facing — which is what makes the
##                      car's nose point up the screen in the top-down mode.
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
	# cos(pitch), which is non-negative across the exported 0..90 range, so the
	# camera can never end up filming upside down.
	var y_axis := z_axis.cross(x_axis)
	return Basis(x_axis, y_axis, z_axis)


## Point the camera from the angles rather than with look_at().
##
## look_at() would fail outright at 90 degrees of pitch, where the view direction
## is parallel to the up vector it needs and the basis is undefined. It is also
## subtly wrong even where it works: because the position is smoothed, the target
## sits slightly off-centre while the camera catches up, and look_at() would roll
## the camera to re-centre it — turning a small positional lag into a rotation of
## the entire world. Deriving the basis from the same angles that produced the
## position keeps the framing rock steady and lets the car drift off-centre, which
## is what the smoothing was for.
func _apply_orientation() -> void:
	global_basis = desired_basis(_yaw_deg, pitch_degrees)


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
