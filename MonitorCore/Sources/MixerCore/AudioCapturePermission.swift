import Foundation

/// Audio-capture permission has no public query API; TCC's private preflight is the only way to
/// know the state before a tap silently delivers silence.
public final class AudioCapturePermission: PermissionProviding {
    private typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int32
    private typealias Request = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void

    private static let service = "kTCCServiceAudioCapture" as CFString
    private let preflight: Preflight?
    private let requestAccess: Request?

    public init() {
        let handle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)
        preflight = handle.flatMap { dlsym($0, "TCCAccessPreflight") }.map { unsafeBitCast($0, to: Preflight.self) }
        requestAccess = handle.flatMap { dlsym($0, "TCCAccessRequest") }.map { unsafeBitCast($0, to: Request.self) }
    }

    public var state: PermissionState {
        guard let preflight else { return .granted }
        switch preflight(Self.service, nil) {
        case 0: return .granted
        case 1: return .denied
        default: return .unknown
        }
    }

    public func request(_ completion: @escaping (Bool) -> Void) {
        guard let requestAccess else {
            DispatchQueue.main.async { completion(true) }
            return
        }
        requestAccess(Self.service, nil) { granted in
            DispatchQueue.main.async { completion(granted) }
        }
    }
}
