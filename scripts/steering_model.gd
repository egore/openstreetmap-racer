class_name SteeringModel
extends RefCounted

## Turns a raw steering input (-1..1) into the actual front-wheel angle, the way a
## driving game with a real steering rack does it.
##
## The naive approach — `wheel.steering = input * max_angle` — is what makes a car
## feel like a remote-control toy: on a keyboard the input snaps from 0 to 1 in a
## single frame, so the wheels teleport to full lock and the car darts. Three
## things fix that, and this class owns all three:
##
##   1. **Rate limiting.** A real steering rack takes time to turn lock-to-lock.
##      The wheel angle chases the target at a bounded angular rate, which gives
##      keyboard steering a natural ramp-in and makes analog sticks feel weighted.
##      Returning to centre is faster than steering away from it (the caster
##      effect: a real wheel self-centres, and drivers let it spin back).
##
##   2. **Speed sensitivity.** Full lock at 200 km/h would spin the car instantly.
##      The available angle shrinks as speed rises, so the same stick deflection
##      means "park it" at low speed and "gentle lane change" at high speed.
##
##   3. **Countersteer assist.** When the rear steps out, a skilled driver
##      instinctively steers *into* the slide. This nudges the wheels that way
##      automatically, in proportion to how far the car is sideways. It is what
##      makes drifts in arcade racers feel achievable rather than a coin flip —
##      the assist catches the slide, the player shapes it.
##
## This is a pure data/logic helper: no physics body, no scene tree. The car owns
## one, calls update() each physics frame with the driver's input and the current
## chassis state, and applies the returned angle to its steering wheels. Keeping
## it standalone makes the feel curve easy to tune and unit-test.
##
## Sign convention (matches the car's input): positive = steering LEFT, negative =
## steering RIGHT. Angles are radians.


# ─── Tunables ────────────────────────────────────────────────────────────────

## Maximum front-wheel angle (radians) available at a standstill. ~18 degrees.
var max_steer_angle: float = 0.32

## Minimum front-wheel angle (radians) available at (and above) full speed. The
## rack never locks out completely — you still need enough authority to change
## lanes at 200 km/h — but it is a small fraction of the parking-lot angle.
var min_steer_angle: float = 0.06

## Speed (m/s) at which the available angle has fully collapsed to
## min_steer_angle. Above this there is no further reduction. ~160 km/h.
var speed_sensitivity_full: float = 45.0

## Shapes how the angle falls off between standstill and speed_sensitivity_full.
## 1.0 is a straight line; values above 1 keep more angle available at low-to-mid
## speed and collapse it late, which feels more natural than a linear taper
## because most cornering happens in the middle of the range.
var speed_sensitivity_curve: float = 1.7

## How fast the wheels can turn AWAY from centre, in radians of steering angle
## per second. This is the rack speed: lower feels heavy and deliberate, higher
## feels twitchy. ~2.2 rad/s crosses the full 0.32 rad lock in about 0.15 s.
var steer_rate: float = 2.2

## How fast the wheels return TO centre, radians per second. Faster than
## steer_rate because a real steering wheel self-centres under caster trail and
## the driver is unwinding rather than fighting the rack.
var return_rate: float = 4.0

## Maximum extra angle (radians) the countersteer assist may add on its own.
## Capped well below max_steer_angle so the assist can never take the car
## somewhere the driver did not ask to go — it catches slides, it does not drive.
var countersteer_max: float = 0.16

## Slip angle (radians) below which the assist stays out of the way. Ordinary
## cornering produces a little slip; only a genuine slide should trigger help.
var countersteer_threshold: float = 0.12

## Slip angle (radians) at which the assist reaches countersteer_max. Beyond this
## the car is fully sideways and more assist would not help.
var countersteer_full: float = 0.7

## Scales the assist by how much the driver is already steering into the slide.
## At 0 the assist works at full strength even when the player is countersteering
## correctly (which double-corrects and feels like the car fighting you); at 1 it
## fully backs off once the player has it handled. The assist is there to cover
## the reaction-time gap, so it should yield as soon as the driver reacts.
var countersteer_player_yield: float = 0.8

## Minimum speed (m/s) before the assist engages. Slip angle is numerically noisy
## at a crawl (and meaningless when parking), so below this it is ignored.
var countersteer_min_speed: float = 4.0


# ─── State ───────────────────────────────────────────────────────────────────

## The current front-wheel angle (radians), i.e. what the rack has actually
## reached after rate limiting. This is what the caller applies to the wheels.
var steer_angle: float = 0.0

## The countersteer contribution included in steer_angle this frame, exposed for
## HUD/debug ("the assist is helping you right now") and for tests.
var assist_angle: float = 0.0


## Advance the steering rack one physics frame and return the new wheel angle.
##
##   input      driver's steering input, -1..1 (positive = left). Analog sticks
##              pass a partial value; keyboard passes exactly -1, 0 or 1.
##   speed      current speed magnitude, m/s. Drives the speed-sensitive taper.
##   slip_angle magnitude of the car's slip angle, radians (always >= 0) — how far
##              sideways the chassis is travelling relative to where it points.
##   slip_sign  which way the car is sliding: +1 when the rear has stepped out to
##              one side, -1 the other. Zero disables the assist for this frame.
##              (The car computes this from its yaw/velocity; see CarController.)
##   delta      physics frame time, seconds.
func update(
	input: float,
	speed: float,
	slip_angle: float,
	slip_sign: float,
	delta: float
) -> float:
	var limit := angle_limit_for_speed(speed)

	# The driver's requested angle, clamped to what the rack allows at this speed.
	var target := clampf(input, -1.0, 1.0) * limit

	# Countersteer assist: bias the target into the slide. Added to the target
	# rather than to the final angle so it is still rate-limited — the assist
	# moves the rack, it does not teleport the wheels.
	assist_angle = countersteer_for(slip_angle, slip_sign, speed, input, limit)
	target = clampf(target + assist_angle, -limit, limit)

	# Rate limit: move toward the target at the rack's speed. Unwinding toward
	# centre is allowed to be quicker than winding on (caster self-centring).
	var returning := absf(target) < absf(steer_angle) and signf(target) == signf(steer_angle) \
		or is_zero_approx(target)
	var rate := return_rate if returning else steer_rate
	steer_angle = move_toward(steer_angle, target, rate * maxf(delta, 0.0))
	return steer_angle


## The maximum wheel angle (radians) available at the given speed (m/s). Falls
## from max_steer_angle at a standstill to min_steer_angle at speed_sensitivity_full,
## along the speed_sensitivity_curve. Exposed separately so the HUD (and tests)
## can ask "how much lock do I have right now?" without stepping the model.
func angle_limit_for_speed(speed: float) -> float:
	if speed_sensitivity_full <= 0.0:
		return max_steer_angle
	var t := clampf(absf(speed) / speed_sensitivity_full, 0.0, 1.0)
	# The curve exponent shapes the taper; see speed_sensitivity_curve.
	var shaped := pow(t, speed_sensitivity_curve)
	return lerpf(max_steer_angle, min_steer_angle, shaped)


## How much countersteer (radians, signed like the steering input) the assist
## wants to add for the given slide. Returns 0 when the car is not really sliding,
## is too slow to matter, or the driver is already correcting it themselves.
##
## Split out from update() so the assist curve can be reasoned about and tested on
## its own — it is the subtlest part of the feel and the easiest to get wrong.
func countersteer_for(
	slip_angle: float,
	slip_sign: float,
	speed: float,
	input: float,
	limit: float
) -> float:
	if speed < countersteer_min_speed or is_zero_approx(slip_sign):
		return 0.0
	if slip_angle <= countersteer_threshold:
		return 0.0
	if countersteer_full <= countersteer_threshold:
		return 0.0

	# Ramp 0..1 across the slip band, so a small slide gets a light hand and a big
	# one gets the full correction.
	var t := clampf(
		(slip_angle - countersteer_threshold) / (countersteer_full - countersteer_threshold),
		0.0,
		1.0
	)

	# Steer INTO the slide: the correction points the same way the car is sliding.
	var direction := signf(slip_sign)
	var amount := t * countersteer_max * direction

	# Back off in proportion to how much the driver is already steering that way.
	# Without this the assist stacks on top of a player who is countersteering
	# correctly and over-rotates the car the other way — the classic "the game is
	# fighting my inputs" complaint.
	var player_correction := clampf(input * direction, 0.0, 1.0)
	amount *= 1.0 - player_correction * countersteer_player_yield

	# Never let the assist alone exceed the speed-limited rack angle.
	return clampf(amount, -limit, limit)


## Reset the rack to centre. Called when the car is respawned or teleported so the
## wheels do not carry a stale angle (or a mid-slide assist) into the new position.
func reset() -> void:
	steer_angle = 0.0
	assist_angle = 0.0
