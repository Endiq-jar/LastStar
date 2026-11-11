shader_type spatial;
render_mode cull_back, diffuse_lambert, specular_toon, depth_draw_opaque;
// Lambert, not toon, for the terrain.
//
// The toon diffuse is what cut the hillsides into hard two-tone wedges with a
// terminator that followed the mesh triangles rather than the form - the reason
// a slope under a cast shadow read as a flat near-black shape with a knife edge
// while the grass standing on it stayed bright. A background painting rolls its
// shadow off gradually; a soft falloff plus the albedo floor below keeps the
// stylisation in the colour ramp and out of the geometry.

// Stylized Genshin-like terrain: three painted layers (meadow / rock / sand)
// triplanar-blended by height + slope, with soft painterly macro variation and
// wet, reflective bands near the waterline. Tuned for mobile (3 samples).

uniform sampler2D meadow_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D rock_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D sand_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D macro_tex : hint_default_white, filter_linear_mipmap, repeat_enable;

uniform vec4 meadow_tint : source_color = vec4(0.235, 0.335, 0.175, 1.0);
uniform vec4 meadow_deep : source_color = vec4(0.115, 0.195, 0.115, 1.0);
// Slightly warm grey. A neutral 0.42 grey under a cool sky turns every cliff the
// same slate blue and the mountains lose all separation from the sky behind them.
uniform vec4 rock_tint : source_color = vec4(0.40, 0.38, 0.36, 1.0);
uniform vec4 sand_tint : source_color = vec4(0.58, 0.52, 0.38, 1.0);
uniform vec4 shadow_tint : source_color = vec4(0.68, 0.72, 0.95, 1.0);

uniform float uv_scale : hint_range(0.002, 0.2) = 0.045;
uniform float macro_scale : hint_range(0.001, 0.05) = 0.006;
uniform float rock_height : hint_range(0.0, 200.0) = 64.0;
uniform float snow_height : hint_range(0.0, 200.0) = 980.0;
uniform float slope_rock : hint_range(0.0, 1.0) = 0.30;
uniform float slope_cliff : hint_range(0.0, 1.0) = 0.52;
uniform float water_level : hint_range(-20.0, 40.0) = 1.0;
uniform float wet_band : hint_range(0.5, 24.0) = 5.0;
uniform float band_softness : hint_range(0.0, 0.3) = 0.055;
// Distance (metres) over which albedo starts to mute toward atmospheric haze.
uniform float haze_begin : hint_range(0.0, 600.0) = 120.0;
uniform float haze_end : hint_range(0.0, 900.0) = 700.0;

varying vec3 v_world;
varying vec3 v_world_normal;

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

vec3 tri(sampler2D tex, vec3 p, vec3 n, float s) {
	vec3 b = pow(abs(n), vec3(4.0));
	b /= (b.x + b.y + b.z + 1e-5);
	return texture(tex, p.zy * s).rgb * b.x + texture(tex, p.xz * s).rgb * b.y + texture(tex, p.xy * s).rgb * b.z;
}

void fragment() {
	vec3 wn = normalize(v_world_normal);
	float slope = 1.0 - clamp(wn.y, 0.0, 1.0);
	float h = v_world.y;

	// Large-scale variation for the meadow colour. This used to be hard
	// quantized into bands for a "hand-painted planes" look; at the scale it
	// was running at, those bands were 20-40 m blocks, which read as giant
	// green camouflage patches rather than brushwork. A gently curved smooth
	// value gives the same painterly breakup without the blocky edges.
	float macro = texture(macro_tex, v_world.xz * macro_scale).r;
	float macro2 = texture(macro_tex, v_world.xz * macro_scale * 3.1 + vec2(0.37, 0.11)).r;
	float patch = smoothstep(0.12, 0.88, macro * 0.65 + macro2 * 0.35);

	// Anime terrain is painted in flat planes, not textured noise. The old
	// version multiplied triplanar noise at uv_scale 0.055 over everything,
	// which at distance turned every mountain into a wall of fine-grained
	// static. Now the large-scale `patch` value picks the colour and the
	// texture only adds a faint brush grain on top.
	float dry = smoothstep(0.55, 1.0, patch);

	// Detail from the painted textures, scaled to a painterly size rather than
	// a photographic one. tri() picks the best projection per surface so cliffs
	// do not stretch the meadow.
	//
	// Only the *luminance* of these is used, never their colour, and it is
	// centred on 1.0 so it modulates rather than tints. Multiplying the albedo
	// by the raw texture was the main source of the neon: the painted greens are
	// blue-poor (blue channel around 0.16), so squaring them into an already
	// blue-poor meadow albedo drove blue near zero and left a pure, saturated
	// green with nothing to hold it back. Luminance detail keeps the texture's
	// brushwork - the variation in value that reads as painted - without
	// touching the hue the lighting depends on.
	vec3 meadow_detail = tri(meadow_tex, v_world, wn, uv_scale);
	vec3 rock_detail = tri(rock_tex, v_world, wn, uv_scale * 0.62);
	vec3 sand_detail = tri(sand_tex, v_world, wn, uv_scale * 1.25);
	// A second, much finer sample at a different scale. One texture at one scale
	// over a whole hillside is what makes procedural terrain read as a single
	// flat colour: there is nothing between the macro patch (hundreds of metres)
	// and the base tint. Blending two scales of the same paint gives the
	// mid-frequency breakup a painted hillside has.
	vec3 meadow_fine = tri(meadow_tex, v_world, wn, uv_scale * 4.7);
	float meadow_fl = dot(meadow_fine, vec3(0.2126, 0.7152, 0.0722));

	// A third scale, sampled from the UV grid rather than triplanar because it is
	// only ever seen on the ground. At 0.62 m this is the size of a patch of
	// longer grass, and it is the scale the camera actually looks at from 4 m -
	// without it the ground immediately under the player is one unbroken fill no
	// matter how much larger-scale paint is layered above it.
	vec3 near_detail = texture(meadow_tex, v_world.xz * 1.6).rgb;
	float near_l = dot(near_detail, vec3(0.2126, 0.7152, 0.0722));
	float meadow_l = dot(meadow_detail, vec3(0.2126, 0.7152, 0.0722));
	float rock_l = dot(rock_detail, vec3(0.2126, 0.7152, 0.0722));
	float sand_l = dot(sand_detail, vec3(0.2126, 0.7152, 0.0722));

	// Meadow: two greens, broken up by the soft macro patches, modulated by the
	// painted detail (kept subtle so the flat anime bands still dominate).
	vec3 grass = mix(meadow_deep.rgb, meadow_tint.rgb, 0.35 + patch * 0.65);
	grass *= mix(1.0, meadow_l * 1.9, 0.50);
	grass *= mix(1.0, meadow_fl * 1.7, 0.30);
	// Weighted by distance: the fine grain is only visible up close, and applying
	// it at range would just be noise under the haze.
	grass *= mix(1.0, near_l * 1.7, 0.34 * (1.0 - smoothstep(18.0, 70.0, length(VERTEX))));
	// A little golden meadow mixed in, the way open-world grass reads. Kept
	// low: push this and the hillsides turn acid yellow-green.
	// The dry blend is nearly as weak as it can be while still breaking up the
	// field. At 0.10 with a lighter yellow it painted large acid-yellow blotches
	// across the meadow that read as camo, not as sun-bleached grass.
	grass = mix(grass, vec3(0.34, 0.36, 0.19), dry * 0.06);
	// Hue and value variety, which is what separates a painted valley from a
	// single flat wash of green. Genshin's fields run from a warm yellow-green on
	// the sunlit crowns to a cool blue-green in the hollows, and the transition
	// follows the terrain's own large-scale noise rather than a screen gradient.
	float warm_patch = smoothstep(0.35, 0.75, macro2);
	grass = mix(grass, grass * vec3(1.16, 1.09, 0.80), warm_patch * 0.55);
	float cool_patch = smoothstep(0.62, 0.20, macro);
	grass = mix(grass, grass * vec3(0.80, 0.94, 1.06), cool_patch * 0.40);

	// Rock: warm grey, cooler in shadowed bands.
	vec3 rock_col = rock_tint.rgb * mix(0.66, 1.0, patch);
	rock_col *= mix(1.0, rock_l * 1.9, 0.42);

	// Height bands: sand at the shoreline, meadow in the valley, rock up high.
	// Narrow. At 2.6 m this covered the whole lake basin in pale sand, which
	// showed up as big cream flats on the map edge.
	float shore = 1.0 - smoothstep(water_level + 0.2, water_level + 1.3, h);
	float highland = smoothstep(rock_height * 0.78, rock_height * 1.35, h);
	vec3 sand_col = sand_tint.rgb * mix(1.0, sand_l * 1.9, 0.38);
	vec3 col = mix(grass, sand_col, shore);
	col = mix(col, rock_col, highland * 0.9);

	// Slope: grass gives way to rock then bare cliff faces.
	//
	// This used to be quantized into three hard steps. Quantizing a slope test
	// that varies with the terrain's own triangle normals turned every
	// hillside fold into a crisp triangular wedge of grey, which is what made
	// the green look like it had been cut out with a knife. The step is soft
	// now, and the transition is pushed by the same macro noise that drives the
	// meadow colour so the boundary wanders the way a treeline does.
	float rock_slope = smoothstep(slope_rock, slope_rock + 0.22, slope + (patch - 0.5) * 0.10);
	float cliff_slope = smoothstep(slope_cliff, slope_cliff + 0.12, slope);
	col = mix(col, rock_col * mix(1.0, 0.80, cliff_slope), rock_slope * 0.92);

	// Snow caps only on genuinely high ground: a clean white with a cool tint,
	// not a noise texture.
	float snow = smoothstep(snow_height - 14.0, snow_height + 20.0, h);
	snow *= 1.0 - smoothstep(0.42, 0.62, slope);
	col = mix(col, vec3(0.615, 0.645, 0.715), snow * 0.74);

	// Wet band near the shore: darker + glossier.
	float wet = 1.0 - smoothstep(water_level, water_level + wet_band, h);
	col = mix(col, col * vec3(0.66, 0.72, 0.82), wet * 0.45);

	// Fine dither. The renderer is 8-bit and the sky gradient is wide and
	// smooth, so a hard band appeared around the horizon and on the hillside
	// falloff. A sub-LSB noise offset breaks the quantization steps up into
	// something the eye reads as a gradient.
	float dither = fract(sin(dot(FRAGCOORD.xy, vec2(12.9898, 78.233))) * 43758.5453);
	col += (dither - 0.5) * (1.0 / 255.0);

	// --- aerial perspective -------------------------------------------------
	// The problem with doing this with fog only is that fog multiplies the
	// *lighting*, so a saturated albedo still arrives as a saturated colour and
	// the far ranges turned into neon green cut-outs against the sky. Muting the
	// albedo with distance (toward its own luminance, nudged cool) is what a
	// painter does, and it is what makes the depth read.
	// In the fragment stage VERTEX is the view-space position, so its length is
	// the distance to the camera on every renderer without extra uniforms.
	float cam_dist = length(VERTEX);
	// Begin further out and reach less far, so the near and middle hills keep their
	// own colour and the muting is reserved for the actual ridge line. At 130-620 m
	// it was flattening the entire visible range into one grey band.
	float haze = smoothstep(haze_begin, haze_end, cam_dist);
	// Mute toward luminance AND darken. Muting alone kept the far ridge as bright
	// as the near hill, so it read as a flat green wall behind the valley instead
	// of receding into atmosphere; the depth cue is mostly the value drop.
	float luma = dot(col, vec3(0.2126, 0.7152, 0.0722));
	// Keep rather more of the surface's own colour (0.72 rather than 0.58) and tint
	// the result toward the sky blue rather than desaturating it to neutral grey,
	// which is what made the ridges read as blank cardboard cut-outs.
	vec3 hazed = mix(vec3(luma), col, 0.72) * vec3(0.80, 0.86, 1.06);
	col = mix(col, hazed, haze * 0.88);

	// Painted ground darkens in the creases. Lambert alone leaves a smooth
	// hillside one flat value across the whole frame; a background painter puts
	// a darker wash on every concave fold and that is most of what gives the
	// ground its rolls. `slope` is already computed for the rock blend, so this
	// costs nothing.
	float fold = smoothstep(0.12, 0.55, slope);
	col *= mix(1.0, 0.78, fold * 0.55);

	// Pull the hue back toward grey before handing the albedo to the light.
	//
	// The neon this project keeps fighting was never brightness - the shadowed
	// hills measure rgb(3,30,20), which is dark and 0.90 saturated at the same
	// time. A saturated albedo stays saturated at every exposure, so no amount of
	// exposure tuning removed it. Mixing 18% of the luminance back in is what a
	// painter does with green, and it is what lets the light add the warmth
	// instead of the pigment being born at maximum chroma.
	float col_luma = dot(col, vec3(0.2126, 0.7152, 0.0722));
	col = mix(col, vec3(col_luma), 0.18);

	// Lift the darkest end. Whatever the light does, no terrain albedo in a
	// stylised open world should be below about 0.06 or the ground turns into a
	// black hole under the camera while the same grass two metres away is bright.
	// The albedo floor also has to clear the tonemap's toe. It was 0.055/0.07/0.05,
	// which after the filmic curve is barely off black - and because the shadow
	// fill is now proportional to this value, a near-zero albedo gives a near-zero
	// fill. Raising it here is what gives the proportional fill something to
	// multiply, so the darkest ground keeps its texture instead of flattening.
	col = max(col, vec3(0.105, 0.130, 0.108) * (0.62 + patch * 0.78));

	ALBEDO = col;
	// A flat painted-ambient lift.
	//
	// Only the terrain sits in shadow: the grass is drawn with shadows_disabled,
	// so the meadow stayed bright while the slope underneath it went to a near
	// black-green under the ridge's cast shadow. The result was a field hovering
	// over a void, and a foreground three stops darker than the sunlit hills
	// behind it - which is the opposite of how an anime background is painted,
	// where shadow is a colour change and almost never a value collapse.
	//
	// This is emission rather than more ambient light on purpose: raising the
	// environment's ambient also greys out the character's blacks, and the whole
	// point of the repaint was to keep them black.
	// A constant cool term, not a multiple of col.
	//
	// Scaling by col does nothing where it is needed most: on a slope facing away
	// from the sun the lit result is already near zero, so col*0.13 rounded to a
	// 2/255 difference in the frame. The foreground stayed black. A fixed lift
	// puts a floor under the shadow instead, which is what makes painted terrain
	// read - shadow is a colour there, and the darkest value on the ground is
	// nowhere near black.
	// The constant dominates on purpose. On a slope facing away from the key the
	// light term is a few thousandths, so this floor *is* the shadow colour, and a
	// floor of 0.03/0.04/0.06 still left the shadowed valley reading as a hole -
	// rgb(3,30,20) in the wide frame, near-black and 0.90 saturated. Painted
	// background shadow is a cool mid green, not an absence of light.
	// The constant is sized against the measured frame, not by eye: the sunlit
	// meadow lands near 0.62 in the green channel after tonemapping and the
	// shadowed ground was arriving at 0.17 - a 4.7x ratio, which is what reads as
	// a black hole. Painted shadow sits around a third of the lit value, so the
	// floor has to be roughly twice what it was.
	// A fill proportional to the surface's own colour, plus a small constant.
	//
	// Two earlier versions of this were wrong in opposite directions. A constant
	// floor alone lifted the shadow out of black but made it perfectly FLAT:
	// measured rgb(62,90,73) across the entire lower third of the frame, every
	// pixel identical, because a constant is by definition constant. Scaling by
	// col alone is invisible where it matters, because on a slope facing away
	// from the key the light term is already near zero.
	//
	// Proportional fill keeps the paint: shadow now carries the same patches,
	// grain and fold darkening as the lit ground, just darker and cooler, which is
	// exactly what painted shadow looks like. The small constant only stops the
	// very darkest creases from going to pure black.
	EMISSION = col * 0.42 + vec3(0.030, 0.038, 0.034);
	ROUGHNESS = mix(0.92, 0.24, wet);
	METALLIC = 0.0;
	SPECULAR = mix(0.18, 0.55, wet);
	// Fake ambient occlusion in the creases the noise made.
	AO = mix(0.82, 1.0, patch);
	AO_LIGHT_AFFECT = 0.25;
}
