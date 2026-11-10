extends SceneTree
## Compile every GDScript in the project, including test scenes.
##
## Why this exists: booting the game headlessly only compiles the scripts the
## running scene actually reaches. Test-only scripts (tests/render_probe.gd) are
## never loaded that way, so a type error in one of them passes the boot check
## and only explodes later in the probe step, which then reports "no
## PROBE_RESULT" instead of the actual mistake. That cost a full CI cycle for a
## one-line error (`Color.hsv` does not exist).
##
## Loading a script and setting it on a live Node forces the engine to compile
## it, and a compile failure leaves the node with no script attached, which is
## what the check below looks for. Parse failures are also printed by the engine
## itself and are picked up by the workflow's grep.
##
## Usage:
##   godot --headless --path . --script res://tools/compile_check.gd

const DIRS := ["res://scripts", "res://tests", "res://tools"]


func _init() -> void:
	var files: Array[String] = []
	for d in DIRS:
		var da := DirAccess.open(d)
		if da == null:
			continue
		for f in da.get_files():
			# .gd is the source; skip .gd.uid style sidecars and hidden files.
			if f.ends_with(".gd"):
				files.append(d.path_join(f))
	files.sort()

	var failed := 0
	for path in files:
		# Never instantiate this script: its _init() would print a result and
		# call quit(), ending the check after the first file.
		if path == "res://tools/compile_check.gd":
			continue
		var script := load(path) as Script
		if script == null:
			print("COMPILE_FAIL: %s did not load" % path)
			failed += 1
			continue
		if not script.can_instantiate():
			# A script that cannot be instantiated failed to compile. Abstract
			# or tool-only base classes are not used in this project, so this is
			# always a real problem.
			print("COMPILE_FAIL: %s cannot be instantiated" % path)
			failed += 1
			continue
		# Instantiating is the strongest check available: it runs the static
		# initialisers and resolves every static reference.
		var inst = script.new()
		if inst == null:
			print("COMPILE_FAIL: %s produced no instance" % path)
			failed += 1
		elif inst is Object:
			# Free without touching the tree; the object was never added to one.
			inst.free()

	print("COMPILED: %d scripts, %d failed" % [files.size(), failed])
	quit(1 if failed > 0 else 0)
