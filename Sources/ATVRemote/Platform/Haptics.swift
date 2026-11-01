import AppKit

/// Тактильный отклик трекпада (работает на MacBook с Force Touch трекпадом).
enum Haptics {
    private static var enabled: Bool {
        UserDefaults.standard.object(forKey: "hapticsEnabled") as? Bool ?? true
    }

    /// Лёгкий «щелчок» при шаге свайпа.
    static func tick() {
        guard enabled else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    /// Более ощутимый — при нажатии кнопок и «выбрать».
    static func click() {
        guard enabled else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }

    static func generic() {
        guard enabled else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
    }
}
