# Autobahnraser

A Godot 4 driving game that dynamically renders OpenStreetMap data as 3D environments.

## How It Works

### Architecture

1. **OSM Parser** (`scripts/osm_parser.gd`) — Parses `.osm` XML files into structured data (nodes, ways, relations). Converts lat/lon to local meter-based coordinates using equirectangular projection.

2. **Tile Manager** (`scripts/osm_tile_manager.gd`) — Divides the world into a grid of tiles (default 200m × 200m). As the camera moves, nearby tiles are loaded and distant ones are unloaded. The OSM file is parsed once at startup into an in-memory spatial index.

3. **Road Builder** (`scripts/osm_road_builder.gd`) — Generates ribbon meshes for roads from OSM ways tagged with `highway=*`. Width and color vary by road type (motorway, primary, residential, footway, etc.).

4. **Building Builder** (`scripts/osm_building_builder.gd`) — Extrudes 3D buildings from OSM way outlines tagged with `building=*`. Height is determined from `height`, `building:levels` tags, or a default.

5. **Asset Placer** (`scripts/osm_asset_placer.gd`) — Places colored placeholder boxes for point features (nodes with tags): traffic lights (green box), trees (green box), benches (brown box), street lamps (yellow pole), bus stops (blue box), etc. **Edit the `ASSET_DEFS` dictionary to add more asset types.**

6. **Relation Builder** (`scripts/osm_relation_builder.gd`) — Handles OSM relations, primarily `type=multipolygon` for complex buildings and land areas.

7. **Car Controller** (`scripts/car_controller.gd`) — Simple WASD driving controller.

### Dynamic Loading

The tile manager tracks which tile the camera is in. When the camera crosses into a new tile, it:
- Loads all tiles within `load_radius` (default: 2 tiles in each direction)
- Unloads tiles beyond `unload_radius` (default: 3 tiles)
- Each tile gets a ground plane, roads, buildings, assets, and relation geometry

### Coordinate System

- OSM lat/lon is projected to local meters using the dataset center as origin
- X = East, Z = South (negated latitude), Y = Up
- 1 unit = 1 meter

## Setup

### Getting Map Data

1. Go to [openstreetmap.org/export](https://www.openstreetmap.org/export)
2. Select your area of interest (keep it reasonable — a few km² works well)
3. Click "Export" to download a `.osm` file
4. Place the file at `data/map.osm`

Alternatively, use [JOSM](https://josm.openstreetmap.de/) for larger exports, or the Overpass API:
```
https://overpass-api.de/api/map?bbox=8.46,49.48,8.48,49.49
```

### Running

1. Open this project in Godot 4.2+
2. Ensure `data/map.osm` exists with your desired map data
3. Press F5 to run

### Controls

- **W / S** — Accelerate / Brake
- **A / D** — Steer left / right
- **Escape** — Toggle mouse capture

## Customization

### Adding New Placeholder Assets

Edit `ASSET_DEFS` in `scripts/osm_asset_placer.gd`. Each entry maps an OSM tag key + value to a placeholder definition:

```gdscript
"highway": {
    "traffic_signals": {
        "color": Color(0.1, 0.7, 0.1),
        "size": Vector3(0.3, 3.0, 0.3),
        "y_offset": 1.5,
        "label": "Traffic Light"
    },
}
```

Use `"*"` as the value to match any value for a given tag key.

### Tile Settings

In the scene inspector or in `osm_tile_manager.gd`:
- `tile_size` — Size of each tile in meters (default: 200)
- `load_radius` — How many tiles to keep loaded around camera (default: 2)
- `unload_radius` — Distance at which tiles are freed (default: 3)

### Scaling Up

For larger maps, consider:
- A **PostGIS** database with `osm2pgsql` imported data, queried via GDScript HTTP or GDExtension
- The **Overpass API** for on-the-fly tile fetching
- Streaming from **`.osm.pbf`** files with a custom C++ GDExtension

The current `.osm` file approach works well for areas up to ~10 km².

## Project Structure

```
autobahnraser/
├── project.godot
├── README.md
├── data/
│   └── map.osm              # Place your OSM export here
├── scenes/
│   └── main.tscn             # Main game scene
└── scripts/
    ├── main.gd               # Main scene logic
    ├── car_controller.gd     # WASD car driving
    ├── osm_parser.gd         # .osm XML parser
    ├── osm_tile_manager.gd   # Dynamic tile loading
    ├── osm_road_builder.gd   # Road mesh generation
    ├── osm_building_builder.gd # Building extrusion
    ├── osm_asset_placer.gd   # Placeholder asset placement
    └── osm_relation_builder.gd # Relation handling
```
