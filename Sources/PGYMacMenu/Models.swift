import Foundation

struct APIKeyProfile: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var apiKey: String
    var password: String
    var updateTemplate: String

    init(
        id: UUID = UUID(),
        name: String = "",
        apiKey: String = "",
        password: String = "",
        updateTemplate: String = ""
    ) {
        self.id = id
        self.name = name
        self.apiKey = apiKey
        self.password = password
        self.updateTemplate = updateTemplate
    }

    var displayName: String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty {
            return trimmedName
        }
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedKey.isEmpty ? "未命名 API Key" : trimmedKey
    }
}

struct APIKeyProfileRecord: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var updateTemplate: String
}

struct UpdateTemplate: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var content: String

    init(id: UUID = UUID(), name: String = "", content: String = "") {
        self.id = id
        self.name = name
        self.content = content
    }

    var displayName: String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedName.isEmpty ? "未命名模板" : trimmedName
    }
}

struct AppPreferences: Codable, Hashable {
    var aaptPath: String
    var androidSDKPath: String
    var quitAfterSuccessfulUpload: Bool
    var allowMenuBarRunning: Bool
    var showMenuBarIcon: Bool

    init(
        aaptPath: String = "",
        androidSDKPath: String = "",
        quitAfterSuccessfulUpload: Bool = false,
        allowMenuBarRunning: Bool = false,
        showMenuBarIcon: Bool = false
    ) {
        self.aaptPath = aaptPath
        self.androidSDKPath = androidSDKPath
        self.quitAfterSuccessfulUpload = quitAfterSuccessfulUpload
        self.allowMenuBarRunning = allowMenuBarRunning
        self.showMenuBarIcon = allowMenuBarRunning ? showMenuBarIcon : false
    }

    private enum CodingKeys: String, CodingKey {
        case aaptPath
        case androidSDKPath
        case quitAfterSuccessfulUpload
        case allowMenuBarRunning
        case showMenuBarIcon
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        aaptPath = try container.decodeIfPresent(String.self, forKey: .aaptPath) ?? ""
        androidSDKPath = try container.decodeIfPresent(String.self, forKey: .androidSDKPath) ?? ""
        quitAfterSuccessfulUpload = try container.decodeIfPresent(Bool.self, forKey: .quitAfterSuccessfulUpload) ?? false
        allowMenuBarRunning = try container.decodeIfPresent(Bool.self, forKey: .allowMenuBarRunning) ?? false
        let decodedShowMenuBarIcon = try container.decodeIfPresent(Bool.self, forKey: .showMenuBarIcon) ?? false
        showMenuBarIcon = allowMenuBarRunning ? decodedShowMenuBarIcon : false
    }
}

struct ApkFileInfo: Hashable {
    var fileURL: URL
    var fileName: String
    var filePath: String
    var fileSize: String
    var fileModifiedTime: String
    var appName: String
    var packageName: String
    var versionName: String
    var versionCode: String
    var buildConfig: String
    var sdkVersion: String
    var targetSdkVersion: String
    var abi: String

    var nameDisplay: String {
        appName.isEmpty ? fileName : appName
    }

    var versionDisplay: String {
        if versionName.isEmpty && versionCode.isEmpty {
            return "未识别"
        }
        if versionCode.isEmpty {
            return versionName
        }
        if versionName.isEmpty {
            return versionCode
        }
        return "\(versionName) (\(versionCode))"
    }

    var sdkVersionDisplay: String {
        sdkVersion.isEmpty ? "未识别" : sdkVersion
    }

    var targetSdkVersionDisplay: String {
        targetSdkVersion.isEmpty ? "未识别" : targetSdkVersion
    }
}

struct PgyerTokenResponse: Decodable {
    var code: Int
    var message: String?
    var data: PgyerUploadToken?
}

struct PgyerUploadToken: Decodable {
    var key: String
    var endpoint: String
    var params: [String: String]

    private enum CodingKeys: String, CodingKey {
        case key
        case endpoint
        case params
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(String.self, forKey: .key)
        endpoint = try container.decode(String.self, forKey: .endpoint)
        let rawParams = try container.decode([String: JSONPrimitive].self, forKey: .params)
        params = rawParams.compactMapValues(\.stringValue)
    }
}

struct JSONPrimitive: Decodable {
    var stringValue: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            stringValue = nil
        } else if let value = try? container.decode(String.self) {
            stringValue = value
        } else if let value = try? container.decode(Int.self) {
            stringValue = String(value)
        } else if let value = try? container.decode(Double.self) {
            stringValue = String(value)
        } else if let value = try? container.decode(Bool.self) {
            stringValue = value ? "true" : "false"
        } else {
            stringValue = nil
        }
    }
}

struct PgyerResponse: Decodable, Hashable {
    var code: Int
    var message: String?
    var data: PgyerBuildData?
}

struct PgyerBuildData: Decodable, Hashable {
    var buildName: String?
    var buildVersion: String?
    var buildShortcutUrl: String?
    var buildUpdateDescription: String?
    var buildQRCodeURL: String?
    var buildKey: String?
    var buildFileName: String?
    var buildFileKey: String?
    var buildFileSize: String?
    var buildIdentifier: String?
    var buildVersionNo: String?
    var buildDescription: String?
    var buildScreenshots: String?
    var buildIsFirst: String?
    var buildType: String?
    var buildUpdated: String?
    var buildBuildVersion: String?
    var buildCreated: String?
    var buildIsLastest: String?
    var buildIcon: String?

    var appURL: URL? {
        guard let shortcut = buildShortcutUrl?.trimmingCharacters(in: .whitespacesAndNewlines),
              !shortcut.isEmpty else {
            return nil
        }
        if shortcut.hasPrefix("http://") || shortcut.hasPrefix("https://") {
            return URL(string: shortcut)
        }
        return URL(string: "https://www.pgyer.com/\(shortcut)")
    }
}

enum UploadProgress: Sendable {
    case status(String)
    case fileUpload(fraction: Double, text: String)
    case polling(index: Int, total: Int)
}

enum PGYMacMenuError: LocalizedError {
    case invalidAPK
    case missingAPIKey
    case invalidResponse(String)
    case httpStatus(Int, String)
    case stillPublishing

    var errorDescription: String? {
        switch self {
        case .invalidAPK:
            return "文件无效，请选择 APK 文件"
        case .missingAPIKey:
            return "请选择 API Key 配置"
        case .invalidResponse(let message):
            return message
        case .httpStatus(let code, let body):
            return "上传文件失败，HTTP 状态码：\(code)，返回：\(body)"
        case .stillPublishing:
            return "应用仍在发布中，请稍后到蒲公英后台查看"
        }
    }
}

func readableFileSize(_ size: Int64) -> String {
    guard size > 0 else {
        return "0"
    }
    let units = ["B", "kB", "MB", "GB", "TB"]
    let digitGroups = min(Int(log10(Double(size)) / log10(1024.0)), units.count - 1)
    let value = Double(size) / pow(1024.0, Double(digitGroups))
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.maximumFractionDigits = 1
    formatter.minimumFractionDigits = 0
    return "\(formatter.string(from: NSNumber(value: value)) ?? "\(value)") \(units[digitGroups])"
}

func valueOrFallback(_ value: String?, fallback: String = "未返回") -> String {
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? fallback : trimmed
}
