class_name RingsAndCellsWorld
extends GooWorld2D
## The rings-and-cells example's ring world: top-down (no gravity, set in the scene), and
## its bodies never merge or split, so the tank keeps its seven rings however hard the
## creatures shove them.

func may_merge(_a: Goo2D, _b: Goo2D) -> bool:
	return false

func may_split(_body: Goo2D) -> bool:
	return false
