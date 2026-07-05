class_name ImpactBurstSpec
extends RefCounted

## Maps a crash severity onto the parameters of a one-shot impact particle burst.
##
## Pure logic with no knowledge of GPUParticles3D or the scene tree — the car hands
## it a severity (the absolute kudos crash penalty) and it answers how many
## particles to spray, how fast, and how widely. ImpactParticles turns those
## numbers into an actual burst. Keeping the mapping here makes the "how big should
## a crash look?" curve easy to tune and unit-test without a viewport.

## Severity at/below which a crash is a light tap: the minimum burst.
var min_severity: float = 5.0
## Severity at which the burst is at full strength.
var full_severity: float = 150.0

## Particle count at the minimum and at full strength. A light tap flicks a few
## sparks; a big hit throws a shower.
var min_count: int = 6
var max_count: int = 40

## Initial spark speed (m/s) at min and full severity. Faster hits throw debris
## further.
var min_speed: float = 3.0
var max_speed: float = 12.0


## Normalised severity in [0, 1] across the min..full band.
func intensity(severity: float) -> float:
	return clampf(
		(severity - min_severity) / maxf(0.0001, full_severity - min_severity),
		0.0, 1.0)


## True if a crash of this severity is worth spawning a burst at all. Below the
## minimum severity we skip it (a negligible bump shouldn't throw sparks).
func should_burst(severity: float) -> bool:
	return severity >= min_severity


## Number of particles to emit for a crash of the given severity. Always at least
## min_count once should_burst() passes, scaling up to max_count.
func particle_count(severity: float) -> int:
	return int(round(lerpf(float(min_count), float(max_count), intensity(severity))))


## Peak spark speed (m/s) for the burst, scaling with severity.
func burst_speed(severity: float) -> float:
	return lerpf(min_speed, max_speed, intensity(severity))
