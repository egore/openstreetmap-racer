class_name BuildingStyleResolver
extends RefCounted

const BRICK_PALETTES := [
	[Color("805044"), Color("936451"), Color("735048"), Color("a47759")],
	[Color("765347"), Color("8b6050"), Color("9b745b"), Color("685249")],
]
const RENDER_PALETTE := [Color("d7cfbb"), Color("c8c2b2"), Color("e1d8c6"), Color("bcb8aa")]
const ROOF_PALETTE := [Color("4b4c50"), Color("66534c"), Color("955c45"), Color("55545a")]


static func resolve(tags: Dictionary, points: PackedVector3Array, id: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash("building:%d" % id)
	var center := PolygonUtils.polygon_centroid(points)
	var district := absi(hash("%d:%d" % [floori(center.x / 400.0), floori(center.z / 400.0)]))
	var kind: String = tags.get("building", tags.get("building:part", "yes"))
	var area := PolygonUtils.polygon_area_xz(points)
	var warehouse := kind in ["industrial", "warehouse", "hangar", "barn"]
	var garage := kind in ["garage", "garages", "shed"]
	var shop := kind == "retail" or tags.has("shop")
	var apartments := kind in ["apartments", "commercial", "office", "school", "hospital"] or float(tags.get("building:levels", "0")) >= 4.0
	var residential := kind in ["house", "detached", "semidetached_house", "terrace", "residential", "bungalow"]
	var modest_unknown := kind == "yes" and area >= 35.0 and area <= 240.0
	var rendered := rng.randf() < 0.25
	var style_name := "rendered_house" if rendered else "brick_house"
	var material := "plaster" if rendered else "brick"
	var palette: Array = RENDER_PALETTE if rendered else BRICK_PALETTES[district % BRICK_PALETTES.size()]
	var wall_color: Color = palette[rng.randi_range(0, palette.size() - 1)]
	var floors := 2
	var bay_width := rng.randf_range(2.5, 3.1)
	var window_width := rng.randf_range(1.1, 1.45)
	var window_height := 1.65
	if apartments:
		style_name = "apartments"
		floors = 4
		window_width = 1.7
		window_height = 1.5
	elif shop:
		style_name = "shop"
	elif warehouse or garage:
		style_name = "warehouse" if warehouse else "garage"
		material = "metal" if warehouse else "brick"
		wall_color = Color("88918e") if warehouse else Color("847566")
		floors = 2 if warehouse else 1
		bay_width = 6.0
		window_width = 2.4
		window_height = 0.85
	elif kind == "bungalow":
		floors = 1

	var resolved := tags.duplicate()
	if not tags.has("building:material"):
		resolved["building:material"] = material
		if not _has_color(tags, "building"):
			resolved["building:colour"] = "#" + wall_color.to_html(false)

	var shape: String = tags.get("roof:shape", "flat")
	shape = shape.strip_edges().to_lower()
	var roof_height := 0.0
	if not tags.has("roof:shape") and not tags.has("building:part") and (residential or modest_unknown) and not apartments and not shop:
		var dimensions := rectangular_dimensions(points)
		var explicit_height := str(tags.get("height", "8")).to_float()
		if dimensions.x >= 4.0 and dimensions.y >= 4.0 and area <= 350.0 and explicit_height >= 5.0:
			shape = "hipped" if kind == "detached" and rng.randf() < 0.4 else "gabled"
			roof_height = minf(clampf(minf(dimensions.x, dimensions.y) * 0.32, 1.4, 3.4), explicit_height - 2.4)
			if not tags.has("roof:height") and not tags.has("roof:angle") and not tags.has("roof:levels"):
				resolved["roof:height"] = str(roof_height)
	resolved["roof:shape"] = shape
	if not tags.has("roof:material"):
		resolved["roof:material"] = "tar_paper" if shape == "flat" else "roof_tiles"
		if not _has_color(tags, "roof"):
			var roof_color: Color = Color("555655") if shape == "flat" else ROOF_PALETTE[rng.randi_range(0, ROOF_PALETTE.size() - 1)]
			resolved["roof:colour"] = "#" + roof_color.to_html(false)
	if not tags.has("height") and not tags.has("building:levels"):
		resolved["building:levels"] = str(floors)
	var openings := not kind in ["roof", "greenhouse", "storage_tank", "silo", "church", "cathedral", "ruins", "construction"]
	openings = openings and tags.get("building:part", "") != "roof" and tags.get("windows", "yes") != "no"
	return {
		"name": style_name, "tags": resolved, "seed": rng.randi_range(0, 65535),
		"frame_color": Color("ddd8c7") if not warehouse else Color("434b4d"),
		"door_color": [Color("344c43"), Color("434b59"), Color("653e34")][rng.randi_range(0, 2)],
		"bay_width": bay_width, "window_width": window_width, "window_height": window_height,
		"openings": openings, "shop": shop, "warehouse": warehouse, "garage": garage,
	}


static func rectangular_dimensions(points: PackedVector3Array) -> Vector2:
	if points.size() < 4 or points.size() > 12:
		return Vector2.ZERO
	var ridge := PolygonUtils.polygon_longest_edge_dir(points)
	var across := Vector3(-ridge.z, 0.0, ridge.x)
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for p: Vector3 in points:
		var q := Vector2(p.dot(ridge), p.dot(across))
		lo = lo.min(q)
		hi = hi.max(q)
	var size := hi - lo
	if size.x * size.y < 1.0 or PolygonUtils.polygon_area_xz(points) / (size.x * size.y) < 0.97:
		return Vector2.ZERO
	return size


static func _has_color(tags: Dictionary, prefix: String) -> bool:
	return tags.has(prefix + ":colour") or tags.has(prefix + ":color") or (prefix == "building" and (tags.has("colour") or tags.has("color")))
