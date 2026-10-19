import Foundation
import MyDikteKit
import Testing

@testable import MyDikte

@Suite("ReconnectSchedule")
struct ReconnectScheduleTests {
    @Test("consecutive failures back off 1, 2, 4, 8, 16, 30 and 60 seconds")
    func backoffSequence() {
        var schedule = ReconnectSchedule()

        let delays: [Duration] = (0..<7).map { _ in schedule.nextDelay(afterSessionLasting: .zero) }

        #expect(delays == [1, 2, 4, 8, 16, 30, 60].map { Duration.seconds($0) })
    }

    @Test("the delay stays at the 60 second cap however long the link keeps failing")
    func capHolds() {
        var schedule = ReconnectSchedule()

        let delays: [Duration] = (0..<20).map { _ in schedule.nextDelay(afterSessionLasting: .seconds(2)) }

        #expect(delays.last == .seconds(60))
        #expect(delays.dropFirst(6).allSatisfy { $0 == .seconds(60) })
    }

    @Test("a session that lived 30 seconds resets the schedule to the first delay")
    func healthySessionResets() {
        var schedule = ReconnectSchedule()
        for _ in 0..<5 {
            _ = schedule.nextDelay(afterSessionLasting: .seconds(1))
        }

        #expect(schedule.nextDelay(afterSessionLasting: .seconds(30)) == .seconds(1))
        #expect(schedule.nextDelay(afterSessionLasting: .seconds(1)) == .seconds(2))
    }

    @Test("a session that died just short of 30 seconds does not reset the schedule")
    func shortSessionDoesNotReset() {
        var schedule = ReconnectSchedule()
        _ = schedule.nextDelay(afterSessionLasting: .zero)

        #expect(schedule.nextDelay(afterSessionLasting: .milliseconds(29_999)) == .seconds(2))
    }
}

@Suite("RemoteLink pure pieces")
struct RemoteLinkTests {
    @Test("the ssh argv for a host is exactly the relay invocation, with no shell quoting")
    func sshArguments() {
        #expect(
            RemoteLink.sshArguments(host: "home-mac") == [
                "-T",
                "-o", "BatchMode=yes",
                "-o", "ConnectTimeout=5",
                "-o", "ServerAliveInterval=5",
                "-o", "ServerAliveCountMax=3",
                "--",
                "home-mac",
                "~/Applications/MyDikteRemote.app/Contents/MacOS/MyDikteRemote --relay",
            ]
        )
    }

    @Test("a host that starts with a dash lands after the option terminator")
    func dashedHostIsNotAnOption() throws {
        let arguments: [String] = RemoteLink.sshArguments(host: "-oProxyCommand=evil")

        let terminator: Int = try #require(arguments.firstIndex(of: "--"))
        #expect(arguments[terminator + 1] == "-oProxyCommand=evil")
    }

    @Test("pipeline stages map onto the three wire stages")
    func stageMapping() {
        #expect(RemoteLink.remoteStage(for: .idle) == .idle)
        #expect(RemoteLink.remoteStage(for: .recording) == .recording)
        #expect(RemoteLink.remoteStage(for: .working(.encoding)) == .processing)
        #expect(RemoteLink.remoteStage(for: .working(.transcribing)) == .processing)
        #expect(RemoteLink.remoteStage(for: .working(.cleaning)) == .processing)
        #expect(RemoteLink.remoteStage(for: .working(.rewriting)) == .processing)
        #expect(RemoteLink.remoteStage(for: .inserting) == .processing)
    }

    @Test("the wire modes map onto the dictation modes")
    func modeMapping() {
        #expect(RemoteLink.dictationMode(for: .dictate) == .dictate)
        #expect(RemoteLink.dictationMode(for: .prompt) == .prompt)
    }
}
