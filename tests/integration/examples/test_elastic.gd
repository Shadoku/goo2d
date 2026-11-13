extends TestCase
## The elastic example (examples/elastic/): the thrown blob flattens on the wall and rounds
## out, the worm bends round the blow, the head-led ship bends into its turn where the stick
## does not, and the jelly squeezes through the gap.

const SCENE := preload("res://examples/elastic/elastic.tscn")

var scene: ElasticExample

func before_each() -> void:
	scene = SCENE.instantiate() as ElasticExample
	add_child(scene)

## The cells' RMS distance from the best rigid fit of `rest` (centred design places).
static func off_design(cr: GooCellCreature, rest: PackedVector2Array) -> float:
	var p := cr.positions()
	var c := Vector2.ZERO
	for q: Vector2 in p:
		c += q
	c /= p.size()
	var sc := 0.0
	var ss := 0.0
	for i: int in p.size():
		sc += rest[i].dot(p[i] - c)
		ss += rest[i].cross(p[i] - c)
	var t := atan2(ss, sc)
	var e := 0.0
	for i: int in p.size():
		e += (c + rest[i].rotated(t) - p[i]).length_squared()
	return sqrt(e / p.size())

static func rest_of(d: GooCellDesign) -> PackedVector2Array:
	var c := Vector2.ZERO
	for q: Vector2 in d.positions:
		c += q
	c /= d.positions.size()
	var out := PackedVector2Array()
	for q: Vector2 in d.positions:
		out.append(q - c)
	return out

func test_the_lanes() -> void:
	var blob_rest := rest_of(GooCellDesign.hex_blob(3, ElasticExample.RADIUS))
	var worm_rest := rest_of(GooCellDesign.hex_worm(16, 5, ElasticExample.RADIUS))
	var ship_rest := rest_of(scene.ship_design())
	var blob_peak := 0.0
	var worm_peak := 0.0
	var led_peak := 0.0
	var stick_peak := 0.0
	var squeezed := 0
	var jelly := scene.jelly
	for f: int in 300:
		await get_tree().physics_frame
		blob_peak = maxf(blob_peak, off_design(scene.blob, blob_rest))
		worm_peak = maxf(worm_peak, off_design(scene.worm, worm_rest))
		led_peak = maxf(led_peak, off_design(scene.led, ship_rest))
		stick_peak = maxf(stick_peak, off_design(scene.stick, ship_rest))
		if scene.jelly != jelly:
			squeezed += 1
			jelly = scene.jelly
	var blob_after := off_design(scene.blob, blob_rest)
	print("off the design (RMS px) at most: the blob %.1f (%.2f after), the worm %.1f, the head-led ship %.1f, the stick %.1f; the jelly through the gap %d time(s) in 5 s" % [blob_peak, blob_after, worm_peak, led_peak, stick_peak, squeezed])
	assert_gt(blob_peak, 3.0, "the blob dents")
	assert_gt(worm_peak, 3.0, "the worm bends")
	assert_gt(led_peak, 2.0 * stick_peak, "the head-led ship bends more than the stick")
	assert_gt(squeezed, 0, "the jelly squeezes through")
