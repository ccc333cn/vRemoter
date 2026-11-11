import Foundation
import Darwin

enum LaunchAtLogin {
    private static let label = "local.simaqingfeng.vRemote.login"

    private static var agentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: agentURL.path)
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try install()
        } else {
            uninstall()
        }
    }

    /// The login item stores the app path from when it was turned on, so it
    /// can keep launching an old copy after the app moves or is reinstalled.
    /// Point it at this copy when this copy is the installed one, or when the
    /// recorded app no longer exists. A build run from elsewhere never takes
    /// over an installed app's login item.
    static func repairPathIfNeeded() {
        guard isEnabled,
              let data = try? Data(contentsOf: agentURL),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data,
                  format: nil
              ) as? [String: Any],
              let arguments = plist["ProgramArguments"] as? [String],
              let recordedPath = arguments.last
        else { return }

        let bundlePath = Bundle.main.bundlePath
        guard bundlePath.hasSuffix(".app"), recordedPath != bundlePath else { return }
        let installed = bundlePath.hasPrefix("/Applications/")
            || bundlePath.hasPrefix(
                FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Applications").path + "/"
            )
        guard installed
                || !FileManager.default.fileExists(atPath: recordedPath)
        else { return }

        var updated = plist
        updated["ProgramArguments"] = ["/usr/bin/open", bundlePath]
        guard let output = try? PropertyListSerialization.data(
            fromPropertyList: updated,
            format: .xml,
            options: 0
        ) else { return }
        // launchd reads the file again at the next login; reloading now
        // would only open this already running app a second time.
        do {
            try output.write(to: agentURL, options: .atomic)
            print("[LOGIN] login item moved from \(recordedPath) to \(bundlePath)")
        } catch {
            print("[LOGIN] could not update login item: \(error.localizedDescription)")
        }
    }

    private static func install() throws {
        let bundlePath = Bundle.main.bundlePath
        guard bundlePath.hasSuffix(".app") else {
            throw NSError(
                domain: "vRemote.LaunchAtLogin",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "无法取得应用路径"]
            )
        }

        let directory = agentURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": ["/usr/bin/open", bundlePath],
            "RunAtLoad": true,
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try data.write(to: agentURL, options: .atomic)

        // Register immediately. Launch Services reuses the existing app.
        _ = runLaunchctl(["bootout", domainTarget, agentURL.path])
        let result = runLaunchctl(["bootstrap", domainTarget, agentURL.path])
        if result != 0 {
            try? FileManager.default.removeItem(at: agentURL)
            throw NSError(
                domain: "vRemote.LaunchAtLogin",
                code: Int(result),
                userInfo: [NSLocalizedDescriptionKey: "无法注册登录启动项"]
            )
        }
    }

    private static func uninstall() {
        _ = runLaunchctl(["bootout", domainTarget, agentURL.path])
        try? FileManager.default.removeItem(at: agentURL)
    }

    private static var domainTarget: String {
        "gui/\(getuid())"
    }

    @discardableResult
    private static func runLaunchctl(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }
}
