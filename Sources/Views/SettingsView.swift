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
                    VStack(alignment: .leading, spacing: 6) {
                        Text("話し終わりの間")
                        Picker("話し終わりの間", selection: $settings.endSilenceSec) {
                            ForEach(Endpointing.choices, id: \.self) { v in
                                Text(String(format: "%.1f秒", v)).tag(v)
                            }
                        }
                        .pickerStyle(.segmented)
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

                Section {
                    InputLevelRow(level: model.inputLevel, threshold: AppModel.loudThreshold)
                } header: {
                    Text("入力レベル")
                } footer: {
                    Text("緑なら声として数えている（しきい値 " + String(format: "%.3f", AppModel.loudThreshold) + "、橙の線）。")
                }
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

/// WP-2o: 入力レベル（RMS）の小さなメーター。しきい値を超えると緑。
struct InputLevelRow: View {
    let level: Float
    let threshold: Float

    var body: some View {
        let loud = level >= threshold
        // 0.05 で満タン（話し声はおおむね 0.01〜0.05）
        let frac = CGFloat(min(max(level / 0.05, 0), 1))
        let mark = CGFloat(min(threshold / 0.05, 1))
        HStack(spacing: 8) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.2))
                    Capsule().fill(loud ? Color.green : Color.gray)
                        .frame(width: g.size.width * frac)
                    Rectangle().fill(Color.orange)
                        .frame(width: 2)
                        .offset(x: g.size.width * mark)
                }
            }
            .frame(height: 8)
            Text(String(format: "%.3f", level))
                .font(.caption.monospacedDigit())
                .foregroundColor(loud ? .green : .secondary)
                .frame(width: 48, alignment: .trailing)
        }
    }
}
