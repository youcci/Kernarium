#!/system/bin/sh
# SPDX-License-Identifier: Apache-2.0
#
# Makes Android lay out around what the host's screen hides of the display. A
# host application whose display fills a phone's screen states the cutout in
# the middle of the top edge (a notch or an island) and the radius of the
# corners at every start (ro.boot.kernarium.display_shape,
# "<height>,<width>,<radius>" in dp). Once boot completes this script makes
# them the platform's display cutout and corner radius, through fabricated
# resource overlays, which only root may create. The platform takes the status
# bar's height from the cutout and keeps the bar's content beside it.
#
# The overlays and their enabled state persist, so the script acts only when
# the launch's shape differs from the one it applied last (the marker), and
# disables them when a launch states none. It logs one line (tag
# kernarium_display_shape) for what it did, and nothing here can fail a boot.

tag=kernarium_display_shape
marker=persist.sys.kernarium.display_shape_applied
# Who owns an overlay fabricated through `cmd`.
owner=com.android.shell

note() {
    log -t "$tag" -p i "$*"
}

shape=$(getprop ro.boot.kernarium.display_shape)
[ "$shape" != "$(getprop "$marker")" ] || exit 0

# `cmd overlay fabricate` takes one value, so each resource has its overlay.
# put NAME TARGET RESOURCE TYPE VALUE
put() {
    cmd overlay fabricate --target "$2" --name "$1" "$3" "$4" "$5" >/dev/null 2>&1 &&
        cmd overlay enable --user 0 "$owner:$1" >/dev/null 2>&1
}

drop() {
    cmd overlay disable --user 0 "$owner:$1" >/dev/null 2>&1
}

# A whole number of dp as a resource's dimension value.
dp() {
    printf '0x%x' $((($1 << 8) | 1))
}

if [ -z "$shape" ]; then
    drop KernariumDisplayCutout
    drop KernariumDisplayCorners
    drop KernariumDisplayCornerPadding
    setprop "$marker" ""
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
    drop KernariumDisplayCutout
fi
if [ "$radius" -gt 0 ]; then
    put KernariumDisplayCorners android \
        android:dimen/rounded_corner_radius 0x05 "$(dp "$radius")" || done=
    # How far the status bar keeps its content from a corner. A platform
    # without the resource lays the content out by the radius alone.
    put KernariumDisplayCornerPadding com.android.systemui \
        com.android.systemui:dimen/rounded_corner_content_padding 0x05 \
        "$(dp $((radius / 2)))"
else
    drop KernariumDisplayCorners
    drop KernariumDisplayCornerPadding
fi

if [ -n "$done" ]; then
    setprop "$marker" "$shape"
    note "the display's cutout and corners are $shape, as the host's screen"
else
    # The marker stays, so the next boot tries again.
    note "the platform refused the display shape $shape"
fi
exit 0
