class_name RoadMaterialFactory
extends RefCounted

## Builds the surface material for road ribbons. Paved highway types get the
## procedural asphalt ShaderMaterial (grainy albedo, varied roughness, faked
## normal bump driven by world-space noise — see scripts/shaders/asphalt.gdshader);
## unpaved/soft surfaces (footway, path, cycleway, track) keep a plain matte
## StandardMaterial3D since asphalt grain would look wrong on dirt/gravel.
##
## The asphalt Shader resource is preloaded once and shared across every road;
## each road gets its own lightweight ShaderMaterial that only overrides the
## `base_color` uniform with the per-highway-type tint. This keeps draw-call
## state small while letting all roads share one compiled shader.

const ASPHALT_SHADER: Shader = preload("res://scripts/shaders/asphalt.gdshader")

## Highway types rendered as plain matte surfaces rather than asphalt.
const UNPAVED_TYPES := {
	"footway": true,
	"path": true,
	"cycleway": true,
	"track": true,
	"pedestrian": true,
}

## Returns the material for a road of the given highway type, tinted `color`.
## Paved roads receive a procedural-asphalt ShaderMaterial; unpaved/soft
## surfaces fall back to a matte StandardMaterial3D.
static func create_road_material(highway_type: String, color: Color) -> Material:
	if UNPAVED_TYPES.has(highway_type):
		var plain := StandardMaterial3D.new()
		plain.albedo_color = color
		plain.roughness = 1.0
		return plain

	var mat := ShaderMaterial.new()
	mat.shader = ASPHALT_SHADER
	mat.set_shader_parameter("base_color", color)
	return mat
