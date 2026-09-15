import Foundation

/// Gcenx Wine builds are x86_64, so Apple Silicon needs Rosetta 2.
public enum Rosetta {
    public enum Status: Sendable, Equatable {
        case notNeeded      // Intel Mac or not macOS
        case installed
        case missing
    }

    public static let installCommand = "softwareupdate --install-rosetta --agree-to-license"

    public static var isAppleSilicon: Bool {
        #if os(macOS)
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 { return value == 1 }
        #if arch(arm64)
        return true
        #else
        return false
        #endif
        #else
        return false
        #endif
    }

    /// Runs `arch -x86_64 /usr/bin/true`; exit 0 means Rosetta can run Intel binaries.
    public static func check() async -> Status {
        #if os(macOS)
        guard isAppleSilicon else { return .notNeeded }
        let spec = CommandSpec(path: "/usr/bin/arch", arguments: ["-x86_64", "/usr/bin/true"], label: "rosetta-check")
        do {
            let result = try await WineProcess.run(spec, check: false)
            return result.succeeded ? .installed : .missing
        } catch {
            return .missing
        }
        #else
        return .notNeeded
        #endif
    }
}
