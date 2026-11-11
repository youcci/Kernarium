// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// One of the host's cameras, by the number the guest's camera provider
/// gives it.
public enum CameraFacing: UInt8, Equatable, Sendable {
    case back = 1
    case front = 2
}

/// A picture of one of the host's cameras, as the guest's camera provider
/// takes it on private vsock port 5559: an 8-byte header ("ANI1", the camera,
/// three zero bytes), then the picture as the sensor lies (its long side is
/// the width): 640 x 480 luma bytes, row after row, then 240 rows of 320
/// Cb, Cr pairs (4:2:0, full range). The provider asks for each picture with a
/// `CameraRequest`.
public enum CameraImage {
    public static let port: UInt32 = 5559
    public static let width = 640
    public static let height = 480
    public static let frameSize = 8 + width * height * 3 / 2

    /// A black picture, for a camera that has none yet.
    public static func black(_ camera: CameraFacing) -> Data {
        header(camera) + Data(repeating: 0, count: width * height)
            + Data(repeating: 128, count: width * height / 2)
    }

    /// The frame of a picture of the protocol's size in two planes, luma and
    /// interleaved chroma, whose rows may be padded; nil for planes that do
    /// not hold one.
    public static func encoded(
        camera: CameraFacing,
        luma: UnsafeRawBufferPointer, lumaStride: Int,
        chroma: UnsafeRawBufferPointer, chromaStride: Int
    ) -> Data? {
        guard lumaStride >= width, chromaStride >= width,
              let lumaStart = luma.baseAddress, let chromaStart = chroma.baseAddress,
              luma.count >= lumaStride * (height - 1) + width,
              chroma.count >= chromaStride * (height / 2 - 1) + width else { return nil }
        var data = header(camera)
        data.reserveCapacity(frameSize)
        for row in 0..<height {
            data.append((lumaStart + row * lumaStride).assumingMemoryBound(to: UInt8.self), count: width)
        }
        for row in 0..<height / 2 {
            data.append((chromaStart + row * chromaStride).assumingMemoryBound(to: UInt8.self), count: width)
        }
        return data
    }

    private static func header(_ camera: CameraFacing) -> Data {
        Data([0x41, 0x4e, 0x49, 0x31, camera.rawValue, 0, 0, 0])
    }
}

/// What the guest's camera provider tells the host over the camera
/// connection: which camera Android has open, and when it wants a picture of
/// it. The provider sends one frame when the host connects, one when a camera
/// is opened or closed, and one for every picture. A frame is 8 bytes: "ANQ1";
/// the open camera (0 none, 1 back, 2 front); 1 to ask for one picture of
/// that camera, else 0; two zero bytes. Anything else is a protocol error.
public struct CameraRequest: Equatable, Sendable {
    public static let frameSize = 8

    /// The camera Android has open.
    public var camera: CameraFacing?
    /// Whether the provider asks for one picture of it.
    public var wantsImage: Bool

    public init?(frame: Data) {
        let bytes = [UInt8](frame)
        guard bytes.count == Self.frameSize, bytes.starts(with: [0x41, 0x4e, 0x51, 0x31]),
              bytes[5] <= 1, bytes[6] == 0, bytes[7] == 0 else { return nil }
        camera = CameraFacing(rawValue: bytes[4])
        wantsImage = bytes[5] == 1
        // A camera is one of the two or none, and a picture is of a camera.
        guard camera != nil || (bytes[4] == 0 && !wantsImage) else { return nil }
    }
}

/// When one of the host's cameras runs for the guest: only while the guest is
/// in front and its camera provider says Android has that camera open, and
/// then only with the person's permission, which is asked for the first time
/// it is needed. A refusal means black pictures; nothing asks again.
public struct CameraSharing: Equatable, Sendable {
    public enum Authorization: Sendable { case undetermined, allowed, refused }
    public enum Action: Equatable, Sendable { case idle, ask, capture(CameraFacing) }

    /// The guest runs a normal boot, in front.
    public var foreground = false
    /// What the provider last said; nil without a connection to it.
    public var camera: CameraFacing?
    public var authorization = Authorization.undetermined

    public init() {}

    public var action: Action {
        guard foreground, let camera else { return .idle }
        return switch authorization {
        case .undetermined: .ask
        case .allowed: .capture(camera)
        case .refused: .idle
        }
    }
}
