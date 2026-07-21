import Foundation
@testable import PointerMacAgentDiscovery
import SQLite3
import Testing

@Suite("Cursor agent store reader")
struct CursorAgentStoreReaderTests {
    @Test("Reads the real content-addressed protobuf graph in logical turn order")
    func readsRealGraph() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let first = try fixture.appendTurn(
            prompt: "Build the real shelf",
            assistantTexts: ["I am inspecting it.", "The shelf is implemented."]
        )
        _ = try fixture.appendTurn(
            prompt: "generated internal context",
            assistantTexts: [],
            simulated: true
        )
        try fixture.publishRoot()

        let reader = CursorAgentStoreReader(configuration: .init(
            maximumRootReferences: 128,
            maximumLatestLookupReferences: 128,
            recentActivityWindowNs: 1_000_000_000
        ))
        let initial = try reader.read(
            storeURL: fixture.storeURL,
            observedAtUnixNs: fixture.baseTimeUnixNs
        )

        #expect(initial.scanKind == .initialReverse)
        #expect(initial.latestHumanPrompt?.text == "Build the real shelf")
        #expect(initial.latestHumanPrompt?.rowID == first.userRowID)
        #expect(initial.latestVisibleAssistantText?.text == "The shelf is implemented.")
        #expect(initial.cursor.identity.agentID == fixture.sessionID)
        #expect(initial.cursor.orderedRootTurnBlobIDs.count == 2)
        #expect(initial.lifecycle == .quiescentUnknown)

        let followup = try fixture.appendTurn(
            prompt: "Now make the status clearer",
            assistantTexts: []
        )
        try fixture.publishRoot()
        let changed = try reader.read(
            storeURL: fixture.storeURL,
            cursor: initial.cursor,
            observedAtUnixNs: fixture.baseTimeUnixNs + 100_000_000
        )

        #expect(changed.scanKind == .incremental)
        #expect(changed.latestHumanPrompt?.text == "Now make the status clearer")
        #expect(changed.latestHumanPrompt?.rowID == followup.userRowID)
        #expect(changed.events.contains { $0.blobID == followup.userBlobID })
        #expect(changed.cursor.maxRowID > initial.cursor.maxRowID)
    }

    @Test("A current-turn hash replacement stays incremental")
    func currentTurnRewrite() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.appendTurn(prompt: "Ship it", assistantTexts: [])
        try fixture.publishRoot()

        let reader = CursorAgentStoreReader()
        let first = try reader.read(storeURL: fixture.storeURL)
        try fixture.appendAssistantToLatestTurn("Working on it.")
        try fixture.publishRoot()
        let second = try reader.read(storeURL: fixture.storeURL, cursor: first.cursor)

        #expect(second.scanKind == .incremental)
        #expect(second.latestHumanPrompt?.blobID == first.latestHumanPrompt?.blobID)
        #expect(second.latestVisibleAssistantText?.text == "Working on it.")
        #expect(second.events.count == 1)
        #expect(second.events.first?.kind == .assistantText)
    }

    @Test("Lifecycle never invents idle or completion from an empty pending list")
    func conservativeLifecycle() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.appendTurn(prompt: "Run the command", assistantTexts: [])
        try fixture.publishRoot(pendingMessage: [
            "role": "assistant",
            "content": [["type": "tool-call", "toolName": "Shell"]],
        ])

        let reader = CursorAgentStoreReader(configuration: .init(
            recentActivityWindowNs: 1_000_000_000
        ))
        let working = try reader.read(
            storeURL: fixture.storeURL,
            observedAtUnixNs: fixture.baseTimeUnixNs
        )
        #expect(working.lifecycle == .working)

        try fixture.publishRoot()
        let recentlyActive = try reader.read(
            storeURL: fixture.storeURL,
            cursor: working.cursor,
            observedAtUnixNs: fixture.baseTimeUnixNs + 100_000_000
        )
        #expect(recentlyActive.lifecycle == .activeRecently)

        let quiescent = try reader.read(
            storeURL: fixture.storeURL,
            cursor: recentlyActive.cursor,
            observedAtUnixNs: fixture.baseTimeUnixNs + 2_000_000_000
        )
        #expect(quiescent.lifecycle == .quiescentUnknown)
    }

    @Test("A just-completed tool is positive recent activity evidence")
    func completedToolIsRecentActivity() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let completedMs = fixture.baseTimeUnixNs / 1_000_000 - 250
        _ = try fixture.appendTurn(
            prompt: "Inspect it",
            assistantTexts: [],
            completedToolAtMs: completedMs
        )
        try fixture.publishRoot()

        let result = try CursorAgentStoreReader(configuration: .init(
            recentActivityWindowNs: 1_000_000_000
        )).read(
            storeURL: fixture.storeURL,
            observedAtUnixNs: fixture.baseTimeUnixNs
        )
        #expect(result.lifecycle == .activeRecently)
    }

    @Test("Registry publishes a stable per-session human prompt cursor")
    func registryIntegration() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Data(#"{"cwd":"/tmp/cursor-work"}"#.utf8).write(
            to: fixture.directory.appendingPathComponent("meta.json")
        )
        let first = try fixture.appendTurn(prompt: "First target", assistantTexts: [])
        try fixture.publishRoot()
        let reader = CursorAgentStoreReader(configuration: .init(
            recentActivityWindowNs: 1_000_000_000
        ))
        let registry = AgentTranscriptRegistry(cursorReader: reader)
        let canonical = AgentCanonicalTranscriptPath(
            provider: .cursor,
            canonicalPath: fixture.storeURL.path,
            providerSessionID: fixture.sessionID
        )

        let initial = try #require(await registry.consumeCursor(
            canonical,
            observedAt: fixture.baseTimeUnixNs
        )?.snapshot)
        #expect(initial.latestUserPrompt?.text == "First target")
        #expect(initial.latestUserPrompt?.sourceOffset == UInt64(first.userRowID))
        #expect(initial.cwd == "/tmp/cursor-work")
        #expect(initial.activityState == .quiescentUnknown)

        let stable = try #require(await registry.consumeCursor(
            canonical,
            observedAt: fixture.baseTimeUnixNs + 2_000_000_000
        )?.snapshot)
        #expect(stable.latestUserPrompt?.sourceOffset == initial.latestUserPrompt?.sourceOffset)
        #expect(stable.recentEvents.isEmpty)

        let second = try fixture.appendTurn(prompt: "Second target", assistantTexts: [])
        try fixture.publishRoot()
        let changed = try #require(await registry.consumeCursor(
            canonical,
            observedAt: fixture.baseTimeUnixNs + 2_100_000_000
        )?.snapshot)
        #expect(changed.latestUserPrompt?.text == "Second target")
        #expect(changed.latestUserPrompt?.sourceOffset == UInt64(second.userRowID))
        #expect(changed.latestUserPrompt?.sourceOffset != initial.latestUserPrompt?.sourceOffset)
        #expect(changed.activityState == .activeRecently)
        #expect(changed.recentEvents.last?.kind == .turnStarted)
    }

    private final class Fixture: @unchecked Sendable {
        struct TurnResult {
            let userRowID: Int64
            let userBlobID: String
        }

        struct Turn {
            let userBlobID: String
            var stepBlobIDs: [String]
            var turnBlobID: String
        }

        let sessionID: String
        let directory: URL
        let storeURL: URL
        let baseTimeUnixNs: UInt64 = 2_000_000_000_000_000_000

        private var connection: OpaquePointer?
        private var turns: [Turn] = []
        private var nextID: UInt64 = 1

        init() throws {
            sessionID = UUID().uuidString.lowercased()
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(sessionID, isDirectory: true)
            storeURL = directory.appendingPathComponent("store.db")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            guard sqlite3_open(storeURL.path, &connection) == SQLITE_OK,
                  let connection else { throw FixtureError.sqlite("open") }
            try execute(connection, "PRAGMA journal_mode=WAL")
            try execute(connection, "PRAGMA wal_autocheckpoint=0")
            try execute(connection, "CREATE TABLE blobs (id TEXT PRIMARY KEY, data BLOB)")
            try execute(connection, "CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT)")
        }

        deinit {
            if let connection { sqlite3_close_v2(connection) }
        }

        func remove() {
            if let connection {
                sqlite3_close_v2(connection)
                self.connection = nil
            }
            try? FileManager.default.removeItem(at: directory)
        }

        func appendTurn(
            prompt: String,
            assistantTexts: [String],
            simulated: Bool = false,
            completedToolAtMs: UInt64? = nil
        ) throws -> TurnResult {
            var user = fieldBytes(1, Data(prompt.utf8))
            user.append(fieldBytes(2, Data(UUID().uuidString.lowercased().utf8)))
            if simulated { user.append(fieldVarint(5, 1)) }
            let userID = makeID()
            let userRow = try insertBlob(id: userID, data: user)

            var stepIDs: [String] = []
            for text in assistantTexts {
                let assistant = fieldBytes(1, Data(text.utf8))
                let step = fieldBytes(1, assistant)
                let stepID = makeID()
                _ = try insertBlob(id: stepID, data: step)
                stepIDs.append(stepID)
            }
            if let completedToolAtMs {
                var tool = fieldVarint(59, completedToolAtMs - 10)
                tool.append(fieldVarint(60, completedToolAtMs))
                let stepID = makeID()
                _ = try insertBlob(id: stepID, data: fieldBytes(2, tool))
                stepIDs.append(stepID)
            }
            let turnID = try insertTurn(userID: userID, stepIDs: stepIDs)
            turns.append(Turn(
                userBlobID: userID,
                stepBlobIDs: stepIDs,
                turnBlobID: turnID
            ))
            return TurnResult(userRowID: userRow, userBlobID: userID)
        }

        func appendAssistantToLatestTurn(_ text: String) throws {
            guard var latest = turns.popLast() else { throw FixtureError.invalidID }
            let assistant = fieldBytes(1, Data(text.utf8))
            let stepID = makeID()
            _ = try insertBlob(id: stepID, data: fieldBytes(1, assistant))
            latest.stepBlobIDs.append(stepID)
            latest.turnBlobID = try insertTurn(
                userID: latest.userBlobID,
                stepIDs: latest.stepBlobIDs
            )
            turns.append(latest)
        }

        func publishRoot(pendingMessage: [String: Any]? = nil) throws {
            var root = fieldBytes(1, Data(repeating: 0xA5, count: 32))
            for turn in turns {
                guard let id = decodeHex(turn.turnBlobID) else { throw FixtureError.invalidID }
                root.append(fieldBytes(8, id))
            }
            if let pendingMessage {
                root.append(fieldBytes(
                    4,
                    try JSONSerialization.data(withJSONObject: pendingMessage)
                ))
            }
            let rootID = makeID()
            _ = try insertBlob(id: rootID, data: root)
            try publishMetadata(rootID: rootID)
        }

        private func insertTurn(userID: String, stepIDs: [String]) throws -> String {
            guard let userHash = decodeHex(userID) else { throw FixtureError.invalidID }
            var agentTurn = fieldBytes(1, userHash)
            for id in stepIDs {
                guard let hash = decodeHex(id) else { throw FixtureError.invalidID }
                agentTurn.append(fieldBytes(2, hash))
            }
            agentTurn.append(fieldBytes(3, Data(UUID().uuidString.lowercased().utf8)))
            let turnID = makeID()
            _ = try insertBlob(id: turnID, data: fieldBytes(1, agentTurn))
            return turnID
        }

        private func publishMetadata(rootID: String) throws {
            let metadata = try JSONSerialization.data(withJSONObject: [
                "agentId": sessionID,
                "latestRootBlobId": rootID,
                "name": "Fixture",
            ])
            let value = metadata.map { String(format: "%02x", $0) }.joined()
            guard let connection else { throw FixtureError.sqlite("closed") }
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            let sql = """
                INSERT INTO meta(key, value) VALUES('0', ?1)
                ON CONFLICT(key) DO UPDATE SET value=excluded.value
                """
            guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK,
                  let statement else { throw FixtureError.sqlite(errorMessage(connection)) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            guard sqlite3_bind_text(statement, 1, value, -1, transient) == SQLITE_OK,
                  sqlite3_step(statement) == SQLITE_DONE
            else { throw FixtureError.sqlite(errorMessage(connection)) }
        }

        private func insertBlob(id: String, data: Data) throws -> Int64 {
            guard let connection else { throw FixtureError.sqlite("closed") }
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(
                connection,
                "INSERT INTO blobs(id, data) VALUES(?1, ?2)",
                -1,
                &statement,
                nil
            ) == SQLITE_OK, let statement else {
                throw FixtureError.sqlite(errorMessage(connection))
            }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            guard sqlite3_bind_text(statement, 1, id, -1, transient) == SQLITE_OK else {
                throw FixtureError.sqlite(errorMessage(connection))
            }
            let bindCode = data.withUnsafeBytes { bytes in
                sqlite3_bind_blob(statement, 2, bytes.baseAddress, Int32(bytes.count), transient)
            }
            guard bindCode == SQLITE_OK, sqlite3_step(statement) == SQLITE_DONE else {
                throw FixtureError.sqlite(errorMessage(connection))
            }
            return sqlite3_last_insert_rowid(connection)
        }

        private func makeID() -> String {
            defer { nextID += 1 }
            return String(format: "%064llx", nextID)
        }

        private func fieldBytes(_ number: UInt64, _ value: Data) -> Data {
            var result = varint(number << 3 | 2)
            result.append(varint(UInt64(value.count)))
            result.append(value)
            return result
        }

        private func fieldVarint(_ number: UInt64, _ value: UInt64) -> Data {
            var result = varint(number << 3)
            result.append(varint(value))
            return result
        }

        private func varint(_ value: UInt64) -> Data {
            var value = value
            var result = Data()
            repeat {
                var byte = UInt8(value & 0x7F)
                value >>= 7
                if value != 0 { byte |= 0x80 }
                result.append(byte)
            } while value != 0
            return result
        }

        private func execute(_ connection: OpaquePointer, _ sql: String) throws {
            guard sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else {
                throw FixtureError.sqlite(errorMessage(connection))
            }
        }

        private func errorMessage(_ connection: OpaquePointer) -> String {
            String(cString: sqlite3_errmsg(connection))
        }

        private func decodeHex(_ value: String) -> Data? {
            guard value.count.isMultiple(of: 2) else { return nil }
            var result = Data()
            var index = value.startIndex
            while index < value.endIndex {
                let next = value.index(index, offsetBy: 2)
                guard let byte = UInt8(value[index ..< next], radix: 16) else { return nil }
                result.append(byte)
                index = next
            }
            return result
        }
    }

    private enum FixtureError: Error {
        case sqlite(String)
        case invalidID
    }
}
