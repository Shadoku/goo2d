extends TestCase
## The thrusters example (examples/thrusters/): the blob flies to its first waypoint by its
## thrusters alone; the spiked block, pushed at the wall, is held off it by its tips.

const SCENE := preload("res://examples/thrusters/thrusters.tscn")

var scene: ThrustersExample

func before_each() -> void:
	scene = SCENE.instantiate() as ThrustersExample
	add_child(scene)

func test_the_blob_flies_by_its_thrusters() -> void:
	await wait_frames(2)
	var start := scene.blob.center()
	var target := ThrustersExample.WAYPOINTS[1]
	var reached := -1.0
	var fastest := 0.0
	for f: int in 900:
		await get_tree().physics_frame
		fastest = maxf(fastest, scene.blob.velocity().length())
		if scene.goal != 1 and reached < 0.0:
			reached = f / 60.0
	var firing := 0
	for level: float in scene.blob.thrusters()["levels"]:
		if level > 0.0:
			firing += 1
	print("the blob from %s to its first waypoint %s in %.1f s, up to %.0f px/s; %d thrusters firing at the end" % [start, target, reached, fastest, firing])
	assert_gt(reached, 0.0, "it reached the first waypoint")
	assert_gt(firing, 0)

func test_the_spiked_block_stops_short_of_the_wall() -> void:
	var wall := 1860.0
	var nearest := INF
	var tip_hits := 0
	for f: int in int(ThrustersExample.BLOCK_RUN * 60.0) - 5:
		await get_tree().physics_frame
		for c: Dictionary in scene.block.contacts():
			if c["tip"] and c["kind"] == GooCellCreature.Touch.WALL:
				tip_hits += 1
	var p := scene.block.positions()
	var r := scene.block.radii()
	for i: int in p.size():
		nearest = minf(nearest, wall - p[i].x - r[i])
	var reach := (ThrustersExample.TIP_LENGTH + ThrustersExample.TIP_RADIUS - 1.0) * ThrustersExample.RADIUS
	print("the spiked block against the wall: its cells %.1f px short (its tips reach %.1f px past them), %d tip contacts with the wall" % [nearest, reach, tip_hits])
	assert_gt(tip_hits, 0, "its tips met the wall")
	assert_gt(nearest, 0.6 * reach, "held off by them")
