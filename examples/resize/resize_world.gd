class_name ResizeWorld
extends GooWorld2D
## The resize example's world: a GooWorld2D whose bodies never merge, so the
## breathing blobs and the squasher stay four bodies however their sizes come
## close (round bodies of one size merge by default).

## Never: the bodies only resize and deform.
func may_merge(_a: Goo2D, _b: Goo2D) -> bool:
	return false
