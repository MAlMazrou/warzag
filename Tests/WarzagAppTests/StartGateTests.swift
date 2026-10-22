import Foundation
import Synchronization
import Testing
import WarzagCore
@testable import WarzagApp

@Suite(.timeLimit(.minutes(1)))
struct StartGateTests {
    final class Counter: Sendable {
        private let count = Mutex(0)
        func add() { count.withLock { $0 += 1 } }
        var value: Int { count.withLock { $0 } }
    }

    @Test func waitersGoOnceTheGateOpens() async {
        let gate = StartGate()
        let passed = Counter()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<3 {
                group.addTask {
                    await gate.wait()
                    passed.add()
                }
            }
            try? await Task.sleep(for: .milliseconds(20))
            #expect(passed.value == 0)
            gate.open()
        }
        #expect(passed.value == 3)
        // An open gate does not wait at all.
        await gate.wait()
        #expect(gate.isOpen)
    }

    @Test func aCancelledWaiterLeavesWithoutTheGateOpening() async {
        let gate = StartGate()
        let waiter = Task {
            await gate.wait()
            return Task.isCancelled
        }
        try? await Task.sleep(for: .milliseconds(20))
        waiter.cancel()
        #expect(await waiter.value)
        #expect(!gate.isOpen)
    }

    @Test func gatedStepsDoNothingWhenCancelled() async {
        let fixture = await AppFixture(welcomed: false)
        var performer = await fixture.performer()
        performer.gate = StartGate()
        let task = Task { await performer.perform(.installSteam, in: SetupState()) }
        try? await Task.sleep(for: .milliseconds(20))
        task.cancel()
        _ = await task.value
        #expect(fixture.steam.calls.isEmpty)
        // The checks on this Mac never wait.
        #expect(await performer.perform(.checkNetwork, in: SetupState()) == .completed)
    }
}
