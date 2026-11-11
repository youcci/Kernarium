#!/system/bin/sh
# SPDX-License-Identifier: Apache-2.0
#
# Makes Android lay out around what the host's screen hides of the display. A
# host application whose display fills a phone's screen states the cutout in
# the middle of the top edge (a notch or an island) and the radius of the
# corners at every start (ro.boot.kernarium.display_shape,
# "<height>,<width>,<radius>" in dp). Once boot completes this script enables
# the product's overlays that fit (rro/): KernariumIslandOverlay or
# KernariumNotchOverlay, which give the display its cutout and the status bar
# its height, and KernariumCornersOverlay, which pads the status bar, the
# shade's header and the navigation bar beside a rounded corner.
#
# The overlays are built ones with one value for each class of phone, not the
# screen's own measures: an overlay created at run time holds no dimension and
# is gone at the next boot, and a cutout that arrives after SystemUI has
# started leaves the status bar's content where it was. An enabled overlay
# stays enabled, so on every boot but the first the script finds nothing to
# change. It reads the overlays' state from the platform, changes only what
# differs, and disables them when a launch states no shape. It logs one line
# (tag kernarium_display_shape) when it changes something, and nothing here can
# fail a boot.

tag=kernarium_display_shape
island=android.kernarium.overlay.island
notch=android.kernarium.overlay.notch
corners=android.kernarium.overlay.corners

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

# The cutout's class: an island insets the top by 59 dp or more, a notch by
# less (the host application draws the same line, GuestDisplayShape).
wanted_cutout=
if [ "$height" -gt 0 ] && [ "$width" -gt 0 ]; then
    if [ "$height" -ge 55 ]; then
        wanted_cutout=$island
    else
        wanted_cutout=$notch
    fi
fi
wanted_corners=
[ "$radius" -eq 0 ] || wanted_corners=$corners

enabled=$(cmd overlay list --user 0 2>/dev/null)
changed=
failed=
# set_overlay PACKAGE WANTED: enable PACKAGE when it is the wanted one, disable
# it when it is not, and leave it when it already is as wanted.
set_overlay() {
    case "$enabled" in
        *"[x] $1"*) is=1 ;;
        *) is= ;;
    esac
    if [ "$1" = "$2" ]; then
        [ -z "$is" ] || return 0
        action=enable
    else
        [ -n "$is" ] || return 0
        action=disable
    fi
    changed=1
    cmd overlay "$action" --user 0 "$1" >/dev/null 2>&1 || failed=1
}

# The cutout first and the corners after it: the status bar lays its content
# out anew on the change that follows the cutout's.
set_overlay "$island" "$wanted_cutout"
set_overlay "$notch" "$wanted_cutout"
set_overlay "$corners" "$wanted_corners"

[ -n "$changed" ] || exit 0
if [ -n "$failed" ]; then
    note "the platform refused the display shape ${shape:-of a display nothing is hidden of}"
elif [ -n "$shape" ]; then
    note "the display's cutout and corners are $shape, as the host's screen"
else
    note "the host's screen hides nothing of the display"
fi
exit 0
