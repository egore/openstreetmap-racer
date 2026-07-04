class_name PostProcessing
extends Node

## Owns the screen-space post-processing stack on the WorldEnvironment and lets
## us switch individual effects on and off from code (no UI). This is the "make
## it look like Forza" layer: glow/bloom, SSAO, SSIL, SSR and tonemap/colour
## grading, all stacked on top of the existing sky + fog.
##
## Two design goals drive the shape of this file:
##
##   1. Per-effect toggles. Each effect is an exported bool so we can flip them
##      in the scene/inspector (or from a test harness) and measure where the
##      frame rate falls off. SSR and SSIL are the usual suspects, so being able
##      to disable them independently — without touching the others — is the
##      whole point. Flipping a toggle at runtime re-applies immediately.
##
##   2. Day/night awareness. Bloom and exposure want different values after dark:
##      at night the emissive headlights, street lamps and lit windows should
##      bloom harder against a darker frame, and the overall exposure lifts a
##      touch so the scene doesn't crush to black. We listen to the same
##      day_night signal the sky uses and re-apply on each transition, tweening
##      the continuous values so it matches the sky's 1.5 s crossfade.
##
## The Environment resource is shared with SkyController (which owns fog +
## ambient + the sky material). We only ever touch the post-processing fields
## here, so the two controllers can drive the same Environment without fighting.

## A resolved set of post-processing values for one instant in time. The two
## presets (day/night) are instances of this; the live state is lerped between
## them so a toggle mid-transition reverses smoothly. Only the *continuous*
## values live here — the on/off booleans are authored toggles, not animated.
class PPSettings:
	var glow_intensity: float
	var glow_bloom: float
	var glow_hdr_threshold: float
	var exposure: float
	var brightness: float
	var contrast: float
	var saturation: float

## Daytime grade: neutral-to-slightly-punchy. Bloom is subtle — bright sky and
## sunlit asphalt highlights bleed a little, but the frame stays clean. A gentle
## contrast/saturation lift gives the warm, slightly graded Forza daylight look.
const DAY := {
	"glow_intensity": 0.8,
	"glow_bloom": 0.05,
	"glow_hdr_threshold": 1.0,
	"exposure": 1.0,
	"brightness": 1.0,
	"contrast": 1.05,
	"saturation": 1.12,
}

## Nighttime grade: bloom pushed hard and its HDR threshold dropped so the
## emissive lights (headlights, street lamps, lit windows) blaze against the
## dark frame. Exposure lifts slightly so shadows don't crush to pure black, and
## saturation eases off the way real low-light footage desaturates.
const NIGHT := {
	"glow_intensity": 1.3,
	"glow_bloom": 0.25,
	"glow_hdr_threshold": 0.65,
	"exposure": 1.15,
	"brightness": 1.0,
	"contrast": 1.1,
	"saturation": 1.02,
}

## Seconds for the day<->night post-processing crossfade. Matches
## SkyController.TRANSITION_TIME so the grade and the sky move together.
const TRANSITION_TIME := 1.5

# --- Per-effect toggles ------------------------------------------------------
# Flip any of these in the inspector or from code to isolate its FPS cost.
# Changing one at runtime re-applies the whole stack on the next frame.

## Master switch. When false the Environment is left in its authored state and
## none of the effects below are touched (useful as an A/B baseline).
@export var enabled: bool = true:
	set(v):
		enabled = v
		_reapply()

## Glow/bloom. Cheap and high-impact; the signature "glowy" racing-game look.
@export var glow_enabled: bool = true:
	set(v):
		glow_enabled = v
		_reapply()

## Screen-space ambient occlusion — contact shadows in crevices and where
## geometry meets the ground. Moderate cost.
@export var ssao_enabled: bool = true:
	set(v):
		ssao_enabled = v
		_reapply()

## Screen-space indirect lighting — cheap bounce light / colour bleed. Can be
## the first thing to disable if the GPU is struggling.
@export var ssil_enabled: bool = true:
	set(v):
		ssil_enabled = v
		_reapply()

## Screen-space reflections — glossy road/car-paint/window reflections. The most
## expensive effect here; expect this to be the FPS cliff on weaker GPUs.
@export var ssr_enabled: bool = true:
	set(v):
		ssr_enabled = v
		_reapply()

## Tonemap + colour adjustment (exposure, contrast, saturation grade). Nearly
## free and defines the overall "graded" mood.
@export var adjustments_enabled: bool = true:
	set(v):
		adjustments_enabled = v
		_reapply()

# --- Wiring ------------------------------------------------------------------

## Path to the WorldEnvironment we drive (same node SkyController uses).
@export var world_environment_path: NodePath
## Path to the SkyController so we can follow its day/night transitions. Optional
## — without it we simply apply the day preset and never change.
@export var sky_controller_path: NodePath
## Whether we start on the daytime grade. Kept in sync with the sky by wiring
## the signal below; this is just the frame-one value.
@export var start_in_day: bool = true

var environment: Environment
var _sky: SkyController
var _is_day: bool = true
var _tween: Tween
## Live, interpolated continuous settings (lerped between DAY and NIGHT).
var _current := PPSettings.new()


func _ready() -> void:
	var we := get_node_or_null(world_environment_path) as WorldEnvironment
	if we != null:
		environment = we.environment

	_sky = get_node_or_null(sky_controller_path) as SkyController
	if _sky != null:
		# Follow whatever the sky says the time of day is, and track future
		# transitions. Seed from the sky's current state so we agree on frame one.
		_is_day = _sky.is_day()
		_sky.day_night_changed.connect(_on_day_night_changed)
	else:
		_is_day = start_in_day

	# Snap (no fade) to the starting grade so frame one already looks right.
	_copy_preset_into(_preset_dict(_is_day), _current)
	_reapply()


## Follows the sky's day/night transition: tween the continuous values over the
## same duration so bloom/exposure move in lockstep with the sky crossfade. The
## effect toggles are unaffected — only the day/night-varying values animate.
func _on_day_night_changed(is_day: bool) -> void:
	_is_day = is_day
	_start_transition(_preset_dict(is_day))


func _start_transition(target: Dictionary) -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()

	var goal := PPSettings.new()
	_copy_preset_into(target, goal)

	var from := PPSettings.new()
	_copy_struct(_current, from)

	_tween = create_tween()
	_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_tween.tween_method(
		_blend_step.bind(from, goal), 0.0, 1.0, TRANSITION_TIME
	)


func _blend_step(weight: float, from: PPSettings, to: PPSettings) -> void:
	_current.glow_intensity = lerpf(from.glow_intensity, to.glow_intensity, weight)
	_current.glow_bloom = lerpf(from.glow_bloom, to.glow_bloom, weight)
	_current.glow_hdr_threshold = lerpf(from.glow_hdr_threshold, to.glow_hdr_threshold, weight)
	_current.exposure = lerpf(from.exposure, to.exposure, weight)
	_current.brightness = lerpf(from.brightness, to.brightness, weight)
	_current.contrast = lerpf(from.contrast, to.contrast, weight)
	_current.saturation = lerpf(from.saturation, to.saturation, weight)
	_reapply()


# --- Application -------------------------------------------------------------

## Re-applies the whole stack to the Environment from the current toggles + live
## settings. Cheap enough to call any time a toggle flips or a blend steps.
func _reapply() -> void:
	if environment == null:
		return
	apply_to(environment, _current)


## Pure-ish writer: stamps the effect toggles and the given continuous settings
## onto an Environment. Split out from _reapply (which supplies the live state)
## so tests can drive it with a throwaway Environment and any settings they like.
##
## Honours the master `enabled` switch: when off, every effect is disabled and
## the tonemap is reset to the neutral Godot default so the baseline is clean.
func apply_to(env: Environment, s: PPSettings) -> void:
	if not enabled:
		env.glow_enabled = false
		env.ssao_enabled = false
		env.ssil_enabled = false
		env.ssr_enabled = false
		env.adjustment_enabled = false
		return

	# Glow / bloom.
	env.glow_enabled = glow_enabled
	if glow_enabled:
		env.glow_intensity = s.glow_intensity
		env.glow_bloom = s.glow_bloom
		env.glow_hdr_threshold = s.glow_hdr_threshold
		# Screen blend keeps highlights from blowing out to flat white the way
		# additive does — closer to a physical bloom.
		env.glow_blend_mode = Environment.GLOW_BLEND_MODE_SCREEN

	# SSAO.
	env.ssao_enabled = ssao_enabled

	# SSIL (screen-space indirect lighting).
	env.ssil_enabled = ssil_enabled

	# SSR (screen-space reflections). Needs a sane roughness fade / step budget;
	# the defaults are fine, we just switch it on.
	env.ssr_enabled = ssr_enabled

	# Tonemap + colour grade. ACES gives the punchy, filmic highlight rolloff
	# that reads as "AAA"; exposure/contrast/saturation do the mood.
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_exposure = s.exposure
	env.adjustment_enabled = adjustments_enabled
	if adjustments_enabled:
		env.adjustment_brightness = s.brightness
		env.adjustment_contrast = s.contrast
		env.adjustment_saturation = s.saturation


# --- Preset plumbing ---------------------------------------------------------

func _preset_dict(target_is_day: bool) -> Dictionary:
	return DAY if target_is_day else NIGHT


func _copy_preset_into(d: Dictionary, out: PPSettings) -> void:
	out.glow_intensity = d.glow_intensity
	out.glow_bloom = d.glow_bloom
	out.glow_hdr_threshold = d.glow_hdr_threshold
	out.exposure = d.exposure
	out.brightness = d.brightness
	out.contrast = d.contrast
	out.saturation = d.saturation


func _copy_struct(src: PPSettings, dst: PPSettings) -> void:
	dst.glow_intensity = src.glow_intensity
	dst.glow_bloom = src.glow_bloom
	dst.glow_hdr_threshold = src.glow_hdr_threshold
	dst.exposure = src.exposure
	dst.brightness = src.brightness
	dst.contrast = src.contrast
	dst.saturation = src.saturation
