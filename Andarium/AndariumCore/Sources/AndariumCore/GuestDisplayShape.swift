// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// What an iPhone's screen hides of the guest's display once the display
/// fills it: the notch or island in the middle of the top edge, and the
/// rounded corners.
///
/// The runtime states it on the kernel command line at every start
/// (`androidboot.kernarium.display_shape`, the boot request's
/// `android_display_*` fields) and the system image's display shape script
/// enables the overlays that fit it, the cutout of its class and the padding
/// beside a corner, so the status bar stands beside the cutout and clear of
/// the corners
/// (`android/lineage-24/README.md`, "Display shape"). The measures are points,
/// which are Android's density-independent pixels in both display modes.
public struct GuestDisplayShape: Equatable, Sendable {
    public var cutoutHeight: UInt32
    public var cutoutWidth: UInt32
    public var cornerRadius: UInt32

    /// The shape of a display whose top edge reaches `topInset` points above
    /// the screen's safe area, or nil for one the screen hides nothing of: a
    /// display inside the safe area, or a screen with neither notch nor island.
    public init?(topInset: Double) {
        // With the status bar hidden, only a notch or an island insets the top.
        guard topInset.isFinite, topInset >= 30, topInset < 200 else { return nil }
        cutoutHeight = UInt32(topInset.rounded(.up))
        // shortcut: iOS states neither the cutout's width nor the corners'
        // radius, so each is the largest of its class (an island insets the
        // top by 59 points or more, a notch by less), which hides nothing but
        // can pad a little more than a model needs; a table by model would be
        // exact.
        cutoutWidth = topInset >= 55 ? 130 : 230
        cornerRadius = max(cutoutHeight, 54)
    }
}
