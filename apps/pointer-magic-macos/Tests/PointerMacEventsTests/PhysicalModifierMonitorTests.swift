@testable import PointerMacEvents
import PointerCore
import Testing

@Suite("Physical modifier sampling")
struct PhysicalModifierMonitorTests {
    @Test("Public device bits preserve the two physical right-side keys")
    func rightSideDeviceBits() {
        #expect(PhysicalModifierMonitor.state(deviceModifierFlags: 0x40) == [.rightOption])
        #expect(PhysicalModifierMonitor.state(deviceModifierFlags: 0x10) == [.rightCommand])
        #expect(PhysicalModifierMonitor.state(deviceModifierFlags: 0x50) == [
            .rightOption,
            .rightCommand,
        ])
    }

    @Test("Left-side and aggregate flags cannot accidentally park the shelf")
    func rejectsNonRightDeviceBits() {
        // Left Command=0x08, Left Option=0x20. Device-independent Command and
        // Option bits are intentionally ignored by this side-specific sampler.
        let leftAndAggregate: UInt = 0x08 | 0x20 | 0x0010_0000 | 0x0008_0000
        #expect(PhysicalModifierMonitor.state(
            deviceModifierFlags: leftAndAggregate
        ).isEmpty)
    }
}
