extends SceneTree
## Compile every GDScript in the project, including test scenes.
##
## Why this exists: booting the game headlessly only compiles the scripts the
## running scene actually reaches. Test-only scripts (tests/render_probe.gd) are
## never loaded that way, so a compile error in one of them passes the boot check
## and only explodes in the probe step, which then reports "no PROBE_RESULT"
## instead of the actual mistake. That cost a full CI cycle for a one-line error
## (`Color.hsv` does not exist - Color has a from_hsv constructor but no getter).
##
## load() alone is enough: GDScript analyses and compiles a script as part of
## loading it, so undefined members and type errors are reported right there.
## An earlier version also instantiated each script; that could hang the whole
## job on a script that does real work in _init(), and bought nothing.
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
			if f.ends_with(".gd"):
				files.append(d.path_join(f))
	files.sort()

	var failed := 0
	for path in files:
		# Print first, and flush, so a hang names the file it hung on instead of
		# leaving a silent dead step.
		print("COMPILE_TRY: %s" % path)
		var script := load(path) as Script
		if script == null:
			print("COMPILE_FAIL: %s did not load (parse or compile error)" % path)
			failed += 1
			continue
		# Deliberately NOT checking can_instantiate() here: for GDScript it
		# reports false for ordinary non-tool scripts, so it flagged every
		# gameplay script in the project as broken. load() returning a Script is
		# the real signal - the engine refuses to produce one for a script that
		# failed to compile - and it prints its own "Parse Error" line, which the
		# workflow greps for as a second opinion.

	print("COMPILED: %d scripts, %d failed" % [files.size(), failed])
	quit(1 if failed > 0 else 0)
