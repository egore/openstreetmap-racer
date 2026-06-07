extends GdUnitTestSuite

## Unit tests for HeightProvider DEM sampling.
##
## These pin the contract the offline DEM baker (tools/bake_dem.py) and the
## runtime sampler agree on: a 16-bit heightmap normalizes elevation across
## [min_elev, max_elev], image row 0 is the north edge, and the local-meter
## inverse projection lines up with OSMParser's forward projection. A synthetic
## gradient heightmap is generated at runtime so the test needs no DEM asset.

const HeightProvider := preload("res://scripts/height_provider.gd")

const W := 8
const H := 8
const MIN_LON := 8.0
const MIN_LAT := 49.0
const MAX_LON := 8.02
const MAX_LAT := 49.02
const MIN_ELEV := 100.0
const MAX_ELEV := 200.0

var _tmp_png := "user://_test_dem.png"
var _tmp_json := "user://_test_dem.json"


# ─── Lifecycle ───────────────────────────────────────────────────────────────

func before() -> void:
	_write_fixture()


func after() -> void:
	_cleanup()


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
	assert_bool(ok) \
		.override_failure_message("load_from_files succeeds with a valid fixture").is_true()
	return hp


# ─── Tests ───────────────────────────────────────────────────────────────────

## With no DEM present, the provider stays flat and reports not-ready.
func test_missing_files_flat() -> void:
	var hp := HeightProvider.new()
	var ok := hp.load_from_files(49.0, 8.0, "user://nope.png", "user://nope.json")
	assert_bool(ok).override_failure_message("load fails when files are missing").is_false()
	assert_bool(hp.is_ready()) \
		.override_failure_message("provider not ready without a heightmap").is_false()
	assert_float(hp.sample_latlon(49.0, 8.0)) \
		.override_failure_message("flat sample is 0").is_equal_approx(0.0, 0.0001)


## The west edge decodes to MIN_ELEV, the east edge to MAX_ELEV.
func test_corner_elevations() -> void:
	var hp := _load()
	# Sample slightly inside the edges to avoid landing exactly between texels.
	assert_float(hp.sample_latlon(49.01, MIN_LON)) \
		.override_failure_message("west edge decodes to min elevation") \
		.is_equal_approx(MIN_ELEV, 0.5)
	assert_float(hp.sample_latlon(49.01, MAX_LON)) \
		.override_failure_message("east edge decodes to max elevation") \
		.is_equal_approx(MAX_ELEV, 0.5)


## Center longitude => normalized 0.5 => midpoint elevation.
func test_bilinear_center() -> void:
	var hp := _load()
	var mid_lon := (MIN_LON + MAX_LON) / 2.0
	var mid_elev := (MIN_ELEV + MAX_ELEV) / 2.0
	assert_float(hp.sample_latlon(49.01, mid_lon)) \
		.override_failure_message("center longitude interpolates to mid elevation") \
		.is_equal_approx(mid_elev, 1.0)


## Coordinates beyond the bounds clamp to the nearest edge rather than wrapping.
func test_out_of_bounds_clamps() -> void:
	var hp := _load()
	assert_float(hp.sample_latlon(49.01, MIN_LON - 1.0)) \
		.override_failure_message("far west clamps to min elevation") \
		.is_equal_approx(MIN_ELEV, 0.5)
	assert_float(hp.sample_latlon(49.01, MAX_LON + 1.0)) \
		.override_failure_message("far east clamps to max elevation") \
		.is_equal_approx(MAX_ELEV, 0.5)


## sample_local_xz must invert OSMParser's projection: feeding the local meters
## for a known lat/lon back in yields the same elevation as sample_latlon.
func test_local_xz_matches_latlon() -> void:
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
	assert_float(via_xz) \
		.override_failure_message("local XZ sampling matches lat/lon sampling") \
		.is_equal_approx(via_latlon, 0.5)
