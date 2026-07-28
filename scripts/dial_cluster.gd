class_name DialCluster
extends Control

## The driver's instrument cluster: a swept rev counter with a redline, a big
## gear number in the hub, a digital speed readout, and assist telltales.
##
## This replaces the plain "0 km/h" corner label. A racing game's HUD is a large
## part of its identity — the dial is the thing that makes the car feel like a
## car, gives the revs a physical presence, and tells the player when to shift
## without them having to read a number.
##
## All the rev logic lives in TachometerModel (a pure helper); this class is only
## responsible for turning those numbers into pixels. That split means the dial's
## behaviour is unit-testable without a viewport, and the styling can change
## without touching the maths.
##
## Everything is drawn with Godot's primitives rather than sprite assets, matching
## the project's texture-free approach elsewhere (procedural shaders, the minimap):
## the cluster scales to any size and needs no art pipeline.

## Emitted when the dial enters or leaves the shift-up zone, so other systems
## (audio, force feedback) can react to the shift light without polling.
signal redline_changed(redlining: bool)

## Outer radius of the dial as a fraction of the control's smaller dimension.
@export var dial_radius_ratio: float = 0.46
## Thickness of the rev arc, as a fraction of the dial radius.
@export var arc_width_ratio: float = 0.13

## Engine speed (RPM) at the top of the range. Feeds the model.
@export var max_rpm: float = 7500.0
## Engine speed (RPM) where the red zone starts.
@export var redline_rpm: float = 6500.0

## Colours. Kept as exports so the cluster can be re-themed per car later.
@export var face_color: Color = Color(0.04, 0.05, 0.07, 0.72)
@export var rim_color: Color = Color(0.55, 0.60, 0.68, 0.55)
@export var arc_track_color: Color = Color(0.16, 0.18, 0.22, 0.85)
@export var arc_fill_color: Color = Color(0.35, 0.78, 1.0, 0.95)
@export var redline_color: Color = Color(1.0, 0.22, 0.18, 0.95)
@export var needle_color: Color = Color(1.0, 0.95, 0.90, 1.0)
@export var text_color: Color = Color(0.96, 0.97, 1.0, 1.0)
@export var muted_text_color: Color = Color(0.62, 0.66, 0.74, 1.0)

## Rev logic. The cluster feeds it gear/speed each frame and reads back the
## needle position and redline state.
var _tacho := TachometerModel.new()

## Latest values pushed in from the car, held so _draw can render them.
var _speed_kmh: float = 0.0
var _gear: int = Transmission.GEAR_NEUTRAL
var _gear_ratio: float = 0.0

## Assist telltale levels, 0..1. Lit when the corresponding aid is intervening,
## exactly like the TC/ABS lamps on a real dashboard.
var _tcs_level: float = 0.0
var _abs_level: float = 0.0
var _stability_level: float = 0.0

## Last redline state broadcast, so the signal only fires on a real change.
var _was_redlining: bool = false

## Number of tick marks around the dial (one per 1000 RPM at the default range,
## plus the zero mark).
const _TICK_COUNT := 8
## Length of a major tick, as a fraction of the dial radius.
const _TICK_LENGTH_RATIO := 0.12
## How far in from the rim the needle's tail is anchored, as a radius fraction.
const _NEEDLE_TAIL_RATIO := 0.12
## Radius of the needle's centre hub, as a fraction of the dial radius.
const _HUB_RATIO := 0.30
## Segments used to approximate the arcs. High enough that the curve reads as
## smooth at typical cluster sizes.
const _ARC_SEGMENTS := 64


func _ready() -> void:
	# The cluster is a passive readout; it must never eat clicks meant for the
	# game or the pause menu underneath it.
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tacho.max_rpm = max_rpm
	_tacho.redline_rpm = redline_rpm


func _process(delta: float) -> void:
	# Advance the needle toward its target. Done in _process rather than on each
	# incoming signal so the needle keeps easing (and settles) even on frames
	# where the car sent no update.
	_tacho.update(_gear, _gear_ratio, _speed_kmh, delta)

	var redlining := _tacho.is_redlining()
	if redlining != _was_redlining:
		_was_redlining = redlining
		redline_changed.emit(redlining)

	# Telltales fade out on their own so a brief intervention still registers
	# visually instead of flickering for a single frame.
	_tcs_level = maxf(0.0, _tcs_level - delta * _TELLTALE_FADE)
	_abs_level = maxf(0.0, _abs_level - delta * _TELLTALE_FADE)
	_stability_level = maxf(0.0, _stability_level - delta * _TELLTALE_FADE)

	queue_redraw()


## How fast an unlit telltale fades back out, per second.
const _TELLTALE_FADE := 3.0


## Push the current speed in from the car. Wired to CarController.speed_changed.
func set_speed(speed_kmh: float) -> void:
	_speed_kmh = absf(speed_kmh)


## Push the current gear in from the car. Wired to CarController.gear_changed.
func set_gear(gear: int) -> void:
	_gear = gear


## Push how far through the gear band the car is (0..1). This is what drives the
## rev sweep, so the cluster needs it every frame rather than only on a shift.
func set_gear_ratio(ratio: float) -> void:
	_gear_ratio = ratio


## Light the assist telltales. Each value is the aid's current intervention level
## (0 = idle, 1 = full). Values only ever raise the lamp; it fades on its own.
func set_assist_levels(tcs: float, abs_level: float, stability: float) -> void:
	_tcs_level = maxf(_tcs_level, clampf(tcs, 0.0, 1.0))
	_abs_level = maxf(_abs_level, clampf(abs_level, 0.0, 1.0))
	_stability_level = maxf(_stability_level, clampf(stability, 0.0, 1.0))


## The rev model, for tests and for anything that needs the raw RPM.
func get_tachometer() -> TachometerModel:
	return _tacho


func _draw() -> void:
	var centre := size * 0.5
	var radius := minf(size.x, size.y) * dial_radius_ratio
	if radius <= 0.0:
		return

	_draw_face(centre, radius)
	_draw_rev_arc(centre, radius)
	_draw_ticks(centre, radius)
	_draw_needle(centre, radius)
	_draw_hub_and_gear(centre, radius)
	_draw_speed(centre, radius)
	_draw_telltales(centre, radius)


## The dial's dark backing disc and its rim. The rim brightens toward red as the
## engine approaches the limiter, which is the shift light.
func _draw_face(centre: Vector2, radius: float) -> void:
	draw_circle(centre, radius, face_color)
	var intensity := _tacho.redline_intensity()
	var rim := rim_color.lerp(redline_color, intensity)
	var width := maxf(2.0, radius * 0.03) * (1.0 + intensity)
	draw_arc(centre, radius, 0.0, TAU, _ARC_SEGMENTS, rim, width, true)


## The swept rev bar: a dim track for the whole range, the filled portion up to
## the current revs, and the red zone marked on the outer edge.
func _draw_rev_arc(centre: Vector2, radius: float) -> void:
	var arc_radius := radius * (1.0 - arc_width_ratio * 0.5)
	var width := radius * arc_width_ratio
	var start := _tacho.dial_start
	var sweep := _tacho.dial_sweep

	# Unfilled track for the full range, so the dial reads as an instrument even
	# at zero revs.
	_draw_dial_arc(centre, arc_radius, start, start + sweep, arc_track_color, width)

	# The red zone, drawn on the track before the fill so the fill sits over it.
	var redline_start := _tacho.angle_for_fraction(_tacho.redline_fraction())
	_draw_dial_arc(
		centre, arc_radius, redline_start, start + sweep,
		Color(redline_color.r, redline_color.g, redline_color.b, 0.35), width
	)

	# The filled portion up to the current revs, turning red past the redline.
	var fraction := _tacho.needle_fraction()
	if fraction <= 0.0:
		return
	var fill := arc_fill_color.lerp(redline_color, _tacho.redline_intensity())
	_draw_dial_arc(
		centre, arc_radius, start, _tacho.angle_for_fraction(fraction), fill, width
	)


## Tick marks around the sweep, so the arc reads as a calibrated scale rather
## than a bare progress bar.
func _draw_ticks(centre: Vector2, radius: float) -> void:
	var inner := radius * (1.0 - arc_width_ratio - _TICK_LENGTH_RATIO)
	var outer := radius * (1.0 - arc_width_ratio)
	for i in range(_TICK_COUNT + 1):
		var fraction := float(i) / float(_TICK_COUNT)
		var angle := _tacho.angle_for_fraction(fraction)
		var dir := _dial_direction(angle)
		# Ticks inside the red zone are drawn red, marking the shift point.
		var tint := redline_color if fraction >= _tacho.redline_fraction() else muted_text_color
		draw_line(centre + dir * inner, centre + dir * outer, tint, maxf(1.0, radius * 0.018), true)


## The needle itself: a tapered pointer from just past the hub out to the arc.
func _draw_needle(centre: Vector2, radius: float) -> void:
	var angle := _tacho.needle_angle()
	var dir := _dial_direction(angle)
	# Perpendicular, for the needle's width at its base.
	var side := Vector2(-dir.y, dir.x)
	var tip := centre + dir * (radius * (1.0 - arc_width_ratio - 0.04))
	var base := centre - dir * (radius * _NEEDLE_TAIL_RATIO)
	var half_width := maxf(1.5, radius * 0.035)
	# A triangle from a wide base to a point reads as a needle at any size.
	var points := PackedVector2Array([
		tip,
		base + side * half_width,
		base - side * half_width,
	])
	draw_colored_polygon(points, needle_color)


## The centre hub carrying the current gear — the number the driver actually
## looks at. Flashes red at the redline as the "shift now" cue.
func _draw_hub_and_gear(centre: Vector2, radius: float) -> void:
	var hub_radius := radius * _HUB_RATIO
	draw_circle(centre, hub_radius, Color(0.02, 0.03, 0.05, 0.92))
	var intensity := _tacho.redline_intensity()
	draw_arc(
		centre, hub_radius, 0.0, TAU, 32,
		rim_color.lerp(redline_color, intensity), maxf(1.5, radius * 0.02), true
	)

	var font := ThemeDB.fallback_font
	var gear_size := int(maxf(12.0, hub_radius * 1.15))
	var label := Transmission.gear_label(_gear)
	var colour := text_color.lerp(redline_color, intensity)
	_draw_centred_text(font, label, gear_size, centre, colour)


## The digital speed readout below the dial, with its unit. Speed stays a number
## because that is what the player checks precisely; the dial handles revs.
func _draw_speed(centre: Vector2, radius: float) -> void:
	var font := ThemeDB.fallback_font
	var speed_size := int(maxf(14.0, radius * 0.30))
	var speed_pos := centre + Vector2(0.0, radius * 0.52)
	_draw_centred_text(font, "%d" % int(round(_speed_kmh)), speed_size, speed_pos, text_color)

	var unit_size := int(maxf(9.0, radius * 0.13))
	var unit_pos := speed_pos + Vector2(0.0, radius * 0.24)
	_draw_centred_text(font, "km/h", unit_size, unit_pos, muted_text_color)


## Assist telltales along the bottom of the cluster: TC, ABS and stability, lit
## while the corresponding aid is working. This is how the player learns the car
## is helping them, instead of the aids being invisible magic.
func _draw_telltales(centre: Vector2, radius: float) -> void:
	var font := ThemeDB.fallback_font
	var lamp_size := int(maxf(8.0, radius * 0.13))
	var y := centre.y - radius * 0.42
	var spacing := radius * 0.42
	var lamps := [
		["TC", _tcs_level, Color(1.0, 0.82, 0.2)],
		["ABS", _abs_level, Color(1.0, 0.65, 0.15)],
		["ESC", _stability_level, Color(0.4, 1.0, 0.6)],
	]
	for i in range(lamps.size()):
		var entry: Array = lamps[i]
		var level: float = entry[1]
		# Unlit lamps stay faintly visible so the cluster looks complete at rest.
		var lit: Color = entry[2]
		var colour := Color(lit.r, lit.g, lit.b, lerpf(0.18, 1.0, level))
		var x := centre.x + (float(i) - 1.0) * spacing
		_draw_centred_text(font, entry[0], lamp_size, Vector2(x, y), colour)


## Draw text centred on a point (Godot's draw_string anchors at the baseline's
## left edge, which would otherwise put every label off-centre).
func _draw_centred_text(
	font: Font, text: String, font_size: int, at: Vector2, colour: Color
) -> void:
	var measured := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size)
	# Shift left by half the width, and down by roughly half the cap height so the
	# glyphs sit visually centred on the point rather than hanging below it.
	var pos := at - Vector2(measured.x * 0.5, -font_size * 0.35)
	draw_string(font, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size, colour)


## Draw a thick arc between two dial angles. Wraps draw_arc with the segment
## count and the antialiasing the cluster wants everywhere.
func _draw_dial_arc(
	centre: Vector2, radius: float, from: float, to: float, colour: Color, width: float
) -> void:
	if to <= from:
		return
	# The dial's angles are measured from straight down (see _dial_direction), but
	# draw_arc measures from the +X axis, so rotate a quarter turn to match.
	var offset := PI * 0.5
	draw_arc(centre, radius, from + offset, to + offset, _ARC_SEGMENTS, colour, width, true)


## Unit vector pointing out along the dial at the given angle.
##
## Dial angles are measured CLOCKWISE from straight DOWN: angle 0 is the 6 o'clock
## position, and increasing angles run 6 -> 9 -> 12 -> 3 on a clock face. With the
## default 60-degree start and 240-degree sweep, 0 RPM sits at roughly 7 o'clock
## and the limiter at 5 o'clock — symmetric about vertical, like a real cluster.
##
## The -sin/+cos pairing (rather than the more obvious sin/cos) is what makes this
## agree with _draw_dial_arc: Godot's draw_arc measures from the +X axis, so a
## dial angle `a` is drawn at `a + 90`, whose direction is exactly
## (cos(a+90), sin(a+90)) == (-sin a, cos a). Using sin/cos here instead mirrors
## the needle horizontally and makes it point away from the filled arc.
static func _dial_direction(angle: float) -> Vector2:
	return Vector2(-sin(angle), cos(angle))
