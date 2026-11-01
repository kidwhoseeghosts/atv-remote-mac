import Foundation

struct PythonInterpreter: Equatable, Identifiable {
    var url: URL
    var major: Int
    var minor: Int
    var patch: Int

    var id: String { url.path }
    var versionString: String { "\(major).\(minor).\(patch)" }
    var displayName: String { "Python \(versionString) — \(url.path)" }

    /// Чем выше, тем лучше. 3.12/3.13 — лучше всего (есть готовые wheels для всех зависимостей pyatv).
    var rank: Int {
        switch (major, minor) {
        case (3, 13): return 100
        case (3, 12): return 95
        case (3, 11): return 90
        case (3, 10): return 80
        case (3, 9): return 60
        case (3, 14): return 50
        default: return 0
        }
    }

    static func parse(_ output: String, url: URL) -> PythonInterpreter? {
        // "Python 3.12.4"
        let parts = output.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "Python ", with: "")
            .split(separator: ".")
        guard parts.count >= 2, let maj = Int(parts[0]), let min = Int(parts[1]) else { return nil }
        let patchDigits = parts.count > 2 ? String(parts[2].prefix(while: { $0.isNumber })) : "0"
        return PythonInterpreter(url: url, major: maj, minor: min, patch: Int(patchDigits) ?? 0)
    }
}

enum EnvironmentStatus: Equatable {
    case checking
    case missing                 // venv не создан
    case broken(String)          // venv есть, но pyatv не импортируется
    case ready(pyatv: String)
    case installing
    case failed(String)
}

enum PythonEnvironmentError: LocalizedError {
    case noPython
    case step(String, Int32)
    case verifyFailed

    var errorDescription: String? {
        switch self {
        case .noPython:
            return String(localized: "Python 3.9+ not found. Install the Command Line Tools (xcode-select --install) or Homebrew Python (brew install python).")
        case .step(let name, let code):
            return String(localized: "Step “\(name)” failed (code \(Int(code))). See the log for details.")
        case .verifyFailed:
            return String(localized: "pyatv was installed but cannot be imported. See the log for details.")
        }
    }
}

enum PythonEnvironment {
    static let minimumMinor = 9

    /// Кандидаты в порядке предпочтения.
    static let candidatePaths: [String] = [
        "/opt/homebrew/bin/python3.13",
        "/opt/homebrew/bin/python3.12",
        "/opt/homebrew/bin/python3.11",
        "/opt/homebrew/bin/python3.10",
        "/opt/homebrew/bin/python3",
        "/usr/local/bin/python3.13",
        "/usr/local/bin/python3.12",
        "/usr/local/bin/python3.11",
        "/usr/local/bin/python3",
        "/Library/Frameworks/Python.framework/Versions/Current/bin/python3",
        "/usr/bin/python3",
    ]

    /// /usr/bin/python3 — заглушка, которая показывает диалог установки CLT, если их нет.
    /// Поэтому сначала проверяем `xcode-select -p`.
    static func commandLineToolsInstalled() -> Bool {
        ProcessRunner.capture(executable: URL(fileURLWithPath: "/usr/bin/xcode-select"), arguments: ["-p"]) != nil
    }

    static func detectInterpreters() -> [PythonInterpreter] {
        let fm = FileManager.default
        let cltOK = commandLineToolsInstalled()
        var found: [PythonInterpreter] = []
        var seenRealPaths = Set<String>()
        for path in candidatePaths {
            guard fm.isExecutableFile(atPath: path) else { continue }
            if path == "/usr/bin/python3" && !cltOK { continue }
            let url = URL(fileURLWithPath: path)
            let real = url.resolvingSymlinksInPath().path
            if seenRealPaths.contains(real) { continue }
            guard let out = ProcessRunner.capture(executable: url, arguments: ["--version"]),
                  let interp = PythonInterpreter.parse(out, url: url),
                  interp.major == 3, interp.minor >= minimumMinor else { continue }
            seenRealPaths.insert(real)
            found.append(interp)
        }
        // стабильная сортировка по рангу (выше — раньше), порядок кандидатов сохраняется при равенстве
        return found.enumerated()
            .sorted { lhs, rhs in
                lhs.element.rank != rhs.element.rank ? lhs.element.rank > rhs.element.rank : lhs.offset < rhs.offset
            }
            .map { $0.element }
    }

    /// Проверка существующего venv: есть ли pyatv, и какой версии.
    static func check() -> EnvironmentStatus {
        let python = AppPaths.venvPython
        guard FileManager.default.isExecutableFile(atPath: python.path) else { return .missing }
        let code = "import pyatv, pyatv.const as c; print(c.__version__)"
        guard let out = ProcessRunner.capture(executable: python, arguments: ["-c", code], timeout: 30) else {
            return .broken(String(localized: "pyatv cannot be imported in the venv"))
        }
        let version = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return .ready(pyatv: version)
    }

    /// Создаёт venv и ставит зависимости. progress — строки журнала.
    static func install(
        using interpreter: PythonInterpreter,
        recreate: Bool = false,
        progress: @escaping (String) -> Void
    ) async throws {
        let fm = FileManager.default
        if recreate, fm.fileExists(atPath: AppPaths.venv.path) {
            progress(String(localized: "Removing old environment…"))
            try? fm.removeItem(at: AppPaths.venv)
        }

        if !fm.isExecutableFile(atPath: AppPaths.venvPython.path) {
            progress(String(localized: "Creating environment (\(interpreter.displayName))…"))
            let code = try await ProcessRunner.run(
                executable: interpreter.url,
                arguments: ["-m", "venv", AppPaths.venv.path],
                onLine: progress
            )
            guard code == 0 else { throw PythonEnvironmentError.step("python -m venv", code) }
        }

        let venvPython = AppPaths.venvPython
        progress(String(localized: "Updating pip…"))
        let pipCode = try await ProcessRunner.run(
            executable: venvPython,
            arguments: ["-m", "pip", "install", "--upgrade", "pip", "setuptools", "wheel"],
            onLine: progress
        )
        guard pipCode == 0 else { throw PythonEnvironmentError.step("pip upgrade", pipCode) }

        progress(String(localized: "Installing pyatv (this may take a couple of minutes)…"))
        var args = ["-m", "pip", "install", "--upgrade"]
        if fm.fileExists(atPath: AppPaths.requirementsFile.path) {
            args += ["-r", AppPaths.requirementsFile.path]
        } else {
            args += ["pyatv", "srptools<2"]
        }
        let installCode = try await ProcessRunner.run(executable: venvPython, arguments: args, onLine: progress)
        guard installCode == 0 else { throw PythonEnvironmentError.step("pip install pyatv", installCode) }

        progress(String(localized: "Verifying installation…"))
        guard case .ready(let version) = check() else { throw PythonEnvironmentError.verifyFailed }
        progress(String(localized: "Done: pyatv \(version)"))
    }
}
