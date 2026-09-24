import Foundation
@testable import OtoLogCore
import Testing

/// 中断したキャプチャを再起動するか諦めるかは、連続回数と前回の再起動からの経過時間だけで決まる
struct CaptureRestartPolicyTests {
    let policy = CaptureRestartPolicy.default
    let lastRestart = Date(timeIntervalSince1970: 1_785_297_600)

    @Test func defaultRestartsThreeTimesResetsAfterAMinuteAndSettlesForASecond() {
        #expect(policy.maxConsecutiveRestarts == 3)
        #expect(policy.stableInterval == .seconds(60))
        #expect(policy.settleDelay == .seconds(1))
    }

    @Test func firstInterruptionRestartsAsFirstAttempt() {
        #expect(policy.decision(consecutiveRestarts: 0, lastRestartAt: nil, now: lastRestart) == .restart(attempt: 1))
    }

    /// 前回の再起動から stableInterval に満たない中断は、同じ障害の続きとして次の回に数える
    @Test func interruptionsWithinStableIntervalCountAsConsecutive() {
        let soon = lastRestart.addingTimeInterval(59)

        #expect(policy.decision(consecutiveRestarts: 1, lastRestartAt: lastRestart, now: soon) == .restart(attempt: 2))
        #expect(policy.decision(consecutiveRestarts: 2, lastRestartAt: lastRestart, now: soon) == .restart(attempt: 3))
    }

    /// 上限まで再起動しても止まり続けるなら諦める
    @Test func givesUpAfterMaxConsecutiveRestarts() {
        let soon = lastRestart.addingTimeInterval(59)

        #expect(policy.decision(consecutiveRestarts: 3, lastRestartAt: lastRestart, now: soon) == .giveUp)
    }

    /// stableInterval 以上動いた後の中断は、上限に達していても1回目から数え直す
    @Test func interruptionAfterStableIntervalStartsCountingAgain() {
        let muchLater = lastRestart.addingTimeInterval(4 * 60 * 60)

        #expect(policy.decision(consecutiveRestarts: 3, lastRestartAt: lastRestart, now: muchLater) == .restart(attempt: 1))
    }

    /// 境界ちょうどは数え直す側。秒未満の間隔も切り捨てずに比べる
    @Test func stableIntervalBoundaryIsInclusiveAndKeepsFractions() {
        var policy = policy
        policy.stableInterval = .milliseconds(1500)

        #expect(policy.decision(
            consecutiveRestarts: 3, lastRestartAt: lastRestart, now: lastRestart.addingTimeInterval(1.5)
        ) == .restart(attempt: 1))
        #expect(policy.decision(
            consecutiveRestarts: 3, lastRestartAt: lastRestart, now: lastRestart.addingTimeInterval(1.4)
        ) == .giveUp)
    }

    @Test func honorsCustomMaximum() {
        var policy = policy
        policy.maxConsecutiveRestarts = 1

        #expect(policy.decision(consecutiveRestarts: 0, lastRestartAt: nil, now: lastRestart) == .restart(attempt: 1))
        #expect(policy.decision(consecutiveRestarts: 1, lastRestartAt: lastRestart, now: lastRestart) == .giveUp)
    }
}
