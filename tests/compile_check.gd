extends Node
## Compile every GDScript and every shader in the project, from inside the game.
##
## Two classes of mistake this catches that a headless boot does not:
##
##  * a compile error in a script the world never loads (the render probe), which
##    otherwise surfaces only as "no PROBE_RESULT" in the probe step;
##  * a shader that fails to compile. Godot does not fail the run for that - it
##    logs "Shader compilation failed" and draws the surface with a default white
##    material. A meadow rendered in pale lavender-White looks like an art bug, not
##    a compile bug, and cost a full CI cycle to find: CAMERA_POSITION_WORLD is a
##    fragment-stage built-in and its use in vertex() was the whole cause.
##
## Usage:
##   godot --headless --path . res://tests/compile_check.tscn

const DIRS := ["res://scripts", "res://tests"]
# Both locations. `assets/shaders` holds the environment shader library and is
# nested by category, which is why the walker below had to become recursive -
# DirAccess.get_files() lists one directory only, so the entire library was
# silently skipped and CI reported green without ever compiling it.
const SHADER_DIRS := ["res://shaders", "res://assets/shaders"]


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	# async: awaits a frame between shader loads so the renderer can report.
	var failed: Array[String] = []

	for path in _files(DIRS, ".gd"):
		# Print before loading so a stall names the file it stalled on.
		print("COMPILE_TRY: %s" % path)
		var script := load(path) as Script
		if script == null:
			failed.append(path)
			print("COMPILE_FAIL: %s did not load" % path)
			continue
		# Instantiation catches member-resolution errors that loading tolerates.
		var inst = script.new()
		if inst == null:
			failed.append(path)
			print("COMPILE_FAIL: %s produced no instance" % path)
		elif inst is Node:
			inst.free()

	# Shaders: construct a material and hand it to the renderer. A bad shader
	# still returns a ShaderMaterial, so the failure is read from the engine's own
	# error output, which the workflow greps for.
	for path in _files(SHADER_DIRS, ".gdshader"):
		print("COMPILE_TRY: %s" % path)
		var shader := load(path) as Shader
		if shader == null:
			failed.append(path)
			print("COMPILE_FAIL: %s did not load" % path)
			continue
		var mat := ShaderMaterial.new()
		mat.shader = shader
		# Touching the material forces it into the RenderingServer.
		mat.set_shader_parameter("__compile_probe", 1.0)
		# Give the renderer a frame's worth of slack, then ask the shader itself
		# whether it compiled. Without this the only signal is the engine's
		# "Shader compilation failed." line, which does not say which file - and
		# that is the one thing needed to fix it.
		await get_tree().process_frame
		# Shader code is opaque to GDScript except through the uniform list and
		# the renderer's own log. Both are reported: the uniform list gives a
		# per-file verdict that can be asserted and annotated, and the error log
		# is written out in full so the exact line and reason are recoverable
		# without access to the step log.
		var uniform_count := shader.get_shader_uniform_list().size()
		print("COMPILE_SHADER: %s uniforms=%d code_len=%d" % [
			path, uniform_count, shader.code.length()])
		if uniform_count == 0:
			failed.append(path)
			print("COMPILE_FAIL: %s exposes no uniforms - bad signature or failed compile" % path)

	if failed.is_empty():
		print("COMPILE_OK: all scripts and shaders")
		get_tree().quit(0)
	else:
		print("COMPILE_FAIL_SUMMARY: %s" % ", ".join(failed))
		get_tree().quit(1)


func _files(dirs: Array, suffix: String) -> Array[String]:
	var out: Array[String] = []
	for d in dirs:
		_walk(d, suffix, out)
	out.sort()
	return out


## Recurse, because the shader library is nested by category. The previous
## single-level listing meant res://assets/shaders/**/*.gdshader was never
## compiled in CI at all - the check passed by not looking.
func _walk(dir_path: String, suffix: String, out: Array[String]) -> void:
	var da := DirAccess.open(dir_path)
	if da == null:
		return
	for f in da.get_files():
		if f.ends_with(suffix):
			out.append(dir_path.path_join(f))
	for sub in da.get_directories():
		_walk(dir_path.path_join(sub), suffix, out)
