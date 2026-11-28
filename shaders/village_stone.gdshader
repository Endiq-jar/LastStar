shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

// One mipmapped 512px texture shared by all settlement paving planes. Each
// repeat covers five metres, so the stones read as small laid cobbles rather
// than giant square slabs. The surface stays a single flat, collision-free mesh.
uniform sampler2D paving_texture : source_color, repeat_enable, filter_linear_mipmap;
uniform vec4 stone_tint : source_color = vec4(0.96, 0.96, 0.93, 1.0);

void fragment() {
    vec3 stone = texture(paving_texture, UV * 22.4).rgb;
    ALBEDO = stone * stone_tint.rgb;
    ROUGHNESS = 0.95;
    SPECULAR = 0.12;
}
