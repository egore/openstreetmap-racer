class_name TrafficCar
extends RigidBody3D

## A single AI traffic car (a stub "block" for now) that drives along an OSM road
## polyline. Owned and pooled by the TrafficManager.
##
## Level of detail — the crux of keeping a whole city of traffic cheap:
##
##   DETAILED (in view / near the player): the car is a full physics body. Its
##     collision is active so the player can bump it, and it is nudged along its
##     route by steering toward the next path point. It looks and reacts like a
##     real obstacle.
##
##   CHEAP (out of view / far away): the car freezes its physics and simply
##     advances a scalar distance along its polyline each frame, teleporting its
##     transform to the interpolated point. No collision solving, no forces — it
##     just has to be *somewhere plausible* on a road so that when it streams back
##     into view it's in a sensible spot. This is the "less valid physics off
##     screen" the design asks for.
##
## The manager flips a car between modes with set_detailed(); the car does not
## decide its own LOD (the manager owns the camera/visibility knowledge).

## How fast this car cruises along its route, meters/second. Set per-car by the
## manager (with a little variance) so traffic isn't lock-step.
var cruise_speed: float = 8.0

## Lateral offset (meters) applied to the right of the road centreline so cars
## keep to the right-hand lane instead of straddling the middle of the road.
## Positive = right of travel direction. Set per-route by the manager from the
## road width: a two-way road offsets by a quarter-width (the centre of the right
## half); a one-way road stays on the centreline (0) since it uses the whole
## carriageway. "Right" is derived from the *travel* direction each frame, so a
## reversed traversal (points already flipped by the manager) still hugs the
## correct kerb.
var _lane_offset: float = 0.0

## The road polyline this car follows and its travel direction. Assigned by the
## manager when the car is (re)spawned onto a road.
var _path: PackedVector3Array = PackedVector3Array()
## Signed progress along the path in meters from points[0].
var _distance: float = 0.0
## Cached total length of _path so we can wrap/despawn at the end.
var _path_length: float = 0.0

## Stable identity of the road this car is currently on: the OSM way id and
## whether it's being traversed reversed (walking the polyline from its far end).
## The manager reads these to (a) count cars per road correctly and (b) continue
## the car onto a *connected* road at the far junction instead of teleporting it
## somewhere random. -1 = unrouted.
var _way_id: int = -1
var _reversed: bool = false
## How far past the end of the route the car has travelled this frame. Carried
## over into the next road when continuing, so speed is unbroken across a
## junction (no pause or backward snap at the seam).
var _overshoot: float = 0.0
## True while the car is a full physics obstacle (in view); false while it is a
## cheap kinematic mover (off screen).
var _detailed: bool = false
## Height to hold the block above the road surface so it rests on the asphalt
## rather than sinking into it (half the body height).
const _RIDE_HEIGHT := 0.5
## Steepest grade (rise/run) the body will pitch to. Clamps the pitch so a near-
## vertical jump between two path points (e.g. a mapping glitch or a very coarse
## DEM) can't tip a car onto its nose. tan(~40 deg) ≈ 0.84 covers any real road.
const _MAX_GRADE := 0.84

## Steering/throttle tuning for the DETAILED mode. The block is driven with
## direct velocity steering (not wheels) — it's a stub, so we keep it simple and
## stable rather than simulating a full drivetrain.
const _STEER_LERP := 6.0
const _SPEED_LERP := 4.0
## How far ahead on the route the pursuit controller aims (meters). Larger =
## smoother/lazier steering that anticipates curves; smaller = tighter tracking
## but more prone to jitter. ~6 m reads as a car looking down the road.
const _LOOK_AHEAD := 6.0
## Distance from a road's end (meters) at which the car is treated as having
## arrived at the junction, so the manager continues it onto the next road
## instead of the car crawling asymptotically toward the exact end and stalling.
const _END_TOLERANCE := 1.5


func _ready() -> void:
	# Blocks shouldn't roll or spin on their own, but they DO need to pitch to
	# follow the road grade (otherwise a rigid level box on a hill rests on one
	# bumper with the other floating, and gravity crabs it sideways down the
	# slope). So lock only roll (Z); leave pitch (X) free for _slope_basis to
	# drive by hand, and yaw (Y) free for steering.
	axis_lock_angular_z = true
	# Start frozen; the manager decides the initial LOD right after spawning.
	freeze = true
	# Halt with the scene when the game is paused. The traffic tree lives under
	# Main, which runs PROCESS_MODE_ALWAYS (so Escape keeps working); without this
	# the cars would inherit ALWAYS and keep driving through the pause menu.
	process_mode = Node.PROCESS_MODE_PAUSABLE
	_randomize_color()


## Give this car a unique random colour via a per-instance material_override, so
## every block is visually distinct (a debugging aid for watching cars flow from
## road to road). Overriding rather than editing the mesh's material leaves the
## shared scene material untouched. A high-value, mid-saturation HSV colour keeps
## the blocks bright and legible against the road/terrain.
func _randomize_color() -> void:
	var mesh := $Mesh as MeshInstance3D
	if mesh == null:
		return
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color.from_hsv(randf(), 0.7, 0.95)
	mat.metallic = 0.1
	mat.roughness = 0.6
	mesh.material_override = mat


## Assign a route and starting distance, hard-placing the car on the road (a
## teleport). Used for fresh spawns and recycling. way_id / reversed record which
## road (and direction) this is so the manager can count and continue the car
## correctly; pass way_id = -1 for an anonymous route (e.g. a test).
func set_route(path: PackedVector3Array, start_distance: float, way_id: int = -1, reversed: bool = false, lane_offset: float = 0.0) -> void:
	_path = path
	_path_length = _polyline_length(path)
	_distance = clampf(start_distance, 0.0, _path_length)
	_way_id = way_id
	_reversed = reversed
	_lane_offset = lane_offset
	_overshoot = 0.0
	_snap_to_path()


## Continue onto a *connected* road at a shared junction. The new road's entering
## endpoint is the same OSM node the car just reached, so the car is already
## essentially there — we place it exactly on that seam and re-aim its motion down
## the new road.
##
## Why we reposition even a detailed (physics) car: leaving the body wherever
## physics left it caused a stuck loop. A car that *overshot* the junction sits a
## bit past the node along the OLD road's heading; when the new road turns, that
## position + stale sideways momentum projects ambiguously (near the start, or
## even past a short road's end), so it kept re-triggering "finished" and never
## advanced. Snapping to the seam is a sub-metre correction (invisible) that
## removes the ambiguity, and re-aiming the velocity kills the old heading so the
## car doesn't fight the new road's direction.
func continue_route(path: PackedVector3Array, start_distance: float, way_id: int, reversed: bool, lane_offset: float = 0.0) -> void:
	_path = path
	_path_length = _polyline_length(path)
	_distance = clampf(start_distance, 0.0, _path_length)
	_way_id = way_id
	_reversed = reversed
	_lane_offset = lane_offset
	_overshoot = 0.0
	_snap_to_path()
	# Re-aim existing momentum down the new road so a detailed car crosses the
	# seam smoothly instead of carrying the previous road's heading into a wall.
	if _detailed:
		var speed := linear_velocity.length()
		if speed > 0.01:
			var ahead := _point_at_distance(minf(_distance + 1.0, _path_length))
			var here := global_position
			var dir := ahead - here
			dir.y = 0.0
			if dir.length_squared() > 0.0001:
				var v := dir.normalized() * speed
				v.y = linear_velocity.y
				linear_velocity = v


## Total drivable length of the current route (0 when unrouted).
func path_length() -> float:
	return _path_length


## Current progress along the route in meters.
func distance_along() -> float:
	return _distance


## The OSM way id of the road this car is currently on (-1 when unrouted). Stable
## identity the manager uses to count cars per road and find the connected road
## to continue onto.
func current_way_id() -> int:
	return _way_id


## Whether the current road is being traversed reversed (far endpoint first).
func is_reversed() -> bool:
	return _reversed


## Meters the car ran past the end of its route before it was recycled, so the
## next road can start that far in and keep speed continuous across the junction.
func overshoot() -> float:
	return _overshoot


## True once the car has reached (within a small tolerance of) the end of its
## route and should be handed onto a connected road, or teleported if the
## junction is a dead end. Also true for an unrouted car so it's picked up
## immediately. The tolerance matches _drive_detailed so both agree on "done"
## and a car never sits crawling at a seam waiting to hit the exact end.
func is_finished() -> bool:
	return _path_length <= 0.0 or _distance >= _path_length - _END_TOLERANCE


## Switch level of detail. In detailed mode the body participates in physics
## (collision on, unfrozen); in cheap mode it is frozen and moved kinematically.
func set_detailed(detailed: bool) -> void:
	if detailed == _detailed:
		return
	_detailed = detailed
	freeze = not detailed
	# Keep the collider present in both modes so a car that pops into view is
	# instantly solid, but only the detailed cars actually resolve contacts
	# (frozen bodies are static and cheap). Sleeping is disabled so a detailed
	# car keeps being nudged along its route.
	can_sleep = not detailed
	if detailed:
		sleeping = false


func is_detailed() -> bool:
	return _detailed


func _physics_process(delta: float) -> void:
	if _path_length <= 0.0:
		return
	if _detailed:
		_drive_detailed(delta)
	else:
		_drive_cheap(delta)


## DETAILED: drive the physics body along the route with a closed-loop pursuit
## controller. Every frame we re-derive our real progress by projecting the
## body's actual position onto the polyline (_closest_distance), then steer
## toward a look-ahead point a fixed distance further along. Steering toward a
## point *ahead* (not the closest point) is what keeps the motion smooth on
## curves; deriving progress from the real position (not dead reckoning) is what
## stops the target racing ahead of the body and inducing the wave/oscillation.
func _drive_detailed(delta: float) -> void:
	# Re-sync progress to where the body actually is. This closes the loop: the
	# open-loop _advance() used to let _distance run ahead of the body, so on a
	# bend the "on-path" point sat around the corner and the lateral correction
	# flung the car sideways — the waving you saw near the roundabout.
	_distance = _closest_distance(global_position)
	if _distance >= _path_length - _END_TOLERANCE:
		# Close enough to the junction: report finished so the manager hands us to
		# the next road *now*. Waiting to hit the exact end never happens because
		# the look-ahead target stops advancing there and the car crawls to a
		# standstill — that asymptotic stall is what made cars get stuck at seams.
		_overshoot = 0.0
		return

	# Look-ahead target: a point _LOOK_AHEAD metres further down the road. Pursuing
	# it gives gentle, anticipatory steering into curves instead of chasing the
	# nearest point (which causes corner-cutting and jitter). Clamp short of the
	# very end so the target always leads the car (never a zero-length vector).
	var look := minf(_distance + _LOOK_AHEAD, _path_length - _END_TOLERANCE * 0.5)
	# Aim at the look-ahead point shifted into the right-hand lane, so the pursuit
	# controller both tracks along the road AND pulls the body over to the correct
	# side. The lateral pull-back the centreline pursuit already provides now
	# settles the car on the lane line rather than the middle of the carriageway.
	var target := _lane_point_at_distance(look)
	var here := global_position
	var to_target := target - here
	to_target.y = 0.0
	if to_target.length_squared() < 0.0001:
		return
	var steer := to_target.normalized()

	# Drive at cruise speed toward the look-ahead point. Because the target is on
	# the centreline ahead, this heading naturally folds in the lateral pull-back
	# when the body is off-line — no separate (destabilising) lateral term needed.
	var desired_vel := steer * cruise_speed
	desired_vel.y = linear_velocity.y  # let gravity/suspension own vertical
	linear_velocity = linear_velocity.lerp(desired_vel, clampf(delta * _SPEED_LERP, 0.0, 1.0))
	_face_direction(steer, delta)


## CHEAP: no physics — just walk the scalar distance forward and teleport the
## transform onto the interpolated path point. Cheap enough to run for hundreds
## of off-screen cars.
func _drive_cheap(delta: float) -> void:
	_advance(cruise_speed * delta)
	_snap_to_path()


## Move `step` meters forward along the route, clamping at the end and banking any
## excess as overshoot. Keeping _distance clamped (instead of letting it run past
## path_length) means is_finished() latches cleanly at the seam and the recorded
## overshoot lets the continuation resume without a stutter.
func _advance(step: float) -> void:
	if _path_length <= 0.0:
		return
	var new_dist := _distance + step
	if new_dist >= _path_length:
		_overshoot = new_dist - _path_length
		_distance = _path_length
	else:
		_distance = new_dist


## Place the body exactly on the route at the current distance, facing forward
## AND pitched along the road's grade — like a real car sitting on a hill.
func _snap_to_path() -> void:
	if _path_length <= 0.0:
		return
	var pos := _lane_point_at_distance(_distance)
	# Sample the point ahead *before* lifting `pos`, so the direction vector keeps
	# the road's true rise/run and the car pitches with the grade. Offset the
	# ahead point too so the heading follows the (parallel) lane path, not a line
	# angling out from the centreline to the offset body.
	var ahead := _lane_point_at_distance(minf(_distance + 1.0, _path_length))
	var dir := ahead - pos
	pos.y += _RIDE_HEIGHT
	global_position = pos
	var target: Variant = _slope_basis(dir)
	if target != null:
		global_transform.basis = target


## Smoothly rotate the body to face `dir` while in detailed mode, pitching along
## the road grade (the Y component of `dir` is honoured) without ever rolling.
func _face_direction(dir: Vector3, delta: float) -> void:
	var target_basis: Variant = _slope_basis(dir)
	if target_basis == null:
		return
	# _slope_basis returns an orthonormalized rotation, and we orthonormalize the
	# current basis too — both are required or slerp's internal quaternion cast
	# rejects a non-rotation basis (the spammed "must be normalized" error).
	var b := global_transform.basis.orthonormalized().slerp(
		target_basis as Basis, clampf(delta * _STEER_LERP, 0.0, 1.0))
	global_transform.basis = b


## Orientation for a car travelling along `dir` on sloped ground: forward follows
## the full 3D direction (so the body pitches up/down the grade), while the right
## axis is kept horizontal so the car never rolls or twists sideways across the
## slope. This mirrors how the road mesh is *draped* onto the terrain — it follows
## the elevation without twisting the cross-section. Returns null for a degenerate
## (zero-length) direction so callers can leave the current orientation untouched.
##
## Why not `look_at`/`Basis.looking_at` with a flattened dir: that forces the body
## dead-level, so on a hill a rigid box touches the road at one edge (front bumper
## down, rear floating) and gravity crabs it sideways down the grade. Keeping the
## grade in `forward` lets the whole underside sit on the slope.
func _slope_basis(dir: Vector3) -> Variant:
	# Horizontal heading first: the yaw must come purely from the XZ travel
	# direction so a steep segment can't wash out the compass heading.
	var flat := Vector3(dir.x, 0.0, dir.z)
	if flat.length_squared() < 0.0001:
		return null
	flat = flat.normalized()
	# Grade (rise over horizontal run), clamped so a near-vertical seam between
	# two path points can never flip the car onto its nose.
	var run := Vector2(dir.x, dir.z).length()
	var slope := 0.0
	if run > 0.0001:
		slope = clampf(dir.y / run, -_MAX_GRADE, _MAX_GRADE)
	# Forward tilted by the grade; right stays perfectly horizontal (no roll).
	var forward := (flat + Vector3.UP * slope).normalized()
	# Right = forward × UP keeps a RIGHT-HANDED basis (X × Y = Z). Using UP ×
	# forward instead makes a reflection (determinant -1), which is NOT a rotation
	# — the quaternion cast then rejects it and spams the "must be normalized"
	# error every frame. Recompute up so all three axes are exactly orthonormal.
	var right := forward.cross(Vector3.UP).normalized()
	var up := right.cross(forward).normalized()
	# Godot's convention: the body's forward is -Z, so column Z = -forward.
	# Orthonormalize to scrub residual float drift, so the result is a valid
	# rotation the physics server and Basis.slerp/quaternion cast will accept.
	return Basis(right, up, -forward).orthonormalized()


## Arc-length distance (meters from the route start) of the point on the polyline
## closest to `world_pos`, considered in the XZ plane. This is the inverse of
## _point_at_distance and the key to stable steering: by re-deriving _distance
## from where the body *actually is* each frame (closed loop) instead of dead-
## reckoning it open-loop, the look-ahead target and the lateral error stay
## honest even on curves — which is what stops the car waving around bends.
func _closest_distance(world_pos: Vector3) -> float:
	if _path.size() < 2:
		return 0.0
	var p := Vector2(world_pos.x, world_pos.z)
	var best_dist := 0.0
	var best_d2 := INF
	var travelled := 0.0
	for i: int in range(_path.size() - 1):
		var a := Vector2(_path[i].x, _path[i].z)
		var b := Vector2(_path[i + 1].x, _path[i + 1].z)
		var ab := b - a
		var seg_len := ab.length()
		if seg_len > 0.0001:
			# Parameter of the projection of p onto segment [a,b], clamped to it.
			var t := clampf((p - a).dot(ab) / (seg_len * seg_len), 0.0, 1.0)
			var proj := a + ab * t
			var d2 := p.distance_squared_to(proj)
			if d2 < best_d2:
				best_d2 = d2
				best_dist = travelled + t * seg_len
		travelled += seg_len
	return best_dist


## World point `dist` meters along the route, clamped to the polyline. Linear
## interpolation between the two bracketing points.
##
## Distance is measured in the XZ (ground) plane, NOT full 3D, so it agrees with
## _closest_distance (which projects onto XZ). Mixing the two — 3D arc length here
## but XZ projection there — made the look-ahead target and the derived progress
## disagree on slopes, which pulled the car off the centreline (the "driving
## sideways" on hills). The interpolated point still carries the correct 3D Y.
func _point_at_distance(dist: float) -> Vector3:
	if _path.size() == 0:
		return global_position
	if _path.size() == 1 or dist <= 0.0:
		return _path[0]
	var remaining := dist
	for i: int in range(_path.size() - 1):
		var seg := _xz_distance(_path[i], _path[i + 1])
		if remaining <= seg or i == _path.size() - 2:
			if seg <= 0.0001:
				return _path[i + 1]
			var t := clampf(remaining / seg, 0.0, 1.0)
			return _path[i].lerp(_path[i + 1], t)
		remaining -= seg
	return _path[_path.size() - 1]


## The point `dist` meters along the route, shifted `_lane_offset` meters to the
## right of the centreline so the car keeps to its lane instead of the middle of
## the road. "Right" is taken from the local travel direction (the tangent at
## `dist`), computed in the XZ plane so the offset is purely lateral and never
## lifts or drops the car off the road surface. With _lane_offset == 0 this is
## exactly _point_at_distance, so one-way / centred routes are unaffected.
func _lane_point_at_distance(dist: float) -> Vector3:
	var pos := _point_at_distance(dist)
	if absf(_lane_offset) < 0.0001 or _path_length <= 0.0:
		return pos
	# Local tangent (travel direction) in the ground plane. Sample a short step
	# ahead, falling back to a step behind at the very end so the tangent is never
	# zero-length. Because the manager reverses the polyline for reversed
	# traversal, this tangent already points the way the car actually drives.
	var ahead := _point_at_distance(minf(dist + 1.0, _path_length))
	var tangent := Vector2(ahead.x - pos.x, ahead.z - pos.z)
	if tangent.length_squared() < 0.0001:
		var behind := _point_at_distance(maxf(dist - 1.0, 0.0))
		tangent = Vector2(pos.x - behind.x, pos.z - behind.z)
	if tangent.length_squared() < 0.0001:
		return pos
	# Driver's right in Godot's right-handed frame is forward × UP — the very same
	# vector _slope_basis uses for the body's +X axis, so the offset lines up with
	# the direction the car actually faces "right". For forward +X this yields +Z.
	var forward := Vector3(tangent.x, 0.0, tangent.y)
	var right := forward.cross(Vector3.UP).normalized()
	return pos + right * _lane_offset


## Horizontal (ground-plane) distance between two world points. Slope is carried
## by Y separately; arc length along a route is reckoned on the ground so it lines
## up with the XZ steering/projection math.
static func _xz_distance(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x, a.z).distance_to(Vector2(b.x, b.z))


static func _polyline_length(points: PackedVector3Array) -> float:
	var total := 0.0
	for i: int in range(points.size() - 1):
		total += _xz_distance(points[i], points[i + 1])
	return total
