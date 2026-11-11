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

// --- clouds -------------------------------------------------------------
// Height of the cloud layer above the world, in metres.
uniform float cloud_height = 1250.0;
// World size of one noise cell. Larger = bigger, fewer clouds.
uniform float cloud_scale = 0.0011;
// 0.0 = clear sky, 1.0 = overcast.
uniform float cloud_coverage : hint_range(0.0, 1.0) = 0.44;
uniform float cloud_opacity : hint_range(0.0, 1.0) = 0.92;
uniform vec3 cloud_color : source_color = vec3(1.0, 1.0, 1.0);
uniform vec3 cloud_shadow_color : source_color = vec3(0.74, 0.80, 0.90);
// How much the cloud layer drifts, in cells per second.
uniform float cloud_drift = 0.004;

float sky_hash21(vec2 p) {
	// Cheap deterministic hash. The constants are the usual fract-sine-free
	// ones: two irrational-ish multipliers and a dot product to mix.
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

float sky_vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	// Smoothstep interpolation: a cosine-free fade that removes the grid.
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(sky_hash21(i), sky_hash21(i + vec2(1.0, 0.0)), u.x),
	           mix(sky_hash21(i + vec2(0.0, 1.0)), sky_hash21(i + vec2(1.0, 1.0)), u.x), u.y);
}

float sky_fbm(vec2 p) {
	// Four octaves is the point of diminishing returns for soft cloud - the
	// fifth only adds grain that reads as noise at this size.
	float v = 0.0;
	float a = 0.5;
	for (int i = 0; i < 4; i++) {
		v += a * sky_vnoise(p);
		p *= 2.03;
		a *= 0.5;
	}
	// Sum of the weights is 0.9375, so this normalises to roughly 0..1.
	return v / 0.9375;
}


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
	// A tighter core and a much wider, fainter skirt. A single exponent either
	// leaves a narrow yellow stripe sitting on the ridge line or, pushed the
	// other way, washes a grey-green veil over the whole lower sky - mixing a
	// warm band into a blue gradient in linear space desaturates to olive.
	// Splitting it keeps the warm core local and lets the skirt read as haze.
	float glow_core = exp(-abs(h) * 26.0);
	float glow_skirt = exp(-abs(h) * 5.0);
	col = mix(col, horizon_glow, (glow_core * 0.75 + glow_skirt * 0.25) * glow_strength);

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


	// --- clouds -----------------------------------------------------------
	// A cloud layer projected onto a horizontal plane at a fixed height.
	//
	// This replaces 3D billboard clouds, which could not be placed correctly
	// here at all. The valley is ringed by a radial rim that peaks around
	// 140 m, and the camera only sees about 17-30 degrees of elevation above
	// it: any cloud low enough to be nearby sat behind the ridge, and any
	// cloud high enough to clear the ridge rose above the top of the frame.
	// Projecting onto a plane decouples the two - the layer lives at one real
	// height and the perspective divide puts each cloud where the eye expects
	// it, converging toward the horizon for free.
	if (h > 0.0) {
		// Distance along the view ray to the layer: height divided by the sine
		// of the elevation angle (which is h, since EYEDIR is unit length).
		float layer_dist = cloud_height / max(h, 0.02);
		vec2 p = EYEDIR.xz * layer_dist * cloud_scale;
		// Two layers at different heights and scales read as depth rather than
		// as one flat sheet of noise.
		float n = sky_fbm(p + vec2(cloud_drift * TIME, 0.0));
		float n2 = sky_fbm(p * 2.7 + vec2(0.0, cloud_drift * TIME * 1.7) + 31.4);
		float density = n * 0.68 + n2 * 0.32;

		// Coverage is a threshold on the noise: raising it lowers the cut, so
		// more of the sky fills in.
		float lo = 1.0 - cloud_coverage;
		float mask = smoothstep(lo, lo + 0.20, density);

		// Fade the layer out at the horizon and at the zenith. The horizon fade
		// avoids a hard seam where the perspective divide blows up; the zenith
		// fade keeps the top of the frame clean blue, which is where a painted
		// sky wants its deepest colour.
		mask *= smoothstep(0.0, 0.14, h) * (1.0 - smoothstep(0.72, 0.99, h));

		// Lit tops, cool shaded undersides - the flat two-tone that reads as
		// cel-shaded cloud rather than a photographic texture.
		float lit = smoothstep(lo + 0.02, lo + 0.30, density);
		vec3 cloud = mix(cloud_shadow_color, cloud_color, lit);
		// Faint rim brightening where the layer faces the sun.
		cloud += sun_color * pow(max(sun_dot, 0.0), 6.0) * 0.18;

		col = mix(col, cloud, mask * cloud_opacity);
	}

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
