import Foundation

/// Модификаторы в формате Carbon (совпадают с cmdKey/shiftKey/optionKey/controlKey).
enum CarbonModifier {
    static let command: UInt32 = 0x0100
    static let shift: UInt32 = 0x0200
    static let option: UInt32 = 0x0800
    static let control: UInt32 = 0x1000
}

struct KeyCombo: Codable, Equatable, Hashable {
    var keyCode: UInt32
    var modifiers: UInt32

    var displayString: String {
        var s = ""
        if modifiers & CarbonModifier.control != 0 { s += "⌃" }
        if modifiers & CarbonModifier.option != 0 { s += "⌥" }
        if modifiers & CarbonModifier.shift != 0 { s += "⇧" }
        if modifiers & CarbonModifier.command != 0 { s += "⌘" }
        return s + KeyCombo.keyName(keyCode)
    }

    static func keyName(_ code: UInt32) -> String {
        if let name = names[code] { return name }
        return "Key\(code)"
    }

    /// ANSI-раскладка (виртуальные коды клавиш macOS).
    static let names: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7",
        27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P",
        36: "↩", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/",
        45: "N", 46: "M", 47: ".", 48: "⇥", 49: "Space", 50: "`", 51: "⌫", 53: "⎋",
        96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11",
        109: "F10", 111: "F12", 115: "↖", 116: "⇞", 117: "⌦", 118: "F4", 119: "↘",
        120: "F2", 121: "⇟", 122: "F1", 123: "←", 124: "→", 125: "↓", 126: "↑",
    ]
}

enum HotKeyAction: String, CaseIterable, Codable, Identifiable {
    case up, down, left, right, select, back, home
    case playPause, skipBack, skipForward
    case volumeUp, volumeDown, mute, power
    case toggleFloatingWindow

    var id: String { rawValue }

    var title: String {
        switch self {
        case .up: return String(localized: "Up")
        case .down: return String(localized: "Down")
        case .left: return String(localized: "Left")
        case .right: return String(localized: "Right")
        case .select: return String(localized: "Select")
        case .back: return String(localized: "Back (Menu)")
        case .home: return String(localized: "Home (TV)")
        case .playPause: return String(localized: "Play / Pause")
        case .skipBack: return String(localized: "Back 10 s")
        case .skipForward: return String(localized: "Forward 10 s")
        case .volumeUp: return String(localized: "Volume Up")
        case .volumeDown: return String(localized: "Volume Down")
        case .mute: return String(localized: "Mute")
        case .power: return String(localized: "Power on/off")
        case .toggleFloatingWindow: return String(localized: "Floating remote window")
        }
    }

    var remoteKey: RemoteKey? {
        switch self {
        case .up: return .up
        case .down: return .down
        case .left: return .left
        case .right: return .right
        case .select: return .select
        case .back: return .menu
        case .home: return .home
        case .playPause: return .playPause
        case .skipBack: return .skipBackward
        case .skipForward: return .skipForward
        case .volumeUp: return .volumeUp
        case .volumeDown: return .volumeDown
        case .mute, .power, .toggleFloatingWindow: return nil
        }
    }

    /// ⌃⌥ + …  (внимание: часть сочетаний занята Rectangle — см. README).
    var defaultCombo: KeyCombo {
        let co = CarbonModifier.control | CarbonModifier.option
        switch self {
        case .up: return KeyCombo(keyCode: 126, modifiers: co)
        case .down: return KeyCombo(keyCode: 125, modifiers: co)
        case .left: return KeyCombo(keyCode: 123, modifiers: co)
        case .right: return KeyCombo(keyCode: 124, modifiers: co)
        case .select: return KeyCombo(keyCode: 36, modifiers: co)
        case .back: return KeyCombo(keyCode: 51, modifiers: co)
        case .home: return KeyCombo(keyCode: 4, modifiers: co)
        case .playPause: return KeyCombo(keyCode: 49, modifiers: co)
        case .skipBack: return KeyCombo(keyCode: 43, modifiers: co)
        case .skipForward: return KeyCombo(keyCode: 47, modifiers: co)
        case .volumeUp: return KeyCombo(keyCode: 24, modifiers: co)
        case .volumeDown: return KeyCombo(keyCode: 27, modifiers: co)
        case .mute: return KeyCombo(keyCode: 46, modifiers: co)
        case .power: return KeyCombo(keyCode: 35, modifiers: co)
        case .toggleFloatingWindow: return KeyCombo(keyCode: 15, modifiers: co)
        }
    }
}

enum HotKeyStore {
    private static let key = "hotkeyBindings.v1"

    static func load() -> [HotKeyAction: KeyCombo] {
        var result: [HotKeyAction: KeyCombo] = [:]
        for action in HotKeyAction.allCases { result[action] = action.defaultCombo }
        if let data = UserDefaults.standard.data(forKey: key),
           let stored = try? JSONDecoder().decode([String: KeyCombo].self, from: data) {
            for (name, combo) in stored {
                if let action = HotKeyAction(rawValue: name) { result[action] = combo }
            }
        }
        return result
    }

    static func save(_ bindings: [HotKeyAction: KeyCombo]) {
        let raw = Dictionary(uniqueKeysWithValues: bindings.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(raw) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
