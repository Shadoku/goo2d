class_name TestCase
extends Node
## Base class for unit tests. Subclass in tests/**/test_*.gd and write test_* methods.

## Per-test timeout. A test that awaits longer than this fails.
var timeout_sec: float = 10.0
## Set to true inside a test that intentionally triggers engine errors (push_error, ERR_FAIL...).
## Otherwise any ERROR / SCRIPT ERROR printed while the test runs marks it failed.
var allow_errors: bool = false
var _failures: PackedStringArray = []
var _skip_reason: String = ""
var _autofree: Array = []

func before_each() -> void:
	pass

func after_each() -> void:
	pass

func fail(msg: String) -> void:
	_failures.append("%s %s" % [msg, _caller_location()])

func skip(reason: String = "") -> void:
	_skip_reason = reason if reason != "" else "skipped"

func autofree(obj: Object) -> Object:
	_autofree.append(obj)
	return obj

func assert_true(cond: bool, msg: String = "") -> bool:
	if not cond:
		fail(_fmt("assert_true failed", msg))
	return cond

func assert_false(cond: bool, msg: String = "") -> bool:
	if cond:
		fail(_fmt("assert_false failed", msg))
	return not cond

func assert_eq(actual: Variant, expected: Variant, msg: String = "") -> bool:
	if not is_same_value(actual, expected):
		fail(_fmt("assert_eq failed: expected %s, got %s" % [_repr(expected), _repr(actual)], msg))
		return false
	return true

func assert_ne(actual: Variant, unexpected: Variant, msg: String = "") -> bool:
	if is_same_value(actual, unexpected):
		fail(_fmt("assert_ne failed: both were %s" % _repr(actual), msg))
		return false
	return true

func assert_almost_eq(actual: float, expected: float, tolerance: float = 0.00001, msg: String = "") -> bool:
	if absf(actual - expected) > tolerance:
		fail(_fmt("assert_almost_eq failed: expected %s ± %s, got %s" % [expected, tolerance, actual], msg))
		return false
	return true

func assert_gt(a: Variant, b: Variant, msg: String = "") -> bool:
	if not (a > b):
		fail(_fmt("assert_gt failed: %s is not > %s" % [_repr(a), _repr(b)], msg))
		return false
	return true

func assert_lt(a: Variant, b: Variant, msg: String = "") -> bool:
	if not (a < b):
		fail(_fmt("assert_lt failed: %s is not < %s" % [_repr(a), _repr(b)], msg))
		return false
	return true

func assert_null(value: Variant, msg: String = "") -> bool:
	if value != null:
		fail(_fmt("assert_null failed: got %s" % _repr(value), msg))
		return false
	return true

func assert_not_null(value: Variant, msg: String = "") -> bool:
	if value == null:
		fail(_fmt("assert_not_null failed", msg))
		return false
	return true

func assert_has(container: Variant, item: Variant, msg: String = "") -> bool:
	var ok := false
	if container is Array or container is PackedStringArray or container is Dictionary or container is String:
		ok = container.has(item) if not (container is String) else container.contains(item)
	if not ok:
		fail(_fmt("assert_has failed: %s not in %s" % [_repr(item), _repr(container)], msg))
	return ok

## Await a signal with a timeout. Returns true if it fired before the timeout.
func await_signal(sig: Signal, timeout: float = 1.0) -> bool:
	var fired := [false]
	var waiter := func() -> void:
		await sig
		fired[0] = true
	waiter.call()
	var deadline := Time.get_ticks_msec() + int(timeout * 1000.0)
	while not fired[0] and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	return fired[0]

## Wait for a number of frames (physics + process).
func wait_frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame

func wait_seconds(s: float) -> void:
	await get_tree().create_timer(s).timeout

# --- internals -------------------------------------------------------------

func is_same_value(a: Variant, b: Variant) -> bool:
	if typeof(a) != typeof(b):
		# Allow the cross-type comparisons GDScript itself treats as equal:
		# 2 == 2.0, and StringName vs String (node.name is a StringName).
		if (a is int or a is float) and (b is int or b is float):
			return a == b
		if (a is String or a is StringName) and (b is String or b is StringName):
			return String(a) == String(b)
		return false
	return a == b

func _fmt(base: String, msg: String) -> String:
	return base if msg == "" else "%s (%s)" % [base, msg]

func _repr(v: Variant) -> String:
	if v is String:
		return '"%s"' % v
	return var_to_str(v).replace("\n", " ")

func _caller_location() -> String:
	for frame in get_stack():
		var file: String = frame.get("source", "")
		if not file.ends_with("test_case.gd"):
			return "[%s:%d]" % [file.trim_prefix("res://"), frame.get("line", 0)]
	return ""

func _teardown() -> void:
	for obj in _autofree:
		if is_instance_valid(obj):
			if obj is Node:
				obj.free()
			elif obj is Object and not obj is RefCounted:
				obj.free()
	_autofree.clear()
