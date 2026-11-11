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
# header and the navigation bar beside a rounded corner and sizes the shade
# header's rows. The platform takes the status bar's height from the cutout and
# keeps the bar's content beside it.
#
# `cmd overlay fabricate` creates strings, colours and integers but no
# dimension, which is why the corner overlay is a built one with one value for
# every phone rather than the screen's own measures.
#
# A fabricated overlay does not survive a system update, so the script keeps no
# record of what it applied: at every boot it reads the cutout and the corner
# overlay's state from the platform and changes only what differs. It logs one
# line (tag kernarium_display_shape) when it changes something, and nothing here
# can fail a boot.

tag=kernarium_display_shape
cutout_resource=android:string/config_mainBuiltInDisplayCutout
# Who owns an overlay fabricated through `cmd`.
cutout_overlay=com.android.shell:KernariumDisplayCutout
corners_overlay=android.kernarium.overlay.corners

note() {
    log -t "$tag" -p i "$*"
}

shape=$(getprop ro.boot.kernarium.display_shape)
height=0
width=0
radius=0
if [ -n "$shape" ]; then
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
fi

# The cutout the display should have: a rectangle in the middle of the top
# edge, where the path's origin is, or none.
wanted_cutout=
if [ "$height" -gt 0 ] && [ "$width" -gt 0 ]; then
    half=$(((width + 1) / 2))
    wanted_cutout="M -$half,0 L -$half,$height L $half,$height L $half,0 Z @dp"
fi
wanted_corners=
[ "$radius" -eq 0 ] || wanted_corners=1

cutout=$(cmd overlay lookup --user 0 android "$cutout_resource" 2>/dev/null)
corners=
case "$(cmd overlay list --user 0 2>/dev/null)" in
    *"[x] $corners_overlay"*) corners=1 ;;
esac
[ "$cutout" != "$wanted_cutout" ] || [ "$corners" != "$wanted_corners" ] || exit 0

done=1
if [ "$cutout" != "$wanted_cutout" ]; then
    if [ -n "$wanted_cutout" ]; then
        cmd overlay fabricate --target android --name KernariumDisplayCutout \
            "$cutout_resource" 0x03 "$wanted_cutout" >/dev/null 2>&1 &&
            cmd overlay enable --user 0 "$cutout_overlay" >/dev/null 2>&1 || done=
    else
        cmd overlay disable --user 0 "$cutout_overlay" >/dev/null 2>&1 || done=
    fi
fi
if [ "$corners" != "$wanted_corners" ]; then
    if [ -n "$wanted_corners" ]; then
        cmd overlay enable --user 0 "$corners_overlay" >/dev/null 2>&1 || done=
    else
        cmd overlay disable --user 0 "$corners_overlay" >/dev/null 2>&1 || done=
    fi
fi

if [ -z "$done" ]; then
    note "the platform refused the display shape ${shape:-of a display nothing is hidden of}"
elif [ -n "$shape" ]; then
    note "the display's cutout and corners are $shape, as the host's screen"
else
    note "the host's screen hides nothing of the display"
fi
exit 0
