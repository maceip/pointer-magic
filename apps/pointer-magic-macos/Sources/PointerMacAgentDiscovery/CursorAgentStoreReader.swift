import Darwin
import Foundation
import SQLite3

public struct CursorAgentStoreReaderConfiguration: Hashable, Sendable {
    public let maximumRootReferences: Int
    public let maximumRootBlobBytes: Int
    public let maximumMessageBlobBytes: Int
    public let maximumTextCharacters: Int
    public let maximumLatestLookupReferences: Int
    public let maximumStepsPerTurn: Int
    public let maximumGraphBlobReads: Int
    public let maximumCumulativeBlobBytes: Int
    public let recentActivityWindowNs: UInt64

    public init(
        maximumRootReferences: Int = 8_192,
        maximumRootBlobBytes: Int = 512 * 1_024,
        maximumMessageBlobBytes: Int = 2 * 1_024 * 1_024,
        maximumTextCharacters: Int = 16_384,
        maximumLatestLookupReferences: Int = 2_048,
        maximumStepsPerTurn: Int = 2_048,
        maximumGraphBlobReads: Int = 4_096,
        maximumCumulativeBlobBytes: Int = 32 * 1_024 * 1_024,
        recentActivityWindowNs: UInt64 = 15_000_000_000
    ) {
        self.maximumRootReferences = max(1, min(maximumRootReferences, 32_768))
        self.maximumRootBlobBytes = max(4_096, min(maximumRootBlobBytes, 4 * 1_024 * 1_024))
        self.maximumMessageBlobBytes = max(4_096, min(maximumMessageBlobBytes, 8 * 1_024 * 1_024))
        self.maximumTextCharacters = max(256, min(maximumTextCharacters, 65_536))
        self.maximumLatestLookupReferences = max(1, min(maximumLatestLookupReferences, 8_192))
        self.maximumStepsPerTurn = max(1, min(maximumStepsPerTurn, 8_192))
        self.maximumGraphBlobReads = max(4, min(maximumGraphBlobReads, 16_384))
        self.maximumCumulativeBlobBytes = max(
            max(self.maximumRootBlobBytes, self.maximumMessageBlobBytes),
            max(
                1 * 1_024 * 1_024,
                min(maximumCumulativeBlobBytes, 128 * 1_024 * 1_024)
            )
        )
        self.recentActivityWindowNs = max(
            250_000_000,
            min(recentActivityWindowNs, 5 * 60 * 1_000_000_000)
        )
    }

    public static let `default` = CursorAgentStoreReaderConfiguration()
}

public struct CursorAgentStoreIdentity: Codable, Hashable, Sendable {
    public let device: UInt64
    public let inode: UInt64
    public let agentID: String

    public init(device: UInt64, inode: UInt64, agentID: String) {
        self.device = device
        self.inode = inode
        self.agentID = agentID
    }
}

public enum CursorAgentStoreEventKind: String, Codable, Hashable, Sendable {
    case humanPrompt
    case assistantText
}

public struct CursorAgentStoreEvent: Codable, Hashable, Sendable {
    /// Stable for the lifetime of one `store.db` inode. The host combines this with
    /// the database device/inode before using it as a human-attention cursor.
    public let rowID: Int64
    public let blobID: String
    public let kind: CursorAgentStoreEventKind
    public let text: String

    public init(rowID: Int64, blobID: String, kind: CursorAgentStoreEventKind, text: String) {
        self.rowID = rowID
        self.blobID = blobID
        self.kind = kind
        self.text = text
    }
}

/// Cursor's exact TUI `isGenerating` value is process-local React state and is not
/// persisted. These states intentionally do not contain `idle` or `completed`.
public enum CursorAgentLifecycleState: String, Codable, Hashable, Sendable {
    /// The persisted root contains at least one pending tool-call message.
    case working
    /// The root/WAL changed recently, or a tool completed inside the recent window.
    case activeRecently
    /// No positive activity evidence remains. This is not proof of idle.
    case quiescentUnknown
}

public enum CursorAgentStoreScanKind: String, Codable, Hashable, Sendable {
    case initialReverse
    case incremental
    case rootRewrite
    case replacement
}

public struct CursorAgentStoreCursor: Codable, Hashable, Sendable {
    public let identity: CursorAgentStoreIdentity
    public let latestRootBlobID: String
    public let orderedRootTurnBlobIDs: [String]
    public let maxRowID: Int64
    public let latestHumanBlobID: String?
    public let latestAssistantBlobID: String?
    public let combinedModificationTimeUnixNs: UInt64
    public let lastActivityUnixNs: UInt64

    public init(
        identity: CursorAgentStoreIdentity,
        latestRootBlobID: String,
        orderedRootTurnBlobIDs: [String],
        maxRowID: Int64,
        latestHumanBlobID: String?,
        latestAssistantBlobID: String?,
        combinedModificationTimeUnixNs: UInt64,
        lastActivityUnixNs: UInt64
    ) {
        self.identity = identity
        self.latestRootBlobID = latestRootBlobID
        self.orderedRootTurnBlobIDs = orderedRootTurnBlobIDs
        self.maxRowID = maxRowID
        self.latestHumanBlobID = latestHumanBlobID
        self.latestAssistantBlobID = latestAssistantBlobID
        self.combinedModificationTimeUnixNs = combinedModificationTimeUnixNs
        self.lastActivityUnixNs = lastActivityUnixNs
    }
}

public struct CursorAgentStoreReadResult: Hashable, Sendable {
    public let events: [CursorAgentStoreEvent]
    public let latestHumanPrompt: CursorAgentStoreEvent?
    public let latestVisibleAssistantText: CursorAgentStoreEvent?
    public let lifecycle: CursorAgentLifecycleState
    public let cursor: CursorAgentStoreCursor
    public let combinedModificationTimeUnixNs: UInt64
    public let scanKind: CursorAgentStoreScanKind
    public let replacementDetected: Bool

    public init(
        events: [CursorAgentStoreEvent],
        latestHumanPrompt: CursorAgentStoreEvent?,
        latestVisibleAssistantText: CursorAgentStoreEvent?,
        lifecycle: CursorAgentLifecycleState,
        cursor: CursorAgentStoreCursor,
        combinedModificationTimeUnixNs: UInt64,
        scanKind: CursorAgentStoreScanKind,
        replacementDetected: Bool
    ) {
        self.events = events
        self.latestHumanPrompt = latestHumanPrompt
        self.latestVisibleAssistantText = latestVisibleAssistantText
        self.lifecycle = lifecycle
        self.cursor = cursor
        self.combinedModificationTimeUnixNs = combinedModificationTimeUnixNs
        self.scanKind = scanKind
        self.replacementDetected = replacementDetected
    }
}

public enum CursorAgentStoreReaderError: Error, Hashable, Sendable {
    case storeUnavailable(String)
    case notReadOnly
    case invalidMetadata
    case sessionIdentityMismatch(expected: String, actual: String)
    case rootBlobUnavailable(String)
    case blobLimitReached
    case referenceLimitReached
    case invalidProtobuf
    case sqlite(code: Int32, message: String)
    case storeReplacedDuringRead
}

/// Reads Cursor CLI's content-addressed per-session SQLite store without modifying it.
///
/// The durable graph is:
/// `meta[0] -> ConversationStateStructure(field 8 turns) ->
/// ConversationTurnStructure -> UserMessage / ConversationStep`.
/// Blob row order is never used as conversation order.
public struct CursorAgentStoreReader: Sendable {
    private static let maximumMetadataHexBytes = 128 * 1_024
    private struct StoreStat {
        let device: UInt64
        let inode: UInt64
        let modificationTimeUnixNs: UInt64
    }

    private struct Metadata: Decodable {
        let agentId: String
        let latestRootBlobId: String
    }

    private struct LoadedBlob {
        let rowID: Int64
        let data: Data
    }

    private struct RootState {
        var turnBlobIDs: [String] = []
        var pendingMessages: [String] = []
    }

    private struct AgentTurn {
        let userBlobID: String?
        let stepBlobIDs: [String]
    }

    private enum ProtobufValue {
        case varint(UInt64)
        case fixed(Data)
        case bytes(Data)
    }

    private struct ProtobufField {
        let number: UInt64
        let value: ProtobufValue
    }

    public let configuration: CursorAgentStoreReaderConfiguration

    public init(configuration: CursorAgentStoreReaderConfiguration = .default) {
        self.configuration = configuration
    }

    public func read(
        storeURL: URL,
        cursor previousCursor: CursorAgentStoreCursor? = nil,
        observedAtUnixNs suppliedObservedAtUnixNs: UInt64? = nil
    ) throws -> CursorAgentStoreReadResult {
        let observedAtUnixNs = suppliedObservedAtUnixNs ?? agentUnixTimeNs()
        let path = storeURL.standardizedFileURL.path
        guard let initialStat = Self.fileStat(at: path) else {
            throw CursorAgentStoreReaderError.storeUnavailable(path)
        }

        var connection: OpaquePointer?
        let openCode = sqlite3_open_v2(
            path,
            &connection,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openCode == SQLITE_OK, let connection else {
            let message = connection.map { String(cString: sqlite3_errmsg($0)) } ?? path
            if let connection { sqlite3_close_v2(connection) }
            throw CursorAgentStoreReaderError.sqlite(code: openCode, message: message)
        }
        defer { sqlite3_close_v2(connection) }
        guard sqlite3_db_readonly(connection, "main") == 1 else {
            throw CursorAgentStoreReaderError.notReadOnly
        }
        // Apply the allocation bound before sqlite3_step can materialize any provider-
        // controlled TEXT or BLOB value. Per-column checks below remain the semantic
        // bounds; this connection limit is the earlier process-memory safety rail.
        let sqliteValueLimit = max(
            Self.maximumMetadataHexBytes,
            configuration.maximumRootBlobBytes,
            configuration.maximumMessageBlobBytes
        ) + (256 * 1_024)
        _ = sqlite3_limit(connection, SQLITE_LIMIT_LENGTH, Int32(sqliteValueLimit))
        sqlite3_busy_timeout(connection, 50)
        try Self.execute(connection, sql: "PRAGMA query_only=ON")
        try Self.execute(connection, sql: "BEGIN DEFERRED")
        defer { _ = sqlite3_exec(connection, "ROLLBACK", nil, nil, nil) }

        let metadata = try readMetadata(connection)
        let expectedSessionID = storeURL.deletingLastPathComponent().lastPathComponent.lowercased()
        guard let expectedUUID = UUID(uuidString: expectedSessionID)?.uuidString.lowercased(),
              let actualUUID = UUID(uuidString: metadata.agentId)?.uuidString.lowercased()
        else { throw CursorAgentStoreReaderError.invalidMetadata }
        guard expectedUUID == actualUUID else {
            throw CursorAgentStoreReaderError.sessionIdentityMismatch(
                expected: expectedUUID,
                actual: actualUUID
            )
        }

        let identity = CursorAgentStoreIdentity(
            device: initialStat.device,
            inode: initialStat.inode,
            agentID: actualUUID
        )
        let rootID = metadata.latestRootBlobId.lowercased()
        var root = RootState()
        var cumulativeBlobBytes = 0
        if !rootID.isEmpty {
            guard Self.isSHA256Hex(rootID) else {
                throw CursorAgentStoreReaderError.invalidMetadata
            }
            guard let rootBlob = try loadBlob(
                connection,
                id: rootID,
                maximumBytes: configuration.maximumRootBlobBytes
            ) else {
                throw CursorAgentStoreReaderError.rootBlobUnavailable(rootID)
            }
            cumulativeBlobBytes = rootBlob.data.count
            root = try decodeRoot(rootBlob.data)
        }
        let maxRowID = try readMaxRowID(connection)

        var blobCache: [String: LoadedBlob?] = [:]
        var graphBlobReadCount = 0
        func cachedBlob(_ id: String) throws -> LoadedBlob? {
            if let cached = blobCache[id] { return cached }
            guard graphBlobReadCount < configuration.maximumGraphBlobReads else {
                throw CursorAgentStoreReaderError.referenceLimitReached
            }
            graphBlobReadCount += 1
            let loaded = try loadBlob(
                connection,
                id: id,
                maximumBytes: configuration.maximumMessageBlobBytes
            )
            if let loaded {
                let (nextTotal, overflow) = cumulativeBlobBytes.addingReportingOverflow(
                    loaded.data.count
                )
                guard !overflow,
                      nextTotal <= configuration.maximumCumulativeBlobBytes
                else { throw CursorAgentStoreReaderError.blobLimitReached }
                cumulativeBlobBytes = nextTotal
            }
            blobCache[id] = loaded
            return loaded
        }

        var latestHuman: CursorAgentStoreEvent?
        var latestAssistant: CursorAgentStoreEvent?
        var latestCompletedToolUnixNs: UInt64 = 0
        let lookupCount = min(
            root.turnBlobIDs.count,
            configuration.maximumLatestLookupReferences
        )
        if lookupCount > 0 {
            let lowerBound = root.turnBlobIDs.count - lookupCount
            for turnIndex in stride(
                from: root.turnBlobIDs.count - 1,
                through: lowerBound,
                by: -1
            ) {
                guard latestHuman == nil || latestAssistant == nil ||
                        turnIndex == root.turnBlobIDs.count - 1
                else { break }
                guard let turnBlob = try cachedBlob(root.turnBlobIDs[turnIndex]),
                      let agentTurn = try decodeAgentTurn(turnBlob.data)
                else { continue }

                if latestHuman == nil,
                   let userID = agentTurn.userBlobID,
                   let userBlob = try cachedBlob(userID),
                   let text = try decodeHumanPrompt(
                       userBlob.data,
                       loadBlob: cachedBlob
                   )
                {
                    latestHuman = CursorAgentStoreEvent(
                        rowID: userBlob.rowID,
                        blobID: userID,
                        kind: .humanPrompt,
                        text: text
                    )
                }

                let steps = agentTurn.stepBlobIDs.suffix(configuration.maximumStepsPerTurn)
                for stepID in steps.reversed() {
                    guard let stepBlob = try cachedBlob(stepID) else { continue }
                    let fields = try Self.decodeFields(stepBlob.data)
                    if latestAssistant == nil,
                       let assistantBytes = Self.firstBytes(field: 1, in: fields),
                       let textBytes = Self.firstBytes(
                           field: 1,
                           in: try Self.decodeFields(assistantBytes)
                       ),
                       let rawText = String(data: textBytes, encoding: .utf8),
                       let text = Self.boundedText(
                           rawText,
                           maximumCharacters: configuration.maximumTextCharacters
                       )
                    {
                        latestAssistant = CursorAgentStoreEvent(
                            rowID: stepBlob.rowID,
                            blobID: stepID,
                            kind: .assistantText,
                            text: text
                        )
                    }
                    if turnIndex == root.turnBlobIDs.count - 1,
                       latestCompletedToolUnixNs == 0,
                       let toolBytes = Self.firstBytes(field: 2, in: fields),
                       let completedMs = Self.firstVarint(
                           field: 60,
                           in: try Self.decodeFields(toolBytes)
                       )
                    {
                        latestCompletedToolUnixNs = Self.millisecondsToNanoseconds(completedMs)
                    }
                    if latestAssistant != nil,
                       turnIndex != root.turnBlobIDs.count - 1 || latestCompletedToolUnixNs > 0
                    {
                        break
                    }
                }
            }
        }

        try Self.execute(connection, sql: "COMMIT")
        guard let finalStat = Self.fileStat(at: path),
              finalStat.device == initialStat.device,
              finalStat.inode == initialStat.inode
        else { throw CursorAgentStoreReaderError.storeReplacedDuringRead }
        let walModification = Self.fileStat(at: path + "-wal")?.modificationTimeUnixNs ?? 0
        let combinedModification = max(finalStat.modificationTimeUnixNs, walModification)

        let replacementDetected = previousCursor.map { $0.identity != identity } ?? false
        let scanKind = Self.scanKind(
            previousCursor: previousCursor,
            identity: identity,
            currentTurns: root.turnBlobIDs
        )
        let storeChanged = previousCursor.map { previous in
            previous.identity != identity ||
                previous.latestRootBlobID != rootID ||
                previous.combinedModificationTimeUnixNs != combinedModification
        } ?? false

        var lastActivity = max(combinedModification, latestCompletedToolUnixNs)
        if let previousCursor, !replacementDetected {
            lastActivity = max(lastActivity, previousCursor.lastActivityUnixNs)
            if storeChanged { lastActivity = max(lastActivity, observedAtUnixNs) }
        }
        let lifecycle: CursorAgentLifecycleState
        if !root.pendingMessages.isEmpty {
            lifecycle = .working
            lastActivity = max(lastActivity, observedAtUnixNs)
        } else if observedAtUnixNs <= lastActivity ||
                    observedAtUnixNs - lastActivity <= configuration.recentActivityWindowNs
        {
            lifecycle = .activeRecently
        } else {
            lifecycle = .quiescentUnknown
        }

        var events: [CursorAgentStoreEvent] = []
        if previousCursor?.latestHumanBlobID != latestHuman?.blobID, let latestHuman {
            events.append(latestHuman)
        }
        if previousCursor?.latestAssistantBlobID != latestAssistant?.blobID, let latestAssistant {
            events.append(latestAssistant)
        }
        events.sort { $0.rowID < $1.rowID }

        let cursor = CursorAgentStoreCursor(
            identity: identity,
            latestRootBlobID: rootID,
            orderedRootTurnBlobIDs: root.turnBlobIDs,
            maxRowID: maxRowID,
            latestHumanBlobID: latestHuman?.blobID,
            latestAssistantBlobID: latestAssistant?.blobID,
            combinedModificationTimeUnixNs: combinedModification,
            lastActivityUnixNs: lastActivity
        )
        return CursorAgentStoreReadResult(
            events: events,
            latestHumanPrompt: latestHuman,
            latestVisibleAssistantText: latestAssistant,
            lifecycle: lifecycle,
            cursor: cursor,
            combinedModificationTimeUnixNs: combinedModification,
            scanKind: scanKind,
            replacementDetected: replacementDetected
        )
    }

    private func decodeRoot(_ data: Data) throws -> RootState {
        var result = RootState()
        for field in try Self.decodeFields(data) {
            switch (field.number, field.value) {
            case let (8, .bytes(value)):
                guard value.count == 32 else {
                    throw CursorAgentStoreReaderError.invalidProtobuf
                }
                guard result.turnBlobIDs.count < configuration.maximumRootReferences else {
                    throw CursorAgentStoreReaderError.referenceLimitReached
                }
                result.turnBlobIDs.append(Self.hex(value))
            case let (4, .bytes(value)):
                guard result.pendingMessages.count < configuration.maximumRootReferences else {
                    throw CursorAgentStoreReaderError.referenceLimitReached
                }
                guard let message = String(data: value, encoding: .utf8) else {
                    throw CursorAgentStoreReaderError.invalidProtobuf
                }
                result.pendingMessages.append(message)
            default:
                break
            }
        }
        return result
    }

    /// `ConversationTurnStructure`: field 1 is a nested
    /// `AgentConversationTurnStructure`; field 2 is a shell-only turn.
    private func decodeAgentTurn(_ data: Data) throws -> AgentTurn? {
        let outer = try Self.decodeFields(data)
        guard let bytes = Self.firstBytes(field: 1, in: outer) else { return nil }
        let fields = try Self.decodeFields(bytes)
        let userID = Self.firstBytes(field: 1, in: fields).flatMap { value in
            value.count == 32 ? Self.hex(value) : nil
        }
        var steps: [String] = []
        steps.reserveCapacity(min(fields.count, 64))
        for field in fields where field.number == 2 {
            guard case let .bytes(value) = field.value, value.count == 32 else {
                throw CursorAgentStoreReaderError.invalidProtobuf
            }
            guard steps.count < configuration.maximumStepsPerTurn else {
                throw CursorAgentStoreReaderError.referenceLimitReached
            }
            steps.append(Self.hex(value))
        }
        return AgentTurn(userBlobID: userID, stepBlobIDs: steps)
    }

    /// Rejects Cursor's explicitly simulated user messages. Unlike the old JSON
    /// compatibility shape, a real CLI prompt is direct protobuf field 1 text.
    private func decodeHumanPrompt(
        _ data: Data,
        loadBlob: (String) throws -> LoadedBlob?
    ) throws -> String? {
        let fields = try Self.decodeFields(data)
        if Self.firstVarint(field: 5, in: fields) == 1 { return nil }
        if let textBytes = Self.firstBytes(field: 1, in: fields),
           let rawText = String(data: textBytes, encoding: .utf8),
           let text = Self.boundedText(
               rawText,
               maximumCharacters: configuration.maximumTextCharacters
           )
        {
            return text
        }
        if let textBlobID = Self.firstBytes(field: 18, in: fields),
           textBlobID.count == 32,
           let blob = try loadBlob(Self.hex(textBlobID)),
           let rawText = String(data: blob.data, encoding: .utf8)
        {
            return Self.boundedText(
                rawText,
                maximumCharacters: configuration.maximumTextCharacters
            )
        }
        return nil
    }

    private func readMetadata(_ connection: OpaquePointer) throws -> Metadata {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(
            connection,
            "SELECT value FROM meta WHERE key='0' LIMIT 1",
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else { throw Self.sqliteError(connection) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let bytes = sqlite3_column_text(statement, 0)
        else { throw CursorAgentStoreReaderError.invalidMetadata }
        let byteCount = Int(sqlite3_column_bytes(statement, 0))
        guard byteCount > 0,
              byteCount <= Self.maximumMetadataHexBytes,
              let data = Self.decodeHex(String(
                  decoding: UnsafeBufferPointer(start: bytes, count: byteCount),
                  as: UTF8.self
              )),
              let value = try? JSONDecoder().decode(Metadata.self, from: data)
        else { throw CursorAgentStoreReaderError.invalidMetadata }
        return value
    }

    private func readMaxRowID(_ connection: OpaquePointer) throws -> Int64 {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(
            connection,
            "SELECT COALESCE(MAX(rowid), 0) FROM blobs",
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else { throw Self.sqliteError(connection) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw Self.sqliteError(connection) }
        return sqlite3_column_int64(statement, 0)
    }

    private func loadBlob(
        _ connection: OpaquePointer,
        id: String,
        maximumBytes: Int
    ) throws -> LoadedBlob? {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(
            connection,
            "SELECT rowid, data FROM blobs WHERE id=?1 LIMIT 1",
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else { throw Self.sqliteError(connection) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard sqlite3_bind_text(statement, 1, id, -1, transient) == SQLITE_OK else {
            throw Self.sqliteError(connection)
        }
        let step = sqlite3_step(statement)
        if step == SQLITE_DONE { return nil }
        guard step == SQLITE_ROW else { throw Self.sqliteError(connection) }
        guard sqlite3_column_type(statement, 1) == SQLITE_BLOB else {
            throw CursorAgentStoreReaderError.invalidProtobuf
        }
        let size = Int(sqlite3_column_bytes(statement, 1))
        guard size <= maximumBytes else {
            throw CursorAgentStoreReaderError.blobLimitReached
        }
        if size == 0 {
            return LoadedBlob(rowID: sqlite3_column_int64(statement, 0), data: Data())
        }
        guard let raw = sqlite3_column_blob(statement, 1) else {
            throw CursorAgentStoreReaderError.invalidProtobuf
        }
        return LoadedBlob(
            rowID: sqlite3_column_int64(statement, 0),
            data: Data(bytes: raw, count: size)
        )
    }

    private static func scanKind(
        previousCursor: CursorAgentStoreCursor?,
        identity: CursorAgentStoreIdentity,
        currentTurns: [String]
    ) -> CursorAgentStoreScanKind {
        guard let previousCursor else { return .initialReverse }
        guard previousCursor.identity == identity else { return .replacement }
        let previous = previousCursor.orderedRootTurnBlobIDs
        let common = zip(previous, currentTurns).prefix { $0 == $1 }.count
        if common == previous.count ||
            (previous.count == currentTurns.count && common + 1 == previous.count)
        {
            return .incremental
        }
        return .rootRewrite
    }

    private static func decodeFields(_ data: Data) throws -> [ProtobufField] {
        var cursor = 0
        var fields: [ProtobufField] = []
        fields.reserveCapacity(min(data.count / 8, 128))
        while cursor < data.count {
            guard fields.count < 65_536 else {
                throw CursorAgentStoreReaderError.referenceLimitReached
            }
            let tag = try readVarint(data, cursor: &cursor)
            let number = tag >> 3
            let wire = tag & 0x07
            guard number > 0 else { throw CursorAgentStoreReaderError.invalidProtobuf }
            switch wire {
            case 0:
                fields.append(ProtobufField(
                    number: number,
                    value: .varint(try readVarint(data, cursor: &cursor))
                ))
            case 1:
                fields.append(ProtobufField(
                    number: number,
                    value: .fixed(try readBytes(data, count: 8, cursor: &cursor))
                ))
            case 2:
                let count = try readVarint(data, cursor: &cursor)
                guard count <= UInt64(Int.max) else {
                    throw CursorAgentStoreReaderError.invalidProtobuf
                }
                fields.append(ProtobufField(
                    number: number,
                    value: .bytes(try readBytes(data, count: Int(count), cursor: &cursor))
                ))
            case 5:
                fields.append(ProtobufField(
                    number: number,
                    value: .fixed(try readBytes(data, count: 4, cursor: &cursor))
                ))
            default:
                throw CursorAgentStoreReaderError.invalidProtobuf
            }
        }
        return fields
    }

    private static func firstBytes(field number: UInt64, in fields: [ProtobufField]) -> Data? {
        for field in fields where field.number == number {
            if case let .bytes(value) = field.value { return value }
        }
        return nil
    }

    private static func firstVarint(field number: UInt64, in fields: [ProtobufField]) -> UInt64? {
        for field in fields where field.number == number {
            if case let .varint(value) = field.value { return value }
        }
        return nil
    }

    private static func readVarint(_ data: Data, cursor: inout Int) throws -> UInt64 {
        var result: UInt64 = 0
        for byteIndex in 0 ..< 10 {
            guard cursor < data.count else {
                throw CursorAgentStoreReaderError.invalidProtobuf
            }
            let byte = data[cursor]
            cursor += 1
            if byteIndex == 9 {
                // A UInt64 varint has only one payload bit in its tenth byte.
                guard byte <= 1 else {
                    throw CursorAgentStoreReaderError.invalidProtobuf
                }
                result |= UInt64(byte) << 63
                return result
            }
            result |= UInt64(byte & 0x7F) << UInt64(byteIndex * 7)
            if byte & 0x80 == 0 { return result }
        }
        throw CursorAgentStoreReaderError.invalidProtobuf
    }

    private static func readBytes(
        _ data: Data,
        count: Int,
        cursor: inout Int
    ) throws -> Data {
        guard count >= 0, count <= data.count - cursor else {
            throw CursorAgentStoreReaderError.invalidProtobuf
        }
        let end = cursor + count
        defer { cursor = end }
        return Data(data[cursor ..< end])
    }

    private static func boundedText(_ value: String, maximumCharacters: Int) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.count > maximumCharacters else { return trimmed }
        return String(trimmed.prefix(maximumCharacters - 1)) + "…"
    }

    private static func millisecondsToNanoseconds(_ milliseconds: UInt64) -> UInt64 {
        guard milliseconds <= UInt64.max / 1_000_000 else { return UInt64.max }
        return milliseconds * 1_000_000
    }

    private static func execute(_ connection: OpaquePointer, sql: String) throws {
        let code = sqlite3_exec(connection, sql, nil, nil, nil)
        guard code == SQLITE_OK else { throw sqliteError(connection) }
    }

    private static func sqliteError(_ connection: OpaquePointer) -> CursorAgentStoreReaderError {
        CursorAgentStoreReaderError.sqlite(
            code: sqlite3_extended_errcode(connection),
            message: String(cString: sqlite3_errmsg(connection))
        )
    }

    private static func fileStat(at path: String) -> StoreStat? {
        var value = Darwin.stat()
        guard lstat(path, &value) == 0, (value.st_mode & S_IFMT) == S_IFREG else {
            return nil
        }
        guard let modificationTimeUnixNs = unixNanoseconds(value.st_mtimespec) else {
            return nil
        }
        return StoreStat(
            device: UInt64(truncatingIfNeeded: value.st_dev),
            inode: UInt64(truncatingIfNeeded: value.st_ino),
            modificationTimeUnixNs: modificationTimeUnixNs
        )
    }

    private static func unixNanoseconds(_ value: timespec) -> UInt64? {
        guard value.tv_sec >= 0,
              value.tv_nsec >= 0,
              value.tv_nsec < 1_000_000_000
        else { return nil }
        let seconds = UInt64(value.tv_sec)
        let nanoseconds = UInt64(value.tv_nsec)
        let (base, multiplyOverflow) = seconds.multipliedReportingOverflow(by: 1_000_000_000)
        let (result, addOverflow) = base.addingReportingOverflow(nanoseconds)
        return multiplyOverflow || addOverflow ? nil : result
    }

    private static func decodeHex(_ value: String) -> Data? {
        guard value.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(value.count / 2)
        var index = value.startIndex
        while index < value.endIndex {
            let next = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index ..< next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return Data(bytes)
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private static func isSHA256Hex(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit }
    }
}
