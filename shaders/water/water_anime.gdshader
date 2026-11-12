shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_toon, specular_toon;

// Stylized lake water: teal->deep-blue gradient, scrolling anime wave lines,
// shoreline foam and glitter glints, transparent with a soft fresnel rim.

uniform vec4 shallow_color : source_color = vec4(0.42, 0.86, 0.86, 1.0);
uniform vec4 deep_color : source_color = vec4(0.07, 0.32, 0.58, 1.0);
uniform vec4 foam_color : source_color = vec4(0.95, 0.99, 1.0, 1.0);
uniform float wave_scale : hint_range(0.01, 0.6) = 0.12;
uniform float wave_speed : hint_range(0.0, 2.0) = 0.5;
uniform float wave_height : hint_range(0.0, 1.0) = 0.08;
uniform float opacity : hint_range(0.0, 1.0) = 0.82;
uniform float foam_scale : hint_range(0.0, 4.0) = 1.4;
uniform float glint_strength : hint_range(0.0, 3.0) = 0.9;

varying vec3 v_world;
varying float v_wave;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float w1 = sin(v_world.x * wave_scale * 2.4 + TIME * wave_speed * 1.7);
	float w2 = cos(v_world.z * wave_scale * 1.9 + TIME * wave_speed * 1.15);
	v_wave = w1 * 0.5 + w2 * 0.5;
	VERTEX.y += v_wave * wave_height;
}

void fragment() {
	vec2 p = v_world.xz;
	// Scrolling banded waves (stylized, three octaves of stripes).
	float bands = 0.0;
	bands += sin((p.x * 0.9 + p.y * 0.4) * wave_scale * 6.0 + TIME * wave_speed * 2.2) * 0.5;
	bands += sin((p.x * -0.5 + p.y * 1.1) * wave_scale * 9.0 + TIME * wave_speed * 1.6) * 0.32;
	bands += sin((p.x + p.y) * wave_scale * 22.0 + TIME * wave_speed * 3.1) * 0.18;
	bands = bands * 0.5 + 0.5;

	float ndv = clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0);
	float fres = pow(1.0 - ndv, 3.0);

	vec3 col = mix(deep_color.rgb, shallow_color.rgb, clamp(0.35 + bands * 0.4 + fres * 0.35, 0.0, 1.0));

	// Foam: thin bright ribbons drifting with the waves.
	float foam_n = sin(p.x * foam_scale + TIME * 0.35) * cos(p.y * foam_scale * 0.9 - TIME * 0.27);
	float foam = smoothstep(0.86, 1.0, foam_n * 0.5 + 0.5);
	foam *= smoothstep(0.35, 0.9, bands);
	col = mix(col, foam_color.rgb, foam * 0.45);

	// Glints: sparse sparkle cells that twinkle at different phases.
	vec2 cell = floor(p * 3.0);
	float tw = hash(cell + floor(TIME * 1.7));
	float sparkle = step(0.985, tw) * (0.5 + 0.5 * sin(TIME * 9.0 + tw * 30.0));
	col += vec3(1.0, 0.98, 0.85) * sparkle * glint_strength;

	ALBEDO = col;
	// lint:allow-transparent - water is the one surface here that genuinely
	// needs the blended pipeline; it is a single large sheet, not thousands of
	// overlapping cards, so the sorting cost is bounded.
	ALPHA = mix(opacity, 0.97, fres);
	ROUGHNESS = mix(0.12, 0.03, fres);
	METALLIC = 0.0;
	SPECULAR = 0.75;
	EMISSION = shallow_color.rgb * foam * 0.05;
}
