class_name ShadersWorld
extends GooWorld2D
## One column of the `shaders` example: a GooWorld2D whose merges stay within
## the drops' range of sizes, so a column of a few hundred px shows several
## bodies side by side instead of one that fills it. Two shapes merge flat face
## to flat face whatever their sizes by the default rule (GooWorld2D.can_merge());
## this caps those too.

## The largest body a merge may make, px (radius).
@export var max_merged_radius: float = 140.0

func may_merge(a: Goo2D, b: Goo2D) -> bool:
	if GooTuning.merged_radius(a.radius, b.radius) > max_merged_radius:
		return false
	return can_merge(a, b)
