class_name RoadLaneSpec
extends RefCounted

## Parsed OSM lane layout for a single road way, distilled to just what the
## marking shader needs to paint a plausible carriageway: how many lanes there
## are, how they split between the two travel directions, and whether the road
## is one-way. See https://wiki.openstreetmap.org/wiki/Lanes
##
## The OSM lanes scheme is rich (turn:lanes, access:lanes, per-lane widths…),
## but for ground markings we only need the *counts*. The precedence we follow
## mirrors the wiki and the existing width logic in OSMWayBuilder:
##
##   • lanes            – total number of through motor-vehicle lanes.
##   • lanes:forward    – lanes in the way's digitised direction.
##   • lanes:backward   – lanes against the way's digitised direction.
##   • oneway=yes/-1/…  – all lanes flow one way (no centre line).
##
## When lanes:forward/backward are given they win; otherwise we derive a
## sensible split from `lanes` and `oneway`. Unpaved/soft ways (footway, path,
## cycleway, track, pedestrian) carry no markings at all.

## Total number of marked lanes across the carriageway (>= 1).
var lane_count: int = 2
## Lanes travelling in the way's forward (digitised) direction.
var forward_lanes: int = 1
## Lanes travelling against the way's direction.
var backward_lanes: int = 1
## True when the road is one-way (junction=roundabout counts). One-way roads get
## no centre line — every divider between lanes is a same-direction dashed line.
var one_way: bool = false
## True when this road type should carry painted markings at all. Dirt paths,
## cycleways and footways do not.
var marked: bool = true

## Highway classes we never paint lane markings on (unpaved / non-motor).
const UNMARKED_TYPES := {
	"footway": true,
	"path": true,
	"cycleway": true,
	"track": true,
	"pedestrian": true,
	"steps": true,
	"bridleway": true,
	"corridor": true,
}

## Very small roads that in reality carry no centre line or lane markings even
## though they're paved (single-track service roads, driveways, alleys). We
## still draw edge lines but suppress the centre/divider lines by treating them
## as a single undivided lane.
const UNDIVIDED_TYPES := {
	"service": true,
	"living_street": true,
}

## Reference single-lane width (meters), matching OSMWayBuilder / traffic net.
const LANE_WIDTH := 3.5


## Build a lane spec from a highway type and the way's OSM tags. Pure and
## side-effect free so it can be unit-tested without any scene.
static func from_tags(highway_type: String, tags: Dictionary) -> RoadLaneSpec:
	var spec := RoadLaneSpec.new()

	spec.marked = not UNMARKED_TYPES.has(highway_type)
	spec.one_way = _parse_one_way(tags)

	# Directional lane counts take precedence when explicitly tagged.
	var fwd := _tag_int(tags, "lanes:forward", -1)
	var bwd := _tag_int(tags, "lanes:backward", -1)
	var total := _tag_int(tags, "lanes", -1)

	if fwd >= 0 or bwd >= 0:
		# At least one direction is explicit. Fill the missing side from the
		# total (if known) or default it to 0/what's left.
		spec.forward_lanes = maxi(fwd, 0)
		spec.backward_lanes = maxi(bwd, 0)
		if fwd < 0 and total > 0:
			spec.forward_lanes = maxi(total - spec.backward_lanes, 0)
		if bwd < 0 and total > 0:
			spec.backward_lanes = maxi(total - spec.forward_lanes, 0)
		spec.lane_count = maxi(spec.forward_lanes + spec.backward_lanes, 1)
	elif total > 0:
		spec.lane_count = total
		_split_by_direction(spec)
	else:
		# No lane tags at all: assume the sensible default for the road type.
		# One-way → a single lane; two-way → two lanes (one each direction).
		spec.lane_count = 1 if spec.one_way else 2
		_split_by_direction(spec)

	# Undivided small paved roads: keep the (usually 1–2) lanes for width but
	# mark them as a single undivided lane so no centre/divider lines are drawn.
	if UNDIVIDED_TYPES.has(highway_type) and spec.lane_count <= 2:
		spec.forward_lanes = spec.lane_count
		spec.backward_lanes = 0
		spec.one_way = spec.one_way  # unchanged; centre line already suppressed

	return spec


## Split spec.lane_count into forward/backward given the one-way flag. For a
## two-way road with an odd lane count the extra lane goes to the forward side
## (the common asymmetric case, e.g. an uphill climbing lane).
static func _split_by_direction(spec: RoadLaneSpec) -> void:
	if spec.one_way:
		spec.forward_lanes = spec.lane_count
		spec.backward_lanes = 0
		return
	spec.forward_lanes = int(ceil(spec.lane_count / 2.0))
	spec.backward_lanes = spec.lane_count - spec.forward_lanes


## Whether a road divides its lanes across two travel directions (i.e. it should
## get a solid centre line). One-way roads and single undivided lanes do not.
func has_center_line() -> bool:
	return not one_way and forward_lanes > 0 and backward_lanes > 0


static func _parse_one_way(tags: Dictionary) -> bool:
	var junction := String(tags.get("junction", ""))
	if junction == "roundabout" or junction == "circular":
		return true
	var v := String(tags.get("oneway", "no"))
	return v == "yes" or v == "true" or v == "1" or v == "-1"


static func _tag_int(tags: Dictionary, key: String, fallback: int) -> int:
	if not tags.has(key):
		return fallback
	var s := String(tags[key])
	if not s.is_valid_int():
		return fallback
	return s.to_int()
