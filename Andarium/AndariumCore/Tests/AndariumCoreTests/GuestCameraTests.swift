// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
@testable import AndariumCore

struct GuestCameraTests {
    @Test func aRequestNamesTheOpenCameraAndAsksForAPicture() throws {
        // Independent wire fixtures.
        let picture = try #require(CameraRequest(frame: Data([0x41, 0x4e, 0x51, 0x31, 1, 1, 0, 0])))
        #expect(picture.camera == .back && picture.wantsImage)
        let opened = try #require(CameraRequest(frame: Data([0x41, 0x4e, 0x51, 0x31, 2, 0, 0, 0])))
        #expect(opened.camera == .front && !opened.wantsImage)
        let closed = try #require(CameraRequest(frame: Data([0x41, 0x4e, 0x51, 0x31, 0, 0, 0, 0])))
        #expect(closed.camera == nil && !closed.wantsImage)
    }

    @Test func aRequestThatIsNotTheProtocolIsRefused() {
        for bytes: [UInt8] in [
            [0x41, 0x4e, 0x51, 0x32, 1, 1, 0, 0],   // another magic
            [0x41, 0x4e, 0x51, 0x31, 3, 0, 0, 0],   // no such camera
            [0x41, 0x4e, 0x51, 0x31, 0, 1, 0, 0],   // a picture of no camera
            [0x41, 0x4e, 0x51, 0x31, 1, 2, 0, 0],
            [0x41, 0x4e, 0x51, 0x31, 1, 1, 0, 1],
            [0x41, 0x4e, 0x51, 0x31, 1, 1, 0],
        ] {
            #expect(CameraRequest(frame: Data(bytes)) == nil)
        }
    }

    @Test func aPictureIsPackedWithoutThePaddingOfItsRows() throws {
        let lumaStride = 704, chromaStride = 672
        // Every row holds its number, and its padding 0xee.
        var luma = [UInt8](repeating: 0xee, count: lumaStride * CameraImage.height)
        for row in 0..<CameraImage.height {
            for column in 0..<CameraImage.width { luma[row * lumaStride + column] = UInt8(row % 200) }
        }
        var chroma = [UInt8](repeating: 0xee, count: chromaStride * CameraImage.height / 2)
        for row in 0..<CameraImage.height / 2 {
            for column in 0..<CameraImage.width { chroma[row * chromaStride + column] = UInt8((row + 7) % 200) }
        }
        let frame = try #require(luma.withUnsafeBytes { luma in
            chroma.withUnsafeBytes { chroma in
                CameraImage.encoded(
                    camera: .front, luma: luma, lumaStride: lumaStride, chroma: chroma, chromaStride: chromaStride)
            }
        })
        #expect(frame.count == CameraImage.frameSize && CameraImage.frameSize == 460_808)
        #expect([UInt8](frame.prefix(8)) == [0x41, 0x4e, 0x49, 0x31, 2, 0, 0, 0])
        let pixels = [UInt8](frame.dropFirst(8))
        let width = CameraImage.width, height = CameraImage.height
        #expect((0..<height).allSatisfy { row in
            pixels[row * width] == UInt8(row % 200) && pixels[row * width + width - 1] == UInt8(row % 200)
        })
        #expect((0..<height / 2).allSatisfy { row in
            let start = width * height + row * width
            return pixels[start] == UInt8((row + 7) % 200) && pixels[start + width - 1] == UInt8((row + 7) % 200)
        })
        #expect(!pixels.contains(0xee))

        // Planes that do not hold a picture of the protocol's size.
        let short = luma.dropLast(lumaStride)
        #expect(short.withUnsafeBytes { short in
            chroma.withUnsafeBytes { chroma in
                CameraImage.encoded(
                    camera: .back, luma: short, lumaStride: lumaStride, chroma: chroma, chromaStride: chromaStride)
            }
        } == nil)
        #expect(luma.withUnsafeBytes { luma in
            chroma.withUnsafeBytes { chroma in
                CameraImage.encoded(camera: .back, luma: luma, lumaStride: 320, chroma: chroma, chromaStride: chromaStride)
            }
        } == nil)
    }

    @Test func aCameraWithoutAPictureIsBlack() {
        let frame = [UInt8](CameraImage.black(.back))
        #expect(frame.count == CameraImage.frameSize)
        #expect(Array(frame.prefix(8)) == [0x41, 0x4e, 0x49, 0x31, 1, 0, 0, 0])
        let luma = CameraImage.width * CameraImage.height
        #expect(frame[8..<8 + luma].allSatisfy { $0 == 0 } && frame[(8 + luma)...].allSatisfy { $0 == 128 })
    }

    @Test func aCameraRunsOnlyInFrontWhileOpenAndAllowed() {
        var sharing = CameraSharing()
        #expect(sharing.action == .idle)
        sharing.camera = .front
        #expect(sharing.action == .idle)
        sharing.foreground = true
        #expect(sharing.action == .ask)
        sharing.authorization = .refused
        #expect(sharing.action == .idle)
        sharing.authorization = .allowed
        #expect(sharing.action == .capture(.front))
        sharing.camera = nil
        #expect(sharing.action == .idle)
    }
}
