import PointerMagicKit
import PointerCore
import Testing

@Suite("Bedrock lifecycle")
@MainActor
struct BedrockLifecycleTests {
    @Test("Construction has no capture side effect")
    func constructionIsQuiet() async {
        let bedrock = PointerBedrock(
            configuration: PointerConfiguration(semanticPolicy: .onDemand)
        )
        #expect(bedrock.health().captureMode == .stopped)
        await bedrock.stop()
    }
}
