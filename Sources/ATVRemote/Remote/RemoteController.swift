#if canImport(Combine)
import Combine
#endif
import Foundation

enum RemotePanel: Equatable {
    case remote
    case apps
    case keyboard
    case devices
    case pairing
    case settings
    case volumeDiag
    case setup
}

enum VolumeDiagPhase: Equatable {
    case idle
    case loading
    case running(index: Int, total: Int, label: String, direction: String)
    case done
    case failed(String)
}

enum PairingPhase: Equatable {
    case idle
    case starting(proto: String)
    /// device показывает PIN сам → вводим его; иначе мы задали PIN (fixedPin) и его нужно ввести на Apple TV.
    case awaitingPIN(proto: String, deviceShowsPIN: Bool, fixedPin: Int?)
    case submitting(proto: String)
    case failed(proto: String, message: String)
    case done
}

/// Главный объект состояния. Все публичные изменения — на главном потоке.
@MainActor
final class RemoteController: ObservableObject {

    // MARK: Окружение (Python)
    @Published var environment: EnvironmentStatus = .checking
    @Published var installLog: [String] = []
    @Published var interpreters: [PythonInterpreter] = []

    // MARK: Соединение
    @Published var connection: ConnectionState = .stopped
    @Published var statusMessage: String = ""
    @Published var devices: [ATVDevice] = []
    @Published var isScanning = false
    @Published var currentDevice: ATVDevice?

    // MARK: Состояние Apple TV
    @Published var playing: PlayingInfo?
    @Published var artworkPath: String?
    @Published var powerState: String = "Unknown"
    @Published var features: [String: String] = [:]
    @Published var volumeLevel: Double?
    @Published var keyboardFocused = false
    @Published var apps: [AppInfo] = []
    @Published var appsLoading = false

    // MARK: UI
    @Published var panel: RemotePanel = .remote
    @Published var toast: String?
    @Published var daemonLog: [String] = []

    // MARK: Сопряжение
    @Published var pairingDevice: ATVDevice?
    @Published var pairingPhase: PairingPhase = .idle
    @Published var pairingTotal = 0
    private var pairingQueue: [String] = []

    // MARK: Диагностика громкости
    @Published var volumeDiagPhase: VolumeDiagPhase = .idle
    @Published var volumeDiagInfo: VolumeDiagInfo?
    @Published var volumeDiagResults: [VolumeDiagStep] = []

    // MARK: Настройки (UserDefaults)
    @Published var showArtwork: Bool { didSet { defaults.set(showArtwork, forKey: Keys.showArtwork); pushOptions() } }
    @Published var hotkeysEnabled: Bool { didSet { defaults.set(hotkeysEnabled, forKey: Keys.hotkeysEnabled) } }
    @Published var demoMode: Bool { didSet { defaults.set(demoMode, forKey: Keys.demoMode) } }
    @Published var floatingAlwaysOnTop: Bool { didSet { defaults.set(floatingAlwaysOnTop, forKey: Keys.floatingOnTop) } }
    @Published var hapticsEnabled: Bool { didSet { defaults.set(hapticsEnabled, forKey: Keys.haptics) } }
    /// Выбранный пользователем способ громкости ("auto" — порядок по умолчанию).
    @Published var volumeMethod: String { didSet { defaults.set(volumeMethod, forKey: Keys.volumeMethod); pushOptions() } }
    /// Принудительно поднимать MRP-туннель через AirPlay.
    @Published var forceMrpTunnel: Bool { didSet { defaults.set(forceMrpTunnel, forKey: Keys.forceMrpTunnel); pushOptions() } }
    @Published var hotkeys: [HotKeyAction: KeyCombo] { didSet { HotKeyStore.save(hotkeys) } }

    /// Устанавливается AppDelegate: показать/скрыть плавающее окно.
    var onToggleFloatingWindow: (() -> Void)?

    // MARK: Внутреннее
    private let defaults = UserDefaults.standard
    private var client: DaemonClient?
    private var eventTask: Task<Void, Never>?
    private var intentionalStop = false
    private var restartCount = 0
    private var toastTask: Task<Void, Never>?
    private var logFileHandle: FileHandle?
    private var lastDevicePersisted: ATVDevice?

    private enum Keys {
        static let showArtwork = "showArtwork"
        static let hotkeysEnabled = "hotkeysEnabled"
        static let demoMode = "demoMode"
        static let floatingOnTop = "floatingAlwaysOnTop"
        static let haptics = "hapticsEnabled"
        static let volumeMethod = "volumeMethod"
        static let forceMrpTunnel = "forceMrpTunnel"
        static let lastDevice = "lastDevice.v1"
        static let knownDevices = "knownDevices.v1"
    }

    init() {
        let d = UserDefaults.standard
        d.register(defaults: [
            Keys.showArtwork: true, Keys.hotkeysEnabled: true, Keys.demoMode: false,
            Keys.floatingOnTop: true, Keys.haptics: true,
            Keys.volumeMethod: "auto", Keys.forceMrpTunnel: false,
        ])
        volumeMethod = d.string(forKey: Keys.volumeMethod) ?? "auto"
        forceMrpTunnel = d.bool(forKey: Keys.forceMrpTunnel)
        showArtwork = d.bool(forKey: Keys.showArtwork)
        hotkeysEnabled = d.bool(forKey: Keys.hotkeysEnabled)
        demoMode = d.bool(forKey: Keys.demoMode)
        floatingAlwaysOnTop = d.bool(forKey: Keys.floatingOnTop)
        hapticsEnabled = d.bool(forKey: Keys.haptics)
        hotkeys = HotKeyStore.load()
        devices = Self.loadKnownDevices()
        if let data = d.data(forKey: Keys.lastDevice), let dev = try? JSONDecoder().decode(ATVDevice.self, from: data) {
            lastDevicePersisted = dev
            currentDevice = dev
        }
    }

    // MARK: - Запуск

    /// Вызывается один раз при старте приложения.
    func bootstrap() {
        environment = .checking
        Task {
            let status = await Task.detached(priority: .userInitiated) { PythonEnvironment.check() }.value
            environment = status
            switch status {
            case .ready:
                startDaemon()
            default:
                panel = .setup
                interpreters = await Task.detached { PythonEnvironment.detectInterpreters() }.value
            }
        }
    }

    // MARK: - Установка окружения

    func installEnvironment(interpreter: PythonInterpreter? = nil, recreate: Bool = false) {
        guard environment != .installing else { return }
        installLog = []
        environment = .installing
        stopDaemon()
        Task {
            var choice = interpreter
            if choice == nil {
                if interpreters.isEmpty {
                    interpreters = await Task.detached { PythonEnvironment.detectInterpreters() }.value
                }
                choice = interpreters.first
            }
            guard let chosen = choice else {
                environment = .failed(PythonEnvironmentError.noPython.localizedDescription)
                return
            }
            do {
                try await PythonEnvironment.install(using: chosen, recreate: recreate) { [weak self = self] line in
                    Task { @MainActor [weak self] in self?.appendInstallLog(line) }
                }
                environment = PythonEnvironment.check()
                if case .ready = environment {
                    panel = .remote
                    startDaemon()
                }
            } catch {
                environment = .failed(error.localizedDescription)
            }
        }
    }

    /// Приблизительный прогресс установки 0…1 по строкам журнала.
    var installProgress: Double {
        var p = 0.03
        var collecting = 0
        for line in installLog {
            if line.hasPrefix(String(localized: "Removing")) { p = max(p, 0.05) }
            else if line.hasPrefix(String(localized: "Creating environment")) { p = max(p, 0.1) }
            else if line.hasPrefix(String(localized: "Updating pip")) { p = max(p, 0.2) }
            else if line.hasPrefix(String(localized: "Installing pyatv")) { p = max(p, 0.3) }
            else if line.hasPrefix("Collecting") { collecting += 1 }
            else if line.hasPrefix(String(localized: "Verifying")) { p = max(p, 0.95) }
            else if line.hasPrefix(String(localized: "Done")) { p = 1 }
        }
        if p >= 0.3 && p < 0.95 { p = min(0.9, 0.3 + Double(collecting) * 0.025) }
        return p
    }

    private func appendInstallLog(_ line: String) {
        installLog.append(line)
        if installLog.count > 400 { installLog.removeFirst(installLog.count - 400) }
    }

    // MARK: - Демон

    func startDaemon() {
        guard client == nil else { return }
        intentionalStop = false
        let launch = DaemonClient.Launch(
            python: AppPaths.venvPython,
            script: AppPaths.daemonScript,
            storage: AppPaths.pyatvStorage,
            cacheDir: AppPaths.cacheDir,
            demo: demoMode
        )
        let newClient = DaemonClient(launch: launch)
        newClient.onLog = { [weak self] line in
            Task { @MainActor in self?.appendDaemonLog(line) }
        }
        newClient.onTermination = { [weak self, weak newClient] code in
            Task { @MainActor in
                guard let self, let newClient, self.client === newClient else { return }
                self.daemonTerminated(code: code)
            }
        }
        do {
            try newClient.start()
        } catch {
            connection = .failed(String(localized: "Failed to start the service: \(error.localizedDescription)"))
            return
        }
        client = newClient
        connection = .disconnected
        eventTask = Task { [weak self] in
            for await event in newClient.events {
                guard let self else { return }
                self.handle(event: event)
            }
        }
        Task { await afterDaemonStarted(newClient) }
    }

    func stopDaemon() {
        intentionalStop = true
        eventTask?.cancel()
        eventTask = nil
        client?.stop()
        client = nil
        connection = .stopped
        resetLiveState()
    }

    func restartDaemon() {
        stopDaemon()
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            restartCount = 0
            startDaemon()
        }
    }

    private func daemonTerminated(code: Int32) {
        client = nil
        eventTask?.cancel()
        resetLiveState()
        if intentionalStop { connection = .stopped; return }
        restartCount += 1
        if restartCount <= 3 {
            connection = .reconnecting
            statusMessage = String(localized: "The service stopped (code \(Int(code))), restarting…")
            Task {
                try? await Task.sleep(nanoseconds: UInt64(restartCount) * 1_500_000_000)
                startDaemon()
            }
        } else {
            connection = .failed(String(localized: "The control service crashed (code \(Int(code))). See the log in Settings."))
        }
    }

    private func afterDaemonStarted(_ c: DaemonClient) async {
        do {
            _ = try await c.request("hello", timeout: 20)
            restartCount = 0
            try await pushOptionsAsync(c)
        } catch {
            appendDaemonLog("hello failed: \(error.localizedDescription)")
            return
        }
        if let last = lastDevicePersisted {
            connect(last)
        } else {
            panel = .devices
            scan()
        }
    }

    private func pushOptions() {
        guard let c = client else { return }
        Task { try? await pushOptionsAsync(c) }
    }

    private func pushOptionsAsync(_ c: DaemonClient) async throws {
        let name = Host.current().localizedName ?? "Mac"
        try await c.request("set_options", [
            "artwork": .bool(showArtwork),
            "client_name": .string("ATVRemote (\(name))"),
            "volume_method": .string(volumeMethod),
            "force_mrp_tunnel": .bool(forceMrpTunnel),
        ])
    }

    private func resetLiveState() {
        playing = nil
        artworkPath = nil
        features = [:]
        powerState = "Unknown"
        volumeLevel = nil
        keyboardFocused = false
        isScanning = false
    }

    // MARK: - События демона

    private func handle(event: DaemonEvent) {
        switch event.name {
        case "state":
            guard let s = try? event.data.decode(StateEvent.self) else { return }
            apply(state: s)
        case "playing":
            playing = try? event.data.decode(PlayingInfo.self)
            if playing?.isActive != true { artworkPath = nil }
        case "artwork":
            artworkPath = showArtwork ? event.data["path"]?.stringValue : nil
        case "power":
            powerState = event.data["state"]?.stringValue ?? "Unknown"
        case "features":
            if let f = event.data["features"], let dict = try? f.decode([String: String].self) { features = dict }
        case "keyboard":
            keyboardFocused = event.data["focus"]?.stringValue == "Focused"
        case "volume":
            volumeLevel = event.data["level"]?.doubleValue
        case "volume_diag":
            guard case .running = volumeDiagPhase else { return }
            let phase = event.data["phase"]?.stringValue ?? ""
            if phase == "done" { return }
            volumeDiagPhase = .running(
                index: Int(event.data["index"]?.doubleValue ?? 0),
                total: Int(event.data["total"]?.doubleValue ?? 0),
                label: event.data["label"]?.stringValue ?? "",
                direction: phase
            )
        case "log":
            if let m = event.data["message"]?.stringValue { appendDaemonLog(m) }
        default:
            break
        }
    }

    private func apply(state s: StateEvent) {
        statusMessage = s.message ?? ""
        switch s.state {
        case "connecting": connection = .connecting
        case "connected": connection = .connected; restartCount = 0
        case "reconnecting": connection = .reconnecting
        case "needs_pairing":
            connection = .needsPairing
        case "disconnected":
            connection = .disconnected
            playing = nil; artworkPath = nil
        default: break
        }
    }

    // MARK: - Поиск и подключение

    func scan() {
        guard let c = client, !isScanning else { return }
        isScanning = true
        Task {
            defer { isScanning = false }
            do {
                let result = try await c.request("scan", ["timeout": 6], as: ScanResult.self, timeout: 30)
                mergeScan(result.devices)
            } catch {
                showToast(error.localizedDescription)
            }
        }
    }

    private func mergeScan(_ found: [ATVDevice]) {
        var byID = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0) })
        for d in found { byID[d.id] = d }
        // известные, но не найденные устройства оставляем, только если они спарены
        devices = byID.values.sorted {
            if $0.isTv != $1.isTv { return $0.isTv && !$1.isTv }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        persistKnownDevices()
        if let cur = currentDevice, let fresh = byID[cur.id] { currentDevice = fresh }
    }

    func connect(_ device: ATVDevice) {
        guard let c = client else { return }
        currentDevice = device
        lastDevicePersisted = device
        if let data = try? JSONEncoder().encode(device) { defaults.set(data, forKey: Keys.lastDevice) }
        connection = .connecting
        statusMessage = String(localized: "Connecting to “\(device.name)”…")
        resetPlaybackState()
        Task {
            do {
                let params: [String: JSONValue] = [
                    "device": .string(device.id), "address": .string(device.address), "name": .string(device.name),
                ]
                let result = try await c.request("connect", params, as: ConnectResult.self, timeout: 60)
                if let fresh = result.device {
                    currentDevice = fresh
                    mergeScan([fresh])
                }
            } catch let error as DaemonError {
                switch error {
                case .timeout:
                    break // демон продолжает переподключаться в фоне; статус придёт событием
                case .remote(let code, let message):
                    if code == "no_credentials" {
                        connection = .needsPairing
                    } else {
                        connection = .failed(message)
                    }
                default:
                    connection = .failed(error.localizedDescription)
                }
            } catch {
                connection = .failed(error.localizedDescription)
            }
        }
    }

    func reconnect() {
        if let d = currentDevice ?? lastDevicePersisted {
            if client == nil { startDaemon() } else { connect(d) }
        } else {
            panel = .devices
            scan()
        }
    }

    func disconnect() {
        guard let c = client else { return }
        Task { try? await c.request("disconnect") }
    }

    private func resetPlaybackState() {
        playing = nil
        artworkPath = nil
        features = [:]
        apps = []
    }

    func forget(_ device: ATVDevice) {
        guard let c = client else { return }
        Task {
            do {
                try await c.request("forget", ["device": .string(device.id)])
                if currentDevice?.id == device.id {
                    connection = .disconnected
                    currentDevice = nil
                    lastDevicePersisted = nil
                    defaults.removeObject(forKey: Keys.lastDevice)
                }
                devices.removeAll { $0.id == device.id }
                persistKnownDevices()
                scan()
            } catch {
                showToast(error.localizedDescription)
            }
        }
    }

    // MARK: - Команды пульта

    /// Кнопка затемняется только если функция точно недоступна. Кнопки HID (стрелки, Home,
    /// Меню, громкость) не затемняем по состоянию функций: Apple TV сам решает, что с ними
    /// делать, а ошибка (если будет) показывается тостом.
    func isAvailable(_ key: RemoteKey) -> Bool {
        guard connection.isConnected else { return false }
        if key.isAlwaysEnabled { return true }
        guard let state = features[key.featureName] else { return true }
        return state == "Available" || state == "Unknown"
    }

    func isFeatureAvailable(_ name: String) -> Bool {
        guard connection.isConnected else { return false }
        guard let state = features[name] else { return true }
        return state == "Available" || state == "Unknown"
    }

    /// Громкость идёт кнопками Companion HID (VolumeUp/VolumeDown) — абсолютный уровень
    /// (SetVolume) для неё не нужен. Mute по этой причине тоже не затемняем.
    var canAdjustVolume: Bool { connection.isConnected }

    /// Один раз за сеанс подсказываем, куда смотреть, если громкость ТВ не меняется.
    private var volumeHintShown = false

    func press(_ key: RemoteKey, action: PressAction = .tap) {
        guard let c = client, connection.isConnected else {
            if connection == .needsPairing { panel = .devices }
            return
        }
        Task {
            do {
                try await c.request("key", ["key": .string(key.rawValue), "action": .string(action.rawValue)], timeout: 15)
                if key.isVolume, !volumeHintShown, !isFeatureAvailable("SetVolume") {
                    volumeHintShown = true
                    showToast(String(localized: "TV volume goes through HDMI-CEC. Not changing? Apple TV → Settings → Remotes and Devices → Volume Control."))
                }
            } catch let error as DaemonError {
                if error.code == "not_supported" {
                    showToast(String(localized: "“\(key.localizedTitle)” is not supported by this device"))
                } else {
                    showToast(error.localizedDescription)
                }
            } catch {
                showToast(error.localizedDescription)
            }
        }
    }

    func press(_ direction: Direction) { press(direction.key) }

    func togglePower() {
        guard let c = client, connection.isConnected else { return }
        Task {
            do {
                try await c.request("power", [:], timeout: 20)
            } catch {
                showToast(error.localizedDescription)
            }
        }
    }

    var isPoweredOn: Bool { powerState == "On" }

    func toggleMute() {
        guard let c = client, connection.isConnected else { return }
        Task {
            do {
                try await c.request("mute", [:], timeout: 15)
            } catch let error as DaemonError {
                // демон сам объясняет причину (HDMI-CEC/ИК: у Companion нет кнопки Mute)
                showToast(error.localizedDescription)
            } catch {
                showToast(error.localizedDescription)
            }
        }
    }

    // MARK: - Приложения и текст

    func loadApps() {
        guard let c = client, connection.isConnected else { return }
        appsLoading = true
        Task {
            defer { appsLoading = false }
            do {
                let result = try await c.request("apps", as: AppsResult.self, timeout: 20)
                apps = result.apps
            } catch {
                showToast(error.localizedDescription)
            }
        }
    }

    func launch(_ app: AppInfo) {
        guard let c = client, connection.isConnected else { return }
        panel = .remote
        Task {
            do { try await c.request("launch_app", ["app": .string(app.id)]) }
            catch { showToast(error.localizedDescription) }
        }
    }

    /// mode: "set" (заменить), "append", "clear"
    func sendText(_ text: String, mode: String = "set") {
        guard let c = client, connection.isConnected else { return }
        Task {
            do { try await c.request("text", ["mode": .string(mode), "text": .string(text)]) }
            catch let error as DaemonError {
                showToast(error.code == "not_supported" ? String(localized: "Text input is not supported by this device") : error.localizedDescription)
            } catch { showToast(error.localizedDescription) }
        }
    }

    // MARK: - Сопряжение

    /// Начать сопряжение со всеми недостающими протоколами устройства.
    func startPairing(_ device: ATVDevice, only protocols: [String]? = nil) {
        guard client != nil else { return }
        pairingDevice = device
        pairingQueue = protocols ?? device.pendingPairingProtocols
        pairingTotal = pairingQueue.count
        panel = .pairing
        if pairingQueue.isEmpty {
            pairingPhase = .done
            finishPairing()
        } else {
            beginCurrentPairingStep()
        }
    }

    var currentPairingProtocol: String? { pairingQueue.first }
    var remainingPairingProtocols: [String] { pairingQueue }

    private func beginCurrentPairingStep() {
        guard let c = client, let device = pairingDevice, let proto = pairingQueue.first else {
            finishPairing()
            return
        }
        pairingPhase = .starting(proto: proto)
        Task {
            do {
                let params: [String: JSONValue] = [
                    "device": .string(device.id), "protocol": .string(proto), "address": .string(device.address),
                ]
                let r = try await c.request("pair_start", params, as: PairStartResult.self, timeout: 30)
                pairingPhase = .awaitingPIN(proto: proto, deviceShowsPIN: r.deviceProvidesPin, fixedPin: r.pin)
            } catch {
                pairingPhase = .failed(proto: proto, message: error.localizedDescription)
            }
        }
    }

    /// pin == nil: PIN задан нами и уже введён на Apple TV — просто завершаем.
    func submitPairingPIN(_ pin: String?) {
        guard let c = client, let proto = pairingQueue.first else { return }
        pairingPhase = .submitting(proto: proto)
        Task {
            do {
                var params: [String: JSONValue] = [:]
                if let pin { params["pin"] = .string(pin) }
                let r = try await c.request("pair_pin", params, as: PairFinishResult.self, timeout: 40)
                if let dev = r.device {
                    pairingDevice = dev
                    mergeScan([dev])
                }
                if !pairingQueue.isEmpty { pairingQueue.removeFirst() }
                if pairingQueue.isEmpty { finishPairing() } else { beginCurrentPairingStep() }
            } catch {
                // сессия сопряжения закрыта демоном — начнём этот протокол заново
                pairingPhase = .failed(proto: proto, message: error.localizedDescription)
            }
        }
    }

    func retryPairingStep() { beginCurrentPairingStep() }

    /// Пропустить текущий протокол (напр. AirPlay) и перейти к следующему.
    func skipPairingStep() {
        if let c = client { Task { try? await c.request("pair_cancel") } }
        if !pairingQueue.isEmpty { pairingQueue.removeFirst() }
        if pairingQueue.isEmpty { finishPairing() } else { beginCurrentPairingStep() }
    }

    func cancelPairing() {
        if let c = client { Task { try? await c.request("pair_cancel") } }
        pairingQueue = []
        pairingPhase = .idle
        pairingDevice = nil
        panel = .devices
    }

    private func finishPairing() {
        pairingPhase = .done
        guard let device = pairingDevice else { return }
        Task {
            try? await Task.sleep(nanoseconds: 900_000_000)
            panel = .remote
            pairingPhase = .idle
            pairingDevice = nil
            connect(devices.first(where: { $0.id == device.id }) ?? device)
        }
    }

    // MARK: - Диагностика громкости

    /// Открыть экран диагностики и подтянуть состояние каналов управления.
    func openVolumeDiagnostics() {
        panel = .volumeDiag
        volumeDiagResults = []
        loadVolumeDiagInfo()
    }

    func loadVolumeDiagInfo() {
        guard let c = client, connection == .connected else {
            volumeDiagInfo = nil
            volumeDiagPhase = .failed(String(localized: "Not connected to Apple TV. Connect to a device first."))
            return
        }
        volumeDiagPhase = .loading
        Task {
            do {
                let info = try await c.request("volume_diag", as: VolumeDiagInfo.self, timeout: 20)
                volumeDiagInfo = info
                volumeDiagPhase = .idle
            } catch {
                volumeDiagPhase = .failed(error.localizedDescription)
            }
        }
    }

    /// Пробует каждый способ по очереди (громче → пауза → тише → пауза); смотрите на экран телевизора.
    func runVolumeDiagnostics() {
        guard let c = client, connection == .connected else {
            volumeDiagPhase = .failed(String(localized: "Not connected to Apple TV."))
            return
        }
        volumeDiagResults = []
        volumeDiagPhase = .running(index: 0, total: volumeDiagInfo?.methods?.count ?? 0, label: "", direction: "up")
        Task {
            do {
                let res = try await c.request("volume_diag", ["run": .bool(true), "delay": .number(2.0)], as: VolumeDiagRunResult.self, timeout: 180)
                volumeDiagResults = res.results
                volumeDiagPhase = .done
            } catch {
                volumeDiagPhase = .failed(error.localizedDescription)
            }
        }
    }

    /// Запомнить способ, который заметно изменил громкость на телевизоре.
    func chooseVolumeMethod(_ id: String) {
        volumeMethod = id
        let label = volumeDiagInfo?.methods?.first(where: { $0.id == id })?.label
            ?? volumeDiagResults.first(where: { $0.id == id })?.label ?? id
        showToast(String(localized: "Volume method: \(label)"))
    }

    func resetVolumeMethod() {
        volumeMethod = "auto"
        showToast(String(localized: "Volume: automatic selection"))
    }

    /// Сопрячь только AirPlay (нужно для MRP-туннеля, которым пользуется официальный пульт).
    func pairAirPlayForVolume() {
        guard let device = currentDevice else { return }
        startPairing(device, only: ["airplay"])
    }

    /// Включить/выключить принудительный MRP-туннель и переподключиться.
    func setForceMrpTunnel(_ on: Bool) {
        guard forceMrpTunnel != on else { return }
        forceMrpTunnel = on
        guard let c = client, let device = currentDevice else { return }
        Task {
            try? await pushOptionsAsync(c)
            connect(device)
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if connection == .connected { loadVolumeDiagInfo() }
        }
    }

    // MARK: - Горячие клавиши

    func perform(_ action: HotKeyAction) {
        switch action {
        case .toggleFloatingWindow: onToggleFloatingWindow?()
        case .mute: toggleMute()
        case .power: togglePower()
        default:
            if let key = action.remoteKey { press(key) }
        }
    }

    // MARK: - Прочее

    func showToast(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            if !Task.isCancelled { toast = nil }
        }
    }

    private func appendDaemonLog(_ line: String) {
        daemonLog.append(line)
        if daemonLog.count > 500 { daemonLog.removeFirst(daemonLog.count - 500) }
        writeToLogFile(line)
    }

    private func writeToLogFile(_ line: String) {
        if logFileHandle == nil {
            let url = AppPaths.logFile
            // ротация: файл > 1 МБ начинаем заново
            if let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil, size > 1_000_000 {
                try? FileManager.default.removeItem(at: url)
            }
            if !FileManager.default.fileExists(atPath: url.path) {
                _ = FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            logFileHandle = try? FileHandle(forWritingTo: url)
            _ = try? logFileHandle?.seekToEnd()
        }
        try? logFileHandle?.write(contentsOf: Data((line + "\n").utf8))
    }

    private func persistKnownDevices() {
        let paired = devices.filter { $0.isPaired }
        if let data = try? JSONEncoder().encode(paired) { defaults.set(data, forKey: Keys.knownDevices) }
    }

    private static func loadKnownDevices() -> [ATVDevice] {
        guard let data = UserDefaults.standard.data(forKey: Keys.knownDevices),
              let list = try? JSONDecoder().decode([ATVDevice].self, from: data) else { return [] }
        return list
    }

    func shutdown() {
        stopDaemon()
    }
}
