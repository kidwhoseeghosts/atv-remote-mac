import Foundation

// MARK: - Модели, приходящие от демона

struct ATVService: Codable, Equatable, Hashable {
    var proto: String
    var paired: Bool
    var pairing: String?
    var port: Int?
    var requiresPassword: Bool?

    enum CodingKeys: String, CodingKey {
        case proto = "protocol"
        case paired, pairing, port
        case requiresPassword
    }

    /// Нужно ли (и можно ли) спаривать этот сервис.
    var needsPairing: Bool {
        guard !paired else { return false }
        switch pairing {
        case "Mandatory", "Optional": return true
        default: return false
        }
    }
}

struct ATVDevice: Codable, Equatable, Hashable, Identifiable {
    var id: String
    var identifiers: [String]?
    var name: String
    var address: String
    var model: String?
    var os: String?
    var version: String?
    var isTv: Bool
    var services: [ATVService]

    var isPaired: Bool {
        guard let companion = services.first(where: { $0.proto == "companion" }) else {
            return services.contains(where: { $0.paired })
        }
        return companion.paired
    }

    /// Протоколы, которые ещё надо спарить, в порядке: Companion, AirPlay, MRP.
    var pendingPairingProtocols: [String] {
        let order = ["companion", "airplay", "mrp"]
        return order.filter { name in
            services.contains(where: { $0.proto == name && $0.needsPairing })
        }
    }
}

struct ScanResult: Codable {
    var devices: [ATVDevice]
}

struct ConnectResult: Codable {
    var device: ATVDevice?
}

struct PairStartResult: Codable {
    var deviceProvidesPin: Bool
    var pin: Int?
}

struct PairFinishResult: Codable {
    var paired: Bool
    var device: ATVDevice?
}

struct PlayingInfo: Codable, Equatable {
    var title: String?
    var artist: String?
    var album: String?
    var seriesName: String?
    var app: String?
    var appId: String?
    var deviceState: String?
    var mediaType: String?
    var position: Double?
    var totalTime: Double?
    var timestamp: Double?

    var isPlaying: Bool { deviceState == "Playing" }
    var isActive: Bool {
        guard let s = deviceState else { return false }
        return s != "Idle" && s != "Stopped"
    }

    var displayTitle: String {
        if let t = title, !t.isEmpty { return t }
        if let a = app, !a.isEmpty { return a }
        return ""
    }

    var displaySubtitle: String {
        var parts: [String] = []
        if let s = seriesName, !s.isEmpty { parts.append(s) }
        if let a = artist, !a.isEmpty { parts.append(a) }
        if parts.isEmpty, let al = album, !al.isEmpty { parts.append(al) }
        if let app = app, !app.isEmpty, title != nil { parts.append(app) }
        return parts.joined(separator: " · ")
    }
}

struct AppInfo: Codable, Equatable, Hashable, Identifiable {
    var id: String
    var name: String
}

struct AppsResult: Codable {
    var apps: [AppInfo]
}

struct StateEvent: Codable {
    var state: String
    var message: String?
    var deviceId: String?
}

// MARK: - Состояние соединения (для UI)

enum ConnectionState: Equatable {
    case stopped          // демон не запущен
    case disconnected
    case connecting
    case connected
    case reconnecting
    case needsPairing
    case failed(String)

    var isConnected: Bool { self == .connected }

    var isBusy: Bool {
        switch self {
        case .connecting, .reconnecting: return true
        default: return false
        }
    }
}

// MARK: - Клавиши пульта

enum RemoteKey: String, CaseIterable, Codable {
    case up, down, left, right, select, menu, home
    case homeHold = "home_hold"
    case topMenu = "top_menu"
    case playPause = "play_pause"
    case play, pause, stop, next, previous
    case skipForward = "skip_forward"
    case skipBackward = "skip_backward"
    case volumeUp = "volume_up"
    case volumeDown = "volume_down"

    /// Имя FeatureName в pyatv — для затемнения недоступных кнопок.
    var featureName: String {
        switch self {
        case .up: return "Up"
        case .down: return "Down"
        case .left: return "Left"
        case .right: return "Right"
        case .select: return "Select"
        case .menu: return "Menu"
        case .home: return "Home"
        case .homeHold: return "HomeHold"
        case .topMenu: return "TopMenu"
        case .playPause: return "PlayPause"
        case .play: return "Play"
        case .pause: return "Pause"
        case .stop: return "Stop"
        case .next: return "Next"
        case .previous: return "Previous"
        case .skipForward: return "SkipForward"
        case .skipBackward: return "SkipBackward"
        case .volumeUp: return "VolumeUp"
        case .volumeDown: return "VolumeDown"
        }
    }

    /// HID-кнопки, которые не затемняем по `features` (их состояние Apple TV не отслеживает).
    var isAlwaysEnabled: Bool {
        switch self {
        case .up, .down, .left, .right, .select, .menu, .home, .homeHold, .topMenu, .volumeUp, .volumeDown:
            return true
        default:
            return false
        }
    }

    var isVolume: Bool { self == .volumeUp || self == .volumeDown }

    var localizedTitle: String {
        switch self {
        case .up: return String(localized: "Up")
        case .down: return String(localized: "Down")
        case .left: return String(localized: "Left")
        case .right: return String(localized: "Right")
        case .select: return String(localized: "Select")
        case .menu: return String(localized: "Back")
        case .home: return String(localized: "Home")
        case .homeHold: return String(localized: "Home (hold)")
        case .topMenu: return String(localized: "Main menu")
        case .playPause: return String(localized: "Play / Pause")
        case .play: return String(localized: "Play")
        case .pause: return String(localized: "Pause")
        case .stop: return String(localized: "Stop")
        case .next: return String(localized: "Next")
        case .previous: return String(localized: "Previous")
        case .skipForward: return String(localized: "Forward 10 s")
        case .skipBackward: return String(localized: "Back 10 s")
        case .volumeUp: return String(localized: "Volume Up")
        case .volumeDown: return String(localized: "Volume Down")
        }
    }
}

enum PressAction: String {
    case tap, double, hold
}

enum Direction: Equatable, Hashable {
    case up, down, left, right

    var key: RemoteKey {
        switch self {
        case .up: return .up
        case .down: return .down
        case .left: return .left
        case .right: return .right
        }
    }
}


// MARK: - Диагностика громкости

struct VolumeMethodInfo: Codable, Equatable, Identifiable, Hashable {
    var id: String
    var label: String
}

struct VolumeStepResult: Codable, Equatable {
    var ok: Bool
    var error: String?
    var volumeChanged: Bool?
    var volumeEvents: Int?
}

struct VolumeDiagStep: Codable, Equatable, Identifiable {
    var id: String
    var label: String
    var ok: Bool
    var up: VolumeStepResult?
    var down: VolumeStepResult?
}

/// Ответ демона на `volume_diag` без параметров: состояние каналов и список способов.
struct VolumeDiagInfo: Codable, Equatable {
    var protocols: [String]
    var mrpTunnel: Bool
    var airplayPaired: Bool?
    var airplayAvailable: Bool?
    var forceMrpTunnel: Bool?
    var preferred: String?
    /// "pair_airplay" | "force_tunnel" | nil
    var advice: String?
    var methods: [VolumeMethodInfo]?
}

struct VolumeDiagRunResult: Codable, Equatable {
    var results: [VolumeDiagStep]
}
