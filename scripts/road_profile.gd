class_name RoadProfile
extends RefCounted

## The single source of truth for a road way's physical cross-section: how wide
## the carriageway is, what colour asphalt it is, whether it carries kerbs, and
## how high above the ground it sits.
##
## These rules used to live inside OSMWayBuilder as private methods and constant
## dictionaries. That was fine while the builder was the only consumer, but the
## junction system needs the *same* answers: RoadJunctionSolver has to know each
## arm's width to place the intersection corners, and if the solver and the
## ribbon builder ever disagreed by even a few centimetres the cap would not
## line up with the ribbon mouths and a visible crack would open at every
## junction in the world. Extracting the rules here makes that class of bug
## structurally impossible — both sides call the same function.
##
## Everything here is static and pure (tags in, numbers out), so it is directly
## unit-testable and safe to call from a worker thread.

## Carriageway width in metres by highway type. These are nominal TWO-lane
## widths; _width scales them by the actual lane count (see below).
const ROAD_WIDTHS := {
	"motorway": 12.0,
	"motorway_link": 6.0,
	"trunk": 10.0,
	"trunk_link": 5.0,
	"primary": 8.0,
	"primary_link": 4.5,
	"secondary": 7.0,
	"secondary_link": 4.0,
	"tertiary": 6.0,
	"tertiary_link": 3.5,
	"residential": 5.0,
	"living_street": 4.0,
	"service": 3.0,
	"unclassified": 5.0,
	"pedestrian": 3.0,
	"footway": 1.5,
	"cycleway": 2.0,
	"path": 1.0,
	"track": 3.0,
	"busway": 6.0,
}

## Asphalt tones. Real asphalt is a dark, slightly warm neutral grey (~0.12–0.22),
## not pale concrete-grey. Larger/faster roads read a touch darker and cooler
## (fresh tarmac); smaller residential/service roads are a hair lighter and
## warmer (aged, sun-bleached). Unpaved footway/path/track lean brown
## (dirt/gravel) and cycleways keep a faint blue tint.
const ROAD_COLORS := {
	"motorway": Color(0.15, 0.15, 0.17),
	"motorway_link": Color(0.15, 0.15, 0.17),
	"trunk": Color(0.16, 0.16, 0.17),
	"trunk_link": Color(0.16, 0.16, 0.17),
	"primary": Color(0.17, 0.17, 0.18),
	"primary_link": Color(0.17, 0.17, 0.18),
	"secondary": Color(0.18, 0.18, 0.19),
	"secondary_link": Color(0.18, 0.18, 0.19),
	"tertiary": Color(0.19, 0.19, 0.19),
	"tertiary_link": Color(0.19, 0.19, 0.19),
	"residential": Color(0.2, 0.2, 0.2),
	"living_street": Color(0.21, 0.205, 0.2),
	"service": Color(0.2, 0.195, 0.19),
	"busway": Color(0.18, 0.18, 0.19),
	"footway": Color(0.32, 0.27, 0.21),
	"cycleway": Color(0.2, 0.22, 0.26),
	"path": Color(0.3, 0.25, 0.19),
	"pedestrian": Color(0.24, 0.23, 0.22),
}

const DEFAULT_WIDTH := 4.0
const DEFAULT_COLOR := Color(0.19, 0.19, 0.2)

## Height of the road surface above the terrain, in metres. Small enough to read
## as flush, large enough that the draped ribbon never sinks into the DEM.
const ROAD_Y := 0.02

## Kerb geometry. SIDEWALK_WIDTH is the walkable depth; SIDEWALK_HEIGHT is the
## kerb face the carriageway is recessed below.
const SIDEWALK_WIDTH := 1.8
const SIDEWALK_HEIGHT := 0.12
const SIDEWALK_COLOR := Color(0.68, 0.68, 0.66)

## Vertical separation between consecutive OSM `layer` levels, in metres. A
## bridge (layer=1) rides this far above the road it crosses so the two no longer
## fight for the same depth. Chosen to clear a car without looking like a ramp.
const LAYER_HEIGHT := 5.0

## Highway classes that are not carriageways: no lane-based width scaling, no
## kerbs, and rendered as matte rather than asphalt.
const SOFT_TYPES := {
	"footway": true,
	"path": true,
	"cycleway": true,
	"track": true,
	"pedestrian": true,
	"steps": true,
	"bridleway": true,
	"corridor": true,
}

## Highway classes AI traffic and the junction system treat as real streets.
## Junctions are only built between these: a footpath crossing a road is a
## crossing, not an intersection, and must not carve a cap out of the asphalt.
const DRIVABLE_TYPES := {
	"motorway": true,
	"motorway_link": true,
	"trunk": true,
	"trunk_link": true,
	"primary": true,
	"primary_link": true,
	"secondary": true,
	"secondary_link": true,
	"tertiary": true,
	"tertiary_link": true,
	"residential": true,
	"living_street": true,
	"unclassified": true,
	"service": true,
	"busway": true,
}


## True when this way is a road of any kind (including soft paths).
static func is_road(way: OSMParser.OSMWay) -> bool:
	if not way.tags.has("highway"):
		return false
	# highway=platform is a transit platform area, not a road ribbon.
	return String(way.tags.get("highway", "")) != "platform"


## True when this way is a real street that forms intersections. Soft paths and
## non-drivable classes are excluded so a footway crossing a street does not
## trigger a junction cap.
static func is_drivable(way: OSMParser.OSMWay) -> bool:
	if not is_road(way):
		return false
	return DRIVABLE_TYPES.has(String(way.tags.get("highway", "")))


## True when the surface should render as asphalt rather than matte dirt.
static func is_paved(highway_type: String) -> bool:
	return not SOFT_TYPES.has(highway_type)


## Highway class of a way, defaulting to "unclassified".
static func highway_type(way: OSMParser.OSMWay) -> String:
	return String(way.tags.get("highway", "unclassified"))


## Surface colour for a highway class.
static func color_for(highway_type: String) -> Color:
	return ROAD_COLORS.get(highway_type, DEFAULT_COLOR)


## Carriageway width in metres (excluding kerbs) for a road way. Precedence:
##
##   1. An explicit `width` tag always wins — it is the real measured width.
##   2. Otherwise width scales with the lane count: lanes × per-lane width,
##      where per-lane is the type default treated as a nominal TWO-lane
##      carriageway (default / 2), floored at LANE_WIDTH so lanes never get
##      unrealistically thin. This is what makes a `oneway=yes` tertiary with no
##      `lanes` tag render at roughly half the width of the two-lane tertiary it
##      branches from, instead of inheriting the full two-lane default.
##   3. Soft ways (footway, path, cycleway, track, pedestrian) are not
##      carriageways and keep their literal type default regardless of any
##      (defaulted) lane count.
static func width_for(way: OSMParser.OSMWay) -> float:
	var ht := highway_type(way)
	var tags := way.tags

	if tags.has("width"):
		var explicit: float = String(tags["width"]).to_float()
		if explicit > 0.0:
			return explicit

	var default_width: float = ROAD_WIDTHS.get(ht, DEFAULT_WIDTH)
	if SOFT_TYPES.has(ht):
		return default_width

	var lane_spec := RoadLaneSpec.from_tags(ht, tags)
	if lane_spec == null or not lane_spec.marked:
		return default_width

	var per_lane: float = maxf(default_width * 0.5, RoadLaneSpec.LANE_WIDTH)
	return lane_spec.lane_count * per_lane


## Vertical offset in metres implied by a way's OSM `layer` tag.
##
## Roads with real intersections no longer need the painter's-algorithm trick of
## never writing depth, so overlapping geometry has to be separated in SPACE
## instead. A bridge (layer=1) rides LAYER_HEIGHT above the road it crosses; a
## tunnel (layer=-1) drops below it. Untagged roads stay at 0.
##
## `bridge`/`tunnel` tags without an explicit layer still imply a level, which is
## common in OSM (a bridge=yes with no layer=* is understood as layer=1).
static func layer_offset(way: OSMParser.OSMWay) -> float:
	return float(layer_of(way)) * LAYER_HEIGHT


## The integer OSM layer level of a way (0 for ground level).
static func layer_of(way: OSMParser.OSMWay) -> int:
	var tags := way.tags
	if tags.has("layer"):
		var raw := String(tags["layer"])
		if raw.is_valid_int():
			return clampi(raw.to_int(), -5, 5)

	# No explicit layer: infer one from bridge/tunnel, which OSM treats as
	# implying a level even when `layer` was left off.
	var bridge := String(tags.get("bridge", ""))
	if bridge != "" and bridge != "no":
		return 1
	var tunnel := String(tags.get("tunnel", ""))
	if tunnel != "" and tunnel != "no":
		return -1
	return 0


## True when a way is carried on a bridge (so it needs a visible deck/underside
## rather than being draped onto the terrain).
static func is_bridge(way: OSMParser.OSMWay) -> bool:
	var bridge := String(way.tags.get("bridge", ""))
	return bridge != "" and bridge != "no"


## True when a way runs through a tunnel and so should not be drawn on the
## surface at all.
static func is_tunnel(way: OSMParser.OSMWay) -> bool:
	var tunnel := String(way.tags.get("tunnel", ""))
	if tunnel != "" and tunnel != "no":
		return true
	return layer_of(way) < 0


## Which sides of a road carry a kerb/sidewalk, as { "left": bool, "right": bool }.
##
## OSM's sidewalk scheme is read strictly here:
##   sidewalk=both/left/right/no      – the classic form
##   sidewalk:left/right=yes|no       – per-side form
##   sidewalk:both=yes|no             – both sides at once
##
## `separate` means the footway is mapped as its OWN way elsewhere in the data,
## so we must NOT draw an inline kerb for it — that would double up with the
## standalone footway geometry. The previous implementation had this exactly
## inverted (it drew kerbs *only* for `separate`), which is why sidewalks
## appeared in the wrong places.
static func sidewalk_sides(tags: Dictionary) -> Dictionary:
	var left := false
	var right := false

	if tags.has("sidewalk"):
		match String(tags["sidewalk"]):
			"both":
				left = true
				right = true
			"left":
				left = true
			"right":
				right = true
			_:
				# "no", "none", "separate" → no inline kerb.
				left = false
				right = false

	if tags.has("sidewalk:both"):
		var both := _is_present(String(tags["sidewalk:both"]))
		left = both
		right = both

	if tags.has("sidewalk:left"):
		left = _is_present(String(tags["sidewalk:left"]))
	if tags.has("sidewalk:right"):
		right = _is_present(String(tags["sidewalk:right"]))

	return {"left": left, "right": right}


## Whether a per-side sidewalk value means "draw a kerb here". `separate` and
## `no` both mean no inline geometry (see sidewalk_sides).
static func _is_present(value: String) -> bool:
	return value != "no" and value != "none" and value != "separate" and value != ""
