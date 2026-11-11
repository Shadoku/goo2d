class_name Health
extends RefCounted
## Example of a testable game-logic class: plain data plus signals, no scene tree
## dependency. Delete it once the project has real code, together with its test.

signal changed(current: int, maximum: int)
signal died

var maximum: int
var current: int

func _init(max_value: int = 100) -> void:
	maximum = maxi(max_value, 1)
	current = maximum

func damage(amount: int) -> void:
	if amount <= 0 or current <= 0:
		return
	current = maxi(current - amount, 0)
	changed.emit(current, maximum)
	if current == 0:
		died.emit()

func heal(amount: int) -> void:
	if amount <= 0 or current >= maximum:
		return
	current = mini(current + amount, maximum)
	changed.emit(current, maximum)

func is_alive() -> bool:
	return current > 0
