extends Node
## Compile every GDScript in the project, from inside the running game.
##
## Why a scene and not `--script`: a SceneTree script runs without autoloads, so
## every script that references the `Game` singleton fails to compile with
## "Identifier not found: Game" and the check reports the whole project as
## broken. Running as a normal scene means autoloads are live and the only errors
## reported are real ones.
##
## Why it exists at all: booting the world headlessly only compiles the scripts
## the world reaches. A compile error in tests/render_probe.gd therefore passed
## that step and only failed in the probe, as "no PROBE_RESULT" - the symptom
## rather than the cause. (Concretely: Color.hsv does not exist; Color has a
## from_hsv constructor but no getter.)
##
## Usage:
##   godot --headless --path . res://tests/compile_check.tscn

const DIRS := ["res://scripts", "res://tests"]


func _ready() -> void:
	# Deferred so the tree is fully up (and autoloads are settled) before any
	# script is loaded.
	_run.call_deferred()


func _run() -> void:
	var files: Array[String] = []
	for d in DIRS:
		var da := DirAccess.open(d)
		if da == null:
			continue
		for f in da.get_files():
			if f.ends_with(".gd"):
				files.append(d.path_join(f))
	files.sort()

	var failed: Array[String] = []
	for path in files:
		# Print before loading so a stall names the file it stalled on.
		print("COMPILE_TRY: %s" % path)
		var script := load(path) as Script
		if script == null:
			failed.append(path)
			print("COMPILE_FAIL: %s did not load" % path)
			continue
		# Instantiating catches resolve errors that loading alone tolerates
		# (e.g. a call to a member that does not exist on a typed variable).
		# Only instantiate nodes and RefCounted; anything that needs a specific
		# constructor signature would report a false failure here.
		var inst = script.new()
		if inst == null:
			failed.append(path)
			print("COMPILE_FAIL: %s produced no instance" % path)
		elif inst is RefCounted:
			pass  # released automatically
		elif inst is Node:
			# Never entered the tree, so free() rather than queue_free().
			inst.free()

	if failed.is_empty():
		print("COMPILE_OK: %d scripts" % files.size())
		get_tree().quit(0)
	else:
		print("COMPILE_FAIL_SUMMARY: %d of %d scripts failed: %s" % [
			failed.size(), files.size(), ", ".join(failed)])
		get_tree().quit(1)
