class_name ParkingHandler
extends OSMWayHandler

## amenity=parking ways → flat colored polygon, draped onto terrain when a DEM
## is present (PolygonUtils).
##
## Parking is matched before the generic AreaHandler so its dedicated naming and
## slightly raised y-offset (0.015 vs 0.01) are preserved.

func handler_name() -> String:
	return "parking"


static func is_parking(way: OSMParser.OSMWay) -> bool:
	return way.tags.get("amenity", "") == "parking"


func matches(way: OSMParser.OSMWay, _ctx: OSMTileContext) -> bool:
	return is_parking(way)


func build(way: OSMParser.OSMWay, ctx: OSMTileContext) -> Node3D:
	var points := PolygonUtils.way_to_points(way.node_ids, ctx.osm_data.nodes)
	var color := PolygonUtils.get_area_color(way.tags)
	# Parking ranks high in the ground layer stack (paints over landcover) and
	# still gets the smaller-patch tiebreak — see PolygonUtils.ground_render_priority.
	var priority := roundi(PolygonUtils.ground_render_priority(
		way.tags, PolygonUtils.polygon_area_xz(points)))
	var mesh_instance: MeshInstance3D
	if ctx.has_terrain:
		mesh_instance = PolygonUtils.build_terrain_draped_mesh(
			points, color, ctx.osm_data.height_provider, ctx.grid_step, 0.015, ctx.tile_clip, priority)
	else:
		mesh_instance = PolygonUtils.build_flat_polygon_mesh(points, color, 0.015, true, priority)
	if mesh_instance != null:
		mesh_instance.name = "Parking_%d" % way.id
	return mesh_instance
