import Foundation
import CoreGraphics
import Darwin
import ObjectiveC

/// Sidecar owns the display and input session. This bridge only discovers
/// devices and asks macOS to start or stop a session. Resolve the private API
/// at runtime so an OS change cannot prevent OpenDisplay from launching.
@MainActor
final class SystemSidecar {
    struct Device: Identifiable, Equatable {
        let id: String
        let name: String
    }

    enum Failure: LocalizedError {
        case unavailable
        case deviceGone
        case timedOut

        var errorDescription: String? {
            switch self {
            case .unavailable: return "Sidecar is unavailable on this version of macOS."
            case .deviceGone: return "The iPad is no longer available for Sidecar."
            case .timedOut: return "Sidecar did not respond. Check that the iPad is awake and unlocked."
            }
        }
    }

    private let manager: NSObject
    private static let connect = NSSelectorFromString("connectToDevice:completion:")
    private static let disconnect = NSSelectorFromString("disconnectFromDevice:completion:")

    init?() {
        guard dlopen("/System/Library/PrivateFrameworks/SidecarCore.framework/SidecarCore",
                     RTLD_LAZY | RTLD_LOCAL) != nil,
              let managerType = NSClassFromString("SidecarDisplayManager") as? NSObject.Type,
              let factory = class_getClassMethod(managerType, NSSelectorFromString("sharedManager")),
              method_getNumberOfArguments(factory) == 2,
              let manager = managerType.perform(NSSelectorFromString("sharedManager"))?
                .takeUnretainedValue() as? NSObject,
              ["devices", "connectedDevices"].allSatisfy({ manager.responds(to: NSSelectorFromString($0)) }),
              Self.supportsRequest(Self.connect, on: manager),
              Self.supportsRequest(Self.disconnect, on: manager) else { return nil }
        self.manager = manager
    }

    func devices() -> [Device] {
        let values = objects(connected: true) + objects(connected: false)
        var seen = Set<String>()
        return values.compactMap { object -> Device? in
            guard let id = deviceID(object), seen.insert(id).inserted,
                  let name = property("name", of: object) as? String, !name.isEmpty else { return nil }
            return Device(id: id, name: name)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func isConnected(_ device: Device) -> Bool {
        objects(connected: true).contains { deviceID($0) == device.id }
    }

    func setConnected(_ connected: Bool, device: Device) async throws {
        if isConnected(device) == connected { return }
        guard let object = objects(connected: !connected).first(where: { deviceID($0) == device.id })
        else { throw Failure.deviceGone }
        let selector = connected ? Self.connect : Self.disconnect
        guard Self.supportsRequest(selector, on: manager), let imp = manager.method(for: selector)
        else { throw Failure.unavailable }

        let request = Request()
        do {
            try await withCheckedThrowingContinuation { continuation in
                request.continuation = continuation
                request.timeout = Task {
                    do { try await Task.sleep(for: .seconds(15)) } catch { return }
                    request.finish(.failure(Failure.timedOut))
                }
                let completion: @convention(block) (NSError?) -> Void = { error in
                    Task { @MainActor in
                        if let error { request.finish(.failure(error)) }
                        else { request.finish(.success(())) }
                    }
                }
                typealias Call = @convention(c) (NSObject, Selector, NSObject, @convention(block) (NSError?) -> Void) -> Void
                unsafeBitCast(imp, to: Call.self)(manager, selector, object, completion)
            }
        } catch {
            if isConnected(device) == connected { return }
            throw error
        }
        // The callback can precede publication in connectedDevices.
        for _ in 0..<20 {
            if isConnected(device) == connected { return }
            try await Task.sleep(for: .milliseconds(150))
        }
        if isConnected(device) != connected { throw Failure.timedOut }
    }

    private func objects(connected: Bool) -> [NSObject] {
        property(connected ? "connectedDevices" : "devices", of: manager) as? [NSObject] ?? []
    }

    private func deviceID(_ object: NSObject) -> String? {
        let value = property("identifier", of: object)
        if let uuid = value as? UUID { return uuid.uuidString }
        return value as? String
    }

    private func property(_ name: String, of object: NSObject) -> AnyObject? {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue()
    }

    private static func supportsRequest(_ selector: Selector, on object: NSObject) -> Bool {
        guard let cls = object_getClass(object),
              let method = class_getInstanceMethod(cls, selector),
              let raw = method_getTypeEncoding(method) else { return false }
        // Objective-C encodes the stack offsets alongside the argument types.
        return String(cString: raw).filter { !$0.isNumber } == "v@:@@?"
    }

    @MainActor
    private final class Request {
        var continuation: CheckedContinuation<Void, Error>?
        var timeout: Task<Void, Never>?

        func finish(_ result: Result<Void, Error>) {
            guard let continuation else { return }
            self.continuation = nil
            timeout?.cancel()
            timeout = nil
            continuation.resume(with: result)
        }
    }
}

/// The system Sidecar agent needs one other online display on a headless Mac.
/// Keep an existing virtual display online and move the desktop to Sidecar.
@MainActor
enum SidecarDisplayArrangement {
    enum Failure: LocalizedError {
        case displayUnavailable
        case arrangementFailed(CGError)

        var errorDescription: String? {
            switch self {
            case .displayUnavailable:
                return "Sidecar connected, but its display did not become ready."
            case .arrangementFailed(let error):
                return "Could not make Sidecar the main display (\(error.rawValue))."
            }
        }
    }

    static func onlineDisplays() -> Set<CGDirectDisplayID> {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &displays, &count) == .success else { return [] }
        return Set(displays.prefix(Int(count)))
    }

    static func makeSidecarPrimary(excluding existingDisplays: Set<CGDirectDisplayID>) async throws {
        for _ in 0..<40 {
            let ids = onlineDisplays().subtracting(existingDisplays).filter { CGDisplayIsActive($0) == 1 }
            if ids.count == 1, let id = ids.first {
                let previous = CGMainDisplayID()
                if previous == id { return }
                var config: CGDisplayConfigRef?
                let begin = CGBeginDisplayConfiguration(&config)
                guard begin == .success else { throw Failure.arrangementFailed(begin) }
                let movePrevious = CGConfigureDisplayOrigin(config, previous, Int32(CGDisplayBounds(id).width), 0)
                let result = movePrevious == .success ? CGConfigureDisplayOrigin(config, id, 0, 0) : movePrevious
                guard result == .success else {
                    CGCancelDisplayConfiguration(config)
                    throw Failure.arrangementFailed(result)
                }
                let applied = CGCompleteDisplayConfiguration(config, .forSession)
                guard applied == .success else { throw Failure.arrangementFailed(applied) }
                Log.info("Sidecar placed as main display id=\(id); existing display id=\(previous) remains online")
                return
            }
            try await Task.sleep(for: .milliseconds(150))
        }
        throw Failure.displayUnavailable
    }
}
