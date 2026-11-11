class_name LinksWorld
extends GooWorld2D
## The links example's world: top-down (no gravity, set in links.tscn), and
## its bodies never merge, so the creature-like groups keep their parts
## (linked bodies would not merge with each other anyway; this keeps a chain's
## bodies one apart from merging when they touch).

func may_merge(_a: Goo2D, _b: Goo2D) -> bool:
	return false
