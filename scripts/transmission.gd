class_name Transmission
extends RefCounted

## Computes which gear a car is in based on its current forward speed.
##
## This is a pure data/logic helper with no knowledge of the physics body or the
## HUD — the car owns one of these and asks it "what gear am I in at X km/h?".
## Keeping it standalone makes the gear curve easy to tune and unit-test, and
## means the sound system can later read the same gear/RPM data without touching
## the physics code.
##
## Gear numbering convention used throughout the project:
##   -1 = reverse
##    0 = neutral (stationary / coasting through the clutch zone)
##  1..N = forward gears (N = forward_gear_count, default 6)

## Number of forward gears. A real car layout: 6 forward + 1 reverse.
const FORWARD_GEAR_COUNT := 6

## Special gear indices so callers don't pass around magic numbers.
const GEAR_REVERSE := -1
const GEAR_NEUTRAL := 0

## How much "taller" each successive gear is than the previous one. A real
## gearbox spaces ratios geometrically: 1st covers a narrow speed band for snappy
## launches, and each higher gear stretches over a wider band. A value of 1.0
## would give evenly-sized bands; >1.0 makes the lower gears progressively
## shorter and the top gears longer, which is what gives that familiar
## "quick through the low gears, long pull in top" feel.
var gear_spacing: float = 1.28

## Below this speed (km/h) the car is treated as in neutral so the HUD shows "N"
## instead of flickering into 1st while sitting still.
var neutral_speed_threshold: float = 1.0

## Upper speed boundary (km/h) of each forward gear, index 0 = 1st gear.
## Built once from max_speed; the last entry always equals max_speed.
var _upshift_points: PackedFloat32Array = PackedFloat32Array()

## The max forward speed (km/h) the bands were built for, so we can rebuild lazily
## if the car's max_speed is retuned at runtime.
var _built_for_max_speed: float = -1.0


## Recomputes the per-gear speed bands for the given top speed (km/h).
##
## The boundaries follow a geometric progression: the width of gear i is
## proportional to gear_spacing^i. We normalise those widths so the cumulative
## sum of all six lands exactly on max_speed_kmh, guaranteeing 6th gear tops out
## at the car's real maximum with no gaps or overlap.
func build_for_max_speed(max_speed_kmh: float) -> void:
	_built_for_max_speed = max_speed_kmh
	_upshift_points.resize(FORWARD_GEAR_COUNT)

	# Relative width of each gear band, e.g. [1, 1.28, 1.64, ...].
	var weights := PackedFloat32Array()
	weights.resize(FORWARD_GEAR_COUNT)
	var total_weight := 0.0
	for i in FORWARD_GEAR_COUNT:
		var w: float = pow(gear_spacing, float(i))
		weights[i] = w
		total_weight += w

	# Convert widths into cumulative upper-speed boundaries scaled to max_speed.
	var cumulative := 0.0
	for i in FORWARD_GEAR_COUNT:
		cumulative += weights[i]
		_upshift_points[i] = max_speed_kmh * (cumulative / total_weight)


## Returns the current gear for a signed forward speed (km/h).
##   forward_speed_kmh > 0 -> moving forward, returns 1..FORWARD_GEAR_COUNT
##   forward_speed_kmh < 0 -> moving backward, returns GEAR_REVERSE
##   |forward_speed_kmh| below the neutral threshold -> GEAR_NEUTRAL
##
## max_speed_kmh is passed in so the car remains the single source of truth for
## its top speed; the bands are rebuilt automatically if it has changed.
func gear_for_speed(forward_speed_kmh: float, max_speed_kmh: float) -> int:
	if not is_equal_approx(max_speed_kmh, _built_for_max_speed):
		build_for_max_speed(max_speed_kmh)

	if forward_speed_kmh <= -neutral_speed_threshold:
		return GEAR_REVERSE
	if forward_speed_kmh < neutral_speed_threshold:
		return GEAR_NEUTRAL

	# Find the first gear whose upper boundary the speed has not yet exceeded.
	for i in FORWARD_GEAR_COUNT:
		if forward_speed_kmh <= _upshift_points[i]:
			return i + 1
	return FORWARD_GEAR_COUNT


## Human-readable label for a gear index, for the HUD ("R", "N", "1".."6").
static func gear_label(gear: int) -> String:
	if gear == GEAR_REVERSE:
		return "R"
	if gear == GEAR_NEUTRAL:
		return "N"
	return str(gear)
