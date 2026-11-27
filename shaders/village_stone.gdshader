shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

uniform vec4 mortar_color : source_color = vec4(0.23, 0.22, 0.21, 1.0);

// A regular laid-stone surface, shaded per tile rather than using thousands of
// individual meshes. World-scale UVs are supplied by the 80 m paving plane.
void fragment() {
    vec2 grid = UV * 64.0;
    vec2 cell = floor(grid);
    vec2 local_uv = fract(grid);
    float edge = min(min(local_uv.x, 1.0 - local_uv.x), min(local_uv.y, 1.0 - local_uv.y));
    float mortar = smoothstep(0.018, 0.034, edge);
    float variation = fract(sin(dot(cell, vec2(127.1, 311.7))) * 43758.5453);
    vec3 stone = mix(vec3(0.38, 0.37, 0.34), vec3(0.53, 0.51, 0.46), variation);
    ALBEDO = mix(mortar_color.rgb, stone, mortar);
    ROUGHNESS = 0.95;
    SPECULAR = 0.15;
}
