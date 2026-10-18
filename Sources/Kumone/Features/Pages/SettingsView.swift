import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: SettingsManager
    @EnvironmentObject private var account: AccountStore
    @Environment(\.openDestination) private var openDestination
    @Environment(\.dismiss) private var dismiss
    #if os(macOS)
    @ObservedObject private var downloader = StemModelDownloader.shared
    #endif

    var body: some View {
        #if os(macOS)
        NavigationStack { settingsForm }
            .background(SettingsWindowToolbar())
            .frame(width: 520, height: 620)
        #else
        settingsForm
        #endif
    }

    private var settingsForm: some View {
        Form {
            Section("播放") {
                Picker("音质", selection: $settings.audioQuality) {
                    ForEach(AudioQuality.allCases) { quality in
                        Text(quality.displayName).tag(quality)
                    }
                }
                Text("无损与 Hi-Res 需要黑胶 VIP，未开通时自动回落到可用音质")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("灰色歌曲解锁", isOn: $settings.enableUnblock)
                Text("无版权或下架歌曲将从已启用音源中匹配播放")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            #if os(macOS)

            // AutoMix is a group of its own because it is a group of costs:
            // the master switch buys analysis, and each sub-switch below adds
            // one specific bill (a seam, extra downloads, the GPU) on top.
            Section {
                Toggle("AutoMix", isOn: $settings.automixEnabled)
                    .onChange(of: settings.automixEnabled) { _, _ in
                        PlayerService.shared.reconcileQueueOrderAvailability()
                    }
                Text("分析已下载的歌曲，自动衔接队列里的歌。所有分析都在本机完成。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("自动过渡", isOn: $settings.automixTransitionsEnabled)
                    .disabled(!settings.automixEnabled)
                Text("在两首歌之间做节拍对齐的过渡。只分析本来就要播放的歌曲，不产生额外下载。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("智能顺序", isOn: $settings.automixOrderEnabled)
                    .disabled(!settings.automixEnabled)
                    .onChange(of: settings.automixOrderEnabled) { _, _ in
                        PlayerService.shared.reconcileQueueOrderAvailability()
                    }
                Text("按过渡效果重排队列，随机按钮会多出一个 AutoMix 状态。需要额外下载候选歌曲（标准音质）来打分。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("统一歌曲响度", isOn: $settings.loudnessCompensationEnabled)
                    .disabled(!settings.automixEnabled)
                Text("按每首歌的母带响度调整播放增益，下一首不会突然变响；需要开启 AutoMix")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // Stem separation runs on MLX, which is Apple silicon only —
                // the x86_64 slice of the universal app never offers it.
                #if arch(arm64)
                // Off *and* unavailable until the model is on disk: a toggle
                // that cannot do anything must not look like it can, and the
                // section below is where it becomes possible.
                Toggle("增强过渡（人声 / 鼓分离）",
                       isOn: stemsBinding)
                    .disabled(!settings.automixEnabled || !stemModelsInstalled)
                Text("用本机 GPU 分离音轨，过渡更干净。需要下载模型，播放时会占用 GPU 并增加发热和耗电。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                StemModelsSettingsSection()
                #endif
            } header: {
                Text("AutoMix")
            } footer: {
                Text("对古典、现场录音、有声书等内容效果不佳，遇到这类歌单可在这里暂时关闭。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            #endif

            if settings.enableUnblock {
                Section {
                    ForEach(AudioSourceID.allCases, id: \.self) { source in
                        Toggle(source.displayName, isOn: Binding(
                            get: { settings.enabledAudioSourceIDs.contains(source) },
                            set: { isEnabled in
                                if isEnabled {
                                    settings.enabledAudioSourceIDs.insert(source)
                                } else {
                                    settings.enabledAudioSourceIDs.remove(source)
                                }
                            }
                        ))
                    }
                } header: {
                    Text("音源")
                }
            }

            Section("外观") {
                Picker("主题", selection: $settings.appearance) {
                    ForEach(AppAppearance.allCases) { appearance in
                        Text(appearance.displayName).tag(appearance)
                    }
                }
                #if os(macOS)
                // macOS only renders two now-playing layouts — 黑胶 and the
                // regular page; the iOS 沉浸/简洁 options all fall back to the
                // regular page here, so offering four was misleading (#105).
                // Map any non-vinyl value onto 经典模式 so a stored default (e.g.
                // 沉浸模式) still shows a valid selection.
                Picker("播放页模式", selection: Binding(
                    get: { settings.nowPlayingMode == .vinyl ? .vinyl : .classic },
                    set: { settings.nowPlayingMode = $0 }
                )) {
                    Text(NowPlayingMode.vinyl.displayName).tag(NowPlayingMode.vinyl)
                    Text(NowPlayingMode.classic.displayName).tag(NowPlayingMode.classic)
                }
                #else
                Picker("播放页模式", selection: $settings.nowPlayingMode) {
                    ForEach(NowPlayingMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                #endif
                Toggle("显示歌词翻译", isOn: $settings.showLyricsTranslation)
                Toggle("逐字歌词（卡拉OK）", isOn: $settings.verbatimLyrics)
                Picker("日文歌词读音", selection: $settings.lyricsAnnotation) {
                    ForEach(LyricsAnnotation.allCases) { annotation in
                        Text(annotation.displayName).tag(annotation)
                    }
                }
                Text("罗马音在歌词上方另起一行，汉字读音把假名标在汉字正上方；缺少官方罗马音时自动生成读音")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("主界面环境色", isOn: $settings.showMainWindowAmbientBackground)
                if settings.showMainWindowAmbientBackground {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("背景色强度")
                            Spacer()
                            Text("\(Int(settings.mainWindowAmbientBackgroundIntensity * 100))%")
                                .foregroundStyle(.secondary)
                        }
                        Slider(
                            value: $settings.mainWindowAmbientBackgroundIntensity,
                            in: SettingsManager.mainWindowAmbientBackgroundIntensityRange,
                            step: 0.1
                        )
                        HStack {
                            Text("50%")
                            Spacer()
                            Text("150%")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                Toggle("自定义卡片圆角", isOn: $settings.customCardCornerRadius)
                if settings.customCardCornerRadius {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("卡片圆角")
                            Spacer()
                            Text("\(Int(settings.cardCornerRadius.rounded())) pt")
                                .foregroundStyle(.secondary)
                        }
                        Slider(
                            value: $settings.cardCornerRadius,
                            in: SettingsManager.cardCornerRadiusRange,
                            step: 1
                        )
                        HStack {
                            Text("0")
                            Spacer()
                            Text("40")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        // Real card size, so the corner reads as it will on the page.
                        RoundedRectangle(cornerRadius: CGFloat(settings.cardCornerRadius), style: .continuous)
                            .fill(Theme.accentGradient)
                            .frame(width: Theme.Layout.cardSize, height: Theme.Layout.cardSize)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .accessibilityHidden(true)
                    }
                }
                Text("作用于推荐和精选页的卡片，使用连续圆角；关闭时恢复默认（封面 8 pt、顶部大卡片 12 pt）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                #if os(macOS)
                Toggle("桌面歌词", isOn: $settings.showDesktopLyrics)
                if settings.showDesktopLyrics {
                    Toggle("桌面歌词水平居中", isOn: $settings.desktopLyricsCentered)
                }
                Text("在屏幕上悬浮显示当前歌词，可拖动调整位置")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                #endif
            }
            #if os(iOS)

            miniPlayerArtworkSection
            #endif

            Section("存储") {
                NavigationLink {
                    StorageSpaceView {
                        #if os(iOS)
                        dismiss()
                        #endif
                        openDestination(.downloaded)
                    }
                } label: {
                    Label("存储空间", systemImage: "internaldrive")
                }
            }

            #if os(macOS)
            Section("通用") {
                NavigationLink {
                    ShortcutSettingsView()
                } label: {
                    Label("快捷键", systemImage: "keyboard")
                }
            }
            #endif

            Section("账号") {
                if let profile = account.profile {
                    LabeledContent("当前账号", value: profile.nickname)
                    Button("退出登录", role: .destructive) {
                        Task { await AccountStore.shared.logout() }
                    }
                } else {
                    Text("未登录")
                        .foregroundStyle(.secondary)
                }
            }

            Section("更新") {
                Toggle("启动时自动检查更新", isOn: $settings.autoCheckUpdates)
                Text("关闭后启动不再自动弹出更新提示，仍可手动检查更新")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("关于") {
                LabeledContent("Kumone", value: appVersion)
                #if os(iOS)
                Button {
                    IOSUpdater.shared.check(interactive: true)
                } label: {
                    Label("检查更新", systemImage: "arrow.triangle.2.circlepath")
                }
                Text("装有 TrollStore（巨魔）可在应用内一键自动安装；否则可下载 IPA 用侧载工具重装（登录状态与设置保留）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                #endif
                Text("网易云音乐第三方客户端 · 数据来自网易云音乐")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
    #if os(macOS)

    /// Whether the two-stem model is on disk, read from the downloader so the
    /// toggle flips the moment a download lands (the launcher wires the
    /// separator in via `onInstalled`; `StemSeparation.isAvailable` is not
    /// observable and only says what was installed at launch).
    private var stemModelsInstalled: Bool { downloader.vocalsInstalled }

    /// Reads as off whenever the models are missing, however the stored
    /// setting stands: the toggle must never claim a capability the machine
    /// does not have. The stored value is left alone so turning it on once and
    /// installing the models later still works.
    private var stemsBinding: Binding<Bool> {
        Binding(get: { settings.automixStemsEnabled && stemModelsInstalled },
                set: { settings.automixStemsEnabled = $0 })
    }

    #endif

    #if os(iOS)

    private var miniPlayerArtworkSection: some View {
        Section {
            MiniPlayerArtworkPreview()

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("封面大小")
                    Spacer()
                    Text("\(Int((settings.miniPlayerArtworkScale * 100).rounded()))%")
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: $settings.miniPlayerArtworkScale,
                    in: SettingsManager.miniPlayerArtworkScaleRange,
                    step: 0.01
                )
                HStack {
                    Text("50%")
                    Spacer()
                    Text("100%")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Toggle("播放时旋转封面", isOn: $settings.miniPlayerArtworkSpins)
            if settings.miniPlayerArtworkSpins {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("旋转速度")
                        Spacer()
                        Text(miniPlayerArtworkSpeedLabel)
                            .foregroundStyle(.secondary)
                    }
                    Slider(
                        value: $settings.miniPlayerArtworkRPM,
                        in: SettingsManager.miniPlayerArtworkRPMRange,
                        step: 1
                    )
                    HStack {
                        Text("慢")
                        Spacer()
                        Text("快")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("播放悬浮条")
        } footer: {
            Text("封面大小按悬浮条高度计算，始终与玻璃同心；暂停时停在当前角度。开启“减弱动态效果”时不旋转。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var miniPlayerArtworkSpeedLabel: String {
        let rpm = settings.miniPlayerArtworkRPM
        let seconds = 60 / rpm
        let secondsText = seconds.rounded() == seconds ? "\(Int(seconds))" : String(format: "%.1f", seconds)
        return "\(Int(rpm.rounded())) 转/分 · 每圈 \(secondsText) 秒"
    }
    #endif

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

}

#if os(iOS)
/// A stand-in mini player so the disc's size and speed can be tuned while the
/// real bar is hidden behind the settings sheet. It always spins, using its own
/// clock so the real bar's paused angle is left alone.
private struct MiniPlayerArtworkPreview: View {
    @EnvironmentObject private var player: PlayerService
    @StateObject private var rotation = ArtworkDiscRotation()

    private let barHeight: CGFloat = 48

    var body: some View {
        HStack(spacing: 8) {
            MiniPlayerArtworkDisc(
                url: player.currentTrack?.album.picUrl?.resizedImageURL(200),
                barHeight: barHeight,
                isPlaying: true,
                rotation: rotation
            )
            VStack(alignment: .leading, spacing: 3) {
                Text(player.currentTrack?.name ?? String(localized: "歌曲名"))
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(player.currentTrack?.artistNames ?? String(localized: "歌手"))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.trailing, 16)
        .frame(height: barHeight)
        .background(.regularMaterial, in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(.primary.opacity(0.08), lineWidth: 0.5)
        }
        .padding(.vertical, 4)
        .accessibilityHidden(true)
    }
}
#endif

#if os(macOS)
/// A Settings scene keeps its preference-style toolbar even when given a
/// scene-level windowToolbarStyle. Configure this window through AppKit so
/// navigation shares the title bar instead of becoming a centered second row.
struct SettingsWindowToolbar: NSViewRepresentable {
    func makeNSView(context: Context) -> ToolbarHost { ToolbarHost() }

    func updateNSView(_ nsView: ToolbarHost, context: Context) {
        nsView.updateToolbar()
    }

    final class ToolbarHost: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            updateToolbar()
        }

        func updateToolbar() {
            DispatchQueue.main.async { [weak self] in
                guard let window = self?.window, window.toolbarStyle != .unifiedCompact else { return }
                window.toolbarStyle = .unifiedCompact
            }
        }
    }
}
#endif
