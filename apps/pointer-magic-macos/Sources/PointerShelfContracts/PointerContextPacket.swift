import Foundation
import PointerCore

/// Freshness of evidence in a context packet. Actions must refuse authority when
/// freshness is not `.current`.
public enum PointerContextFreshness: String, Codable, Hashable, Sendable {
    case current
    case stale
    case partial
}

public enum PointerContextSnippetProvenance: String, Codable, Hashable, Sendable {
    case ax
    case ocr
    case selection
}

/// Short text near the pointer. Providers may promote these into context chips.
public struct PointerContextSnippet: Codable, Hashable, Sendable {
    public var id: String
    public var text: String
    public var bounds: GlobalRect?
    public var provenance: PointerContextSnippetProvenance

    public init(
        id: String,
        text: String,
        bounds: GlobalRect? = nil,
        provenance: PointerContextSnippetProvenance
    ) {
        self.id = id
        self.text = text
        self.bounds = bounds
        self.provenance = provenance
    }
}

public struct PointerContextAppWindow: Codable, Hashable, Sendable {
    public var bundleIdentifier: String?
    public var applicationName: String?
    public var windowTitle: String?
    public var processID: Int32?

    public init(
        bundleIdentifier: String? = nil,
        applicationName: String? = nil,
        windowTitle: String? = nil,
        processID: Int32? = nil
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.applicationName = applicationName
        self.windowTitle = windowTitle
        self.processID = processID
    }
}

public struct PointerContextHitTarget: Codable, Hashable, Sendable {
    public var targetID: String?
    public var role: String?
    public var subrole: String?
    public var title: String?
    public var value: String?
    public var selectedText: String?
    public var bounds: GlobalRect?
    public var isEditable: Bool?

    public init(
        targetID: String? = nil,
        role: String? = nil,
        subrole: String? = nil,
        title: String? = nil,
        value: String? = nil,
        selectedText: String? = nil,
        bounds: GlobalRect? = nil,
        isEditable: Bool? = nil
    ) {
        self.targetID = targetID
        self.role = role
        self.subrole = subrole
        self.title = title
        self.value = value
        self.selectedText = selectedText
        self.bounds = bounds
        self.isEditable = isEditable
    }
}

/// Opaque thumb token. Pixels are never embedded in the default packet; providers
/// request bytes only through a capability grant.
public struct PointerContextThumbToken: Codable, Hashable, Sendable {
    public var token: String
    public var bounds: GlobalRect?
    public var pixelWidth: Int?
    public var pixelHeight: Int?

    public init(
        token: String,
        bounds: GlobalRect? = nil,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil
    ) {
        self.token = token
        self.bounds = bounds
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

/// Immutable, schema-versioned under-pointer context for shelf providers.
public struct PointerContextPacket: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 1
    public static let maximumSnippetCount = 8
    public static let maximumSnippetCharacters = 240

    public var schemaVersion: Int
    public var revision: UInt64
    public var generation: UInt64
    public var sequence: UInt64
    public var assembledAtNs: UInt64
    public var point: GlobalPoint
    public var displayID: UInt32?
    public var freshness: PointerContextFreshness
    public var appWindow: PointerContextAppWindow
    public var hitTarget: PointerContextHitTarget
    public var snippets: [PointerContextSnippet]
    public var thumb: PointerContextThumbToken?

    public init(
        schemaVersion: Int = currentSchemaVersion,
        revision: UInt64,
        generation: UInt64,
        sequence: UInt64,
        assembledAtNs: UInt64,
        point: GlobalPoint,
        displayID: UInt32? = nil,
        freshness: PointerContextFreshness,
        appWindow: PointerContextAppWindow = PointerContextAppWindow(),
        hitTarget: PointerContextHitTarget = PointerContextHitTarget(),
        snippets: [PointerContextSnippet] = [],
        thumb: PointerContextThumbToken? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.revision = revision
        self.generation = generation
        self.sequence = sequence
        self.assembledAtNs = assembledAtNs
        self.point = point
        self.displayID = displayID
        self.freshness = freshness
        self.appWindow = appWindow
        self.hitTarget = hitTarget
        self.snippets = Array(snippets.prefix(Self.maximumSnippetCount)).map { snippet in
            var copy = snippet
            if copy.text.count > Self.maximumSnippetCharacters {
                copy.text = String(copy.text.prefix(Self.maximumSnippetCharacters))
            }
            return copy
        }
        self.thumb = thumb
    }

    public var authorizesActions: Bool {
        freshness == .current
    }
}
