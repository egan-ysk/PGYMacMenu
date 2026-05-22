import Foundation

enum ApkMetadataReader {
    static func read(fileURL: URL, preferences: AppPreferences) -> ApkFileInfo {
        let attributes = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)) ?? [:]
        let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let modifiedDate = attributes[.modificationDate] as? Date

        var info = ApkFileInfo(
            fileURL: fileURL,
            fileName: fileURL.lastPathComponent,
            filePath: fileURL.path,
            fileSize: readableFileSize(fileSize),
            fileModifiedTime: formatDate(modifiedDate),
            appName: "",
            packageName: "",
            versionName: "",
            versionCode: "",
            buildConfig: "未识别",
            sdkVersion: "",
            targetSdkVersion: "",
            abi: ""
        )

        guard let aaptURL = findAapt(preferences: preferences) else {
            return info
        }
        fillApkInfoFromAapt(aaptURL: aaptURL, apkURL: fileURL, info: &info)
        return info
    }

    private static func fillApkInfoFromAapt(aaptURL: URL, apkURL: URL, info: inout ApkFileInfo) {
        let process = Process()
        process.executableURL = aaptURL
        process.arguments = ["dump", "badging", apkURL.path]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let output = String(data: data, encoding: .utf8) else {
                return
            }
            parseAaptBadging(output, info: &info)
        } catch {
            if process.isRunning {
                process.terminate()
            }
        }
    }

    private static func findAapt(preferences: AppPreferences) -> URL? {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser.path

        if let configuredAapt = resolveConfiguredAapt(preferences.aaptPath, fileManager: fileManager, home: home) {
            return configuredAapt
        }

        var sdkRoots: [String] = []

        let configured = preferences.androidSDKPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !configured.isEmpty {
            sdkRoots.append(configured)
        }
        if let androidHome = ProcessInfo.processInfo.environment["ANDROID_HOME"] {
            sdkRoots.append(androidHome)
        }
        if let androidSDKRoot = ProcessInfo.processInfo.environment["ANDROID_SDK_ROOT"] {
            sdkRoots.append(androidSDKRoot)
        }
        sdkRoots.append("\(home)/Library/Android/sdk")
        sdkRoots.append("\(home)/Android/Sdk")

        for sdkRoot in sdkRoots where !sdkRoot.isEmpty {
            let buildTools = URL(fileURLWithPath: sdkRoot).appendingPathComponent("build-tools")
            guard let versions = try? fileManager.contentsOfDirectory(
                at: buildTools,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }
            for version in versions.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) {
                let candidate = version.appendingPathComponent("aapt")
                if fileManager.isExecutableFile(atPath: candidate.path) {
                    return candidate
                }
            }
        }
        return nil
    }

    private static func resolveConfiguredAapt(_ rawPath: String, fileManager: FileManager, home: String) -> URL? {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let expandedPath: String
        if trimmed == "~" {
            expandedPath = home
        } else if trimmed.hasPrefix("~/") {
            expandedPath = home + String(trimmed.dropFirst())
        } else {
            expandedPath = trimmed
        }

        let configuredURL = URL(fileURLWithPath: expandedPath)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: configuredURL.path, isDirectory: &isDirectory) else {
            return nil
        }

        if !isDirectory.boolValue {
            return fileManager.isExecutableFile(atPath: configuredURL.path) ? configuredURL : nil
        }

        let directAapt = configuredURL.appendingPathComponent("aapt")
        if fileManager.isExecutableFile(atPath: directAapt.path) {
            return directAapt
        }

        let buildTools = configuredURL.appendingPathComponent("build-tools")
        guard let versions = try? fileManager.contentsOfDirectory(
            at: buildTools,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        for version in versions.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) {
            let candidate = version.appendingPathComponent("aapt")
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    private static func parseAaptBadging(_ output: String, info: inout ApkFileInfo) {
        let lines = output.components(separatedBy: .newlines)
        var hasPackageInfo = false
        var isDebuggable = false

        for line in lines {
            if line.hasPrefix("package:") {
                hasPackageInfo = true
                info.packageName = matchValue(pattern: "name='([^']*)'", text: line)
                info.versionCode = matchValue(pattern: "versionCode='([^']*)'", text: line)
                info.versionName = matchValue(pattern: "versionName='([^']*)'", text: line)
            } else if info.appName.isEmpty && line.hasPrefix("application-label") {
                info.appName = matchValue(pattern: "application-label(?:-[^:]+)?:'([^']*)'", text: line)
            } else if line.hasPrefix("application-debuggable") {
                isDebuggable = true
            } else if line.hasPrefix("sdkVersion:") {
                info.sdkVersion = matchValue(pattern: "'([^']*)'", text: line)
            } else if line.hasPrefix("targetSdkVersion:") {
                info.targetSdkVersion = matchValue(pattern: "'([^']*)'", text: line)
            } else if line.hasPrefix("native-code:") {
                info.abi = matchAllValues(pattern: "'([^']*)'", text: line).joined(separator: ", ")
            }
        }

        if hasPackageInfo {
            info.buildConfig = isDebuggable ? "Debug" : "非 Debug"
        }
    }

    private static func matchValue(pattern: String, text: String) -> String {
        matchAllValues(pattern: pattern, text: text).first ?? ""
    }

    private static func matchAllValues(pattern: String, text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let range = Range(match.range(at: 1), in: text) else {
                return nil
            }
            return String(text[range])
        }
    }

    private static func formatDate(_ date: Date?) -> String {
        guard let date else {
            return ""
        }
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }
}
