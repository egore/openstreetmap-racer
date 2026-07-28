extends GdUnitTestSuite

## Tests for the DialCluster instrument readout.
##
## TachometerModel's own suite covers the rev maths. This suite covers the parts
## that only exist once the cluster is a real Control in a tree: that the values
## the car pushes in actually reach the model, that the telltales latch and fade,
## that the redline signal fires, and — most importantly — that drawing the dial
## does not crash at awkward sizes.
##
## The draw path matters because it runs every frame in front of the player and
## is full of division by size/radius; a zero-sized cluster during a layout pass
## would take the whole HUD down with it.

const DialClusterScript := preload("res://scripts/dial_cluster.gd")
const Transmission := preload("res://scripts/transmission.gd")

const STEP := 1.0 / 60.0


# ─── Fixtures ────────────────────────────────────────────────────────────────

## Build a cluster, put it in the tree so _ready runs, and give it a sane size.
func _make(cluster_size: Vector2 = Vector2(220, 220)) -> DialCluster:
	var cluster: DialCluster = DialClusterScript.new()
	cluster.size = cluster_size
	add_child(cluster)
	auto_free(cluster)
	return cluster


## Pump _process frames so the needle and telltales advance.
func _tick(cluster: DialCluster, frames: int = 1) -> void:
	for _i in frames:
		cluster._process(STEP)


# ─── Values reach the model ──────────────────────────────────────────────────

func test_gear_reaches_the_dial() -> void:
	var cluster := _make()
	cluster.set_gear(4)
	_tick(cluster)
	# The gear drives both the hub number and the rev band, so it must land.
	assert_int(cluster._gear).override_failure_message("the gear is stored").is_equal(4)


func test_speed_reaches_the_dial() -> void:
	var cluster := _make()
	cluster.set_speed(88.0)
	assert_float(cluster._speed_kmh) \
		.override_failure_message("the speed readout is stored") \
		.is_equal_approx(88.0, 0.001)


func test_speed_is_shown_as_a_magnitude() -> void:
	var cluster := _make()
	# Reversing sends a negative speed; a speedometer reading "-12" would be wrong.
	cluster.set_speed(-12.0)
	assert_float(cluster._speed_kmh) \
		.override_failure_message("reversing shows a positive speed") \
		.is_equal_approx(12.0, 0.001)


func test_gear_ratio_drives_the_revs() -> void:
	var low := _make()
	var high := _make()
	# The band position is the rev sweep, so a car deep in its gear must show more
	# revs than one that just shifted.
	low.set_gear(3)
	low.set_gear_ratio(0.1)
	high.set_gear(3)
	high.set_gear_ratio(0.95)
	_tick(low, 120)
	_tick(high, 120)
	assert_float(high.get_tachometer().display_rpm) \
		.override_failure_message("more band position -> more revs") \
		.is_greater(low.get_tachometer().display_rpm)


func test_cluster_configures_the_model_from_its_exports() -> void:
	var cluster: DialCluster = DialClusterScript.new()
	cluster.max_rpm = 9000.0
	cluster.redline_rpm = 8000.0
	add_child(cluster)
	auto_free(cluster)
	# The exports are the cluster's tuning surface; they must reach the model or
	# the dial would silently render a different range than it advertises.
	assert_float(cluster.get_tachometer().max_rpm) \
		.override_failure_message("max_rpm export reaches the model") \
		.is_equal_approx(9000.0, 0.001)
	assert_float(cluster.get_tachometer().redline_rpm) \
		.override_failure_message("redline_rpm export reaches the model") \
		.is_equal_approx(8000.0, 0.001)


# ─── Assist telltales ────────────────────────────────────────────────────────

func test_telltales_light_when_an_aid_intervenes() -> void:
	var cluster := _make()
	cluster.set_assist_levels(0.8, 0.0, 0.0)
	assert_float(cluster._tcs_level) \
		.override_failure_message("the TC lamp lights").is_greater(0.5)
	assert_float(cluster._abs_level) \
		.override_failure_message("the ABS lamp stays dark").is_equal_approx(0.0, 0.001)


func test_telltales_latch_to_the_highest_level() -> void:
	var cluster := _make()
	# A brief spike must not be erased by the next quiet frame, or interventions
	# shorter than a frame or two would be invisible.
	cluster.set_assist_levels(0.9, 0.0, 0.0)
	cluster.set_assist_levels(0.1, 0.0, 0.0)
	assert_float(cluster._tcs_level) \
		.override_failure_message("the lamp holds its peak").is_greater(0.5)


func test_telltales_fade_out() -> void:
	var cluster := _make()
	cluster.set_assist_levels(1.0, 1.0, 1.0)
	# ...but they must not stay lit forever once the aid stops working.
	_tick(cluster, 120)
	assert_float(cluster._tcs_level) \
		.override_failure_message("the TC lamp fades").is_equal_approx(0.0, 0.001)
	assert_float(cluster._abs_level) \
		.override_failure_message("the ABS lamp fades").is_equal_approx(0.0, 0.001)
	assert_float(cluster._stability_level) \
		.override_failure_message("the ESC lamp fades").is_equal_approx(0.0, 0.001)


func test_telltale_levels_are_clamped() -> void:
	var cluster := _make()
	# An out-of-range level must not push the lamp's alpha past opaque.
	cluster.set_assist_levels(5.0, 5.0, 5.0)
	assert_float(cluster._tcs_level) \
		.override_failure_message("levels clamp to full").is_less_equal(1.0)


# ─── Redline signal ──────────────────────────────────────────────────────────

func test_redline_signal_fires_when_entering_the_zone() -> void:
	var cluster := _make()
	var monitor := monitor_signals(cluster)
	cluster.set_gear(4)
	cluster.set_gear_ratio(1.0)
	_tick(cluster, 200)
	await assert_signal(monitor).is_emitted("redline_changed", [true])


func test_redline_signal_does_not_repeat_while_held() -> void:
	var cluster := _make()
	cluster.set_gear(4)
	cluster.set_gear_ratio(1.0)
	_tick(cluster, 200)
	# Now that it is already redlining, further frames must not re-announce it —
	# a signal firing every frame would spam anything listening for the shift cue.
	var monitor := monitor_signals(cluster)
	_tick(cluster, 60)
	await assert_signal(monitor).is_not_emitted("redline_changed")


# ─── Drawing is safe ─────────────────────────────────────────────────────────

func test_draw_survives_a_normal_size() -> void:
	var cluster := _make(Vector2(220, 220))
	cluster.set_gear(3)
	cluster.set_gear_ratio(0.6)
	cluster.set_speed(120.0)
	cluster.set_assist_levels(0.5, 0.5, 0.5)
	_tick(cluster, 30)
	# _draw runs every frame in front of the player; it must complete cleanly.
	cluster._draw()
	assert_bool(true).override_failure_message("drawing completed").is_true()


func test_draw_survives_a_zero_size() -> void:
	var cluster := _make(Vector2.ZERO)
	# Controls are momentarily zero-sized during layout. The radius guard must
	# catch this rather than dividing by zero and taking down the HUD.
	cluster._draw()
	assert_bool(true).override_failure_message("zero-size draw is safe").is_true()


func test_draw_survives_an_extreme_aspect_ratio() -> void:
	var cluster := _make(Vector2(400, 8))
	cluster.set_speed(200.0)
	_tick(cluster, 5)
	cluster._draw()
	assert_bool(true).override_failure_message("thin cluster draws safely").is_true()


func test_draw_survives_every_gear() -> void:
	var cluster := _make()
	# Reverse and neutral take different paths through the rev model, and the hub
	# renders their labels rather than a number.
	for gear in range(Transmission.GEAR_REVERSE, Transmission.FORWARD_GEAR_COUNT + 1):
		cluster.set_gear(gear)
		cluster.set_gear_ratio(0.5)
		cluster.set_speed(60.0)
		_tick(cluster, 5)
		cluster._draw()
	assert_bool(true).override_failure_message("all gears draw safely").is_true()


func test_draw_survives_redlining() -> void:
	var cluster := _make()
	cluster.set_gear(6)
	cluster.set_gear_ratio(1.0)
	cluster.set_speed(200.0)
	_tick(cluster, 200)
	# The redline path swaps colours and widens the rim; make sure that branch is
	# exercised too.
	assert_bool(cluster.get_tachometer().is_redlining()) \
		.override_failure_message("the fixture is actually redlining").is_true()
	cluster._draw()
	assert_bool(true).override_failure_message("redlining draws safely").is_true()


# ─── Dial geometry ───────────────────────────────────────────────────────────

func test_needle_direction_agrees_with_the_drawn_arc() -> void:
	var cluster := _make()
	# Regression: the needle and the filled arc are drawn by different code paths
	# (a polygon vs. draw_arc), and draw_arc measures angles from +X while the dial
	# measures them clockwise from straight down. Getting that conversion wrong
	# mirrored the needle horizontally, so it pointed away from the filled arc —
	# visible immediately in a screenshot but invisible to every other test.
	#
	# The two must agree: for any dial angle, the needle's direction has to match
	# the point on the circle that draw_arc would place that same angle at.
	for i in range(0, 13):
		var dial_angle := TAU * float(i) / 12.0
		var needle: Vector2 = DialClusterScript._dial_direction(dial_angle)
		# What draw_arc does with the +90 degree offset applied in _draw_dial_arc.
		var drawn_at := dial_angle + PI * 0.5
		var arc := Vector2(cos(drawn_at), sin(drawn_at))
		assert_float(needle.x) \
			.override_failure_message("needle x matches the arc at step %d" % i) \
			.is_equal_approx(arc.x, 0.0001)
		assert_float(needle.y) \
			.override_failure_message("needle y matches the arc at step %d" % i) \
			.is_equal_approx(arc.y, 0.0001)


func test_zero_revs_points_down_and_left() -> void:
	var cluster := _make()
	# The dial's resting position should be the lower-left of the face, the way a
	# car's cluster reads. This pins the start angle against an accidental rotation.
	var start: Vector2 = DialClusterScript._dial_direction(
		cluster.get_tachometer().dial_start
	)
	assert_float(start.x) \
		.override_failure_message("0 RPM points to the left half").is_less(0.0)
	assert_float(start.y) \
		.override_failure_message("0 RPM points to the lower half").is_greater(0.0)


func test_max_revs_points_down_and_right() -> void:
	var cluster := _make()
	# ...and the limiter mirrors it on the lower-right, so the sweep is symmetric.
	var tacho := cluster.get_tachometer()
	var end: Vector2 = DialClusterScript._dial_direction(
		tacho.angle_for_fraction(1.0)
	)
	assert_float(end.x) \
		.override_failure_message("max RPM points to the right half").is_greater(0.0)
	assert_float(end.y) \
		.override_failure_message("max RPM points to the lower half").is_greater(0.0)


func test_needle_sweeps_across_the_top_of_the_dial() -> void:
	var cluster := _make()
	# Mid-range revs should put the needle near the top of the face. If the sweep
	# ran the wrong way this would land at the bottom instead.
	var tacho := cluster.get_tachometer()
	var mid: Vector2 = DialClusterScript._dial_direction(tacho.angle_for_fraction(0.5))
	assert_float(mid.y) \
		.override_failure_message("half revs points to the upper half of the dial") \
		.is_less(0.0)


# ─── Input transparency ──────────────────────────────────────────────────────

func test_cluster_ignores_mouse_input() -> void:
	var cluster := _make()
	# The cluster covers a corner of the screen. If it swallowed clicks it would
	# block the pause menu underneath it.
	assert_int(cluster.mouse_filter) \
		.override_failure_message("the cluster never eats clicks") \
		.is_equal(Control.MOUSE_FILTER_IGNORE)
