import Foundation
import Security

/// トークンだけは Keychain に置く（UserDefaults には書かない）。
enum Keychain {
    static let service = "dev.momo.zundanavi"

    static func get(_ account: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        let st = SecItemCopyMatching(q as CFDictionary, &out)
        guard st == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func set(_ account: String, _ value: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        if value.isEmpty { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        // バックグラウンド（画面ロック中）でも読めるように AfterFirstUnlock
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
}

enum MicSource: String, CaseIterable, Identifiable {
    case earphone
    case builtIn

    var id: String { return rawValue }

    var label: String {
        switch self {
        case .earphone: return "イヤホン (HFP)"
        case .builtIn: return "本体マイク"
        }
    }
}

@MainActor
final class AppSettings: ObservableObject {
    /// Tailscale の内側アドレス（プレースホルダ。設定画面で変更する）
    static let defaultServerURL = "http://100.98.48.27:47400"

    private let ud = UserDefaults.standard

    @Published var serverURL: String {
        didSet { ud.set(serverURL, forKey: "serverURL") }
    }
    @Published var token: String {
        didSet { Keychain.set("token", token) }
    }
    @Published var wakeWordEnabled: Bool {
        didSet { ud.set(wakeWordEnabled, forKey: "wakeWordEnabled") }
    }
    @Published var micSource: MicSource {
        didSet { ud.set(micSource.rawValue, forKey: "micSource") }
    }
    @Published var gpsSendEnabled: Bool {
        didSet { ud.set(gpsSendEnabled, forKey: "gpsSendEnabled") }
    }
    @Published var batteryLogEnabled: Bool {
        didSet { ud.set(batteryLogEnabled, forKey: "batteryLogEnabled") }
    }

    init() {
        let d = UserDefaults.standard
        serverURL = d.string(forKey: "serverURL") ?? AppSettings.defaultServerURL
        token = Keychain.get("token") ?? ""
        wakeWordEnabled = d.object(forKey: "wakeWordEnabled") as? Bool ?? true
        micSource = MicSource(rawValue: d.string(forKey: "micSource") ?? "") ?? .earphone
        gpsSendEnabled = d.object(forKey: "gpsSendEnabled") as? Bool ?? true
        batteryLogEnabled = d.object(forKey: "batteryLogEnabled") as? Bool ?? false
    }

    var appVersion: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return v + " (" + b + ")"
    }
}
