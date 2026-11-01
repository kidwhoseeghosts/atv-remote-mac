import Foundation

struct DaemonEvent {
    var name: String
    var data: JSONValue
}

enum DaemonError: LocalizedError {
    case notRunning
    case timeout(String)
    case remote(code: String, message: String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .notRunning: return String(localized: "The control service is not running")
        case .timeout(let cmd): return String(localized: "Command “\(cmd)” timed out")
        case .remote(_, let message): return message
        case .invalidResponse: return String(localized: "Invalid response from the service")
        }
    }

    var code: String? {
        if case .remote(let code, _) = self { return code }
        return nil
    }
}

/// Клиент для Python-демона (atvd.py): JSON Lines через stdin/stdout.
final class DaemonClient: @unchecked Sendable {
    struct Launch {
        var python: URL
        var script: URL
        var storage: URL
        var cacheDir: URL
        var demo: Bool
        var verbose: Bool = false
        /// Язык сообщений демона для пользователя (en | ru) — тот, на котором сейчас работает приложение.
        var language: String = Bundle.main.preferredLocalizations.first ?? "en"
    }

    private let launch: Launch
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let lock = NSLock()
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var running = false
    private var stdoutBuffer: LineBuffer?
    private var stderrBuffer: LineBuffer?

    /// События демона (state, playing, artwork, power, features, keyboard, volume, log, ready).
    let events: AsyncStream<DaemonEvent>
    private let eventContinuation: AsyncStream<DaemonEvent>.Continuation

    /// Строки stderr процесса (логи pyatv/демона).
    var onLog: ((String) -> Void)?
    /// Вызывается один раз, когда процесс завершился (код выхода).
    var onTermination: ((Int32) -> Void)?

    init(launch: Launch) {
        self.launch = launch
        var cont: AsyncStream<DaemonEvent>.Continuation!
        self.events = AsyncStream<DaemonEvent> { cont = $0 }
        self.eventContinuation = cont
    }

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    // MARK: Запуск / остановка

    func start() throws {
        signal(SIGPIPE, SIG_IGN)
        try? FileManager.default.createDirectory(at: launch.cacheDir, withIntermediateDirectories: true)

        process.executableURL = launch.python
        var args = [launch.script.path, "--storage", launch.storage.path, "--cache-dir", launch.cacheDir.path]
        if launch.demo { args.append("--demo") }
        if launch.verbose { args.append("--verbose") }
        args += ["--lang", launch.language]
        process.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        env["PYTHONIOENCODING"] = "utf-8"
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        process.environment = env
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let outBuf = LineBuffer { [weak self] line in self?.handleStdoutLine(line) }
        let errBuf = LineBuffer { [weak self] line in self?.onLog?(line) }
        stdoutBuffer = outBuf
        stderrBuffer = errBuf

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; outBuf.flush() } else { outBuf.append(data) }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; errBuf.flush() } else { errBuf.append(data) }
        }

        process.terminationHandler = { [weak self] proc in
            let code = proc.terminationStatus
            // небольшая пауза, чтобы дочитать последние строки stdout
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.handleTermination(code: code)
            }
        }

        try process.run()
        lock.lock(); running = true; lock.unlock()
    }

    /// Вежливая остановка: команда quit, затем закрытие stdin, затем terminate по таймауту.
    func stop() {
        guard isRunning else { return }
        let line = "{\"id\":0,\"cmd\":\"quit\"}\n"
        try? stdinPipe.fileHandleForWriting.write(contentsOf: Data(line.utf8))
        try? stdinPipe.fileHandleForWriting.close()
        let proc = process
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            if proc.isRunning { proc.terminate() }
        }
    }

    private func handleTermination(code: Int32) {
        lock.lock()
        guard running else { lock.unlock(); return }
        running = false
        let waiting = pending
        pending.removeAll()
        lock.unlock()
        for (_, cont) in waiting { cont.resume(throwing: DaemonError.notRunning) }
        stdoutBuffer?.flush()
        stderrBuffer?.flush()
        eventContinuation.finish()
        onTermination?(code)
    }

    // MARK: Запросы

    /// Отправляет команду и ждёт ответ. Параметры кладутся в корень сообщения (плоско).
    @discardableResult
    func request(_ cmd: String, _ params: [String: JSONValue] = [:], timeout: TimeInterval = 20) async throws -> JSONValue {
        guard isRunning else { throw DaemonError.notRunning }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<JSONValue, Error>) in
            lock.lock()
            let id = nextID
            nextID += 1
            pending[id] = cont
            lock.unlock()

            var message = params
            message["id"] = .number(Double(id))
            message["cmd"] = .string(cmd)
            do {
                var data = try JSONEncoder().encode(JSONValue.object(message))
                data.append(0x0A)
                try stdinPipe.fileHandleForWriting.write(contentsOf: data)
            } catch {
                resolve(id: id, with: .failure(DaemonError.notRunning))
                return
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.resolve(id: id, with: .failure(DaemonError.timeout(cmd)))
            }
        }
    }

    /// Типизированный запрос.
    func request<T: Decodable>(_ cmd: String, _ params: [String: JSONValue] = [:], as type: T.Type, timeout: TimeInterval = 20) async throws -> T {
        let value = try await request(cmd, params, timeout: timeout)
        do { return try value.decode(T.self) } catch { throw DaemonError.invalidResponse }
    }

    private func resolve(id: Int, with result: Result<JSONValue, Error>) {
        lock.lock()
        let cont = pending.removeValue(forKey: id)
        lock.unlock()
        guard let cont else { return }
        cont.resume(with: result)
    }

    // MARK: Разбор вывода

    private func handleStdoutLine(_ line: String) {
        guard let data = line.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              let type = value["type"]?.stringValue else {
            onLog?("stdout: \(line)")
            return
        }
        switch type {
        case "response":
            guard let idValue = value["id"]?.doubleValue else { return }
            let id = Int(idValue)
            if value["ok"]?.boolValue == true {
                resolve(id: id, with: .success(value["result"] ?? .object([:])))
            } else {
                let code = value["error"]?["code"]?.stringValue ?? "error"
                let message = value["error"]?["message"]?.stringValue ?? String(localized: "Unknown error")
                resolve(id: id, with: .failure(DaemonError.remote(code: code, message: message)))
            }
        case "event":
            let name = value["event"]?.stringValue ?? ""
            eventContinuation.yield(DaemonEvent(name: name, data: value["data"] ?? .object([:])))
        default:
            break
        }
    }
}
