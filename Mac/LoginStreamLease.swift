import Foundation
import Darwin

/// Local coordination only. This file never contains a credential or grants
/// access to the Screen Sharing socket. Both processes run as the same user.
struct LoginStreamLease: Codable {
    let session: UUID
    let updatedAt: TimeInterval
    let active: Bool

    var isFresh: Bool {
        let age = Date().timeIntervalSince1970 - updatedAt
        return (0...18).contains(age)
    }

    struct Store {
        let directory: URL

        static var local: Store? {
            guard let home = getpwuid(getuid())?.pointee.pw_dir else { return nil }
            return Store(directory: URL(fileURLWithPath: String(cString: home), isDirectory: true)
                .appendingPathComponent("Library/Caches/OpenDisplay Login Handoff", isDirectory: true))
        }

        func read(udid: String) -> LoginStreamLease? {
            guard isPrivateDirectory, let url = file(udid),
                  let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
                  let size = (attributes[.size] as? NSNumber)?.intValue, (1..<1024).contains(size),
                  let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(LoginStreamLease.self, from: data)
        }

        func write(_ lease: LoginStreamLease, udid: String) throws {
            guard let url = file(udid) else { return }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            guard isPrivateDirectory else { throw CocoaError(.fileWriteNoPermission) }
            try JSONEncoder().encode(lease).write(to: url, options: .atomic)
        }

        private var isPrivateDirectory: Bool {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: directory.path),
                  attributes[.type] as? FileAttributeType == .typeDirectory,
                  (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
                  let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue else { return false }
            return permissions & 0o077 == 0
        }

        private func file(_ udid: String) -> URL? {
            guard !udid.isEmpty, udid.count <= 80,
                  udid.allSatisfy({ $0.isHexDigit || $0 == "-" }) else { return nil }
            return directory.appendingPathComponent(udid + ".json")
        }
    }
}
