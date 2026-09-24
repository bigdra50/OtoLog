import Foundation
@testable import OtoLogCore
import Testing

/// 制御ソケットの往復を実ソケット（一時パス）で検証する。TCC・ネットワーク不要
struct ControlServerTests {
    // MARK: Internal

    @Test func roundTripsCommandAndResponse() async throws {
        try await withServer(handler: { request in
            ControlResponse(ok: true, state: "idle-\(request.command.rawValue)")
        }) { socketPath in
            let response = try await ControlClient.send(
                ControlRequest(command: .status), socketPath: socketPath, timeout: .seconds(5)
            )
            #expect(response == ControlResponse(ok: true, state: "idle-status"))
        }
    }

    /// 連続コマンド（1接続1リクエストを繰り返す）が独立に処理される
    @Test func handlesSequentialRequests() async throws {
        try await withServer(handler: { request in
            ControlResponse(ok: true, state: request.command.rawValue)
        }) { socketPath in
            for command in [ControlCommand.start, .status, .stop] {
                let response = try await ControlClient.send(
                    ControlRequest(command: command), socketPath: socketPath, timeout: .seconds(5)
                )
                #expect(response.state == command.rawValue)
            }
        }
    }

    /// ソケットは自ユーザーのみ（0600）。他ユーザーからの操作を防ぐ契約
    @Test func socketFileIsOwnerOnly() async throws {
        try await withServer(handler: { _ in ControlResponse(ok: true) }) { socketPath in
            let attributes = try FileManager.default.attributesOfItem(atPath: socketPath)
            #expect((attributes[.posixPermissions] as? Int) == 0o600)
        }
    }

    /// 前回の異常終了でソケットファイルが残っていても起動できる
    @Test func rebindsOverStaleSocketFile() async throws {
        let socketPath = temporarySocketPath()
        defer { try? FileManager.default.removeItem(atPath: socketPath) }
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: socketPath).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: socketPath, contents: Data())

        let server = ControlServer(socketPath: socketPath) { _ in ControlResponse(ok: true) }
        try server.start()
        defer { server.stop() }
        try await Task.sleep(for: .milliseconds(100))

        let response = try await ControlClient.send(
            ControlRequest(command: .status), socketPath: socketPath, timeout: .seconds(5)
        )
        #expect(response.ok)
    }

    /// 再起動では新しいインスタンスが同じパスへ bind し直してから古いインスタンスが止まる。
    /// 古い方の stop が新しい方のソケットファイルを消すと、次の起動まで新しい方へ接続できなくなる
    @Test func stopLeavesSocketReboundByAnotherServer() async throws {
        let socketPath = temporarySocketPath()
        defer { try? FileManager.default.removeItem(atPath: socketPath) }
        let previous = ControlServer(socketPath: socketPath) { _ in ControlResponse(ok: true, state: "previous") }
        try previous.start()
        defer { previous.stop() }
        try #require(await eventuallyServes("previous", at: socketPath))

        let current = ControlServer(socketPath: socketPath) { _ in ControlResponse(ok: true, state: "current") }
        try current.start()
        defer { current.stop() }
        try #require(await eventuallyServes("current", at: socketPath))

        previous.stop()

        #expect(FileManager.default.fileExists(atPath: socketPath))
        let response = try await ControlClient.send(
            ControlRequest(command: .status), socketPath: socketPath, timeout: .seconds(5)
        )
        #expect(response.state == "current")
    }

    /// 自分が bind したソケットファイルは stop で片付ける
    @Test func stopRemovesOwnSocketFile() async throws {
        let socketPath = temporarySocketPath()
        defer { try? FileManager.default.removeItem(atPath: socketPath) }
        let server = ControlServer(socketPath: socketPath) { _ in ControlResponse(ok: true, state: "own") }
        try server.start()
        try #require(await eventuallyServes("own", at: socketPath))

        server.stop()

        #expect(!FileManager.default.fileExists(atPath: socketPath))
    }

    /// bind していないサーバーはパス上のファイルを消さない。
    /// 他のインスタンスのものかもしれず、残骸なら次の start が消す
    @Test func stopWithoutBindingLeavesExistingFile() throws {
        let socketPath = temporarySocketPath()
        defer { try? FileManager.default.removeItem(atPath: socketPath) }
        try #require(FileManager.default.createFile(atPath: socketPath, contents: Data()))
        let server = ControlServer(socketPath: socketPath) { _ in ControlResponse(ok: true) }

        server.stop()

        #expect(FileManager.default.fileExists(atPath: socketPath))
    }

    /// 接続先が無い（アプリ未起動）は分かるエラーで即失敗する
    @Test func failsFastWhenServerAbsent() async {
        await #expect(throws: ControlClientError.self) {
            _ = try await ControlClient.send(
                ControlRequest(command: .status),
                socketPath: temporarySocketPath(),
                timeout: .seconds(5)
            )
        }
    }

    // MARK: Private

    /// unix socket のパス長上限（104 バイト）を超えないよう短い一時パスを使う
    private func temporarySocketPath() -> String {
        "/tmp/otolog-test-\(UUID().uuidString.prefix(8)).sock"
    }

    /// 指定の state を返すサーバーへ接続できるまで待つ。
    /// 応答が返った時点で .ready の処理も済んでいる（.ready の通知は最初の接続より先にサーバーのキューへ届く）
    private func eventuallyServes(_ state: String, at socketPath: String) async -> Bool {
        await eventually {
            let response = try? await ControlClient.send(
                ControlRequest(command: .status), socketPath: socketPath, timeout: .seconds(1)
            )
            return response?.state == state
        }
    }

    private func withServer(
        handler: @escaping ControlServer.Handler,
        body: (String) async throws -> Void
    ) async throws {
        let socketPath = temporarySocketPath()
        let server = ControlServer(socketPath: socketPath, handler: handler)
        try server.start()
        defer {
            server.stop()
            try? FileManager.default.removeItem(atPath: socketPath)
        }
        try await Task.sleep(for: .milliseconds(100))
        try await body(socketPath)
    }
}
