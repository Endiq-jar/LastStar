extends Node3D
## Builds every vegetation species on the real terrain.
##
## This is the integration point: it instantiates one VegetationLayer per species
## from the preset table and hands each one the shared material and wind driver.
## The world can adopt it by adding this node under Terrain, or the individual
## layers can be dropped in directly.

const VegLayer := preload("res://scripts/performance/vegetation_layer.gd")
const Presets := preload("res://scripts/performance/vegetation_presets.gd")
const WindDriver := preload("res://scripts/performance/vegetation_wind.gd")

@export var terrain_path: NodePath
@export var player_path: NodePath = ^"../Player"
## Set false to build only grass - useful when checking one species in isolation.
@export var all_species: bool = true

var _layers: Array[Node] = []
var _wind: Node = null


func _ready() -> void:
	var terrain := get_node_or_null(terrain_path)
	if terrain == null:
		# Fall back to a sibling named Terrain, which is the layout in
		# scenes/world.tscn.
		terrain = get_node_or_null("../Terrain")
	if terrain == null:
		push_warning("VegetationDemo: no terrain found - nothing to plant")
		return
	var player := get_node_or_null(player_path) as Node3D

	_wind = WindDriver.new()
	_wind.name = "WindDriver"
	add_child(_wind)
	if player != null and _wind.has_method("set_player"):
		_wind.call("set_player", player)

	for spec in Presets.species():
		if not all_species and spec["name"] != "grass":
			continue
		var mat := Presets.material_for(spec)
		if mat == null:
			push_warning("VegetationDemo: no material for %s" % spec["name"])
			continue
		if _wind.has_method("register_material"):
			_wind.call("register_material", mat)

		var layer := Node3D.new()
		layer.name = "Layer_%s" % spec["name"]
		layer.set_script(VegLayer)
		add_child(layer)
		layer.set("density", spec["density"])
		layer.set("min_height", spec["hmin"])
		layer.set("max_height", spec["hmax"])
		layer.set("max_slope", spec["slope"])
		layer.set("model_kind", spec["model"])
		layer.set("material", mat)
		layer.call("setup", terrain, player, hash(spec["name"]))
		_layers.append(layer)


## Aggregate census across every layer, for the performance probe.
func census() -> String:
	var total_chunks := 0
	var total_instances := 0
	for layer in _layers:
		if is_instance_valid(layer) and layer.has_method("census"):
			var c: Dictionary = layer.call("census")
			total_chunks += int(c["chunks"])
			total_instances += int(c["instances"])
	return "vegetation layers=%d chunks=%d instances=%d" % [
		_layers.size(), total_chunks, total_instances]
