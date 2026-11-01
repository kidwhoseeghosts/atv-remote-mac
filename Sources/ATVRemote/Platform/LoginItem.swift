import Foundation
import ServiceManagement

/// Автозапуск при входе в систему через SMAppService.mainApp (macOS 13+).
/// Для ad-hoc/Personal Team подписи работает, если приложение лежит в /Applications (или ~/Applications).
enum LoginItem {
    static var status: SMAppService.Status { SMAppService.mainApp.status }

    static var isEnabled: Bool { status == .enabled }

    static var needsApproval: Bool { status == .requiresApproval }

    static func set(enabled: Bool) throws {
        let service = SMAppService.mainApp
        if enabled {
            if service.status != .enabled { try service.register() }
        } else {
            if service.status == .enabled || service.status == .requiresApproval {
                try service.unregister()
            }
        }
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
