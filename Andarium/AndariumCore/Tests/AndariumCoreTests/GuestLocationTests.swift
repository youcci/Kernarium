// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
@testable import AndariumCore

struct GuestLocationTests {
    private func fix(
        latitude: Double = 52.5, longitude: Double = -0.25, horizontalAccuracy: Double = 8,
        altitude: Double = 64, verticalAccuracy: Double = 4,
        speed: Double = 1.5, speedAccuracy: Double = 0.5,
        course: Double = 90, courseAccuracy: Double = 2,
        time: Date = Date(timeIntervalSince1970: 1_700_000_000.25)
    ) -> LocationFix? {
        LocationFix(
            latitude: latitude, longitude: longitude, horizontalAccuracy: horizontalAccuracy,
            altitude: altitude, verticalAccuracy: verticalAccuracy,
            speed: speed, speedAccuracy: speedAccuracy,
            course: course, courseAccuracy: courseAccuracy, time: time)
    }

    @Test func aFullFixIsTheWireFixture() throws {
        // Independent wire fixture: every value present, written out byte by byte.
        var expected: [UInt8] = [0x41, 0x4e, 0x4c, 0x31, 0xff, 0, 0, 0]
        expected += [0, 0, 0, 0, 0, 0x40, 0x4a, 0x40]        // 52.5
        expected += [0, 0, 0, 0, 0, 0, 0xd0, 0xbf]           // -0.25
        expected += [0, 0, 0, 0, 0, 0, 0x50, 0x40]           // 64
        expected += [0, 0, 0, 0, 0, 0, 0xf8, 0x3f]           // 1.5
        expected += [0, 0, 0, 0, 0, 0x80, 0x56, 0x40]        // 90
        expected += [0, 0, 0, 0, 0, 0, 0x20, 0x40]           // 8
        expected += [0, 0, 0, 0, 0, 0, 0x10, 0x40]           // 4
        expected += [0, 0, 0, 0, 0, 0, 0xe0, 0x3f]           // 0.5
        expected += [0, 0, 0, 0, 0, 0, 0, 0x40]              // 2
        expected += [0xfa, 0x68, 0xe5, 0xcf, 0x8b, 0x01, 0, 0] // 1 700 000 000 250 ms
        #expect(try #require(fix()?.encoded) == Data(expected))
        #expect(expected.count == LocationFix.frameSize)
    }

    @Test func whatCoreLocationDoesNotKnowIsLeftOut() throws {
        // No altitude, speed or course: only the position and its accuracy.
        let bare = try #require(fix(verticalAccuracy: -1, speed: -1, course: -1))
        #expect(bare.altitude == nil && bare.speed == nil && bare.bearing == nil)
        let data = try #require(bare.encoded)
        #expect(data[4] == 0x11)
        #expect(data[24..<48].allSatisfy { $0 == 0 } && data[56..<80].allSatisfy { $0 == 0 })
        // A speed and a course without their accuracies.
        let moving = try #require(fix(speedAccuracy: -1, courseAccuracy: -1))
        #expect(try #require(moving.encoded)[4] == 0x3f)
        // An accuracy without its value is not a value.
        #expect(try #require(fix(speed: -1, speedAccuracy: 0.5)).speedAccuracy == nil)
        // Without a horizontal accuracy there is no position.
        #expect(fix(horizontalAccuracy: -1) == nil)
    }

    @Test func aFixTheProtocolCannotSayIsNotSent() throws {
        #expect(try #require(fix(latitude: 91)).encoded == nil)
        #expect(try #require(fix(longitude: -181)).encoded == nil)
        #expect(try #require(fix(altitude: .infinity)).encoded == nil)
        #expect(try #require(fix(latitude: .nan)).encoded == nil)
        #expect(try #require(fix(time: Date(timeIntervalSince1970: -5))).encoded == nil)
    }

    @Test func theDemandFrameSaysWhetherFixesAreWanted() {
        #expect(LocationDemand.wanted(frame: Data([0x41, 0x4e, 0x47, 0x31, 1, 0, 0, 0])) == true)
        #expect(LocationDemand.wanted(frame: Data([0x41, 0x4e, 0x47, 0x31, 0, 0, 0, 0])) == false)
        #expect(LocationDemand.wanted(frame: Data([0x41, 0x4e, 0x47, 0x31, 2, 0, 0, 0])) == nil)
        #expect(LocationDemand.wanted(frame: Data([0x41, 0x4e, 0x43, 0x31, 1, 0, 0, 0])) == nil)
        #expect(LocationDemand.wanted(frame: Data([0x41, 0x4e, 0x47, 0x31, 1, 0, 0])) == nil)
    }

    @Test func theHostLocatesOnlyOnDemandInFrontAndWithPermission() {
        var sharing = LocationSharing()
        #expect(sharing.action == .idle)
        sharing.foreground = true
        #expect(sharing.action == .idle)
        // The first demand asks; nothing is asked before it.
        sharing.wanted = true
        #expect(sharing.action == .ask)
        sharing.authorization = .allowed
        #expect(sharing.action == .locate)
        sharing.foreground = false
        #expect(sharing.action == .idle)
        sharing.foreground = true
        sharing.wanted = false
        #expect(sharing.action == .idle)
        // A refusal is no fixes, and is not asked again.
        sharing.wanted = true
        sharing.authorization = .refused
        #expect(sharing.action == .idle)
    }
}
