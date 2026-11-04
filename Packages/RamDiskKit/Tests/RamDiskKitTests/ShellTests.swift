import Foundation
import Testing
@testable import RamDiskKit

@Suite struct ShellTests {
    @Test func runIsFastAndCapturesOutput() async throws {
        let start = Date()
        let r = try await Shell.run("/bin/echo", ["hello"])
        let elapsed = Date().timeIntervalSince(start)
        #expect(r.stdout == "hello\n")
        #expect(r.status == 0)
        #expect(elapsed < 0.5, "Shell.run took \(elapsed)s")
    }

    @Test func stdinIsDelivered() async throws {
        let r = try await Shell.run("/bin/cat", [], stdin: Data("secret".utf8))
        #expect(r.stdout == "secret")
    }

    @Test func largeOutputDoesNotDeadlock() async throws {
        let r = try await Shell.run("/bin/sh", ["-c", "head -c 3000000 /dev/zero | tr '\\\\0' a; head -c 200000 /dev/zero | tr '\\\\0' b >&2"])
        #expect(r.stdout.count == 3_000_000)
        #expect(r.stderr.count == 200_000)
    }

    @Test func checkedThrowsOnFailure() async {
        await #expect(throws: CommandError.self) { try await Shell.checked("/bin/sh", ["-c", "echo boom >&2; exit 3"]) }
    }

    @Test func quoteRoundTrips() async throws {
        let nasty = "it's a \"test\" $HOME `x` \\ end"
        let r = try await Shell.run("/bin/sh", ["-c", "printf %s " + ShellQuote.quote(nasty)])
        #expect(r.stdout == nasty)
    }
}
