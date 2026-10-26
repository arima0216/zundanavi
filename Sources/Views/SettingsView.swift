import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var battery: BatteryLogger

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("http://100.x.x.x:47400", text: $settings.serverURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit { model.applyServerSettings() }
                    SecureField("トークン", text: $settings.token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit { model.applyServerSettings() }
                    Button("接続テスト") {
                        model.testConnection()
                    }
                    if !model.testResult.isEmpty {
                        Text(model.testResult)
                            .font(.footnote)
                            .foregroundStyle(model.testResult.hasPrefix("OK") ? Color.green : Color.red)
                    }
                } header: {
                    Text("サーバー")
                } footer: {
                    Text("Tailscale の内側アドレスを入れる。トークンは Keychain に保存。")
                }

                Section("音声") {
                    Toggle("ウェイクワード「ふぇーぶる」", isOn: $settings.wakeWordEnabled)
                        .onChange(of: settings.wakeWordEnabled) { _, on in
                            model.setWakeEnabled(on)
                        }
                    Picker("マイク", selection: $settings.micSource) {
                        ForEach(MicSource.allCases) { m in
                            Text(m.label).tag(m)
                        }
                    }
                    .onChange(of: settings.micSource) { _, m in
                        model.setMic(m)
                    }
                    Text("経路: " + model.routeText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("徒歩ナビ") {
                    Toggle("徒歩ナビ音声", isOn: $settings.walkVoiceEnabled)
                    Toggle("自動再探索", isOn: $settings.autoReroute)
                    Toggle("端末合成にフォールバック", isOn: $settings.localTTSFallback)
                }

                Section("位置") {
                    Toggle("GPS を送る", isOn: $settings.gpsSendEnabled)
                    Text(model.gpsText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("電池ログ") {
                    Toggle("電池ログ (5分ごと)", isOn: $settings.batteryLogEnabled)
                        .onChange(of: settings.batteryLogEnabled) { _, on in
                            battery.setEnabled(on)
                        }
                    if battery.fileExists || battery.lineCount > 0 {
                        ShareLink(item: BatteryLogger.fileURL) {
                            Label("CSV を共有", systemImage: "square.and.arrow.up")
                        }
                    }
                }

                Section("情報") {
                    LabeledContent("バージョン", value: settings.appVersion)
                    LabeledContent("サーバー", value: model.serverDetail.isEmpty ? "-" : model.serverDetail)
                }
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
