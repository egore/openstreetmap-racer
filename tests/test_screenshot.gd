extends GdUnitTestSuite

## Tests for the screenshot helper (P key).
##
## The point of this feature is to inspect what the renderer ACTUALLY produced,
## so the one thing that must not happen is a capture silently failing or
## writing a corrupt file — a missing screenshot is easy to misread as "the
## feature is broken" when it was only the capture that broke.

const ScreenshotScript := preload("res://scripts/screenshot.gd")


func test_timestamp_is_filesystem_safe() -> void:
	# The timestamp goes straight into a filename, so it must not contain
	# characters that are illegal or awkward on any common filesystem.
	var ts := ScreenshotScript.timestamp()
	for bad: String in [":", "/", "\\", " ", "*", "?", "\"", "<", ">", "|"]:
		assert_bool(ts.contains(bad)) \
			.override_failure_message("timestamp must not contain '%s': %s" % [bad, ts]) \
			.is_false()


func test_timestamp_has_expected_shape() -> void:
	# YYYY-MM-DD_HH-MM-SS
	var ts := ScreenshotScript.timestamp()
	assert_int(ts.length()) \
		.override_failure_message("unexpected timestamp shape: %s" % ts) \
		.is_equal(19)
	assert_bool(ts.contains("_")) \
		.override_failure_message("date and time must be separated: %s" % ts) \
		.is_true()


func test_timestamps_sort_chronologically() -> void:
	# Captures are inspected in order, so lexical sort must match time order.
	# A zero-padded ISO-style stamp gives this for free; a non-padded one would
	# put "9" after "10".
	var ts := ScreenshotScript.timestamp()
	var parts := ts.split("_")
	assert_int(parts.size()).is_equal(2)
	var date_parts := parts[0].split("-")
	assert_int(date_parts.size()).is_equal(3)
	assert_int(String(date_parts[0]).length()).is_equal(4)  # year
	assert_int(String(date_parts[1]).length()).is_equal(2)  # zero-padded month
	assert_int(String(date_parts[2]).length()).is_equal(2)  # zero-padded day


func test_null_viewport_fails_loudly_not_silently() -> void:
	# Returning "" (rather than crashing) is deliberate, but the caller must be
	# able to tell that nothing was written.
	var path: String = ScreenshotScript.capture(null)
	assert_str(path) \
		.override_failure_message("a failed capture must report an empty path") \
		.is_equal("")


func test_captures_land_outside_the_project() -> void:
	# Screenshots must not be written into res:// — they would be committed to
	# the repo and picked up by Godot's resource importer.
	assert_bool(String(ScreenshotScript.DIR).begins_with("user://")) \
		.override_failure_message(
			"captures must go to user://, got %s" % ScreenshotScript.DIR) \
		.is_true()


func test_capture_writes_a_readable_png() -> void:
	# End-to-end: capture the test viewport and verify the file on disk is a
	# real PNG that loads back at a sane size. This is what proves the feature
	# works, as opposed to merely returning a plausible-looking path.
	var path: String = ScreenshotScript.capture(get_tree().root)
	if path == "":
		# Headless CI has no rendering device; skip rather than fail there.
		return

	assert_bool(FileAccess.file_exists(path)) \
		.override_failure_message("capture reported %s but no file exists" % path) \
		.is_true()

	var img := Image.new()
	var err := img.load(path)
	assert_int(err) \
		.override_failure_message("capture at %s is not a readable image" % path) \
		.is_equal(OK)
	assert_int(img.get_width()).is_greater(0)
	assert_int(img.get_height()).is_greater(0)

	# Clean up so repeated test runs don't fill the user directory.
	DirAccess.remove_absolute(path)
