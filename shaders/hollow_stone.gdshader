shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

// World-projected stone avoids stretched UVs on the Last Seal's long walls.
// Only one texture lookup per fragment, including on the mobile renderer.
uniform sampler2D stone_texture : source_color, repeat_enable, filter_linear_mipmap;
uniform vec4 tint : source_color = vec4(0.8, 0.82, 0.9, 1.0);
varying vec3 world_pos;
varying vec3 world_normal;

void vertex() {
    world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
    world_normal = normalize(mat3(MODEL_MATRIX) * NORMAL);
}

void fragment() {
    vec3 n = abs(normalize(world_normal));
    vec2 projected = world_pos.xz;
    if (n.x > n.y && n.x > n.z) {
        projected = world_pos.zy;
    } else if (n.z > n.y) {
        projected = world_pos.xy;
    }
    vec3 stone = texture(stone_texture, projected * 0.30).rgb * tint.rgb;
    ALBEDO = stone;
    // A small baked-looking fill keeps the floor and walls legible even when
    // the compatibility renderer limits the number of local lights.
    EMISSION = stone * 0.13;
    ROUGHNESS = 1.0;
    SPECULAR = 0.05;
}
