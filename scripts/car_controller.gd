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

## Emitted every physics frame with how far through the current gear's speed band
## the car is (0 = just shifted in, 1 = about to upshift). The instrument cluster
## turns this into the rev-counter sweep. Sent continuously rather than only on a
## shift, because the needle moves constantly within a gear.
signal gear_ratio_changed(ratio: float)

## Emitted every physics frame with how hard each driver aid is currently working
## (0 = idle, 1 = full intervention). Drives the TC/ABS/ESC telltales on the
## cluster, so the player can see the car helping them.
signal assists_changed(tcs: float, abs_level: float, stability: float)

@export var max_speed: float = 55.0
@export var reverse_max_speed: float = 18.0
@export var engine_force_value: float = 3200.0
@export var reverse_engine_force: float = 1600.0
@export var brake_force_value: float = 65.0
@export var idle_brake_force: float = 8.0
@export var max_steer_angle: float = 0.32
@export var min_steer_angle: float = 0.05

## Steering rack feel. Rate-limits the wheel angle, tapers it with speed, and adds
## countersteer assist so slides are catchable. Without this the wheels snap to
## full lock the frame a key goes down, which is the single biggest thing that
## makes an arcade car feel like an RC toy. See steering_model.gd.
@export var steering_rate: float = 2.2
## How quickly the wheels unwind to centre (rad/s). Faster than steering_rate
## because a real rack self-centres under caster.
@export var steering_return_rate: float = 4.0
## Maximum angle (rad) the countersteer assist may add on its own. 0 disables it.
@export var countersteer_assist: float = 0.16

## Driver aids (traction control / ABS / stability control), Forza-style. Each is
## independently switchable at runtime through the assists helper; these exports
## set the starting state. See driving_assists.gd.
@export var traction_control_enabled: bool = true
@export var abs_enabled: bool = true
@export var stability_control_enabled: bool = true

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
## The camera itself hangs off the pivot at a fixed "boom" offset. Shake and the
## speed FOV-kick are applied to THIS node (on top of its rest transform) so they
## layer cleanly over the pivot's smooth rotational follow.
@onready var camera: Camera3D = $CameraPivot/Camera3D
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

## Steering rack. Converts the raw steering input into the actual wheel angle with
## rate limiting, speed-sensitive lock and countersteer assist. Pure logic; see
## steering_model.gd for the feel curves.
var _steering := SteeringModel.new()

## Driver aids. Filters the throttle/brake the driver asked for and produces the
## stability-control yaw torque. Pure logic; see driving_assists.gd.
var _assists := DrivingAssists.new()

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

## Camera shake for impact/landing feedback. Pure logic: we feed it trauma on a
## crash or hard landing and each frame add its decaying offset onto the camera's
## rest transform. See camera_shake.gd for the trauma model.
var _camera_shake := CameraShake.new()
## The camera's rest transform (captured at _ready), i.e. the boom offset from the
## pivot with no shake applied. Shake and FOV-kick are composed relative to this so
## they always settle back to the exact authored framing.
var _camera_rest_transform := Transform3D.IDENTITY
## The camera's authored resting FOV (captured at _ready). The speed kick widens
## the FOV above this and relaxes back to it when slow.
var _camera_rest_fov: float = 70.0

## Trauma added for a crash, scaled by the crash's severity. A gentle bump adds a
## little; a full-speed head-on adds a lot (clamped inside CameraShake to 1.0).
const _CRASH_TRAUMA_PER_KMH := 0.012
## Minimum trauma for any crash the kudos tracker reports, so even a light tap has
## a perceptible thump.
const _CRASH_TRAUMA_MIN := 0.25
## Trauma added on a hard landing, scaled by downward speed at touchdown.
const _LANDING_TRAUMA_PER_MS := 0.06
## Downward speed (m/s) at touchdown below which a landing is "soft" (no shake).
const _LANDING_SOFT_THRESHOLD := 4.0

## How far (in km/h of forward speed) the FOV kick ramps in. At/above this the kick
## is at full strength; it scales linearly from zero at standstill.
const _FOV_KICK_FULL_SPEED_KMH := 120.0
## Maximum extra FOV (degrees) added at full speed. A subtle widening reads as
## "fast" without the fisheye distortion a big number would cause.
const _FOV_KICK_MAX_DEGREES := 12.0
## How quickly the FOV eases toward its target (per-second lerp weight). Keeps the
## kick from snapping when speed changes abruptly (e.g. a crash).
const _FOV_KICK_LERP := 4.0

## Wheels-on-ground last frame, so we can detect the airborne→grounded transition
## that marks a landing (and read the impact speed at that moment).
var _was_airborne: bool = false

## True while the driver is commanding deceleration this frame (handbrake, or the
## foot brake actively slowing a forward car). Captured in _physics_process where
## the input is read, and handed to the kudos tracker so a hard handbrake stop
## isn't misread as a crash (which was firing the impact sound + shake).
var _braking_this_frame: bool = false

## Decides when to screech the tyres and how loud impacts should be. Pure logic;
## the two AudioStreamPlayers below turn its numbers into sound. See
## car_audio_triggers.gd for the feel curves.
var _audio_triggers := CarAudioTriggers.new()
## Looping tyre-screech player. Volume follows _audio_triggers.screech_level; the
## loop starts/stops as the level crosses ~0. Optional — silent if the file is absent.
var _screech_sound: AudioStreamPlayer = null
## One-shot impact/crash player. Restarted (with a fresh volume) on each qualifying
## crash. Optional — silent if the file is absent.
var _impact_sound: AudioStreamPlayer = null
## Optional sound files. Missing files degrade gracefully (warn once, stay silent),
## exactly like the dirt-driving sound, so the game runs without any extra assets.
## WAV is used (rather than OGG) because it imports losslessly and natively in
## Godot and the screech loop wants a clean, click-free loop point.
const _SCREECH_SOUND_PATH := "res://sounds/tire_screech.wav"
const _IMPACT_SOUND_PATH := "res://sounds/impact.wav"
## Screech volume (linear) floor/ceiling. Mapped from screech_level 0..1. The floor
## is only ~10 dB below the ceiling so that even a light drift (low level) is clearly
## audible over the engine — a -30 dB floor made gentle drifts effectively silent.
const _SCREECH_VOLUME_MIN_DB := -14.0
const _SCREECH_VOLUME_MAX_DB := -3.0
## Below this screech_level the loop is ducked to silence (but kept playing, to
## avoid restart-thrash from frame-to-frame flicker around the threshold).
const _SCREECH_AUDIBLE_LEVEL := 0.02
## Volume (dB) the ducked/idle screech loop sits at — effectively inaudible.
const _SCREECH_SILENT_DB := -60.0
## Impact one-shot volume (linear) floor/ceiling. Mapped from register_impact volume.
const _IMPACT_VOLUME_MIN_DB := -16.0
const _IMPACT_VOLUME_MAX_DB := 0.0
## The kudos event label that represents an actual collision. Only this event
## plays the impact/crash sound; spin-outs and flips shake but don't "clang".
const _CRASH_EVENT_LABEL := "CRASH"

## One-shot spark/debris burst fired on a collision. Created in _ready and parented
## to the car; burst() is called at the crash point on CRASH events.
var _impact_particles: ImpactParticles = null

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

## Switch every driver aid (TCS, ABS, stability control) on or off together —
## the "assists off / pro" preset every racing game offers. The countersteer
## assist in the steering rack goes with them, since it is the same class of help.
## Called from the pause menu.
func set_driving_assists_enabled(enabled: bool) -> void:
	_assists.set_all_enabled(enabled)
	_steering.countersteer_max = countersteer_assist if enabled else 0.0


## True while the driver aids are active. Lets the pause menu show the current
## state without keeping its own copy of it.
func are_driving_assists_enabled() -> bool:
	return _assists.traction_control_enabled


## Silence or restore all car audio (engine loop and dirt driving sound).
## Called by the main scene when the pause menu opens / closes.
func set_engine_muted(muted: bool) -> void:
	_engine_sound.set_muted(muted)
	if _dirt_sound != null:
		if muted:
			_dirt_sound.stop()
		# Dirt sound restarts naturally via _update_dirt_sound() when un-muted.
	if muted and _screech_sound != null:
		_screech_sound.stop()
		# Screech restarts naturally via _update_screech_sound() when un-muted.


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
	_setup_steering_and_assists()
	# Pre-compute the gear speed bands from this car's top speed so the very first
	# gear lookup is cheap and the HUD can show a gear immediately.
	_transmission.build_for_max_speed(max_speed * 3.6)
	_setup_wheel_particles()
	_setup_dirt_sound()
	_setup_impact_sounds()
	_impact_particles = ImpactParticles.new()
	_impact_particles.name = "ImpactParticles"
	add_child(_impact_particles)
	add_child(_engine_sound)
	# Remember the camera's authored framing so shake/FOV-kick always relax back to it.
	if camera != null:
		_camera_rest_transform = camera.transform
		_camera_rest_fov = camera.fov


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


## Push this car's exported tuning into the steering rack and the driver aids.
## Both helpers keep their own defaults; the exports here are the car's opinion,
## so a designer can retune feel from the inspector without editing either script.
func _setup_steering_and_assists() -> void:
	_steering.max_steer_angle = max_steer_angle
	_steering.min_steer_angle = min_steer_angle
	_steering.steer_rate = steering_rate
	_steering.return_rate = steering_return_rate
	_steering.countersteer_max = countersteer_assist
	# The rack's speed taper should reach full lock-out near the car's top speed
	# rather than at an arbitrary fixed figure, so faster cars keep usable steering
	# through their whole range.
	_steering.speed_sensitivity_full = max_speed * 0.85

	_assists.traction_control_enabled = traction_control_enabled
	_assists.abs_enabled = abs_enabled
	_assists.stability_control_enabled = stability_control_enabled


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
		# loop_end must be the real last sample frame. A runtime loop_end of -1
		# yields an empty [0, -1] loop and the stream plays silent (see
		# _wav_frame_count / the tyre-screech fix).
		stream.loop_begin = 0
		stream.loop_end = _wav_frame_count(stream)
		_dirt_sound.stream = stream
	elif stream is AudioStream:
		_dirt_sound.stream = stream
	else:
		push_warning("CarController: could not load dirt sound at %s" % _DIRT_SOUND_PATH)
	add_child(_dirt_sound)


## Create the tyre-screech (looping) and impact (one-shot) players. Both sound
## files are OPTIONAL: if a file is missing the player is left with no stream and
## the corresponding update method no-ops, so the game runs silently rather than
## crashing (same graceful-degradation contract as the dirt sound).
func _setup_impact_sounds() -> void:
	_screech_sound = AudioStreamPlayer.new()
	_screech_sound.name = "TireScreechSound"
	_screech_sound.bus = &"Master"
	_screech_sound.volume_db = _SCREECH_VOLUME_MIN_DB
	_screech_sound.process_mode = Node.PROCESS_MODE_PAUSABLE
	var screech := load(_SCREECH_SOUND_PATH) if ResourceLoader.exists(_SCREECH_SOUND_PATH) else null
	if screech is AudioStreamWAV:
		screech.loop_mode = AudioStreamWAV.LOOP_FORWARD
		# loop_end must be the actual last sample frame. Setting it to -1 at RUNTIME
		# (the "end of sample" sentinel only valid in import settings) creates an
		# empty [0, -1] loop region and the stream plays SILENT. Use the real length.
		screech.loop_begin = 0
		screech.loop_end = _wav_frame_count(screech)
		_screech_sound.stream = screech
	elif screech is AudioStream:
		_screech_sound.stream = screech
	else:
		push_warning("CarController: tyre-screech sound absent at %s (silent)" % _SCREECH_SOUND_PATH)
	add_child(_screech_sound)

	_impact_sound = AudioStreamPlayer.new()
	_impact_sound.name = "ImpactSound"
	_impact_sound.bus = &"Master"
	_impact_sound.process_mode = Node.PROCESS_MODE_PAUSABLE
	var impact := load(_IMPACT_SOUND_PATH) if ResourceLoader.exists(_IMPACT_SOUND_PATH) else null
	if impact is AudioStream:
		_impact_sound.stream = impact
	else:
		push_warning("CarController: impact sound absent at %s (silent)" % _IMPACT_SOUND_PATH)
	add_child(_impact_sound)


## Number of sample frames in a 16-bit PCM AudioStreamWAV, for setting a valid
## loop_end (the count of frames, i.e. data bytes / bytes-per-frame). Returns 0 if
## the format is unexpected, which disables looping rather than risking silence.
func _wav_frame_count(wav: AudioStreamWAV) -> int:
	var bytes := wav.data.size()
	# format 2 (FORMAT_16_BITS) => 2 bytes per channel per frame.
	var channels := 2 if wav.stereo else 1
	var bytes_per_frame := 2 * channels
	if wav.format != AudioStreamWAV.FORMAT_16_BITS or bytes_per_frame == 0:
		return 0
	# Integer division is intended: a whole number of sample frames.
	@warning_ignore("integer_division")
	return bytes / bytes_per_frame


## Fire the impact one-shot for a crash of the given severity (the absolute kudos
## penalty). The trigger logic gates on severity + a cooldown so a multi-frame
## crash thumps once, not in a burst. No-ops if the sound file is absent.
func _play_impact(severity: float) -> void:
	var decision := _audio_triggers.register_impact(severity)
	if not decision["play"]:
		return
	if _impact_sound == null or _impact_sound.stream == null:
		return
	var vol: float = decision["volume"]
	_impact_sound.volume_db = lerpf(_IMPACT_VOLUME_MIN_DB, _IMPACT_VOLUME_MAX_DB, vol)
	_impact_sound.play()


## Spray a spark/debris burst for a collision of the given severity. The sparks
## originate at the front of the car (the most likely contact point when driving
## into something) and spray upward-and-outward. No-ops if the burst node is absent
## or the severity is below the burst threshold.
func _burst_impact_particles(severity: float) -> void:
	if _impact_particles == null:
		return
	# Front of the car: the collision box is ~4.1 m long, so ~2 m ahead of centre
	# along the nose axis (basis.z is the car's forward in VehicleBody convention),
	# lifted to roughly bumper height.
	var nose := global_transform.basis.z.normalized()
	var origin := global_position + nose * 2.0 + Vector3(0.0, 0.4, 0.0)
	# Spray up and back toward the driver: mostly upward with a component opposing
	# travel so sparks fly back over the bonnet rather than straight ahead.
	var dir := (Vector3.UP * 1.5 - nose).normalized()
	_impact_particles.burst(origin, severity, dir)


## Update the looping tyre-screech volume/playback from the current screech level.
## Called each frame with the smoothed level the triggers computed. No-ops if the
## sound file is absent.
##
## The loop is kept PLAYING continuously and gated by volume, not by stop()/play().
## The screech level flickers above and below the audible floor from frame to frame
## during a drift; toggling the player on and off each time restarted the sample
## from zero every few frames and produced no audible sound at all. Instead we let
## the loop run and just duck the volume to (near) silent when there's no slip.
func _update_screech_sound() -> void:
	if _screech_sound == null or _screech_sound.stream == null:
		return
	var level := _audio_triggers.screech_level
	if level >= _SCREECH_AUDIBLE_LEVEL:
		_screech_sound.volume_db = lerpf(_SCREECH_VOLUME_MIN_DB, _SCREECH_VOLUME_MAX_DB, level)
		# Slightly raise pitch with intensity for a more urgent squeal.
		_screech_sound.pitch_scale = lerpf(0.9, 1.15, level)
		if not _screech_sound.playing:
			_screech_sound.play()
	elif _screech_sound.playing:
		# Duck to inaudible rather than stopping, so a brief dip below the floor
		# mid-drift doesn't restart the sample and swallow the sound. Only once the
		# level has fully settled to zero (drift clearly over) do we stop the loop
		# to free the voice.
		_screech_sound.volume_db = _SCREECH_SILENT_DB
		if level <= 0.0:
			_screech_sound.stop()


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

	# Record whether the driver is commanding deceleration this frame: the handbrake,
	# or the foot brake actively slowing a forward car (brake_force lifted above the
	# idle drag). The kudos tracker reads this so a hard stop isn't scored as a crash.
	_braking_this_frame = handbrake_active or brake_force > idle_brake_force

	# Steering goes through the rack rather than straight to the wheels: rate
	# limited, speed-tapered, and nudged into any slide by the countersteer assist.
	var speed_now := linear_velocity.length()
	var slip := _compute_slip_angle()
	var steer_angle := _steering.update(
		steer_input, speed_now, slip, _slip_direction(), _delta
	)
	front_left_wheel.steering = steer_angle
	front_right_wheel.steering = steer_angle

	# Driver aids filter the pedals before they reach the tyres. Both take the
	# driven/braked wheels' surface speed so they can measure real slip rather
	# than guessing from inputs.
	#
	# Both filters are called EVERY frame, even when the pedal is at zero. Their
	# intervention levels are smoothed over time, so skipping the call would freeze
	# the last value instead of letting it decay — the telltales would stay lit and
	# the next application of throttle would start from a stale cut.
	var rear_wheel_speed := _driven_wheel_surface_speed()
	drive_force = _assists.filter_engine_force(
		drive_force, rear_wheel_speed, forward_speed, _delta
	)
	var filtered_brake := _assists.filter_brake_force(
		rear_brake, rear_wheel_speed, forward_speed, _delta
	)
	# ABS only makes sense on the foot brake. The handbrake is an explicit request
	# to LOCK the rear axle for a drift, so it keeps the unfiltered force (the
	# filter still ran above, purely to keep its smoothing state moving).
	var abs_rear_brake := rear_brake if handbrake_active else filtered_brake

	rear_left_wheel.engine_force = drive_force
	rear_right_wheel.engine_force = drive_force
	rear_left_wheel.brake = abs_rear_brake
	rear_right_wheel.brake = abs_rear_brake
	front_left_wheel.brake = brake_force * 0.35
	front_right_wheel.brake = brake_force * 0.35
	_apply_stability_control(steer_angle, speed_now, forward_speed, handbrake_active)
	_broadcast_assist_levels()
	_apply_anti_roll(_delta)
	_sync_wheel_meshes()
	_update_camera_pivot(_delta)

	_update_wheel_particles()
	_broadcast_speed()
	_update_gear(forward_speed)
	_update_kudos(_delta, forward_speed)
	# After kudos (which may have added crash/landing trauma this frame) apply the
	# shake and speed FOV-kick to the camera.
	_update_camera_effects(_delta)


## Which way the car is sliding, as +1 / -1 / 0, for the countersteer assist.
##
## The sign is the side of the car's nose that the velocity vector has swung to:
## +1 when the car is travelling to the left of where it points, -1 to the right.
## Steering the wheels toward this sign is "steering into the slide", because
## positive steering is a left turn (see the steer_left/steer_right input mapping).
##
## Returns 0 at a crawl, where the travel direction is numerically meaningless,
## and while REVERSING — backing up puts the velocity roughly opposite the nose,
## which reads as a ~180 degree slip and would otherwise peg the assist at full
## lock and fight the driver all the way out of a parking space.
func _slip_direction() -> float:
	var vel := linear_velocity
	vel.y = 0.0
	if vel.length() < 1.0:
		return 0.0
	var forward := global_transform.basis.z
	forward.y = 0.0
	if forward.length_squared() < 0.0001:
		return 0.0
	forward = forward.normalized()
	# Travelling backwards relative to the nose is reversing, not sliding.
	if vel.normalized().dot(forward) < 0.0:
		return 0.0
	# Cross the nose with the travel direction about the up axis: the sign tells us
	# which side of "straight ahead" the car is actually heading toward.
	var lateral := forward.cross(vel.normalized()).y
	if is_zero_approx(lateral):
		return 0.0
	return signf(lateral)


## Surface speed (m/s) of the driven/braked rear wheels: how fast the tyre contact
## patch is travelling, i.e. the ground speed the wheels are currently "asking
## for". Comparing this against the car's real speed is what reveals wheelspin
## (wheels faster) or lock-up (wheels slower), which is what TCS and ABS act on.
##
## VehicleWheel3D exposes RPM, so this converts revolutions per minute into a
## linear speed via the tyre circumference.
func _driven_wheel_surface_speed() -> float:
	var rpm := (rear_left_wheel.get_rpm() + rear_right_wheel.get_rpm()) * 0.5
	# rev/min -> rad/s is (2*PI/60); multiplying by the radius gives m/s.
	return rpm * (TAU / 60.0) * rear_left_wheel.wheel_radius


## Apply the stability-control corrective yaw torque for this frame.
##
## Compares how fast the car is actually rotating against how fast the driver's
## steering angle says it should be, and pushes back on the difference. This is
## what catches the snap-oversteer after a kerb or a bad landing before it becomes
## an unrecoverable spin.
func _apply_stability_control(
	steer_angle: float,
	speed: float,
	forward_speed: float,
	handbrake_active: bool
) -> void:
	var yaw_rate := angular_velocity.dot(global_transform.basis.y)
	var desired := _desired_yaw_rate(steer_angle, forward_speed)
	var torque := _assists.stability_torque(yaw_rate, desired, speed, handbrake_active)
	if is_zero_approx(torque):
		return
	# Torque about the car's up axis rotates it in yaw (the spin we are damping).
	apply_torque(global_transform.basis.y * torque)


## The yaw rate (rad/s) the driver's steering input is asking for, from the
## bicycle model: yaw_rate = speed * tan(steer_angle) / wheelbase.
##
## This is the reference stability control measures the real car against — the
## gap between "what the driver asked the car to do" and "what the car is doing"
## is precisely the definition of over/understeer.
func _desired_yaw_rate(steer_angle: float, forward_speed: float) -> float:
	var wheelbase := _wheelbase()
	if wheelbase <= 0.0:
		return 0.0
	return forward_speed * tan(steer_angle) / wheelbase


## Distance (m) between the front and rear axles, measured from the actual wheel
## node positions so it stays correct if the car model or wheel layout changes.
func _wheelbase() -> float:
	return absf(front_left_wheel.position.z - rear_left_wheel.position.z)


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


## Layer the shake and the speed FOV-kick onto the camera each frame, on top of
## its authored rest transform. Called after _update_camera_pivot so the pivot
## owns the smooth "look where we're going" rotation and this owns the local jitter.
func _update_camera_effects(delta: float) -> void:
	if camera == null:
		return
	# 1) Shake: decay trauma, then add its offset to the rest transform. When fully
	# settled the offset is exactly zero so the camera snaps back to authored framing.
	_camera_shake.tick(delta)
	var shaken := _camera_rest_transform
	if _camera_shake.is_active():
		var off := _camera_shake.get_offset()
		var pos_off := off["position"] as Vector3
		var rot_off := off["rotation"] as Vector3
		shaken.origin += pos_off
		shaken.basis = shaken.basis * Basis.from_euler(rot_off)
	camera.transform = shaken

	# 2) FOV kick: widen the field of view with speed for a sense of speed, easing
	# toward the target so it never snaps. Uses forward speed magnitude so reversing
	# fast doesn't count.
	var speed_kmh := linear_velocity.length() * 3.6
	var kick := clampf(speed_kmh / _FOV_KICK_FULL_SPEED_KMH, 0.0, 1.0) * _FOV_KICK_MAX_DEGREES
	var target_fov := _camera_rest_fov + kick
	camera.fov = lerpf(camera.fov, target_fov, clampf(delta * _FOV_KICK_LERP, 0.0, 1.0))


func _broadcast_speed() -> void:
	var speed_kmh: float = linear_velocity.length() * 3.6
	speed_changed.emit(speed_kmh)


## Report how hard each driver aid is working, for the cluster's telltales.
##
## The stability figure is normalised against the aid's own ceiling so the lamp
## reads 0..1 like the other two, rather than exposing raw newton-metres to the HUD.
func _broadcast_assist_levels() -> void:
	var stability := 0.0
	if _assists.stability_max_torque > 0.0:
		stability = clampf(
			_assists.stability_intervention / _assists.stability_max_torque, 0.0, 1.0
		)
	assists_changed.emit(_assists.tcs_cut, _assists.abs_release, stability)


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
	# The cluster's rev needle sweeps within a gear, so this goes out every frame
	# rather than only when the gear itself changes.
	gear_ratio_changed.emit(gear_ratio)


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
	t.braking = _braking_this_frame

	# Hard-landing shake: on the airborne→grounded transition, read the downward
	# speed and thump the camera if the car came down fast. Airtime scoring already
	# lives in the kudos tracker; this is purely the visual/feel side of touchdown.
	var airborne_now := t.wheels_on_ground == 0
	if _was_airborne and not airborne_now:
		var down_speed := maxf(0.0, -linear_velocity.y)
		if down_speed > _LANDING_SOFT_THRESHOLD:
			_camera_shake.add_trauma((down_speed - _LANDING_SOFT_THRESHOLD) * _LANDING_TRAUMA_PER_MS)
	_was_airborne = airborne_now

	# Tyre screech: reuse the slip/speed telemetry. The car is "gripping" unless the
	# handbrake has dropped rear grip (a deliberate drift) — a broken-traction slide
	# squeals louder than a clean-tyre chirp. Skip while airborne (no tyre contact).
	var gripping := not _rear_grip_lowered
	var screech_speed := 0.0 if airborne_now else t.speed
	_audio_triggers.update_screech(t.slip_angle, screech_speed, gripping, delta)
	_update_screech_sound()

	var events := _kudos.update(t, delta)
	for ev: KudosTracker.KudosEvent in events:
		kudos_event.emit(ev.label, ev.amount, ev.is_penalty)
		if not ev.is_penalty:
			continue
		var severity := float(absi(ev.amount))
		# Camera shake fits any jarring mistake (crash, flip, spin-out), so shake on
		# every penalty.
		_camera_shake.add_trauma(maxf(_CRASH_TRAUMA_MIN, severity * _CRASH_TRAUMA_PER_KMH))
		# The impact one-shot is a COLLISION sound (metal-on-metal), so it must only
		# fire on an actual crash — NOT on a spin-out or flip, which are loss-of-
		# control events. Otherwise a handbrake drift that spins the car past the
		# yaw threshold plays the crash sound (the bug we're fixing).
		if ev.label == _CRASH_EVENT_LABEL:
			_play_impact(severity)
			_burst_impact_particles(severity)

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
