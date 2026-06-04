class_name HeightProvider
extends RefCounted

## Samples terrain elevation (meters) for any point in the world.
##
## Elevation comes from a pre-baked heightmap (a 16-bit grayscale PNG) produced
## offline from a DEM such as Copernicus GLO-30 or NASA SRTM (see tools/bake_dem.py).
## A sidecar JSON file describes how to map the image back to geographic
## coordinates and to absolute elevation in meters:
##
##   {
##     "min_lon": 8.46, "min_lat": 49.48,
##     "max_lon": 8.48, "max_lat": 49.49,
##     "width": 512, "height": 256,
##     "min_elev": 102.4, "max_elev": 187.9,
##     "source": "Copernicus GLO-30"
##   }
##
## The heightmap encodes elevation normalized to [0, 65535] across
## [min_elev, max_elev]. Sampling is done in the same local meter space the OSM
## parser uses (X=east, Z=south, origin at dataset center), so the same provider
## drives both OSM node lifting and the terrain mesh.
##
## When no heightmap is configured (or it fails to load) the provider degrades
## gracefully to a flat world at y=0, keeping the game playable without DEM data.

const DEFAULT_HEIGHTMAP_PATH := "res://data/map.dem.png"
const DEFAULT_META_PATH := "res://data/map.dem.json"

var _ready: bool = false
var _img: Image = null
var _width: int = 0
var _height: int = 0

# Geographic bounds (degrees) of the heightmap coverage.
var _min_lon: float = 0.0
var _min_lat: float = 0.0
var _max_lon: float = 0.0
var _max_lat: float = 0.0

# Elevation range (meters) the 16-bit values are normalized across.
var _min_elev: float = 0.0
var _max_elev: float = 0.0

# Dataset center (degrees) used to convert local meters <-> lat/lon.
# These must match the values OSMParser used so both agree on the origin.
var _ref_lat: float = 0.0
var _ref_lon: float = 0.0

# Cached meters-per-degree factors at the reference latitude.
var _m_per_deg_lat: float = 111132.0
var _m_per_deg_lon: float = 111132.0

var _source: String = ""


## True when a heightmap is loaded and elevation queries are non-trivial.
func is_ready() -> bool:
	return _ready


## Human-readable description of the DEM source, or "" when flat.
func get_source() -> String:
	return _source


## Load the baked heightmap + metadata and bind it to the dataset origin.
##
## ref_lat/ref_lon are the OSM dataset center (OSMData.center_lat/center_lon).
## They tie the height field to the exact same local-meter origin OSMParser uses.
## Returns true on success; false leaves the provider in flat (y=0) mode.
func load_from_files(ref_lat: float, ref_lon: float,
		heightmap_path: String = DEFAULT_HEIGHTMAP_PATH,
		meta_path: String = DEFAULT_META_PATH) -> bool:
	_ready = false
	_ref_lat = ref_lat
	_ref_lon = ref_lon
	_m_per_deg_lat = 111132.0
	_m_per_deg_lon = 111132.0 * cos(deg_to_rad(ref_lat))

	if not FileAccess.file_exists(meta_path):
		print("HeightProvider: no DEM metadata at %s; terrain is flat." % meta_path)
		return false
	if not FileAccess.file_exists(heightmap_path):
		print("HeightProvider: no heightmap at %s; terrain is flat." % heightmap_path)
		return false

	var meta := _read_meta(meta_path)
	if meta.is_empty():
		return false

	var img := Image.load_from_file(heightmap_path)
	if img == null:
		push_error("HeightProvider: failed to load heightmap %s" % heightmap_path)
		return false

	# Sampling reads luminance; force a predictable single-channel layout.
	if img.get_format() != Image.FORMAT_L8 and img.get_format() != Image.FORMAT_RF \
			and img.get_format() != Image.FORMAT_RH:
		img.convert(Image.FORMAT_RF)

	_img = img
	_width = img.get_width()
	_height = img.get_height()
	if _width < 2 or _height < 2:
		push_error("HeightProvider: heightmap too small (%dx%d)" % [_width, _height])
		return false

	_min_lon = meta.get("min_lon", 0.0)
	_min_lat = meta.get("min_lat", 0.0)
	_max_lon = meta.get("max_lon", 0.0)
	_max_lat = meta.get("max_lat", 0.0)
	_min_elev = meta.get("min_elev", 0.0)
	_max_elev = meta.get("max_elev", 0.0)
	_source = meta.get("source", "DEM")

	if _max_lon <= _min_lon or _max_lat <= _min_lat:
		push_error("HeightProvider: invalid bounds in metadata")
		return false

	_ready = true
	print("HeightProvider: loaded %s heightmap %dx%d, elev %.1f..%.1f m" % [
		_source, _width, _height, _min_elev, _max_elev
	])
	return true


## Elevation (meters) at a local world position. Y is ignored; only XZ matter.
## Returns 0.0 when no heightmap is loaded.
func sample_local(pos: Vector3) -> float:
	return sample_local_xz(pos.x, pos.z)


## Elevation (meters) for a local-meter XZ coordinate (X=east, Z=south).
func sample_local_xz(x: float, z: float) -> float:
	if not _ready:
		return 0.0
	# Local meters -> lat/lon (inverse of OSMParser._latlon_to_local).
	var lon := _ref_lon + x / _m_per_deg_lon
	var lat := _ref_lat - z / _m_per_deg_lat
	return sample_latlon(lat, lon)


## Elevation (meters) at a geographic coordinate, with bilinear interpolation.
## Coordinates outside the heightmap are clamped to the nearest edge.
func sample_latlon(lat: float, lon: float) -> float:
	if not _ready:
		return 0.0

	# Fractional pixel coordinates. Image row 0 is the north (max_lat) edge,
	# which is the standard top-down raster orientation produced by the baker.
	var u := (lon - _min_lon) / (_max_lon - _min_lon)
	var v := (_max_lat - lat) / (_max_lat - _min_lat)
	u = clampf(u, 0.0, 1.0)
	v = clampf(v, 0.0, 1.0)

	var fx := u * float(_width - 1)
	var fy := v * float(_height - 1)
	var x0 := int(floor(fx))
	var y0 := int(floor(fy))
	var x1 := mini(x0 + 1, _width - 1)
	var y1 := mini(y0 + 1, _height - 1)
	var tx := fx - float(x0)
	var ty := fy - float(y0)

	var h00 := _texel_elev(x0, y0)
	var h10 := _texel_elev(x1, y0)
	var h01 := _texel_elev(x0, y1)
	var h11 := _texel_elev(x1, y1)

	var top := lerpf(h00, h10, tx)
	var bottom := lerpf(h01, h11, tx)
	return lerpf(top, bottom, ty)


## Decode a single texel to absolute elevation in meters.
func _texel_elev(x: int, y: int) -> float:
	# get_pixel returns normalized [0,1] for the red/luminance channel across
	# all supported formats (L8, RF, RH), so one path covers 8- and 16-bit maps.
	var norm := _img.get_pixel(x, y).r
	return _min_elev + norm * (_max_elev - _min_elev)


func _read_meta(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("HeightProvider: cannot open metadata %s" % path)
		return {}
	var text := f.get_as_text()
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("HeightProvider: metadata is not a JSON object: %s" % path)
		return {}
	return parsed
