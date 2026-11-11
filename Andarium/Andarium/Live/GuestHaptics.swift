// SPDX-License-Identifier: GPL-2.0-or-later

import AndariumCore
import CoreHaptics
import Foundation

private nonisolated struct VibratorConnector: GuestStreamOpener {
    func openStream() throws -> Int32 {
        let descriptor = kernarium_runtime_loader_connect_vsock(VibrationCommand.port, 250)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: -descriptor) ?? .EIO) }
        return descriptor
    }
}

/// Android's vibrator on the device's haptic engine. The connection to the
/// guest's vibrator HAL is held while the guest is booted and in front, and
/// the engine runs only for what the HAL says to play. A device without
/// haptics (an iPad, a Mac, the Simulator) never connects, and the guest's
/// vibrations do nothing.
@MainActor
final class GuestHaptics {
    private var stream: GuestFrameStream?
    private var engine: CHHapticEngine?
    private var player: (any CHHapticPatternPlayer)?

    init() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        stream = GuestFrameStream(
            // An image without the HAL is asked again at this pace for as
            // long as it is in front.
            opener: VibratorConnector(), frameSize: VibrationCommand.frameSize, retryDelay: .seconds(5)
        ) { [weak self] frame in
            guard let command = VibrationCommand(frame: frame) else { return false }
            // The main queue keeps the commands in the order they arrived.
            DispatchQueue.main.async { self?.play(command.play, amplitude: command.amplitude) }
            return true
        }
    }

    func update(foreground: Bool) {
        guard let stream else { return }
        if foreground {
            stream.start()
        } else {
            stream.stop()
            play(.stop, amplitude: 1)
        }
    }

    private func play(_ play: VibrationCommand.Play, amplitude: Float) {
        try? player?.stop(atTime: CHHapticTimeImmediate)
        player = nil
        let event: CHHapticEvent
        let parameters = [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: amplitude),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5),
        ]
        switch play {
        case .stop: return
        case .tap: event = CHHapticEvent(eventType: .hapticTransient, parameters: parameters, relativeTime: 0)
        case .hold(let seconds):
            event = CHHapticEvent(
                eventType: .hapticContinuous, parameters: parameters, relativeTime: 0, duration: seconds)
        }
        do {
            let engine = try engine ?? makeEngine()
            // The engine shuts itself down when idle; starting a running one does nothing.
            try engine.start()
            let player = try engine.makePlayer(with: CHHapticPattern(events: [event], parameters: []))
            try player.start(atTime: CHHapticTimeImmediate)
            self.player = player
        } catch {
            // The next vibration gets a new engine.
            engine = nil
            print("Andarium: the haptic engine could not play: \(error)")
        }
    }

    private func makeEngine() throws -> CHHapticEngine {
        let engine = try CHHapticEngine()
        engine.isAutoShutdownEnabled = true
        // The system reset the haptic server; the engine's players are gone.
        engine.resetHandler = { [weak self] in
            DispatchQueue.main.async {
                self?.engine = nil
                self?.player = nil
            }
        }
        self.engine = engine
        return engine
    }
}
