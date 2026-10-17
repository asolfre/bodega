#!/bin/sh
# Captures Bodega's main window (any display, even behind others) to $1. Needs Screen Recording.
set -eu
ID=$(osascript -l JavaScript -e '
ObjC.import("CoreGraphics"); ObjC.import("Foundation");
var a = ObjC.castRefToObject($.CGWindowListCopyWindowInfo(0, 0)), id = "";
for (var i = 0; i < a.count; i++) { var w = a.objectAtIndex(i);
  if (ObjC.unwrap(w.objectForKey("kCGWindowOwnerName")) == "Bodega" && ObjC.unwrap(w.objectForKey("kCGWindowName")) == "Bodega")
    id = ObjC.unwrap(w.objectForKey("kCGWindowNumber")); }
id;')
[ -n "$ID" ] || { echo "no Bodega window" >&2; exit 1; }
screencapture -x -o -l"$ID" "$1"
