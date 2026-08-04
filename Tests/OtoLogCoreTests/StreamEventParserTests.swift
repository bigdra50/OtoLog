import Foundation
@testable import OtoLogCore
import Testing

/// stream-json からのツール実行問題の収集。
/// ツールが使えないまま完了した生成を「成功」として黙って通さないための検出側
struct StreamEventParserTests {
    // MARK: Internal

    @Test func permission_denialsを権限拒否として収集する() {
        let parser = StreamEventParser(onPartial: { _ in })
        feed(
            parser,
            #"{"type":"result","result":"本文","permission_denials":[{"tool_name":"WebSearch","tool_use_id":"t1","tool_input":{}}]}"#
        )

        #expect(parser.collectedToolIssues() == [ToolIssue(toolName: "WebSearch", kind: .permissionDenied)])
    }

    @Test func is_errorのtool_resultを実行失敗として収集する() {
        let parser = StreamEventParser(onPartial: { _ in })
        feed(
            parser,
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"WebFetch","input":{}}]}}"#
        )
        feed(
            parser,
            #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","is_error":true,"content":"fetch failed"}]}}"#
        )

        #expect(parser.collectedToolIssues() == [ToolIssue(toolName: "WebFetch", kind: .executionFailed)])
    }

    @Test func 問題が無ければ空() {
        let parser = StreamEventParser(onPartial: { _ in })
        feed(
            parser,
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"WebSearch","input":{}}]}}"#
        )
        feed(
            parser,
            #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}"#
        )
        feed(parser, #"{"type":"result","result":"本文","permission_denials":[]}"#)

        #expect(parser.collectedToolIssues().isEmpty)
    }

    /// 権限拒否されたツール呼び出しは is_error の tool_result としても流れてくるため、
    /// 同じツールを二重に報告しない
    @Test func 権限拒否があるツールの実行失敗は重ねて数えない() {
        let parser = StreamEventParser(onPartial: { _ in })
        feed(
            parser,
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"WebSearch","input":{}}]}}"#
        )
        feed(
            parser,
            #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","is_error":true,"content":"denied"}]}}"#
        )
        feed(
            parser,
            #"{"type":"result","result":"本文","permission_denials":[{"tool_name":"WebSearch","tool_use_id":"t1"}]}"#
        )

        #expect(parser.collectedToolIssues() == [ToolIssue(toolName: "WebSearch", kind: .permissionDenied)])
    }

    @Test func 同じツールの同種問題は1件にまとめる() {
        let parser = StreamEventParser(onPartial: { _ in })
        feed(
            parser,
            #"{"type":"result","result":"本文","permission_denials":[{"tool_name":"WebSearch"},{"tool_name":"WebSearch"},{"tool_name":"WebFetch"}]}"#
        )

        #expect(parser.collectedToolIssues() == [
            ToolIssue(toolName: "WebSearch", kind: .permissionDenied),
            ToolIssue(toolName: "WebFetch", kind: .permissionDenied),
        ])
    }

    // MARK: Private

    private func feed(_ parser: StreamEventParser, _ line: String) {
        parser.consume(Data((line + "\n").utf8))
    }
}
