class_name OSMRoadBuilder
extends RefCounted

## Builds 3D road meshes from OSM ways tagged with "highway".

# Road width in meters based on highway type
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
}

const ROAD_COLORS := {
	"motorway": Color(0.4, 0.4, 0.45),
	"motorway_link": Color(0.4, 0.4, 0.45),
	"trunk": Color(0.42, 0.42, 0.44),
	"trunk_link": Color(0.42, 0.42, 0.44),
	"primary": Color(0.45, 0.44, 0.42),
	"primary_link": Color(0.45, 0.44, 0.42),
	"secondary": Color(0.5, 0.5, 0.48),
	"secondary_link": Color(0.5, 0.5, 0.48),
	"tertiary": Color(0.52, 0.52, 0.5),
	"tertiary_link": Color(0.52, 0.52, 0.5),
	"residential": Color(0.55, 0.55, 0.53),
	"living_street": Color(0.6, 0.58, 0.55),
	"service": Color(0.58, 0.57, 0.55),
	"footway": Color(0.65, 0.6, 0.5),
	"cycleway": Color(0.5, 0.55, 0.6),
	"path": Color(0.6, 0.55, 0.45),
	"pedestrian": Color(0.62, 0.6, 0.55),
}

const DEFAULT_WIDTH := 4.0
const DEFAULT_COLOR := Color(0.5, 0.5, 0.5)
const ROAD_Y := 0.02  # slightly above ground

func build_road(way: OSMParser.OSMWay, osm_data: OSMParser.OSMData) -> MeshInstance3D:
	var points := PolygonUtils.way_to_points(way.node_ids, osm_data.nodes)

	if points.size() < 2:
		return null

	var highway_type: String = way.tags.get("highway", "unclassified")
	var width: float = ROAD_WIDTHS.get(highway_type, DEFAULT_WIDTH)
	var color: Color = ROAD_COLORS.get(highway_type, DEFAULT_COLOR)

	# Check for lanes tag to override width
	if way.tags.has("lanes"):
		var lanes: int = way.tags["lanes"].to_int()
		if lanes > 0:
			width = lanes * 3.5

	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = "Road_%d" % way.id

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	st.set_material(mat)

	# Build a ribbon mesh along the polyline
	var half_w := width / 2.0

	for i: int in range(points.size() - 1):
		var p0 := points[i]
		var p1 := points[i + 1]
		var forward := (p1 - p0).normalized()
		var right := Vector3(-forward.z, 0.0, forward.x).normalized() * half_w

		var v0 := Vector3(p0.x - right.x, ROAD_Y, p0.z - right.z)
		var v1 := Vector3(p0.x + right.x, ROAD_Y, p0.z + right.z)
		var v2 := Vector3(p1.x + right.x, ROAD_Y, p1.z + right.z)
		var v3 := Vector3(p1.x - right.x, ROAD_Y, p1.z - right.z)

		# Triangle 1
		st.set_normal(Vector3.UP)
		st.add_vertex(v0)
		st.set_normal(Vector3.UP)
		st.add_vertex(v2)
		st.set_normal(Vector3.UP)
		st.add_vertex(v1)

		# Triangle 2
		st.set_normal(Vector3.UP)
		st.add_vertex(v0)
		st.set_normal(Vector3.UP)
		st.add_vertex(v3)
		st.set_normal(Vector3.UP)
		st.add_vertex(v2)

	mesh_instance.mesh = st.commit()
	return mesh_instance
