class_name TachometerModel
extends RefCounted

## Works out what a rev counter should be showing: engine RPM, where the needle
## sits on the dial, and whether the driver is in the shift-up zone.
##
## The car already has a Transmission that answers "what gear am I in, and how far
## through its speed band?". That band position is exactly the shape of an RPM
## sweep — bottom of the gear is just after a shift (low revs), top of the gear is
## the moment before the next one (near the limiter). This class turns that
## normalised 0..1 into the numbers a dial needs, and adds the parts a gear band
## has no opinion about: an idle floor, the redline, and needle smoothing.
##
## Why smoothing matters: the gear band jumps discontinuously at every shift (1.0
## in 3rd becomes ~0.0 in 4th in a single frame). A needle that teleported would
## look broken; a real tacho needle has mass and takes a moment to drop. The
## needle therefore chases the target rather than snapping to it, which is what
## produces the familiar "sweep up, flick down, sweep up" motion.
##
## This is a pure data/logic helper: no Control, no drawing, no scene tree. The
## HUD owns one, feeds it speed/gear each frame, and reads back numbers to render.
## Keeping it standalone means the dial's behaviour is unit-testable without a
## viewport, exactly like Transmission and KudosTracker.


# ─── Tunables ────────────────────────────────────────────────────────────────

## Engine speed (RPM) at idle. The needle never falls below this while the engine
## is running, because a running engine never actually stops turning.
var idle_rpm: float = 800.0

## Engine speed (RPM) at the top of a gear — where the shift light comes on and
## the next upshift happens.
var max_rpm: float = 7500.0

## Engine speed (RPM) at which the dial's red zone begins. Slightly below max_rpm
## so there is a visible warning band before the limiter rather than a single
## instant of red.
var redline_rpm: float = 6500.0

## How quickly the needle chases its target, as a per-second response rate.
## High enough to feel responsive, low enough to read as a physical needle with
## mass rather than a digital readout.
var needle_response: float = 12.0

## The dial's total sweep in radians (the angle between the 0 RPM mark and the
## max RPM mark). ~240 degrees, the usual car-dashboard sweep.
var dial_sweep: float = deg_to_rad(240.0)

## Where the 0 RPM mark sits, in radians, measured clockwise from straight down
## (0 = the 6 o'clock position). 60 degrees puts the first mark at roughly 7
## o'clock; with the 240-degree sweep the limiter lands at about 5 o'clock, so the
## dial is symmetric about vertical with a gap at the bottom, like a real cluster.
var dial_start: float = deg_to_rad(60.0)


# ─── State ───────────────────────────────────────────────────────────────────

## The smoothed RPM the needle is currently displaying. This is what to draw.
var display_rpm: float = 0.0

## The instantaneous RPM implied by the current gear and speed, before smoothing.
## Exposed mainly so tests and tuning can see the raw target.
var target_rpm: float = 0.0


## Recompute the tacho for this frame.
##
##   gear        current gear (-1 reverse, 0 neutral, 1..N forward), from Transmission.
##   gear_ratio  how far through the current gear's speed band the car is, 0..1,
##               from Transmission.gear_ratio_for_speed.
##   speed_kmh   current speed magnitude, km/h. Only used to decide whether the
##               car is genuinely stationary (idle) versus rolling in neutral.
##   delta       frame time, seconds.
##
## Returns the smoothed RPM to display.
func update(gear: int, gear_ratio: float, speed_kmh: float, delta: float) -> float:
	target_rpm = rpm_for(gear, gear_ratio, speed_kmh)
	# A zero-length frame (paused, or the very first frame) must leave the needle
	# exactly where it is: no time has passed, so nothing can have moved. Snapping
	# to the target here would make the dial jerk whenever the game is paused.
	if delta <= 0.0:
		return display_rpm

	# needle_response of 0 disables smoothing entirely (an instant digital
	# readout), which is a legitimate configuration rather than a paused frame.
	if needle_response <= 0.0:
		display_rpm = target_rpm
		return display_rpm

	# Chase the target rather than snapping, so the needle reads as a physical
	# part with mass — and so the discontinuity at every gear change becomes a
	# quick sweep down instead of a teleport.
	var weight := clampf(needle_response * delta, 0.0, 1.0)
	display_rpm = lerpf(display_rpm, target_rpm, weight)
	return display_rpm


## The RPM implied by a gear and its band position, with no smoothing applied.
##
## In gear, revs sweep from just above idle at the bottom of the band to max_rpm
## at the top. In neutral (or reverse at a standstill) the engine sits at idle.
func rpm_for(gear: int, gear_ratio: float, speed_kmh: float) -> float:
	# Neutral: the engine is disconnected from the wheels, so it idles regardless
	# of how fast the car happens to be rolling.
	if gear == Transmission.GEAR_NEUTRAL:
		return idle_rpm

	# Reverse has a single short ratio. Scale revs with speed across the reverse
	# band rather than using gear_ratio, which Transmission leaves at 0 in reverse.
	if gear == Transmission.GEAR_REVERSE:
		var reverse_fraction := clampf(absf(speed_kmh) / _REVERSE_FULL_REV_KMH, 0.0, 1.0)
		return lerpf(idle_rpm, max_rpm, reverse_fraction)

	# Forward gears: the band position IS the rev sweep. Revs never drop below
	# idle, because a running engine is always turning.
	var t := clampf(gear_ratio, 0.0, 1.0)
	return lerpf(_shift_down_rpm(), max_rpm, t)


## Where the needle sits on the dial, as 0..1 across the full sweep. This is the
## number the drawing code turns into an angle; keeping it normalised means the
## dial's geometry can be restyled without touching the rev logic.
func needle_fraction() -> float:
	if max_rpm <= 0.0:
		return 0.0
	return clampf(display_rpm / max_rpm, 0.0, 1.0)


## The needle's angle in radians for the current revs, ready to hand to a draw
## call. Measured so that 0 RPM sits at dial_start and max_rpm is dial_sweep
## further round.
func needle_angle() -> float:
	return angle_for_fraction(needle_fraction())


## The dial angle (radians) for an arbitrary 0..1 position on the sweep. Used for
## the needle and for laying out the tick marks and the redline arc.
func angle_for_fraction(fraction: float) -> float:
	return dial_start + clampf(fraction, 0.0, 1.0) * dial_sweep


## Where the red zone starts as a 0..1 dial position, for drawing the red arc.
func redline_fraction() -> float:
	if max_rpm <= 0.0:
		return 1.0
	return clampf(redline_rpm / max_rpm, 0.0, 1.0)


## True when the engine is in the red zone — the cue to upshift. The HUD flashes
## the gear number and the dial rim on this, which is the shift light every racing
## game uses to tell the player "now".
func is_redlining() -> bool:
	return display_rpm >= redline_rpm


## How deep into the red zone the engine is, 0..1 (0 = just touching the redline,
## 1 = at the limiter). Lets the HUD ramp the shift light's intensity instead of
## flicking it on, so the warning builds as the shift point approaches.
func redline_intensity() -> float:
	if max_rpm <= redline_rpm:
		return 1.0 if is_redlining() else 0.0
	return clampf((display_rpm - redline_rpm) / (max_rpm - redline_rpm), 0.0, 1.0)


## Reset the needle to rest. Called when the car respawns so the dial does not
## sweep down from a stale value.
func reset() -> void:
	display_rpm = 0.0
	target_rpm = 0.0


## RPM at the bottom of a gear band, i.e. the revs the engine drops to right after
## an upshift. Sits above idle because the clutch re-engages with the wheels still
## turning — the engine is dragged up to road speed, not left idling.
func _shift_down_rpm() -> float:
	return lerpf(idle_rpm, max_rpm, _SHIFT_DOWN_FRACTION)


## Where in the rev range a fresh gear starts. 0.35 gives the familiar drop to
## roughly a third of the range on an upshift.
const _SHIFT_DOWN_FRACTION := 0.35

## Speed (km/h) at which reverse is considered to be at full revs. Reverse is a
## short gear, so it runs out of revs early.
const _REVERSE_FULL_REV_KMH := 30.0
