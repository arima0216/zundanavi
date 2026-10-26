import PhotosUI
import SwiftUI
import UIKit

struct NavView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var nav: NavEngine
    @EnvironmentObject var script: ScriptPlayer
    @State private var inputText = ""
    @State private var pressing = false
    @State private var showCamera = false
    @State private var photoItem: PhotosPickerItem?

    private let zundaGreen = Color(red: 0.30, green: 0.69, blue: 0.31)

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let b = model.offlineBanner {
                    Text(b)
                        .font(.subheadline.bold())
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color.red)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        statusGrid
                        cardBox
                        walkBox
                        if !model.lastReply.isEmpty {
                            GroupBox("最後の返事") {
                                Text(model.lastReply)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .padding(16)
                }
                Divider()
                controls
                    .padding(16)
            }
            .navigationTitle("ずんだもん案内")
            .navigationBarTitleDisplayMode(.inline)
            .overlay(alignment: .top) { toastView }
            .sheet(isPresented: $showCamera) {
                ImagePicker(sourceType: .camera) { img in
                    model.sendPhoto(img, note: takeNote())
                }
                .ignoresSafeArea()
            }
            .onChange(of: photoItem) { _, item in
                loadPhoto(item)
            }
        }
    }

    // MARK: 状態行

    private var statusGrid: some View {
        let cols = [GridItem(.flexible()), GridItem(.flexible())]
        return LazyVGrid(columns: cols, alignment: .leading, spacing: 6) {
            chip(serverText, color: serverColor)
            chip(model.listenText, color: model.isRecordingAny ? .red : .blue)
            chip(model.gpsText, color: .teal)
            chip(model.wsConnected ? "WS 接続" : "WS 切断", color: model.wsConnected ? zundaGreen : .gray)
        }
    }

    private var serverText: String {
        switch model.serverOK {
        case .some(true): return "サーバー OK"
        case .some(false): return "サーバー NG"
        case .none: return "サーバー 確認中"
        }
    }

    private var serverColor: Color {
        switch model.serverOK {
        case .some(true): return zundaGreen
        case .some(false): return .red
        case .none: return .gray
        }
    }

    private func chip(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption.bold())
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
            .foregroundColor(color)
    }

    // MARK: 状況カード

    private var cardBox: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                if let c = model.card, !c.isEmpty {
                    ForEach(c.rows) { row in
                        HStack(alignment: .top, spacing: 8) {
                            Text(row.label)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 72, alignment: .leading)
                            Text(row.value)
                                .font(.body)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    if let u = c.updated {
                        Text("更新 " + u)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("ナビ未開始")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            HStack {
                Text("状況カード")
                Spacer()
                Button {
                    Task { await model.refreshCard() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
    }

    // MARK: 徒歩ナビ（WP-2n）

    private var walkBox: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text(nav.statusText)
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let i = nav.currentStepIdx, let st = nav.steps.first(where: { $0.idx == i }) {
                    Text("次: " + st.instruction)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    Button(nav.active ? "再探索" : "案内開始") { model.guideButton() }
                        .buttonStyle(.borderedProminent)
                    if let taxi = model.card?.taxi {
                        Button(taxi.label) { model.openURL(taxi.url) }
                            .buttonStyle(.bordered)
                    }
                    Spacer(minLength: 0)
                    if model.deck != nil {
                        Button("デッキ") { model.activeSheet = .deck }
                            .buttonStyle(.bordered)
                    }
                    if script.info != nil {
                        Button("台本") { model.activeSheet = .script }
                            .buttonStyle(.bordered)
                    }
                }
                .font(.subheadline)
            }
        } label: {
            HStack {
                Text("徒歩ナビ")
                Spacer()
                Text(model.navActive ? "ナビ中" : "停止中")
                    .font(.caption)
                    .foregroundStyle(model.navActive ? zundaGreen : Color.secondary)
            }
        }
    }

    // MARK: 操作

    private var controls: some View {
        VStack(spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                VStack(spacing: 4) {
                    bigButton
                    Text("押しっぱなしで話す／短く押すと自動で終わる")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(width: 130)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(spacing: 8) {
                    TextField("文字で聞く", text: $inputText)
                        .textFieldStyle(.roundedBorder)
                        .submitLabel(.send)
                        .onSubmit { sendText() }
                    HStack(spacing: 8) {
                        Button("送信") { sendText() }
                            .buttonStyle(.borderedProminent)
                            .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Spacer(minLength: 0)
                        Button {
                            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                                showCamera = true
                            } else {
                                model.showToast("カメラが使えないのだ")
                            }
                        } label: {
                            Image(systemName: "camera.fill")
                                .font(.title3)
                        }
                        .accessibilityLabel("写真を撮って送る")
                        PhotosPicker(selection: $photoItem, matching: .images) {
                            Image(systemName: "photo.on.rectangle")
                                .font(.title3)
                        }
                        .accessibilityLabel("写真を選んで送る")
                    }
                }
            }
            HStack(spacing: 8) {
                Button("ナビ開始") { model.startNavButton() }
                    .frame(maxWidth: .infinity)
                Button("ナビ終了") { model.stopNavButton() }
                    .frame(maxWidth: .infinity)
                Button("静かに(10分)") { model.quiet(minutes: 10) }
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .font(.subheadline)
        }
    }

    private var bigButton: some View {
        let active = model.isRecordingAny
        return ZStack {
            Circle()
                .fill(active ? Color.red : zundaGreen)
                .shadow(radius: active ? 8 : 3)
            VStack(spacing: 4) {
                Image(systemName: active ? "waveform" : "mic.fill")
                    .font(.system(size: 40, weight: .bold))
                Text(model.pttLabel)
                    .font(.caption.bold())
                    .multilineTextAlignment(.center)
            }
            .foregroundColor(.white)
        }
        .frame(width: 130, height: 130)
        .scaleEffect(pressing ? 0.94 : 1.0)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !pressing {
                        pressing = true
                        model.pttDown()
                    }
                }
                .onEnded { _ in
                    pressing = false
                    model.pttUp()
                }
        )
        .accessibilityLabel("押して話す")
    }

    @ViewBuilder
    private var toastView: some View {
        if let t = model.toast {
            Text(t)
                .font(.subheadline.bold())
                .foregroundColor(.white)
                .padding(12)
                .frame(maxWidth: .infinity)
                .background(Color.orange, in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .onTapGesture { model.toast = nil }
        }
    }

    // MARK: 動作

    private func sendText() {
        let t = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        inputText = ""
        model.askText(t, mode: "text")
    }

    /// 入力欄の文字を写真のメモとして使う
    private func takeNote() -> String? {
        let t = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        inputText = ""
        return t.isEmpty ? nil : t
    }

    private func loadPhoto(_ item: PhotosPickerItem?) {
        guard let item = item else { return }
        Task {
            if let d = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: d) {
                model.sendPhoto(img, note: takeNote())
            } else {
                model.showToast("写真を読めないのだ")
            }
            photoItem = nil
        }
    }
}

/// カメラで撮る（UIImagePickerController）
struct ImagePicker: UIViewControllerRepresentable {
    var sourceType: UIImagePickerController.SourceType
    var onPick: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let p = UIImagePickerController()
        p.sourceType = sourceType
        p.delegate = context.coordinator
        return p
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        return Coordinator(self)
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: ImagePicker

        init(_ parent: ImagePicker) {
            self.parent = parent
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let img = info[.originalImage] as? UIImage {
                parent.onPick(img)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
