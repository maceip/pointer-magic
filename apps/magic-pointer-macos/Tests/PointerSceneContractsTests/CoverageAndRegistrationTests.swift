import Foundation
import PointerSceneContracts
import Testing

@Suite("Coverage and source authority")
struct CoverageAndRegistrationTests {
    @Test("Evidence diagnostics cannot become a second content channel")
    func evidenceDetailCodesAreClosedTokens() throws {
        let safe = try SceneEvidence(
            kind: .accessibility,
            detailCode: "ax.value-unavailable_v1"
        )
        #expect(safe.detailCode == "ax.value-unavailable_v1")

        #expect(throws: SceneContractValidationError.invalidFormat(
            field: "evidence.detailCode"
        )) {
            try SceneEvidence(
                kind: .accessibility,
                detailCode: "copied user text"
            )
        }
    }

    @Test("Coverage states exactly which evidence it guarantees")
    func explicitCoverageGuarantee() throws {
        let epoch = registrationEpoch()
        let field = try SceneFieldKey("content.label")
        let report = try CoverageReport(
            streamID: CoverageStreamID(),
            scope: .sourceProjection(epoch),
            continuitySequence: 1,
            state: .started(maximumSilenceNs: 1_000_000_000),
            guarantee: .completeEvents,
            coveredFields: [field],
            coveredEvidenceKinds: [.accessibility],
            observedAtSourceMonotonicNs: 1
        )

        #expect(report.guarantee == .completeEvents)
        #expect(report.coveredFields == [field])
        #expect(report.coveredEvidenceKinds == [.accessibility])
    }

    @Test("Grant policy rejects an unauthorized field")
    func fieldAuthorityIsEnforced() throws {
        let epoch = registrationEpoch()
        let session = SceneSessionID()
        let allowed = try SceneFieldKey("content.label")
        let denied = try SceneFieldKey("content.value")
        let manifest = try SceneSourceManifest(
            sourceEpoch: epoch,
            sessionID: session,
            displayName: "Test AX source",
            kind: .syntheticTest,
            capabilities: [.structuredHierarchy]
        )
        let grant = SceneSourceGrant(
            sourceEpoch: epoch,
            capabilities: [.structuredHierarchy],
            eventKinds: [.observation],
            evidenceKinds: [.accessibility],
            fields: .listed([allowed]),
            surfaces: .ownDevice
        )
        let handle = SceneSourceHandle(
            sourceEpoch: epoch,
            sessionID: session,
            grantID: grant.id
        )
        let authorization = try SceneSourceAuthorization(
            manifest: manifest,
            grant: grant,
            handle: handle,
            receiverNowNs: 1
        )
        let event = try authorizedFixtureEnvelope(
            epoch: epoch,
            sequence: 1,
            field: denied
        )
        let batch = try SceneEventBatch(events: [event])

        #expect(throws: SceneContractValidationError.unauthorized(field: "event.fields")) {
            try authorization.validate(batch, receiverNowNs: 2)
        }
    }

    @Test("Cross-source dependencies default to denied without a receiver allowlist")
    func dependencySourcesDefaultToOwnEpoch() throws {
        let ownerEpoch = registrationEpoch()
        let dependencyEpoch = registrationEpoch()
        let session = SceneSessionID()
        let manifest = try SceneSourceManifest(
            sourceEpoch: ownerEpoch,
            sessionID: session,
            displayName: "Derived source",
            kind: .syntheticTest,
            capabilities: [.crossSourceDependencies]
        )
        let grant = SceneSourceGrant(
            sourceEpoch: ownerEpoch,
            capabilities: [.crossSourceDependencies],
            eventKinds: [.observation],
            evidenceKinds: [],
            fields: .all,
            surfaces: .ownDevice
        )
        let authorization = try SceneSourceAuthorization(
            manifest: manifest,
            grant: grant,
            handle: SceneSourceHandle(
                sourceEpoch: ownerEpoch,
                sessionID: session,
                grantID: grant.id
            ),
            receiverNowNs: 1
        )
        let claim = try SceneFieldClaim(
            field: SceneFieldKey("content.derived"),
            value: .text("derived"),
            knowledge: .derived,
            confidence: 1,
            sensitivity: .ordinary,
            dependencies: [
                SceneClaimDependency(
                    revision: SourceRevision(
                        sourceEpoch: dependencyEpoch,
                        sequence: 1
                    ),
                    object: SourceObjectKey(
                        sourceEpoch: dependencyEpoch,
                        objectID: SourceObjectID()
                    )
                ),
            ]
        )
        let event = try SceneEventEnvelope(
            revision: SourceRevision(sourceEpoch: ownerEpoch, sequence: 1),
            emittedAtSourceMonotonicNs: 1,
            payload: .observation(
                try SceneObservation(
                    subject: SourceObjectKey(
                        sourceEpoch: ownerEpoch,
                        objectID: SourceObjectID()
                    ),
                    observedAtSourceMonotonicNs: 1,
                    claims: [claim]
                )
            )
        )

        #expect(
            throws: SceneContractValidationError.unauthorized(
                field: "claim.dependencies.source"
            )
        ) {
            try authorization.validate(
                SceneEventBatch(events: [event]),
                receiverNowNs: 2
            )
        }
    }
}

private func registrationEpoch() -> SceneSourceEpoch {
    SceneSourceEpoch(
        source: SceneSourceIdentity(
            device: DevicePrincipalID(),
            source: SceneSourceID()
        )
    )
}

private func authorizedFixtureEnvelope(
    epoch: SceneSourceEpoch,
    sequence: UInt64,
    field: SceneFieldKey
) throws -> SceneEventEnvelope {
    let revision = try SourceRevision(sourceEpoch: epoch, sequence: sequence)
    let claim = try SceneFieldClaim(
        field: field,
        value: .text("value"),
        knowledge: .observed,
        confidence: 1,
        sensitivity: .ordinary,
        evidence: [try SceneEvidence(kind: .accessibility, sourceRevision: revision)]
    )
    let observation = try SceneObservation(
        subject: SourceObjectKey(sourceEpoch: epoch, objectID: SourceObjectID()),
        observedAtSourceMonotonicNs: sequence,
        claims: [claim]
    )
    return try SceneEventEnvelope(
        revision: revision,
        emittedAtSourceMonotonicNs: sequence,
        payload: .observation(observation)
    )
}
