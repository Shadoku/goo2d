class_name TwoToneWorld
extends GooWorld2D
## A GooWorld2D whose blobs merge whatever their colours, with
## GooWorld2D.two_tone_merges on (set in two_tone.tscn): a merge of two colours
## makes a blob drawn in both, each on the side its parent came from, the
## division turning with the blob as it rolls. The colours are the default
## merged_colors()' (the same combination merges as usual; any other pair
## takes the two dominant colours), so this world overrides one hook only:
## may_merge(), to let any two blobs merge up to MAX_MERGED_RADIUS.

## Largest radius, in px at GooTuning.unit 1, of a merged blob: two blobs
## whose merge would be bigger just rest against each other, so the box keeps
## a few blobs instead of one.
const MAX_MERGED_RADIUS: float = 110.0

## True when the touching `a` and `b` combine: whatever their colours and
## sizes, as long as the merged blob is no bigger than MAX_MERGED_RADIUS.
func may_merge(a: Goo2D, b: Goo2D) -> bool:
	return GooTuning.merged_radius(a.radius, b.radius) <= MAX_MERGED_RADIUS * GooTuning.unit
