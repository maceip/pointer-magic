import Darwin
import PointerCore
import PointerTransport

let iterations = 2_000_000
let mailbox = MotionMailbox()
var lastVersion: UInt64 = 0
var checksum: UInt64 = 0

let started = MonotonicClock.nowNs()
for sequence in 1...iterations {
    let value = UInt64(sequence)
    mailbox.write(
        TransportMotionSample(
            sequence: value,
            eventTimestampNs: value,
            observedTimestampNs: value,
            coordinates: PointerCoordinates(
                quartzGlobal: GlobalPoint(x: Double(sequence), y: Double(sequence + 1)),
                appKitGlobal: GlobalPoint(x: Double(sequence), y: Double(sequence + 1))
            ),
            flags: 0,
            buttons: 0,
            kind: .moved
        )
    )
    if let update = mailbox.read(afterVersion: lastVersion) {
        lastVersion = update.version
        checksum &+= update.sample.sequence
    }
}
let elapsed = MonotonicClock.nowNs() - started
let average = elapsed / UInt64(iterations)

print("iterations=\(iterations)")
print("elapsed_ns=\(elapsed)")
print("write_read_average_ns=\(average)")
print("checksum=\(checksum)")

// This is a transport regression gate, not the end-to-end cursor-to-photon budget.
// It is intentionally generous enough for loaded development machines.
if average > 5_000 {
    fputs("transport regression: average write/read exceeded 5 microseconds\n", stderr)
    exit(1)
}
