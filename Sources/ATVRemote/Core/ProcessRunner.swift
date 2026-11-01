import Foundation

enum ProcessRunnerError: LocalizedError {
    case launchFailed(String)
    case nonZeroExit(Int32)

    var errorDescription: String? {
        switch self {
        case .launchFailed(let m): return String(localized: "Failed to launch the process: \(m)")
        case .nonZeroExit(let c): return String(localized: "The process exited with code \(Int(c))")
        }
    }
}

/// Потоковый запуск внешней команды (stdout+stderr построчно в onLine).
enum ProcessRunner {
    /// Запускает процесс и ждёт завершения. Возвращает код выхода.
    @discardableResult
    static func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        onLine: @escaping (String) -> Void = { _ in }
    ) async throws -> Int32 {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        env["PIP_DISABLE_PIP_VERSION_CHECK"] = "1"
        env["PIP_NO_INPUT"] = "1"
        if let extra = environment { env.merge(extra) { $1 } }
        process.environment = env

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let buffer = LineBuffer(onLine: onLine)
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                buffer.flush()
            } else {
                buffer.append(data)
            }
        }

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int32, Error>) in
            process.terminationHandler = { proc in
                // даём readabilityHandler дочитать хвост
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) {
                    buffer.flush()
                    cont.resume(returning: proc.terminationStatus)
                }
            }
            do {
                try process.run()
            } catch {
                pipe.fileHandleForReading.readabilityHandler = nil
                cont.resume(throwing: ProcessRunnerError.launchFailed(error.localizedDescription))
            }
        }
    }

    /// Короткая команда: вернуть stdout целиком (или nil при ошибке).
    static func capture(executable: URL, arguments: [String], timeout: TimeInterval = 15) -> String? {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        let box = DataBox()
        let reader = DispatchQueue(label: "capture")
        let group = DispatchGroup()
        group.enter()
        reader.async {
            box.data = out.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning { process.terminate() }
        _ = group.wait(timeout: .now() + 2)
        guard process.terminationStatus == 0 else { return nil }
        return String(data: box.data, encoding: .utf8)
    }
}

final class DataBox: @unchecked Sendable { var data = Data() }

/// Накопитель строк из потока байтов.
final class LineBuffer: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()
    private let onLine: (String) -> Void

    init(onLine: @escaping (String) -> Void) { self.onLine = onLine }

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        var lines: [String] = []
        while let idx = data.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let lineData = data.subdata(in: data.startIndex..<idx)
            data.removeSubrange(data.startIndex...idx)
            if let s = String(data: lineData, encoding: .utf8), !s.isEmpty { lines.append(s) }
        }
        lock.unlock()
        lines.forEach(onLine)
    }

    func flush() {
        lock.lock()
        let rest = data
        data.removeAll()
        lock.unlock()
        if let s = String(data: rest, encoding: .utf8), !s.isEmpty { onLine(s) }
    }
}
