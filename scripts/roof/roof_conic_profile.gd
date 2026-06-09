class_name RoofConicProfile
extends RefCounted

## Conic-profile roof family: pyramidal, dome, onion.
##
## Inspired by UrbanEye3D's MesherConicProfile: concentric rings of vertices are
## created by scaling each polygon vertex toward the centroid. The profile
## defines how much to scale (x = scale factor, 1.0 at base → 0.0 at apex) and
## the height (y = height fraction, 0.0 at base → 1.0 at apex) at each ring.
## This works on any polygon shape, not just circles or rectangles.
##
## Extracted from the former monolithic OSMBuildingBuilder. All methods static.

# ─── Pyramidal ───────────────────────────────────────────────────────────────
# Straight linear taper from base (scale=1, h=0) to apex (scale=0, h=1).

static func pyramidal(points: PackedVector3Array, base_y: float, roof_h: float,
		roof_color: Color) -> Array[Node3D]:
	var centroid := PolygonUtils.polygon_centroid(points)
	var profile: Array[Vector2] = [Vector2(1.0, 0.0), Vector2(0.0, 1.0)]
	return build(points, base_y, roof_h, roof_color, centroid, profile)

# ─── Dome ────────────────────────────────────────────────────────────────────
# Quarter-circle profile (per-vertex centroid scaling, 8 rings).

static func dome(points: PackedVector3Array, base_y: float, roof_h: float,
		roof_color: Color) -> Array[Node3D]:
	var centroid := PolygonUtils.polygon_centroid(points)
	var dome_profile: Array[Vector2] = _make_dome_profile(8)
	return build(points, base_y, roof_h, roof_color, centroid, dome_profile)

## Dome profile: quarter-circle from base (scale=1, h=0) to apex (scale=0, h=1).
static func _make_dome_profile(rings: int) -> Array[Vector2]:
	var profile: Array[Vector2] = []
	for j: int in range(rings + 1):
		var t := float(j) / rings
		var angle := t * PI * 0.5
		# x = scale factor (how much of the base polygon shape to keep)
		# y = height fraction
		profile.append(Vector2(cos(angle), sin(angle)))
	return profile

# ─── Onion ───────────────────────────────────────────────────────────────────
# Bulges wider than the base, then tapers to a point. Control points adapted
# from UrbanEye3D's MesherConicProfile onionProfile().

static func onion(points: PackedVector3Array, base_y: float, roof_h: float,
		roof_color: Color) -> Array[Node3D]:
	var centroid := PolygonUtils.polygon_centroid(points)
	var onion_profile := _make_onion_profile()
	return build(points, base_y, roof_h, roof_color, centroid, onion_profile)

## Onion profile: bulges outward (wider than base), then tapers to a point.
## Vector2(x=scale_factor, y=height_fraction).
static func _make_onion_profile() -> Array[Vector2]:
	return [
		Vector2(1.0000, 0.0000),  # base
		Vector2(1.2971, 0.0999),  # bulge outward
		Vector2(1.2971, 0.2462),  # max bulge
		Vector2(1.1273, 0.3608),  # narrowing
		Vector2(0.6219, 0.4785),  # rapid taper
		Vector2(0.2131, 0.5984),  # near tip
		Vector2(0.1003, 0.7243),  # close to tip
		Vector2(0.0000, 1.0000),  # apex
	]

# ─── Shared conic-profile builder ────────────────────────────────────────────

## Build a roof of revolution by stacking rings of the footprint scaled toward
## `center`. Each profile entry is Vector2(scale_factor, height_fraction).
static func build(points: PackedVector3Array, base_y: float, roof_h: float,
		roof_color: Color, center: Vector3, profile: Array[Vector2]) -> Array[Node3D]:
	var st := RoofGeometry.new_st(roof_color)
	var n := points.size() - 1  # exclude closing vertex
	if n < 3:
		return []
	var rows := profile.size() - 1

	# Build vertex rings: ring 0 = base polygon, ring j = scaled toward center
	# profile[j].x = scale factor (1.0 at base, 0.0 at apex)
	# profile[j].y = relative height (0.0 at base, 1.0 at apex)
	var rings: Array[PackedVector3Array] = []
	for j: int in range(rows + 1):
		var ring: PackedVector3Array = []
		var scale_factor: float = profile[j].x
		var ring_y := base_y + roof_h * profile[j].y
		for i: int in range(n):
			var px := center.x + (points[i].x - center.x) * scale_factor
			var pz := center.z + (points[i].z - center.z) * scale_factor
			ring.append(Vector3(px, ring_y, pz))
		rings.append(ring)

	# Create quad strips between adjacent rings
	for j: int in range(rows - 1):
		var lower := rings[j]
		var upper := rings[j + 1]
		for i: int in range(n):
			var ni := (i + 1) % n
			RoofGeometry.add_quad(st, lower[i], lower[ni], upper[ni], upper[i])

	# Top ring to apex: triangles
	var top_ring := rings[rows - 1]
	var apex := Vector3(center.x, base_y + roof_h * profile[rows].y, center.z)
	for i: int in range(n):
		var ni := (i + 1) % n
		RoofGeometry.add_tri(st, top_ring[i], top_ring[ni], apex)

	var result: Array[Node3D] = []
	result.append(RoofGeometry.make_mesh(st, "Roof"))
	return result
