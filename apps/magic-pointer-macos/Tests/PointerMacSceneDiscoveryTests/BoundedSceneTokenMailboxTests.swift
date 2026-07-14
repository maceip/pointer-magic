import PointerMacSceneDiscovery
import Testing

@Suite("bounded scene token mailbox")
struct BoundedSceneTokenMailboxTests {
    private enum Token: Hashable, Sendable {
        case application
        case display
        case space
    }

    @Test("coalesces tokens and makes overflow an explicit drain fact")
    func coalescingAndOverflow() throws {
        let mailbox = BoundedSceneTokenMailbox<Token>(capacity: 2)

        #expect(mailbox.offer(.application) == .inserted)
        #expect(mailbox.offer(.application) == .coalesced)
        #expect(mailbox.offer(.display) == .inserted)
        #expect(mailbox.offer(.space) == .overflowed)

        let drain = try #require(mailbox.drain())
        #expect(drain.tokens == [.application, .display])
        #expect(drain.overflowed)
        #expect(mailbox.drain() == nil)

        #expect(mailbox.offer(.space) == .inserted)
        let second = try #require(mailbox.drain())
        #expect(second.tokens == [.space])
        #expect(!second.overflowed)

        mailbox.close()
        #expect(mailbox.offer(.application) == .closed)
        if case .closed = mailbox.waitAndDrain() {
            // Expected.
        } else {
            Issue.record("closed mailbox did not wake as closed")
        }
    }
}
