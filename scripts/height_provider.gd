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
var _width: int = 0
var _height: int = 0

# Pre-decoded absolute elevation (meters) for every texel, row-major
# (index = y * _width + x). Decoding the whole image once at load time turns
# each sample into plain array indexing instead of 4x Image.get_pixel() calls
# (which allocate a Color and re-decode the pixel format every time).
var _elev: PackedFloat32Array = PackedFloat32Array()

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

# Precomputed sampling constants (filled in load_from_files) so the per-sample
# hot path uses multiplications instead of divisions.
var _inv_m_per_deg_lat: float = 0.0   # 1 / _m_per_deg_lat
var _inv_m_per_deg_lon: float = 0.0   # 1 / _m_per_deg_lon
var _u_scale: float = 0.0             # (_width  - 1) / (_max_lon - _min_lon)
var _v_scale: float = 0.0             # (_height - 1) / (_max_lat - _min_lat)
var _max_x: int = 0                   # _width  - 1
var _max_y: int = 0                   # _height - 1

var _source: String = ""


## True when a heightmap is loaded and elevation queries are non-trivial.
func is_ready() -> bool:
	return _ready


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

	var img := _load_heightmap_image(heightmap_path)
	if img == null:
		push_error("HeightProvider: failed to load heightmap %s" % heightmap_path)
		return false

	# Sampling reads luminance; force a predictable single-channel layout.
	if img.get_format() != Image.FORMAT_L8 and img.get_format() != Image.FORMAT_RF \
			and img.get_format() != Image.FORMAT_RH:
		img.convert(Image.FORMAT_RF)

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

	# Precompute per-sample constants so the hot path multiplies instead of
	# dividing. (_m_per_deg_* are already > 0 for any real latitude.)
	_inv_m_per_deg_lat = 1.0 / _m_per_deg_lat
	_inv_m_per_deg_lon = 1.0 / _m_per_deg_lon
	_max_x = _width - 1
	_max_y = _height - 1
	_u_scale = float(_max_x) / (_max_lon - _min_lon)
	_v_scale = float(_max_y) / (_max_lat - _min_lat)

	# Decode the whole heightmap to absolute meters once. After this the raw
	# Image is no longer needed; it goes out of scope and frees its buffer.
	_decode_elevations(img)

	_ready = true
	print("HeightProvider: loaded %s heightmap %dx%d, elev %.1f..%.1f m" % [
		_source, _width, _height, _min_elev, _max_elev
	])
	return true


## Decode every texel of the heightmap into absolute elevation (meters), stored
## row-major in _elev. Runs once at load; afterwards sampling is array indexing.
func _decode_elevations(img: Image) -> void:
	var count := _width * _height
	_elev.resize(count)
	var range_elev := _max_elev - _min_elev
	var min_elev := _min_elev
	# get_pixel().r is normalized [0,1] for L8, RF and RH alike, so this single
	# loop handles 8- and 16-bit maps identically.
	var i := 0
	for y: int in range(_height):
		for x: int in range(_width):
			_elev[i] = min_elev + img.get_pixel(x, y).r * range_elev
			i += 1


## Elevation (meters) for a local-meter XZ coordinate (X=east, Z=south).
func sample_local_xz(x: float, z: float) -> float:
	if not _ready:
		return 0.0
	# Local meters -> lat/lon (inverse of OSMParser._latlon_to_local).
	# Multiply by cached reciprocals instead of dividing per sample.
	var lon := _ref_lon + x * _inv_m_per_deg_lon
	var lat := _ref_lat - z * _inv_m_per_deg_lat
	return sample_latlon(lat, lon)


## Elevation (meters) at a geographic coordinate, with bilinear interpolation.
## Coordinates outside the heightmap are clamped to the nearest edge.
func sample_latlon(lat: float, lon: float) -> float:
	if not _ready:
		return 0.0

	# Fractional pixel coordinates straight from degrees, using precomputed
	# scales. Image row 0 is the north (max_lat) edge, the standard top-down
	# raster orientation produced by the baker.
	var fx := (lon - _min_lon) * _u_scale
	var fy := (_max_lat - lat) * _v_scale
	fx = clampf(fx, 0.0, float(_max_x))
	fy = clampf(fy, 0.0, float(_max_y))

	var x0 := int(fx)
	var y0 := int(fy)
	var x1 := mini(x0 + 1, _max_x)
	var y1 := mini(y0 + 1, _max_y)
	var tx := fx - float(x0)
	var ty := fy - float(y0)

	# Direct array indexing into the pre-decoded elevation buffer.
	var row0 := y0 * _width
	var row1 := y1 * _width
	var h00 := _elev[row0 + x0]
	var h10 := _elev[row0 + x1]
	var h01 := _elev[row1 + x0]
	var h11 := _elev[row1 + x1]

	var top := lerpf(h00, h10, tx)
	var bottom := lerpf(h01, h11, tx)
	return lerpf(top, bottom, ty)


## Load the heightmap as an Image.
## For res:// paths we go through the imported Texture2D resource so the load
## also works in exported builds (Image.load_from_file does not). For external
## (e.g. user://) paths we fall back to decoding the file directly.
func _load_heightmap_image(path: String) -> Image:
	if path.begins_with("res://") and ResourceLoader.exists(path):
		var tex := ResourceLoader.load(path) as Texture2D
		if tex != null:
			var tex_img := tex.get_image()
			if tex_img != null:
				return tex_img
	return Image.load_from_file(path)


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
