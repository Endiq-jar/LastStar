// Shared wind model for every foliage material in Last Star.
//
// This is a Godot 4 shader include (`.gdshaderinc`), which is included with
// `#include "res://..."` and compiled inline - no extra pass, no extra draw.
//
// The model is deliberately the cheapest thing that still looks alive:
//
//   * A vertex displaced by a sinusoid driven by WORLD position, not local
//     position. Local-space wind makes every instance sway in lockstep, which
//     reads as the whole field pulsing; world-space means neighbouring tufts
//     are already out of phase and the meadow ripples.
//   * A second, slower, larger-wavelength term for gusts, so the field has
//     broad rolling motion on top of the per-blade flutter.
//   * Displacement weighted by height up the blade, so roots stay pinned and
//     tips move most. A leaf that slides at the root looks like it is floating.
//   * A soft player push: a radial falloff around PLAYER_POS that bends grass
//     away from the character. It is a pure vertex operation - no physics, no
//     per-blade script - so it costs nothing at runtime.

uniform float wind_strength : hint_range(0.0, 2.0) = 0.22;
uniform float wind_speed : hint_range(0.0, 5.0) = 1.35;
uniform float gust_strength : hint_range(0.0, 2.0) = 0.35;
uniform vec2 wind_direction = vec2(0.82, 0.57);
// Radius in metres over which the character pushes foliage aside.
uniform float player_push_radius : hint_range(0.0, 4.0) = 0.85;
uniform float player_push_strength : hint_range(0.0, 1.5) = 0.55;
// World position of the character. Game-logic pushes this; see
// scripts/performance/vegetation_wind.gd.
uniform vec3 player_world_pos = vec3(0.0, -9999.0, 0.0);

// Returns the world-space offset to add to a vertex.
vec3 wind_offset(vec3 world_pos, float local_height, float height_norm, float t) {
	float h = clamp(height_norm, 0.0, 1.0);
	// Height weighting: roots barely move, tips move fully. Squaring makes the
	// bend read as an arc rather than a shear.
	float bend = h * h;

	// Flutter: per-plant phase from world XZ.
	float phase = dot(world_pos.xz, vec2(0.37, 0.29));
	float flutter = sin(t * wind_speed + phase) * wind_strength;

	// Gust: a much longer wavelength travelling along the wind direction, so
	// whole sections of the meadow lean together.
	float gust_phase = dot(world_pos.xz, wind_direction) * 0.021 - t * wind_speed * 0.31;
	float gust = sin(gust_phase) * gust_strength;

	vec3 dir = vec3(wind_direction.x, 0.0, wind_direction.y);
	// Slight vertical dip as it bends, so blades shorten rather than stretch.
	vec3 offset = dir * ((flutter + gust) * bend * local_height);
	offset.y = -abs(flutter + gust) * bend * local_height * 0.18;

	// Character push: bend away from the player, falling off with distance.
	vec3 to_player = world_pos - player_world_pos;
	to_player.y = 0.0;
	float pd = length(to_player);
	if (pd < player_push_radius && pd > 0.0001) {
		float push = 1.0 - (pd / player_push_radius);
		push *= push;
		offset += (to_player / pd) * push * player_push_strength * bend * local_height;
	}
	return offset;
}
