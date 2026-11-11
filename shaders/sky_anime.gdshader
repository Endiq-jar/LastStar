shader_type sky;

// Painted anime sky.
//
// The stock ProceduralSkyMaterial gives a clean two-colour gradient, and that is
// exactly what it looks like: a gradient swatch. What a painted open-world sky
// actually has, and what this adds, is a stack of horizontal value bands near the
// horizon - the accumulated haze you get from looking through tens of kilometres
// of air - plus a warm band right at the horizon line where the light comes from.
//
// This is deliberately cheap for the Compatibility renderer: no textures, no
// raymarching, no sun disc geometry, just a handful of smoothsteps on the view
// direction. It runs once per sky pixel, which is a small fraction of a frame.

// Zenith and the colour the sky reaches just above the horizon.
uniform vec3 zenith_color : source_color = vec3(0.10, 0.28, 0.68);
uniform vec3 horizon_color : source_color = vec3(0.86, 0.93, 1.0);
// Warm band sitting right on the horizon line, where the sun's light is.
uniform vec3 horizon_glow : source_color = vec3(1.0, 0.94, 0.80);
uniform float glow_strength : hint_range(0.0, 1.5) = 0.45;
// How tightly the gradient collapses onto the horizon.
uniform float gradient_power : hint_range(0.2, 4.0) = 0.52;
// The haze stack: number of visible bands and how strongly they show.
uniform float band_strength : hint_range(0.0, 0.6) = 0.11;
uniform float band_count : hint_range(2.0, 10.0) = 5.0;
// Where the bands fade out, measured as height above the horizon.
uniform float band_extent : hint_range(0.02, 0.6) = 0.16;
// Below the horizon the sky shader still renders what shows through gaps.
uniform vec3 ground_color : source_color = vec3(0.42, 0.52, 0.48);
// Sun disc, drawn analytically. Kept soft and large - anime skies have a broad,
// diffuse sun rather than a laser point.
uniform float sun_size : hint_range(0.0005, 0.06) = 0.011;
uniform vec3 sun_color : source_color = vec3(1.0, 0.97, 0.88);
uniform float sun_strength : hint_range(0.0, 4.0) = 1.6;

void sky() {
	// EYEDIR is the unit direction from the camera through this pixel.
	float h = EYEDIR.y;

	// The vertical gradient runs from the horizon colour at h=0 to the zenith.
	//
	// The exponent is well below 1, which front-loads the transitions: the sky
	// reaches its deep blue just 20-30 degrees up instead of at the zenith. That
	// matters because the beauty camera is pitched about 4 degrees down with a 68
	// degree fov - the entire sky it can see tops out around 30 degrees of
	// elevation. A linear (or worse, exponent > 1) ramp spends that whole visible
	// band still blending out of the horizon colour, and the frame reads as a flat
	// white wash no matter how saturated zenith_color is.
	float t = pow(clamp(h, 0.0, 1.0), gradient_power);
	vec3 col = mix(horizon_color, zenith_color, t);

	// --- haze stack -------------------------------------------------------
	// Horizontal bands, evenly spaced in height above the horizon, fading out as
	// they climb. Each one is a smooth pulse rather than a hard stripe so there is
	// no aliasing when the horizon sits exactly on a band edge.
	if (h > 0.0 && h < band_extent) {
		float band_t = h / band_extent;
		// Fractional position within the stack, then a triangle wave that peaks
		// at the centre of each band.
		float phase = band_t * band_count;
		float wave = abs(fract(phase) - 0.5) * 2.0;
		float band = smoothstep(0.72, 1.0, wave);
		// Fade the whole stack out toward the top of its extent.
		float fade = 1.0 - smoothstep(0.0, 1.0, band_t);
		col += vec3(0.055, 0.048, 0.030) * band * fade * band_strength;
	}

	// --- horizon glow -----------------------------------------------------
	// A warm, wide bloom hugging the horizon line. This is the single strongest
	// cue that there is a sun in the sky and a world under it, and it is what the
	// flat gradient was missing most.
	float horizon_band = exp(-abs(h) * 14.0);
	col = mix(col, horizon_glow, horizon_band * glow_strength);

	// --- sun --------------------------------------------------------------
	// LIGHT0 is the first directional light, i.e. the sun.
	//
	// LIGHT0_DIRECTION is the direction the light is FACING (the way its rays
	// travel), not the direction toward it - the docs are explicit about that and
	// it is the classic way to get a sun that sits 180 degrees wrong and never
	// appears. Negate it to point at the sun, and use LIGHT0_SIZE for the angular
	// diameter so the disc matches the light the world is actually lit by.
	vec3 sun_dir = -LIGHT0_DIRECTION;
	float sun_dot = dot(EYEDIR, sun_dir);
	// LIGHT0_SIZE is in radians; convert to a cosine-space threshold at the rim.
	float angular = max(LIGHT0_SIZE, 0.004) * 1.4;
	float disc = smoothstep(cos(angular), cos(angular * 0.45), sun_dot);
	// A broad halo around the disc, and a wider one around that.
	float halo = pow(max(sun_dot, 0.0), 260.0) * 0.55 + pow(max(sun_dot, 0.0), 20.0) * 0.09;
	vec3 sun_tint = sun_color * mix(vec3(1.0), LIGHT0_COLOR, 0.55);
	col += sun_tint * (disc * sun_strength + halo * sun_strength * 0.45);

	// --- below the horizon ------------------------------------------------
	// Anything under h=0 is the ground half; keep it a calm haze so it never
	// flashes through a terrain seam.
	// Note the negation: GLSL smoothstep is only defined for edge0 < edge1, and
	// smoothstep(0.0, -0.12, h) is undefined behaviour that some drivers return
	// as a constant.
	float below = smoothstep(0.0, 0.12, -h);
	col = mix(col, ground_color, below);

	COLOR = col;
}
