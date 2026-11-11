extends Node3D
## Procedural ambience + one-shot SFX. No audio files: wind, birds and combat
## chimes are synthesised at runtime so the project stays asset-light.

const RATE := 22050.0

var _wind: AudioStreamPlayer
var _playback: AudioStreamGeneratorPlayback
var _phase := 0.0
var _noise_a := 0.0
var _noise_b := 0.0
var _chirp_clock := 0.0
var _sfx: AudioStreamPlayer


func _ready() -> void:
	add_to_group("ambience")
	_wind = AudioStreamPlayer.new()
	_wind.name = "Wind"
	_wind.volume_db = -17.0
	var gen := AudioStreamGenerator.new()
	gen.mix_rate = RATE
	gen.buffer_length = 0.6
	_wind.stream = gen
	add_child(_wind)
	_wind.play()
	_playback = _wind.get_stream_playback() as AudioStreamGeneratorPlayback

	_sfx = AudioStreamPlayer.new()
	_sfx.name = "SFX"
	_sfx.volume_db = -6.0
	add_child(_sfx)


func _process(_delta: float) -> void:
	if _playback == null:
		return
	var frames := _playback.get_frames_available()
	if frames <= 0:
		return
	for i in range(frames):
		_noise_a = lerpf(_noise_a, randf_range(-1.0, 1.0), 0.06)
		_noise_b = lerpf(_noise_b, randf_range(-1.0, 1.0), 0.02)
		_phase += 1.0 / RATE
		var gust := sin(_phase * 0.24) * 0.35 + sin(_phase * 0.071) * 0.3 + sin(_phase * 0.6) * 0.12
		var wind := (_noise_a * 0.65 + _noise_b * 0.35) * (0.16 + gust * 0.12)
		# Sparse bird calls: two short FM chirps every few seconds.
		_chirp_clock += 1.0 / RATE
		var bird := 0.0
		var t := fmod(_chirp_clock * 0.09, 1.0)
		if t < 0.02:
			bird = sin(_phase * TAU * 1750.0) * exp(-t * 80.0) * 0.05
		var t2 := fmod(_chirp_clock * 0.047 + 0.35, 1.0)
		if t2 < 0.012:
			bird += sin(_phase * TAU * 2250.0) * exp(-t2 * 95.0) * 0.035
		var s := clampf(wind + bird, -0.6, 0.6)
		_playback.push_frame(Vector2(s, s))


func play_ui_chime() -> void:
	_sfx.stream = _chime([880.0, 1320.0], 0.18, 0.30)
	_sfx.play()


func play_switch() -> void:
	_sfx.stream = _chime([660.0, 990.0, 1320.0], 0.26, 0.26)
	_sfx.play()


func play_waypoint() -> void:
	_sfx.stream = _chime([523.0, 659.0, 784.0, 1046.0], 0.9, 0.32)
	_sfx.play()


func play_hit() -> void:
	_sfx.stream = _noise_burst(0.08, 0.35)
	_sfx.play()


func _chime(freqs: Array, duration: float, amp: float) -> AudioStreamWAV:
	var n := int(RATE * duration)
	var data := PackedByteArray()
	data.resize(n * 2)
	for i in range(n):
		var t := float(i) / RATE
		var env := exp(-t * (4.0 / maxf(duration, 0.01)))
		var s := 0.0
		for k in range(freqs.size()):
			var f: float = freqs[k]
			s += sin(TAU * f * t) * (0.5 / (1.0 + float(k)))
		s = clampf(s * amp * env, -1.0, 1.0)
		var v := int(s * 32767.0)
		data[i * 2] = v & 0xFF
		data[i * 2 + 1] = (v >> 8) & 0xFF
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = int(RATE)
	stream.stereo = false
	stream.data = data
	return stream


func _noise_burst(duration: float, amp: float) -> AudioStreamWAV:
	var n := int(RATE * duration)
	var data := PackedByteArray()
	data.resize(n * 2)
	for i in range(n):
		var t := float(i) / RATE
		var env := exp(-t * 40.0)
		var s := clampf(randf_range(-1.0, 1.0) * amp * env, -1.0, 1.0)
		var v := int(s * 32767.0)
		data[i * 2] = v & 0xFF
		data[i * 2 + 1] = (v >> 8) & 0xFF
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = int(RATE)
	stream.stereo = false
	stream.data = data
	return stream
