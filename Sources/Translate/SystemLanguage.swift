import AppKit
import Foundation

enum SystemLanguage {
    struct Result {
        var german: Bool
        var failed: Bool
        var stillOpen: [String]
    }

    static func prefersGerman() -> Bool {
        languages().first?.lowercased().hasPrefix("de") ?? false
    }

    static func toggle() -> Result {
        let current = languages()
        guard let first = current.first else {
            return Result(german: false, failed: true, stillOpen: [])
        }
        let nextGerman = !first.lowercased().hasPrefix("de")
        let primary = nextGerman ? existing(current, prefix: "de") ?? "de-DE" : existing(current, prefix: "en") ?? "en-US"
        let secondary = nextGerman ? existing(current, prefix: "en") ?? "en-US" : existing(current, prefix: "de") ?? "de-DE"
        var ordered = [primary, secondary]
        for code in current where !ordered.contains(where: { $0.caseInsensitiveCompare(code) == .orderedSame }) {
            ordered.append(code)
        }
        run("/usr/bin/defaults", ["write", "NSGlobalDomain", "AppleLanguages", "-array"] + ordered)
        run("/usr/bin/defaults", ["write", "NSGlobalDomain", "AppleLocale", "-string", locale(current: localeValue(), german: nextGerman)])
        let identifier = nextGerman ? "de_DE.UTF-8" : "en_US.UTF-8"
        run("/bin/launchctl", ["setenv", "LANG", identifier])
        run("/bin/launchctl", ["setenv", "LANGUAGE", nextGerman ? "de_DE" : "en_US"])
        updatePinnedLocales(german: nextGerman)
        guard prefersGerman() == nextGerman else {
            return Result(german: prefersGerman(), failed: true, stillOpen: [])
        }
        relaunchInterface()
        let stillOpen = relaunchApplications()
        return Result(german: nextGerman, failed: false, stillOpen: stillOpen)
    }

    private static func languages() -> [String] {
        let output = capture("/usr/bin/defaults", ["read", "NSGlobalDomain", "AppleLanguages"])
        guard let regex = try? NSRegularExpression(pattern: "\"([A-Za-z0-9_-]+)\"") else { return [] }
        let range = NSRange(output.startIndex..., in: output)
        return regex.matches(in: output, range: range).compactMap { match in
            Range(match.range(at: 1), in: output).map { String(output[$0]) }
        }
    }

    private static func localeValue() -> String {
        let output = capture("/usr/bin/defaults", ["read", "NSGlobalDomain", "AppleLocale"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return output.isEmpty ? "en_US" : output
    }

    private static func existing(_ codes: [String], prefix: String) -> String? {
        codes.first { $0.lowercased().hasPrefix(prefix) }
    }

    private static func locale(current: String, german: Bool) -> String {
        let region = current.split(separator: "_", maxSplits: 1).dropFirst().first.map(String.init) ?? "US"
        return "\(german ? "de" : "en")_\(region)"
    }

    private static func updatePinnedLocales(german: Bool) {
        let replacement = german ? "de-DE" : "en-US"
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        guard let folders = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for folder in folders {
            let url = folder.appendingPathComponent("config.json")
            guard var text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            guard let range = text.range(of: #""locale"\s*:\s*"[^"]+""#, options: .regularExpression) else { continue }
            let snippet = String(text[range]).lowercased()
            let pinnedGerman = snippet.contains("\"de")
            let pinnedEnglish = snippet.contains("\"en")
            if german && !pinnedEnglish { continue }
            if !german && !pinnedGerman { continue }
            text.replaceSubrange(range, with: "\"locale\": \"\(replacement)\"")
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private static func relaunchInterface() {
        for name in ["Finder", "Dock", "ControlCenter", "SystemUIServer"] {
            run("/usr/bin/killall", [name])
        }
    }

    private static func relaunchApplications() -> [String] {
        let own = Bundle.main.bundleIdentifier
        let targets = NSWorkspace.shared.runningApplications.compactMap { app -> (NSRunningApplication, URL, String)? in
            guard app.activationPolicy == .regular, app.bundleIdentifier != own, app.bundleIdentifier != "com.apple.finder", let url = app.bundleURL else {
                return nil
            }
            let name = app.localizedName ?? url.deletingPathExtension().lastPathComponent
            return (app, url, name)
        }
        for (app, _, _) in targets {
            app.terminate()
        }
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline && targets.contains(where: { !$0.0.isTerminated }) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        var stillOpen: [String] = []
        for (app, url, name) in targets {
            if app.isTerminated {
                NSWorkspace.shared.open(url)
            } else {
                stillOpen.append(name)
            }
        }
        return stillOpen
    }

    @discardableResult
    private static func run(_ path: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return 1
        }
    }

    private static func capture(_ path: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }
}
