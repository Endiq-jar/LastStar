extends CharacterBody3D
## Test-only target for enemy and trap damage without changing player health.
var last_damage := 0.0
func take_damage(amount: float, _from: Vector3) -> void:
	last_damage = amount
