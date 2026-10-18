#if os(iOS)
import SwiftUI
import UniformTypeIdentifiers

/// 设置 → 自定义音源: the LX Music custom-source scripts the user imported.
struct LXSourcesSettingsView: View {
    @ObservedObject private var manager = LXSourceManager.shared
    @State private var showFileImporter = false
    @State private var showLinkPrompt = false
    @State private var linkText = ""
    @State private var isImporting = false
    @State private var importError: String?

    var body: some View {
        List {
            if manager.scripts.isEmpty {
                Section {
                    VStack(spacing: 12) {
                        Image(systemName: "square.stack.3d.up")
                            .font(.system(size: 40, weight: .light))
                            .foregroundStyle(.tertiary)
                        Text("还没有自定义音源")
                            .font(.headline)
                        Text("点右上角 + 导入 LX Music（洛雪音乐）格式的 .js 音源脚本")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                }
            } else {
                Section {
                    ForEach(manager.scripts) { script in
                        NavigationLink {
                            LXScriptDetailView(scriptID: script.id)
                        } label: {
                            LXScriptRow(script: script, status: manager.statuses[script.id] ?? .loading,
                                        hasUpdate: manager.updateAlerts[script.id] != nil)
                        }
                    }
                    .onDelete { offsets in
                        offsets.map { manager.scripts[$0].id }.forEach(manager.delete)
                    }
                    .onMove { manager.move(fromOffsets: $0, toOffset: $1) }
                } header: {
                    Text("已导入")
                } footer: {
                    Text("播放时按列表顺序向脚本获取链接，可在“编辑”中拖动调整。")
                }
            }

            Section {
                Text("兼容 LX Music 自定义音源接口：支持 musicUrl、lyric，以及部分脚本扩展的 search / musicSearch。脚本在本机运行，可以访问网络，请只导入信任的来源。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("网易云歌曲在官方无法播放（灰色、VIP、试听）时，会先向支持“网易云音乐”的脚本获取链接，需要开启“灰色歌曲解锁”。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("说明")
            }
        }
        .navigationTitle("自定义音源")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if !manager.scripts.isEmpty {
                    EditButton()
                }
                Menu {
                    Button {
                        showFileImporter = true
                    } label: {
                        Label("从文件导入", systemImage: "doc")
                    }
                    Button {
                        linkText = ""
                        showLinkPrompt = true
                    } label: {
                        Label("从链接导入", systemImage: "link")
                    }
                    Button {
                        importFromClipboard()
                    } label: {
                        Label("从剪贴板导入", systemImage: "doc.on.clipboard")
                    }
                } label: {
                    if isImporting {
                        ProgressView()
                    } else {
                        Image(systemName: "plus")
                    }
                }
                .disabled(isImporting)
                .accessibilityLabel("导入音源")
            }
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.javaScript, .plainText, .text, .data],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                var imported: [String] = []
                for url in urls {
                    do {
                        imported.append(try manager.importScript(fromFile: url).displayName)
                    } catch {
                        importError = error.localizedDescription
                    }
                }
                if !imported.isEmpty {
                    ToastCenter.shared.show(String(localized: "已导入：\(imported.joined(separator: "、"))"))
                }
            case .failure(let error):
                importError = error.localizedDescription
            }
        }
        .alert("从链接导入", isPresented: $showLinkPrompt) {
            TextField("https://…/source.js", text: $linkText)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("导入") { importFromLink() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("输入音源脚本的下载地址")
        }
        .alert("导入失败", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("好", role: .cancel) { importError = nil }
        } message: {
            Text(importError ?? "")
        }
    }

    private func importFromLink() {
        let trimmed = linkText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            importError = String(localized: "链接无效")
            return
        }
        isImporting = true
        Task {
            defer { isImporting = false }
            do {
                let script = try await manager.importScript(fromRemote: url)
                ToastCenter.shared.show(String(localized: "已导入：\(script.displayName)"))
            } catch {
                importError = error.localizedDescription
            }
        }
    }

    private func importFromClipboard() {
        guard let text = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            importError = String(localized: "剪贴板里没有文字")
            return
        }
        if let url = URL(string: text), let scheme = url.scheme?.lowercased(),
           (scheme == "http" || scheme == "https"), !text.contains("\n") {
            linkText = text
            importFromLink()
            return
        }
        do {
            let script = try manager.importScript(text: text)
            ToastCenter.shared.show(String(localized: "已导入：\(script.displayName)"))
        } catch {
            importError = error.localizedDescription
        }
    }
}

private struct LXScriptRow: View {
    let script: LXSourceManager.Script
    let status: LXSourceManager.Status
    let hasUpdate: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(script.displayName)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                if !script.info.version.isEmpty {
                    Text(script.info.version)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
                if hasUpdate {
                    Text("有更新")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Theme.accent, in: Capsule())
                }
            }
            LXScriptStatusLine(status: status)
        }
        .padding(.vertical, 2)
    }
}

private struct LXScriptStatusLine: View {
    let status: LXSourceManager.Status

    var body: some View {
        switch status {
        case .disabled:
            Label("已停用", systemImage: "pause.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("正在加载…")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        case .ready(let sources):
            Label(sources.isEmpty ? String(localized: "已加载，但没有注册任何平台") : sources.map(\.name).joined(separator: "、"),
                  systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
        }
    }
}

private struct LXScriptDetailView: View {
    let scriptID: UUID
    @ObservedObject private var manager = LXSourceManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false
    @State private var isUpdating = false

    private var script: LXSourceManager.Script? { manager.scripts.first { $0.id == scriptID } }

    var body: some View {
        if let script {
            List {
                Section {
                    Toggle("启用", isOn: Binding(
                        get: { script.isEnabled },
                        set: { manager.setEnabled($0, for: scriptID) }
                    ))
                    LXScriptStatusLine(status: manager.statuses[scriptID] ?? .loading)
                }

                Section("信息") {
                    LabeledContent("名称", value: script.displayName)
                    if !script.info.version.isEmpty { LabeledContent("版本", value: script.info.version) }
                    if !script.info.author.isEmpty { LabeledContent("作者", value: script.info.author) }
                    if !script.info.description.isEmpty {
                        Text(script.info.description)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if let homepage = URL(string: script.info.homepage), homepage.scheme?.hasPrefix("http") == true {
                        Link("主页", destination: homepage)
                    }
                    LabeledContent("导入时间", value: script.importedAt.formatted(date: .abbreviated, time: .shortened))
                }

                let sources = manager.statuses[scriptID]?.sources ?? []
                if !sources.isEmpty {
                    Section("支持的平台") {
                        ForEach(sources) { source in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(source.name)
                                    .font(.body.weight(.medium))
                                Text(capabilities(of: source))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if !source.qualities.isEmpty {
                                    Text(String(localized: "音质：\(source.qualities.joined(separator: " / "))"))
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                if let alert = manager.updateAlerts[scriptID] {
                    Section("更新提示") {
                        Text(alert.log)
                            .font(.subheadline)
                        if let urlString = alert.updateURL, let url = URL(string: urlString) {
                            Link("打开更新地址", destination: url)
                        }
                    }
                }

                Section {
                    Button("重新加载") { manager.reload(scriptID) }
                        .disabled(!script.isEnabled)
                    if let origin = script.originURL, let url = URL(string: origin) {
                        Button {
                            isUpdating = true
                            Task {
                                defer { isUpdating = false }
                                do {
                                    _ = try await manager.importScript(fromRemote: url)
                                    ToastCenter.shared.show(String(localized: "已更新"))
                                } catch {
                                    ToastCenter.shared.show(error.localizedDescription)
                                }
                            }
                        } label: {
                            HStack {
                                Text("从原链接更新")
                                if isUpdating {
                                    Spacer()
                                    ProgressView()
                                }
                            }
                        }
                        .disabled(isUpdating)
                    }
                    Button("删除音源", role: .destructive) { confirmDelete = true }
                }

                let logs = manager.logs[scriptID] ?? []
                if !logs.isEmpty {
                    Section("日志") {
                        ForEach(Array(logs.suffix(30).enumerated().reversed()), id: \.offset) { _, line in
                            Text(line)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .navigationTitle(script.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .confirmationDialog("删除“\(script.displayName)”？", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("删除", role: .destructive) {
                    manager.delete(scriptID)
                    dismiss()
                }
                Button("取消", role: .cancel) {}
            }
        } else {
            Text("音源已删除")
                .foregroundStyle(.secondary)
        }
    }

    private func capabilities(of source: LXRegisteredSource) -> String {
        var items: [String] = []
        if source.supportsMusicURL { items.append(String(localized: "播放")) }
        if source.searchAction != nil { items.append(String(localized: "搜索")) }
        if source.supportsLyric { items.append(String(localized: "歌词")) }
        let unknown = source.actions.filter { !["musicUrl", "lyric", "search", "musicSearch"].contains($0) }
        items += unknown
        return items.isEmpty ? String(localized: "无") : items.joined(separator: " · ")
    }
}
#endif
