import AppKit
import AVFoundation

/// Microphone access, checked before recording and shown on the main page when it is off.
enum MicrophonePermission {
    static let deniedMessage = "Blitztext darf das Mikrofon nicht nutzen. Bitte in den Systemeinstellungen unter Datenschutz & Sicherheit > Mikrofon erlauben."

    static var isDenied: Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .denied, .restricted: return true
        default: return false
        }
    }

    static var isAuthorized: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    static func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") else { return }
        NSWorkspace.shared.open(url)
    }
}
