import Foundation

/// Все пути приложения. Песочница выключена, поэтому пишем в обычный Application Support.
enum AppPaths {
    static let appSupport: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("ATVRemote", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static var venv: URL { appSupport.appendingPathComponent("venv", isDirectory: true) }
    static var venvPython: URL { venv.appendingPathComponent("bin/python3") }
    static var pyatvStorage: URL { appSupport.appendingPathComponent("pyatv.conf") }
    static var cacheDir: URL { appSupport.appendingPathComponent("cache", isDirectory: true) }
    static var logFile: URL { appSupport.appendingPathComponent("daemon.log") }

    /// Каталог с python-скриптами внутри бандла (Resources/python).
    /// Для запуска вне .app (тесты/Linux) можно переопределить переменной ATVREMOTE_PYTHON_DIR.
    static var bundledPythonDir: URL {
        if let override = ProcessInfo.processInfo.environment["ATVREMOTE_PYTHON_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        if let res = Bundle.main.resourceURL {
            return res.appendingPathComponent("python", isDirectory: true)
        }
        return URL(fileURLWithPath: "Resources/python", isDirectory: true)
    }

    static var daemonScript: URL { bundledPythonDir.appendingPathComponent("atvd.py") }
    static var requirementsFile: URL { bundledPythonDir.appendingPathComponent("requirements.txt") }
}
