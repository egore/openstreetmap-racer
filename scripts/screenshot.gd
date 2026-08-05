class_name Screenshot
extends RefCounted

## Saves a PNG of the current frame to disk.
##
## Used to capture what the game actually looks like so rendering problems can be
## inspected and discussed from an image rather than from description alone. The
## road/junction work in particular is much easier to judge from a screenshot
## than from geometry assertions — several visual regressions passed every unit
## test because the maths was self-consistent but wrong.
##
## Files land OUTSIDE the project (in the user data directory) so captures never
## end up in the repo or get picked up by Godot's resource importer. On macOS
## that resolves to:
##
##     ~/Library/Application Support/Godot/app_userdata/OpenStreetMap Racer/screenshots/
##
## capture() prints the absolute path it wrote, so it can be opened directly from
## the console output.

## Directory (inside user://) that captures are written to.
const DIR := "user://screenshots"

## Filename pattern: screenshot_YYYY-MM-DD_HH-MM-SS.png, so captures sort
## chronologically and never collide within a session.
const PREFIX := "screenshot"


## Grab the current frame and write it to disk.
##
## MUST be called after the frame has been drawn — the viewport texture is only
## valid then. Callers driving this from input should await
## RenderingServer.frame_post_draw first (see capture_deferred).
##
## Returns the absolute path written, or "" on failure (which is also pushed as
## an error, since a silent no-op here is confusing to debug).
static func capture(viewport: Viewport) -> String:
	if viewport == null:
		push_error("Screenshot: no viewport to capture")
		return ""

	var image := viewport.get_texture().get_image()
	if image == null:
		push_error("Screenshot: viewport produced no image")
		return ""

	if not DirAccess.dir_exists_absolute(DIR):
		var err := DirAccess.make_dir_recursive_absolute(DIR)
		if err != OK:
			push_error("Screenshot: cannot create %s (error %d)" % [DIR, err])
			return ""

	var path := "%s/%s_%s.png" % [DIR, PREFIX, timestamp()]
	var save_err := image.save_png(path)
	if save_err != OK:
		push_error("Screenshot: failed to write %s (error %d)" % [path, save_err])
		return ""

	return ProjectSettings.globalize_path(path)


## Filesystem-safe timestamp for a capture filename: YYYY-MM-DD_HH-MM-SS.
## Local time, so a capture's name matches the clock the user just looked at.
static func timestamp() -> String:
	var t := Time.get_datetime_dict_from_system()
	return "%04d-%02d-%02d_%02d-%02d-%02d" % [
		t["year"], t["month"], t["day"], t["hour"], t["minute"], t["second"],
	]
