class_name RoofBuilder
extends RefCounted

## Roof-shape dispatcher. Maps a canonical roof:shape value to the matching
## family builder and returns the resulting mesh nodes ("Roof", and optionally
## "Gables" / "SkillionWalls" / "SawtoothWalls").
##
## This is the single entry point for roof geometry; OSMBuildingBuilder delegates
## here so the wall/footprint logic stays small. The per-family implementations
## live alongside this file in scripts/roof/:
##   - RoofLinearProfile: gabled, gambrel, round, saltbox
##   - RoofConicProfile:  pyramidal, dome, onion
##   - RoofHipped:        hipped, half-hipped, mansard
##   - RoofSpecial:       flat, skillion, sawtooth
##   - RoofGeometry:      shared mesh/ridge/profile helpers
##
## Supported shapes: flat, gabled, hipped, pyramidal, skillion, half-hipped,
## gambrel, mansard, round, dome, onion, saltbox, sawtooth. Unknown shapes fall
## back to flat.

## Build the roof for `shape`, seated on top of walls of height `wall_h`.
## All geometry is in building-local space (footprint at y=0); the caller raises
## the finished node onto the terrain.
static func build_roof_shape(points: PackedVector3Array, wall_h: float, roof_h: float,
		roof_color: Color, wall_color: Color, shape: String, orientation: String,
		roof_direction: float = -1.0) -> Array[Node3D]:
	var base_y := RoofGeometry.BUILDING_Y + wall_h
	match shape:
		"gabled":
			return RoofLinearProfile.gabled(points, base_y, roof_h, roof_color, wall_color, orientation, roof_direction)
		"hipped":
			return RoofHipped.hipped(points, base_y, roof_h, roof_color, orientation, roof_direction)
		"pyramidal":
			return RoofConicProfile.pyramidal(points, base_y, roof_h, roof_color)
		"skillion":
			return RoofSpecial.skillion(points, base_y, roof_h, roof_color, wall_color, orientation, roof_direction)
		"half-hipped":
			return RoofHipped.half_hipped(points, base_y, roof_h, roof_color, wall_color, orientation, roof_direction)
		"gambrel":
			return RoofLinearProfile.gambrel(points, base_y, roof_h, roof_color, wall_color, orientation, roof_direction)
		"mansard":
			return RoofHipped.mansard(points, base_y, roof_h, roof_color, orientation)
		"round":
			return RoofLinearProfile.round_roof(points, base_y, roof_h, roof_color, orientation, roof_direction)
		"dome":
			return RoofConicProfile.dome(points, base_y, roof_h, roof_color)
		"onion":
			return RoofConicProfile.onion(points, base_y, roof_h, roof_color)
		"saltbox":
			return RoofLinearProfile.saltbox(points, base_y, roof_h, roof_color, wall_color, orientation, roof_direction)
		"sawtooth":
			return RoofSpecial.sawtooth(points, base_y, roof_h, roof_color, wall_color, orientation, roof_direction)
		_:
			return RoofSpecial.flat(points, base_y, roof_color)
