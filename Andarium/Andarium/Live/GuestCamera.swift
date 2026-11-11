// SPDX-License-Identifier: GPL-2.0-or-later

import AndariumCore
import AVFoundation
import Foundation

private nonisolated struct CameraConnector: GuestStreamOpener {
    func openStream() throws -> Int32 {
        let descriptor = kernarium_runtime_loader_connect_vsock(CameraImage.port, 250)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: -descriptor) ?? .EIO) }
        return descriptor
    }
}

/// The capture session and the connection to the guest's camera provider.
/// The provider asks for each picture and gets the latest one, or a black
/// one while the camera has none; `opened` hears which camera the provider
/// says Android has open, and nil when the connection ends.
private nonisolated final class CameraFeed: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    /// Starting and stopping a session blocks, so both happen here, in order;
    /// the pictures arrive here too. It owns the session and `running`.
    private let queue = DispatchQueue(label: "andarium-guest-camera")
    private var session: AVCaptureSession?
    private var running: CameraFacing?
    private let lock = NSLock()
    private var latest: (camera: CameraFacing, frame: Data)?
    private var stream: GuestFrameStream!

    init(opened: @escaping @Sendable (CameraFacing?) -> Void) {
        super.init()
        stream = GuestFrameStream(
            // An image without the provider is asked again at this pace for
            // as long as it is in front.
            opener: CameraConnector(), frameSize: CameraRequest.frameSize, retryDelay: .seconds(5),
            connectionChanged: { connected in
                // The next connection starts from what the provider says on it.
                if !connected { opened(nil) }
            },
            received: { [weak self] frame in
                guard let request = CameraRequest(frame: frame) else { return false }
                opened(request.camera)
                if request.wantsImage, let camera = request.camera { self?.answer(camera) }
                return true
            })
    }

    func start() { stream.start() }
    func stop() { stream.stop() }

    private func answer(_ camera: CameraFacing) {
        let frame = lock.withLock { latest?.camera == camera ? latest?.frame : nil }
        // The provider waits for the picture it asked for and reads it at once.
        stream.send(frame ?? CameraImage.black(camera), patience: 200)
    }

    /// Runs one camera, or none.
    func capture(_ camera: CameraFacing?) {
        queue.async { [self] in
            if session?.isRunning == true { session?.stopRunning() }
            lock.withLock { latest = nil }
            running = camera
            guard let camera,
                  let device = AVCaptureDevice.default(
                      .builtInWideAngleCamera, for: .video, position: camera == .back ? .back : .front),
                  let input = try? AVCaptureDeviceInput(device: device) else { return }
            let session = session ?? makeSession()
            session.beginConfiguration()
            session.inputs.forEach(session.removeInput)
            if session.canAddInput(input) { session.addInput(input) }
            session.commitConfiguration()
            session.startRunning()
        }
    }

    /// A session that scales to the protocol's size and delivers the two
    /// planes the protocol carries, as the sensor lies.
    private func makeSession() -> AVCaptureSession {
        let session = AVCaptureSession()
        session.sessionPreset = .vga640x480
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(output) { session.addOutput(output) }
        self.session = session
        return session
    }

    func captureOutput(
        _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection
    ) {
        guard let camera = running, let pixels = sampleBuffer.imageBuffer,
              CVPixelBufferGetPlaneCount(pixels) == 2,
              CVPixelBufferGetWidth(pixels) == CameraImage.width,
              CVPixelBufferGetHeight(pixels) == CameraImage.height else { return }
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(pixels, 0)
        let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(pixels, 1)
        let frame = CameraImage.encoded(
            camera: camera,
            luma: UnsafeRawBufferPointer(
                start: CVPixelBufferGetBaseAddressOfPlane(pixels, 0), count: lumaStride * CameraImage.height),
            lumaStride: lumaStride,
            chroma: UnsafeRawBufferPointer(
                start: CVPixelBufferGetBaseAddressOfPlane(pixels, 1), count: chromaStride * CameraImage.height / 2),
            chromaStride: chromaStride)
        guard let frame else { return }
        lock.withLock { latest = (camera, frame) }
    }
}

/// The device's cameras for the running guest. The connection to the guest's
/// camera provider is held while the guest is booted and in front; a camera
/// runs only while the provider says Android has it open (`CameraSharing`),
/// and iOS asks the person the first time that happens. Without permission
/// the guest gets black pictures.
@MainActor
final class GuestCamera {
    private var sharing = CameraSharing()
    private var capturing: CameraFacing?
    private lazy var feed = CameraFeed { [weak self] camera in
        // The main queue keeps what the provider says in the order it arrived.
        DispatchQueue.main.async { self?.demand(camera) }
    }

    init() {
        sharing.authorization = switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .notDetermined: .undetermined
        case .authorized: .allowed
        default: .refused
        }
    }

    func update(foreground: Bool) {
        sharing.foreground = foreground
        if foreground {
            feed.start()
        } else {
            feed.stop()
            sharing.camera = nil
        }
        reconcile()
    }

    private func demand(_ camera: CameraFacing?) {
        let camera = sharing.foreground ? camera : nil
        // The provider names its camera with every picture it asks for.
        guard camera != sharing.camera else { return }
        sharing.camera = camera
        reconcile()
    }

    private func reconcile() {
        var wanted: CameraFacing?
        switch sharing.action {
        case .idle: break
        case .ask:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                Task { @MainActor [weak self] in
                    self?.sharing.authorization = granted ? .allowed : .refused
                    self?.reconcile()
                }
            }
        case .capture(let camera): wanted = camera
        }
        guard wanted != capturing else { return }
        capturing = wanted
        feed.capture(wanted)
    }
}
