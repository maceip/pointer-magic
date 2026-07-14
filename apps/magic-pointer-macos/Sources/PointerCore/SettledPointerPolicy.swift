import Foundation

public struct SettledPointerPolicyState: Sendable {
    private var anchor: GlobalPoint?
    private var anchorSinceNs: UInt64 = 0
    private var lastRequestNs: UInt64 = 0

    public init() {}

    public mutating func reset() {
        anchor = nil
        anchorSinceNs = 0
        lastRequestNs = 0
    }

    public mutating func requestIfReady(
        frame: PointerFrame,
        policy: SemanticPolicy,
        cachedTargetFrame: GlobalRect?,
        cachedAtNs: UInt64?,
        cacheLifetimeNs: UInt64
    ) -> SemanticRequest? {
        guard case let .settled(delayNs, radius, minimumIntervalNs) = policy else {
            return nil
        }

        let point = frame.coordinates.quartzGlobal
        if let cachedTargetFrame,
           let cachedAtNs,
           frame.publishedTimestampNs >= cachedAtNs,
           frame.publishedTimestampNs - cachedAtNs <= cacheLifetimeNs,
           cachedTargetFrame.contains(point, inset: 1)
        {
            return nil
        }

        guard let anchor else {
            self.anchor = point
            anchorSinceNs = frame.publishedTimestampNs
            return nil
        }

        if anchor.distanceSquared(to: point) > radius * radius {
            self.anchor = point
            anchorSinceNs = frame.publishedTimestampNs
            return nil
        }

        let settledFor = frame.publishedTimestampNs &- anchorSinceNs
        let sinceLastRequest = frame.publishedTimestampNs &- lastRequestNs
        guard settledFor >= delayNs,
              lastRequestNs == 0 || sinceLastRequest >= minimumIntervalNs
        else {
            return nil
        }

        lastRequestNs = frame.publishedTimestampNs
        return SemanticRequest(
            generation: frame.generation,
            point: point,
            requestedAtNs: frame.publishedTimestampNs
        )
    }
}
