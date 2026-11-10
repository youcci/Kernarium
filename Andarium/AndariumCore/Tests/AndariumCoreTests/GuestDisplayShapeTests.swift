// SPDX-License-Identifier: GPL-2.0-or-later

import Testing

@testable import AndariumCore

struct GuestDisplayShapeTests {
    @Test func aDisplayInsideTheSafeAreaHasNoShape() {
        #expect(GuestDisplayShape(topInset: 0) == nil)
        // A status bar alone is no cutout.
        #expect(GuestDisplayShape(topInset: 24) == nil)
        #expect(GuestDisplayShape(topInset: .nan) == nil)
        #expect(GuestDisplayShape(topInset: .infinity) == nil)
    }

    @Test func anIslandIsNarrowAndItsCornersAreAsDeepAsItsInset() throws {
        let shape = try #require(GuestDisplayShape(topInset: 59))
        #expect(shape.cutoutHeight == 59)
        #expect(shape.cutoutWidth == 130)
        #expect(shape.cornerRadius == 59)
        #expect(GuestDisplayShape(topInset: 62)?.cornerRadius == 62)
    }

    @Test func aNotchIsWideAndItsCornersAreTheLargestOfItsClass() throws {
        let shape = try #require(GuestDisplayShape(topInset: 47))
        #expect(shape.cutoutHeight == 47)
        #expect(shape.cutoutWidth == 230)
        #expect(shape.cornerRadius == 54)
    }

    @Test func aFractionalInsetIsRoundedUp() {
        #expect(GuestDisplayShape(topInset: 47.33)?.cutoutHeight == 48)
    }
}
