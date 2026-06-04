extends SceneTree

## Headless unit tests for HeightProvider DEM sampling.
##
## These pin the contract the offline DEM baker (tools/bake_dem.py) and the
## runtime sampler agree on: a 16-bit heightmap normalizes elevation across
## [min_elev, max_elev], image row 0 is the north edge, and the local-meter
## inverse projection lines up with OSMParser's forward projection. A synthetic
## gradient heightmap is generated at runtime so the test needs no DEM asset.
##
## Run with:
##   godot --headless --path . --script res://tests/test_height_provider.gd
##
## Exits with code 0 when all tests pass, 1 otherwise (CI-friendly).

const HeightProvider := preload("res://scripts/height_provider.gd")

const W := 8
const H := 8
const MIN_LON := 8.0
const MIN_LAT := 49.0
const MAX_LON := 8.02
const MAX_LAT := 49.02
const MIN_ELEV := 100.0
const MAX_ELEV := 200.0

var _failures: int = 0
var _checks: int = 0
var _tmp_png := "user://_test_dem.png"
var _tmp_json := "user://_test_dem.json"


func _init() -> void:
	_write_fixture()
	_run_all()
	_cleanup()
	if _failures == 0:
		print("PASS: all %d checks passed" % _checks)
		quit(0)
	else:
		print("FAIL: %d of %d checks failed" % [_failures, _checks])
		quit(1)


# ─── Assertion helpers ───────────────────────────────────────────────────────

func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error("CHECK FAILED: %s" % message)
		print("  FAIL: %s" % message)


func _check_near(actual: float, expected: float, tol: float, message: String) -> void:
	_check(absf(actual - expected) <= tol,
		"%s (got %.4f, want %.4f +-%.4f)" % [message, actual, expected, tol])


# ─── Fixture ─────────────────────────────────────────────────────────────────

## Build a heightmap whose normalized value increases left->right (west->east):
## column gx maps to norm = gx / (W-1). Row is constant, so elevation depends
## only on longitude. This makes expected values easy to reason about.
func _write_fixture() -> void:
	var img := Image.create(W, H, false, Image.FORMAT_RF)
	for y: int in range(H):
		for x: int in range(W):
			var norm := float(x) / float(W - 1)
			img.set_pixel(x, y, Color(norm, norm, norm))
	img.save_png(_tmp_png)

	var meta := {
		"min_lon": MIN_LON, "min_lat": MIN_LAT,
		"max_lon": MAX_LON, "max_lat": MAX_LAT,
		"width": W, "height": H,
		"min_elev": MIN_ELEV, "max_elev": MAX_ELEV,
		"source": "test gradient",
	}
	var f := FileAccess.open(_tmp_json, FileAccess.WRITE)
	f.store_string(JSON.stringify(meta))
	f.close()


func _cleanup() -> void:
	for p: String in [_tmp_png, _tmp_json]:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(p))


func _load() -> HeightProvider:
	var hp := HeightProvider.new()
	var ref_lat := (MIN_LAT + MAX_LAT) / 2.0
	var ref_lon := (MIN_LON + MAX_LON) / 2.0
	var ok := hp.load_from_files(ref_lat, ref_lon, _tmp_png, _tmp_json)
	_check(ok, "load_from_files succeeds with a valid fixture")
	return hp


# ─── Tests ───────────────────────────────────────────────────────────────────

func _run_all() -> void:
	_test_missing_files_flat()
	_test_corner_elevations()
	_test_bilinear_center()
	_test_out_of_bounds_clamps()
	_test_local_xz_matches_latlon()


## With no DEM present, the provider stays flat and reports not-ready.
func _test_missing_files_flat() -> void:
	var hp := HeightProvider.new()
	var ok := hp.load_from_files(49.0, 8.0, "user://nope.png", "user://nope.json")
	_check(not ok, "load fails when files are missing")
	_check(not hp.is_ready(), "provider not ready without a heightmap")
	_check_near(hp.sample_latlon(49.0, 8.0), 0.0, 0.0001, "flat sample is 0")


## The west edge decodes to MIN_ELEV, the east edge to MAX_ELEV.
func _test_corner_elevations() -> void:
	var hp := _load()
	# Sample slightly inside the edges to avoid landing exactly between texels.
	_check_near(hp.sample_latlon(49.01, MIN_LON), MIN_ELEV, 0.5,
		"west edge decodes to min elevation")
	_check_near(hp.sample_latlon(49.01, MAX_LON), MAX_ELEV, 0.5,
		"east edge decodes to max elevation")


## Center longitude => normalized 0.5 => midpoint elevation.
func _test_bilinear_center() -> void:
	var hp := _load()
	var mid_lon := (MIN_LON + MAX_LON) / 2.0
	var mid_elev := (MIN_ELEV + MAX_ELEV) / 2.0
	_check_near(hp.sample_latlon(49.01, mid_lon), mid_elev, 1.0,
		"center longitude interpolates to mid elevation")


## Coordinates beyond the bounds clamp to the nearest edge rather than wrapping.
func _test_out_of_bounds_clamps() -> void:
	var hp := _load()
	_check_near(hp.sample_latlon(49.01, MIN_LON - 1.0), MIN_ELEV, 0.5,
		"far west clamps to min elevation")
	_check_near(hp.sample_latlon(49.01, MAX_LON + 1.0), MAX_ELEV, 0.5,
		"far east clamps to max elevation")


## sample_local_xz must invert OSMParser's projection: feeding the local meters
## for a known lat/lon back in yields the same elevation as sample_latlon.
func _test_local_xz_matches_latlon() -> void:
	var hp := _load()
	var ref_lat := (MIN_LAT + MAX_LAT) / 2.0
	var ref_lon := (MIN_LON + MAX_LON) / 2.0
	var lat := 49.012
	var lon := 8.013
	# Forward projection identical to OSMParser._latlon_to_local.
	var m_per_deg_lat := 111132.0
	var m_per_deg_lon := 111132.0 * cos(deg_to_rad(ref_lat))
	var x := (lon - ref_lon) * m_per_deg_lon
	var z := -(lat - ref_lat) * m_per_deg_lat
	var via_xz := hp.sample_local_xz(x, z)
	var via_latlon := hp.sample_latlon(lat, lon)
	_check_near(via_xz, via_latlon, 0.5, "local XZ sampling matches lat/lon sampling")
