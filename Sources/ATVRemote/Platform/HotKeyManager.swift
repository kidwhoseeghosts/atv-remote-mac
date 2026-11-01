import AppKit
import Carbon.HIToolbox

/// Глобальные горячие клавиши через Carbon RegisterEventHotKey.
/// Не требует разрешения «Универсальный доступ» и внешних библиотек.
final class HotKeyManager {
    static let shared = HotKeyManager()

    /// Вызывается на главном потоке.
    var onAction: ((HotKeyAction) -> Void)?

    /// Сочетания, которые не удалось зарегистрировать (обычно — заняты другим приложением).
    private(set) var failures: [HotKeyAction: OSStatus] = [:]

    private var refs: [HotKeyAction: EventHotKeyRef] = [:]
    private var idToAction: [UInt32: HotKeyAction] = [:]
    private var handlerRef: EventHandlerRef?
    private var repeatTimer: Timer?
    private var repeatingID: UInt32?
    private let signature: OSType = 0x41545652 // 'ATVR'

    private static let repeatable: Set<HotKeyAction> = [
        .up, .down, .left, .right, .volumeUp, .volumeDown, .skipBack, .skipForward,
    ]

    private init() {}

    // MARK: Публичный API

    /// Перерегистрирует все сочетания. enabled == false — просто снимает всё.
    func apply(enabled: Bool, bindings: [HotKeyAction: KeyCombo]) {
        unregisterAll()
        failures = [:]
        guard enabled else { return }
        installHandlerIfNeeded()
        var nextID: UInt32 = 1
        for action in HotKeyAction.allCases {
            guard let combo = bindings[action] else { continue }
            var ref: EventHotKeyRef?
            let hkID = EventHotKeyID(signature: signature, id: nextID)
            let status = RegisterEventHotKey(
                combo.keyCode, combo.modifiers, hkID, GetApplicationEventTarget(), 0, &ref
            )
            if status == noErr, let ref {
                refs[action] = ref
                idToAction[nextID] = action
            } else {
                failures[action] = status
            }
            nextID += 1
        }
    }

    /// Временно снять все сочетания (например, пока записывается новое).
    func suspend() { unregisterAll() }

    // MARK: Внутреннее

    private func unregisterAll() {
        stopRepeat()
        for (_, ref) in refs { UnregisterEventHotKey(ref) }
        refs.removeAll()
        idToAction.removeAll()
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var specs = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let callback: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var hkID = EventHotKeyID()
            let err = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hkID
            )
            guard err == noErr else { return err }
            let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
            let kind = GetEventKind(event)
            let id = hkID.id
            DispatchQueue.main.async {
                if kind == UInt32(kEventHotKeyPressed) { manager.handlePressed(id: id) }
                else { manager.handleReleased(id: id) }
            }
            return noErr
        }
        InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            specs.count,
            &specs,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )
    }

    private func handlePressed(id: UInt32) {
        guard let action = idToAction[id] else { return }
        onAction?(action)
        guard Self.repeatable.contains(action) else { return }
        stopRepeat()
        repeatingID = id
        // автоповтор при удержании: пауза 0.4 с, затем каждые 0.12 с
        repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            guard let self, self.repeatingID == id else { return }
            self.repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
                guard let self, self.repeatingID == id, let action = self.idToAction[id] else { return }
                self.onAction?(action)
            }
        }
    }

    private func handleReleased(id: UInt32) {
        if repeatingID == id { stopRepeat() }
    }

    private func stopRepeat() {
        repeatTimer?.invalidate()
        repeatTimer = nil
        repeatingID = nil
    }
}

extension KeyCombo {
    /// Из NSEvent (запись нового сочетания).
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var mods: UInt32 = 0
        if flags.contains(.control) { mods |= CarbonModifier.control }
        if flags.contains(.option) { mods |= CarbonModifier.option }
        if flags.contains(.shift) { mods |= CarbonModifier.shift }
        if flags.contains(.command) { mods |= CarbonModifier.command }
        guard mods != 0 else { return nil } // глобальные сочетания без модификаторов не допускаем
        self.init(keyCode: UInt32(event.keyCode), modifiers: mods)
    }
}
