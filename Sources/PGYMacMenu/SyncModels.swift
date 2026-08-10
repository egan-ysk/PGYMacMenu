import Foundation

public enum SyncModelError: LocalizedError, Equatable {
    case unsupportedVersion(Int)
    case datasetMismatch
    case generationOverflow
    case invalidPreferencesRecord
    case duplicateRecordID
    case tooManyRecords

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            return "不支持的同步数据版本：\(version)"
        case .datasetMismatch:
            return "远端同步数据属于另一个数据集"
        case .generationOverflow:
            return "同步数据版本号已达到上限"
        case .invalidPreferencesRecord:
            return "同步偏好记录标识无效"
        case .duplicateRecordID:
            return "同步数据包含重复的记录标识"
        case .tooManyRecords:
            return "同步数据包含过多记录"
        }
    }
}

/// A hybrid logical clock timestamp. Device identity is deliberately kept on
/// `VersionedRecord` so equal timestamps have a deterministic writer tie-break.
public struct HLCRevision: Codable, Hashable, Comparable, Sendable {
    public var wallTimeMilliseconds: Int64
    public var counter: UInt32

    public init(wallTimeMilliseconds: Int64, counter: UInt32 = 0) {
        self.wallTimeMilliseconds = wallTimeMilliseconds
        self.counter = counter
    }

    public static func < (lhs: HLCRevision, rhs: HLCRevision) -> Bool {
        if lhs.wallTimeMilliseconds != rhs.wallTimeMilliseconds {
            return lhs.wallTimeMilliseconds < rhs.wallTimeMilliseconds
        }
        return lhs.counter < rhs.counter
    }

    /// Advances a local HLC while incorporating an optional timestamp observed
    /// from another device.
    public static func next(
        local: HLCRevision?,
        observed: HLCRevision? = nil,
        now: Date = Date()
    ) -> HLCRevision {
        next(
            local: local,
            observed: observed,
            nowMilliseconds: Int64((now.timeIntervalSince1970 * 1_000).rounded(.down))
        )
    }

    /// Injectable-clock form used by stores and deterministic tests.
    public static func next(
        local: HLCRevision?,
        observed: HLCRevision? = nil,
        nowMilliseconds: Int64
    ) -> HLCRevision {
        let localWall = local?.wallTimeMilliseconds ?? Int64.min
        let observedWall = observed?.wallTimeMilliseconds ?? Int64.min
        let wall = max(nowMilliseconds, localWall, observedWall)
        let localIsAtWall = local?.wallTimeMilliseconds == wall
        let observedIsAtWall = observed?.wallTimeMilliseconds == wall

        let baseCounter: UInt32?
        if localIsAtWall && observedIsAtWall {
            baseCounter = max(local?.counter ?? 0, observed?.counter ?? 0)
        } else if localIsAtWall {
            baseCounter = local?.counter
        } else if observedIsAtWall {
            baseCounter = observed?.counter
        } else {
            baseCounter = nil
        }

        guard let baseCounter else {
            return HLCRevision(wallTimeMilliseconds: wall, counter: 0)
        }
        guard baseCounter == UInt32.max else {
            return HLCRevision(wallTimeMilliseconds: wall, counter: baseCounter + 1)
        }
        guard wall < Int64.max else {
            return HLCRevision(wallTimeMilliseconds: wall, counter: UInt32.max)
        }
        return HLCRevision(wallTimeMilliseconds: wall + 1, counter: 0)
    }
}

/// A single synchronizable value. `order` is immutable for the lifetime of the
/// UUID. A nil value is a permanent tombstone and must never be garbage-collected.
public struct VersionedRecord<Value: Codable & Hashable & Sendable>: Codable, Hashable, Sendable {
    public let id: UUID
    public let order: Int64
    public var revision: HLCRevision
    public var writerDeviceID: String
    public var value: Value?

    public init(
        id: UUID,
        order: Int64,
        revision: HLCRevision,
        writerDeviceID: String,
        value: Value?
    ) {
        self.id = id
        self.order = order
        self.revision = revision
        self.writerDeviceID = writerDeviceID
        self.value = value
    }

    public var isTombstone: Bool {
        value == nil
    }

    public static func tombstone(
        id: UUID,
        order: Int64,
        revision: HLCRevision,
        writerDeviceID: String
    ) -> Self {
        Self(
            id: id,
            order: order,
            revision: revision,
            writerDeviceID: writerDeviceID,
            value: nil
        )
    }
}

public struct SyncAPIKeyProfileValue: Codable, Hashable, Sendable {
    public var name: String
    public var apiKey: String
    public var password: String
    public var updateTemplate: String

    public init(name: String, apiKey: String, password: String, updateTemplate: String) {
        self.name = name
        self.apiKey = apiKey
        self.password = password
        self.updateTemplate = updateTemplate
    }
}

public struct SyncUpdateTemplateValue: Codable, Hashable, Sendable {
    public var name: String
    public var content: String

    public init(name: String, content: String) {
        self.name = name
        self.content = content
    }
}

/// Only portable behavioral preferences belong here. Machine-local tool paths
/// intentionally remain outside the synchronization document.
public struct SyncPreferencesValue: Codable, Hashable, Sendable {
    public var quitAfterSuccessfulUpload: Bool
    public var allowMenuBarRunning: Bool
    public var showMenuBarIcon: Bool

    public init(
        quitAfterSuccessfulUpload: Bool,
        allowMenuBarRunning: Bool,
        showMenuBarIcon: Bool
    ) {
        self.quitAfterSuccessfulUpload = quitAfterSuccessfulUpload
        self.allowMenuBarRunning = allowMenuBarRunning
        self.showMenuBarIcon = allowMenuBarRunning ? showMenuBarIcon : false
    }

    private enum CodingKeys: String, CodingKey {
        case quitAfterSuccessfulUpload
        case allowMenuBarRunning
        case showMenuBarIcon
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let allowMenuBarRunning = try container.decode(Bool.self, forKey: .allowMenuBarRunning)
        self.init(
            quitAfterSuccessfulUpload: try container.decode(Bool.self, forKey: .quitAfterSuccessfulUpload),
            allowMenuBarRunning: allowMenuBarRunning,
            showMenuBarIcon: try container.decode(Bool.self, forKey: .showMenuBarIcon)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(quitAfterSuccessfulUpload, forKey: .quitAfterSuccessfulUpload)
        try container.encode(allowMenuBarRunning, forKey: .allowMenuBarRunning)
        try container.encode(allowMenuBarRunning ? showMenuBarIcon : false, forKey: .showMenuBarIcon)
    }
}

public struct SyncDocument: Codable, Hashable, Sendable {
    public static let currentVersion = 1
    public static let preferencesRecordID = UUID(uuidString: "8D3DD7B8-D6E4-4A63-9536-B995BD68FC7A")!
    public static let maximumRecordCount = 10_000

    public var version: Int
    public var datasetID: UUID
    public var generation: UInt64
    public var previousHash: String?
    public var apiKeyProfiles: [VersionedRecord<SyncAPIKeyProfileValue>]
    public var updateTemplates: [VersionedRecord<SyncUpdateTemplateValue>]
    public var preferences: VersionedRecord<SyncPreferencesValue>?

    public init(
        version: Int = SyncDocument.currentVersion,
        datasetID: UUID = UUID(),
        generation: UInt64 = 0,
        previousHash: String? = nil,
        apiKeyProfiles: [VersionedRecord<SyncAPIKeyProfileValue>] = [],
        updateTemplates: [VersionedRecord<SyncUpdateTemplateValue>] = [],
        preferences: VersionedRecord<SyncPreferencesValue>? = nil
    ) {
        self.version = version
        self.datasetID = datasetID
        self.generation = generation
        self.previousHash = previousHash
        self.apiKeyProfiles = apiKeyProfiles
        self.updateTemplates = updateTemplates
        self.preferences = preferences
    }

    /// Commutative, associative merge suitable for retries after an ETag race.
    /// Tombstones are delete-wins forever; re-creation requires a new UUID.
    public func merged(with other: SyncDocument) throws -> SyncDocument {
        try validateVersion()
        try other.validateVersion()
        guard datasetID == other.datasetID else {
            throw SyncModelError.datasetMismatch
        }

        let lhs = try normalized()
        let rhs = try other.normalized()
        let mergedPreviousHash: String?
        if lhs.generation > rhs.generation {
            mergedPreviousHash = lhs.previousHash
        } else if rhs.generation > lhs.generation {
            mergedPreviousHash = rhs.previousHash
        } else {
            mergedPreviousHash = Self.maximumOptional(lhs.previousHash, rhs.previousHash)
        }

        return SyncDocument(
            datasetID: datasetID,
            generation: max(lhs.generation, rhs.generation),
            previousHash: mergedPreviousHash,
            apiKeyProfiles: try Self.mergeRecords(lhs.apiKeyProfiles, rhs.apiKeyProfiles),
            updateTemplates: try Self.mergeRecords(lhs.updateTemplates, rhs.updateTemplates),
            preferences: try Self.mergeOptionalRecord(lhs.preferences, rhs.preferences)
        )
    }

    /// Returns a canonical copy with duplicate IDs collapsed and record arrays
    /// sorted by immutable order, then UUID.
    public func normalized() throws -> SyncDocument {
        try validateVersion()
        guard apiKeyProfiles.count <= Self.maximumRecordCount,
              updateTemplates.count <= Self.maximumRecordCount,
              apiKeyProfiles.count + updateTemplates.count <= Self.maximumRecordCount else {
            throw SyncModelError.tooManyRecords
        }
        guard Set(apiKeyProfiles.map(\.id)).count == apiKeyProfiles.count,
              Set(updateTemplates.map(\.id)).count == updateTemplates.count else {
            throw SyncModelError.duplicateRecordID
        }
        if let preferences, preferences.id != Self.preferencesRecordID {
            throw SyncModelError.invalidPreferencesRecord
        }
        return SyncDocument(
            datasetID: datasetID,
            generation: generation,
            previousHash: previousHash,
            apiKeyProfiles: try Self.mergeRecords(apiKeyProfiles, []),
            updateTemplates: try Self.mergeRecords(updateTemplates, []),
            preferences: preferences
        )
    }

    public func canonicalData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(normalized())
    }

    /// Advances lineage after a successful pull/merge. The supplied hash must
    /// be the canonical hash of the remote generation used as the upload base.
    public func nextGeneration(previousHash: String?) throws -> SyncDocument {
        guard generation < UInt64.max else {
            throw SyncModelError.generationOverflow
        }
        var result = try normalized()
        result.generation += 1
        result.previousHash = previousHash
        return result
    }

    private func validateVersion() throws {
        guard version == Self.currentVersion else {
            throw SyncModelError.unsupportedVersion(version)
        }
    }

    private static func mergeRecords<Value>(
        _ lhs: [VersionedRecord<Value>],
        _ rhs: [VersionedRecord<Value>]
    ) throws -> [VersionedRecord<Value>] where Value: Codable & Hashable & Sendable {
        var records: [UUID: VersionedRecord<Value>] = [:]
        for record in lhs + rhs {
            if let existing = records[record.id] {
                records[record.id] = try preferred(existing, record)
            } else {
                records[record.id] = record
            }
        }
        return records.values.sorted(by: orderedBefore)
    }

    private static func mergeOptionalRecord<Value>(
        _ lhs: VersionedRecord<Value>?,
        _ rhs: VersionedRecord<Value>?
    ) throws -> VersionedRecord<Value>? where Value: Codable & Hashable & Sendable {
        switch (lhs, rhs) {
        case (.none, .none):
            return nil
        case (.some(let value), .none), (.none, .some(let value)):
            return value
        case (.some(let lhs), .some(let rhs)):
            return try preferred(lhs, rhs)
        }
    }

    private static func preferred<Value>(
        _ lhs: VersionedRecord<Value>,
        _ rhs: VersionedRecord<Value>
    ) throws -> VersionedRecord<Value> where Value: Codable & Hashable & Sendable {
        precondition(lhs.id == rhs.id)
        let immutableOrder = min(lhs.order, rhs.order)
        let winner: VersionedRecord<Value>

        if lhs.isTombstone != rhs.isTombstone {
            winner = lhs.isTombstone ? lhs : rhs
        } else if lhs.revision != rhs.revision {
            winner = lhs.revision > rhs.revision ? lhs : rhs
        } else if lhs.writerDeviceID != rhs.writerDeviceID {
            winner = lhs.writerDeviceID > rhs.writerDeviceID ? lhs : rhs
        } else {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let lhsData = try encoder.encode(lhs.value)
            let rhsData = try encoder.encode(rhs.value)
            winner = lhsData.lexicographicallyPrecedes(rhsData) ? rhs : lhs
        }

        return VersionedRecord(
            id: winner.id,
            order: immutableOrder,
            revision: winner.revision,
            writerDeviceID: winner.writerDeviceID,
            value: winner.value
        )
    }

    private static func orderedBefore<Value>(
        _ lhs: VersionedRecord<Value>,
        _ rhs: VersionedRecord<Value>
    ) -> Bool where Value: Codable & Hashable & Sendable {
        if lhs.order != rhs.order {
            return lhs.order < rhs.order
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func maximumOptional(_ lhs: String?, _ rhs: String?) -> String? {
        switch (lhs, rhs) {
        case (.none, .none):
            return nil
        case (.some(let value), .none), (.none, .some(let value)):
            return value
        case (.some(let lhs), .some(let rhs)):
            return max(lhs, rhs)
        }
    }
}
