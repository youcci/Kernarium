#!/system/bin/sh
# SPDX-License-Identifier: Apache-2.0
#
# Makes Android lay out around what the host's screen hides of the display. A
# host application whose display fills a phone's screen states the cutout in
# the middle of the top edge (a notch or an island) and the radius of the
# corners at every start (ro.boot.kernarium.display_shape,
# "<height>,<width>,<radius>" in dp). Once boot completes this script makes the
# cutout the platform's display cutout, through a resource overlay it
# fabricates, which only root may create, and enables the product's corner
# overlay (rro/KernariumCornersOverlay), which pads the status bar, the shade's
# header and the navigation bar beside a rounded corner. The platform takes the
# status bar's height from the cutout and keeps the bar's content beside it.
#
# `cmd overlay fabricate` creates strings, colours and integers but no
# dimension, which is why the padding is a built overlay with one value for
# every phone rather than the screen's own radius.
#
# The overlays and their enabled state persist, so the script acts only when
# the launch's shape differs from the one it applied last (the marker), and
# disables them when a launch states none. It logs one line (tag
# kernarium_display_shape) for what it did, and nothing here can fail a boot.

tag=kernarium_display_shape
marker=persist.sys.kernarium.display_shape_applied
# Who owns an overlay fabricated through `cmd`.
owner=com.android.shell
corners=android.kernarium.overlay.corners

note() {
    log -t "$tag" -p i "$*"
}

shape=$(getprop ro.boot.kernarium.display_shape)
# The marker names the set of overlays as well as the shape, so a guest an
# earlier set was applied to gets this one once.
applied="3:$shape"
[ "$applied" != "$(getprop "$marker")" ] || exit 0

# put NAME TARGET RESOURCE TYPE VALUE
put() {
    cmd overlay fabricate --target "$2" --name "$1" "$3" "$4" "$5" >/dev/null 2>&1 &&
        cmd overlay enable --user 0 "$owner:$1" >/dev/null 2>&1
}

if [ -z "$shape" ]; then
    cmd overlay disable --user 0 "$owner:KernariumDisplayCutout" >/dev/null 2>&1
    cmd overlay disable --user 0 "$corners" >/dev/null 2>&1
    setprop "$marker" "$applied"
    note "the host's screen hides nothing of the display"
    exit 0
fi

# The runtime checks the value too. Nothing else may reach `cmd`.
height=${shape%%,*}
rest=${shape#*,}
width=${rest%%,*}
radius=${rest#*,}
for measure in "$height" "$width" "$radius"; do
    case "$measure" in
        "" | *[!0-9]* | ????*)
            note "ignoring the host's display shape: not three measures"
            exit 0
            ;;
    esac
done
[ "$shape" = "$height,$width,$radius" ] || {
    note "ignoring the host's display shape: not three measures"
    exit 0
}

done=1
if [ "$height" -gt 0 ] && [ "$width" -gt 0 ]; then
    # A rectangle in the middle of the top edge: the path's origin is the
    # middle of the edge.
    half=$(((width + 1) / 2))
    put KernariumDisplayCutout android \
        android:string/config_mainBuiltInDisplayCutout 0x03 \
        "M -$half,0 L -$half,$height L $half,$height L $half,0 Z @dp" || done=
else
    cmd overlay disable --user 0 "$owner:KernariumDisplayCutout" >/dev/null 2>&1
fi
if [ "$radius" -gt 0 ]; then
    cmd overlay enable --user 0 "$corners" >/dev/null 2>&1 || done=
else
    cmd overlay disable --user 0 "$corners" >/dev/null 2>&1
fi

if [ -n "$done" ]; then
    setprop "$marker" "$applied"
    note "the display's cutout and corners are $shape, as the host's screen"
else
    # The marker stays, so the next boot tries again.
    note "the platform refused the display shape $shape"
fi
exit 0
