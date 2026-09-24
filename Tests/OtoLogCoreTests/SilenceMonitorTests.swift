import Foundation
@testable import OtoLogCore
import Testing

/// 無音が続いたかどうかは、文字か数字を含む結果が最後に届いた時刻（届いていなければ開始時刻）からの経過時間だけで決まる
struct SilenceMonitorTests {
    /// 文字（文字体系を問わない）か数字を1つでも含む結果
    static let spokenTexts = ["hello", "こんにちは", "カタカナ", "漢字", "안녕", "3", "１２", "えー、", " a "]
    /// 句読点・空白・記号・絵文字だけの結果
    static let unspokenTexts = ["", " ", "\n", ", , ,", "、。", "…", "!?", "「」", "♪", "😀"]

    let startedAt = Date(timeIntervalSince1970: 1_785_297_600)

    /// 何も話されなければ、開始から timeout たったところで無音が続いたとみなす。境界ちょうどは止める側
    @Test func expiresWhenNothingIsSpokenForTheTimeoutAfterTheStart() {
        let monitor = SilenceMonitor(timeout: .seconds(60), startedAt: startedAt)

        #expect(!monitor.isExpired(at: startedAt.addingTimeInterval(59)))
        #expect(monitor.isExpired(at: startedAt.addingTimeInterval(60)))
    }

    /// 発話が届いたら、その時刻から数え直す
    @Test func activityRestartsTheCountFromItsTime() {
        var monitor = SilenceMonitor(timeout: .seconds(60), startedAt: startedAt)

        monitor.recordActivity("こんにちは", at: startedAt.addingTimeInterval(45))

        #expect(!monitor.isExpired(at: startedAt.addingTimeInterval(104)))
        #expect(monitor.isExpired(at: startedAt.addingTimeInterval(105)))
    }

    /// 認識器は雑音にも句読点だけの結果を返す。それでは数え直さない
    @Test func punctuationOnlyTextDoesNotRestartTheCount() {
        var monitor = SilenceMonitor(timeout: .seconds(60), startedAt: startedAt)

        monitor.recordActivity(", , ,", at: startedAt.addingTimeInterval(45))
        monitor.recordActivity("、。", at: startedAt.addingTimeInterval(50))

        #expect(monitor.isExpired(at: startedAt.addingTimeInterval(60)))
    }

    /// 秒未満の timeout も切り捨てずに比べる
    @Test func timeoutKeepsFractionsOfASecond() {
        let monitor = SilenceMonitor(timeout: .milliseconds(1500), startedAt: startedAt)

        #expect(!monitor.isExpired(at: startedAt.addingTimeInterval(1.4)))
        #expect(monitor.isExpired(at: startedAt.addingTimeInterval(1.5)))
    }

    @Test(arguments: spokenTexts) func textWithALetterOrDigitCountsAsActivity(text: String) {
        #expect(SilenceMonitor.isActivity(text))
    }

    @Test(arguments: unspokenTexts) func textWithoutLettersOrDigitsDoesNotCountAsActivity(text: String) {
        #expect(!SilenceMonitor.isActivity(text))
    }
}
