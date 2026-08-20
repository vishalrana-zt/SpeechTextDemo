import Foundation
#if canImport(UIKit)
import UIKit
#endif

final class STTSessionLogger {
    static let shared = STTSessionLogger()

    private let queue = DispatchQueue(label: "STTSessionLogger.queue", qos: .utility)
    private let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private let logsDirectoryURL: URL
    private let currentLogFileURL: URL

    private init() {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        logsDirectoryURL = base.appendingPathComponent("STTLogs", isDirectory: true)

        let sessionName = "stt-session-\(Self.sessionTimestamp()).log"
        currentLogFileURL = logsDirectoryURL.appendingPathComponent(sessionName)

        queue.sync {
            try? FileManager.default.createDirectory(at: logsDirectoryURL, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: currentLogFileURL.path) {
                FileManager.default.createFile(atPath: currentLogFileURL.path, contents: nil)
            }
            writeLine("[STT][logger] session_start file=\(currentLogFileURL.lastPathComponent)")
            writeSessionHeader()
        }
    }

    func log(source: String, message: String) {
        queue.async {
            self.writeLine("[\(source)] \(message)")
        }
    }

    func getCurrentLogFileURL() -> URL {
        queue.sync { currentLogFileURL }
    }

    func createShareSnapshotURL() -> URL? {
        queue.sync {
            let shareDirectoryURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("STTLogsShare", isDirectory: true)
            try? FileManager.default.createDirectory(at: shareDirectoryURL, withIntermediateDirectories: true)

            let baseName = currentLogFileURL.deletingPathExtension().lastPathComponent
            let snapshotName = "\(baseName)-share-\(Self.sessionTimestamp()).txt"
            let snapshotURL = shareDirectoryURL.appendingPathComponent(snapshotName)

            do {
                let data = try Data(contentsOf: currentLogFileURL)
                try data.write(to: snapshotURL, options: .atomic)
                return snapshotURL
            } catch {
                return nil
            }
        }
    }

    func shareableLogText() -> String {
        queue.sync {
            guard let data = try? Data(contentsOf: currentLogFileURL),
                  let text = String(data: data, encoding: .utf8) else {
                return "[STT] Unable to read current log content."
            }
            return text
        }
    }

    func clearCurrentLog() {
        queue.sync {
            try? "".data(using: .utf8)?.write(to: currentLogFileURL, options: .atomic)
            writeLine("[STT][logger] clear_current")
        }
    }

    func clearPreviousLogs() {
        queue.sync {
            let files = (try? FileManager.default.contentsOfDirectory(at: logsDirectoryURL, includingPropertiesForKeys: nil)) ?? []
            for fileURL in files where fileURL != currentLogFileURL {
                try? FileManager.default.removeItem(at: fileURL)
            }
            writeLine("[STT][logger] clear_previous")
        }
    }

    func clearAllLogs() {
        queue.sync {
            let files = (try? FileManager.default.contentsOfDirectory(at: logsDirectoryURL, includingPropertiesForKeys: nil)) ?? []
            for fileURL in files {
                try? FileManager.default.removeItem(at: fileURL)
            }
            FileManager.default.createFile(atPath: currentLogFileURL.path, contents: nil)
            writeLine("[STT][logger] clear_all")
        }
    }

    private func writeLine(_ line: String) {
        let ts = isoFormatter.string(from: Date())
        let fullLine = "\(ts) \(line)\n"
        guard let data = fullLine.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: currentLogFileURL) {
            defer { try? handle.close() }
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } catch {
                return
            }
        } else {
            try? data.write(to: currentLogFileURL, options: .atomic)
        }
    }

    private static func sessionTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    private func writeSessionHeader() {
        let bundle = Bundle.main
        let appVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let buildNumber = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        let bundleID = bundle.bundleIdentifier ?? "unknown"

        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        let locale = Locale.current.identifier
        let preferredLanguage = Locale.preferredLanguages.first ?? "unknown"

        let deviceModel: String
        #if canImport(UIKit)
        deviceModel = Self.hardwareModelIdentifier()
        #else
        deviceModel = "unknown"
        #endif

        writeLine("[STT][session] bundle_id=\(bundleID) app_version=\(appVersion) build=\(buildNumber)")
        writeLine("[STT][session] os=\(osVersion) locale=\(locale) preferred_language=\(preferredLanguage)")
        writeLine("[STT][session] device_model=\(deviceModel)")
    }

    #if canImport(UIKit)
    private static func hardwareModelIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafePointer(to: &systemInfo.machine) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(cString: $0)
            }
        }
    }
    #endif
}
