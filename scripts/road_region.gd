class_name RoadRegion
extends RefCounted

## Where in the world the loaded map is, and what that implies for how roads are
## marked and driven.
##
## OSM data is global: the same parser happily loads Amsterdam, London or Los
## Angeles. Almost everything about a road is derived from its tags and is
## therefore already location-independent — but two things are not, and both
## were previously hardcoded:
##
##   1. WHICH SIDE traffic drives on. This decides which half of the carriageway
##      an approach's stop line spans. Getting it wrong paints the bar across
##      the ONCOMING lane, which reads as a stop line for the traffic coming the
##      other way.
##   2. WHAT A GIVE-WAY LINE LOOKS LIKE. The dashed transverse line assumed here
##      is the UK/US convention. The Netherlands and Belgium instead use
##      "haaientanden" (shark's teeth): a row of solid triangles whose apexes
##      point back at the driver who must yield. They are not a stylistic
##      variant — a Dutch driver reads the triangle direction as the priority
##      cue, so drawing dashes there loses information.
##
## ── Why latitude/longitude and not a country code ────────────────────────────
## The OSM extracts this game loads carry bounds (OSMParser.OSMData.center_lat /
## center_lon) but no country tag; there is nothing in the data that names the
## country. Reverse-geocoding a coordinate properly needs a border polygon set we
## do not ship and cannot download mid-race.
##
## So this uses coarse bounding boxes: enough to distinguish "Benelux" from
## "British Isles" from "everywhere else", which is all the rendering actually
## depends on. A box is deliberately a crude instrument, and near a border it
## will be wrong — accepted, because the alternative (a full border dataset) buys
## a level of precision no marking decision here needs. `for_style()` exists so a
## caller that DOES know better can just say so.
##
## Everything here is static and pure (coordinates in, enum out), so it is
## directly unit-testable and safe to call from a worker thread.

## Which side of the road traffic drives on.
enum DrivingSide {
	RIGHT = 0,  ## Continental Europe, the Americas, most of the world.
	LEFT = 1,   ## UK, Ireland, Japan, Australia, India, southern Africa.
}

## How a give-way (yield) line is painted.
enum GiveWayStyle {
	## Dashed transverse line. The default nearly everywhere, and the safe
	## fallback for a region we have no specific rule for.
	DASHED = 0,
	## Shark's teeth: solid triangles pointing at the driver who must yield.
	## The Netherlands and Belgium. Standardised in NL as RVV 1990 marking B6.
	SHARK_TEETH = 1,
}

## Coarse bounding boxes, as (min_lon, min_lat, max_lon, max_lat).
##
## These are intentionally generous rectangles around a region, not borders. They
## are tested in the order listed by `for_coordinates`, so a box that overlaps
## another must come first if it should win.

## Netherlands + Belgium: the shark's-teeth region. Luxembourg sits inside this
## box too and uses a triangle give-way marking as well, so its inclusion is
## correct rather than merely tolerated.
const BENELUX_BOUNDS := Rect2(2.5, 49.4, 4.7, 4.2)   # lon 2.5..7.2, lat 49.4..53.6

## Great Britain + Ireland: left-hand traffic, dashed give-way lines.
## Kept clear of the Benelux box (which starts at lon 2.5) so the two cannot
## both match; the North Sea between them is not somewhere a road map loads.
const BRITISH_ISLES_BOUNDS := Rect2(-11.0, 49.8, 13.0, 11.2)  # lon -11..2, lat 49.8..61

## A resolved region: the two facts the renderer actually needs.
var driving_side: int = DrivingSide.RIGHT
var give_way_style: int = GiveWayStyle.DASHED


func _init(
		p_driving_side: int = DrivingSide.RIGHT,
		p_give_way_style: int = GiveWayStyle.DASHED) -> void:
	driving_side = p_driving_side
	give_way_style = p_give_way_style


## True when traffic drives on the left here.
func drives_on_left() -> bool:
	return driving_side == DrivingSide.LEFT


## Sign to multiply a road's RIGHT-hand lateral by to get the side that traffic
## APPROACHING along that lateral's forward direction travels on.
##
## Everything in the road system expresses "sideways" as the right-hand lateral
## (-dir.z, 0, dir.x) — see RoadJunctionSolver.Arm.lateral. Callers that need the
## driving side ask for this factor rather than rebuilding the vector, so there
## is exactly one place the handedness is decided.
func lateral_sign() -> float:
	return -1.0 if drives_on_left() else 1.0


## The region covering a lat/lon, falling back to right-hand traffic with dashed
## give-way lines — the most common combination worldwide, and the behaviour this
## code had before regions existed.
##
## Note Rect2.has_point treats the rectangle as half-open on its far edges, which
## is irrelevant at this scale: a road exactly on a box edge is already in
## fuzzy-border territory where either answer is defensible.
static func for_coordinates(lat: float, lon: float) -> RoadRegion:
	var here := Vector2(lon, lat)
	if BENELUX_BOUNDS.has_point(here):
		return RoadRegion.new(DrivingSide.RIGHT, GiveWayStyle.SHARK_TEETH)
	if BRITISH_ISLES_BOUNDS.has_point(here):
		return RoadRegion.new(DrivingSide.LEFT, GiveWayStyle.DASHED)
	return RoadRegion.new()


## The region for a parsed OSM extract, from the bounds it carries.
##
## A dataset with no bounds at all (synthetic test fixtures, hand-built ways)
## reports 0,0 — the Gulf of Guinea — which lands on the default. That is the
## right outcome: geometry with no stated location should render the way it
## always did rather than pick up a region by accident.
static func for_osm_data(data: OSMParser.OSMData) -> RoadRegion:
	if data == null:
		return RoadRegion.new()
	return for_coordinates(data.center_lat, data.center_lon)


## An explicitly chosen region, bypassing coordinate lookup. For callers that
## know the country outright (a hand-authored map, a test, a user setting).
static func for_style(driving_side: int, give_way_style: int) -> RoadRegion:
	return RoadRegion.new(driving_side, give_way_style)
