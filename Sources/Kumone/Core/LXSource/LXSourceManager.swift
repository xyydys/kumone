import Foundation
import os.log

/// The LX Music custom-source scripts the user imported: stored on disk,
/// one `LXScriptRuntime` per enabled script, and the three things the rest
/// of the app asks of them — search, a stream URL, lyrics.
@MainActor
final class LXSourceManager: ObservableObject {
    static let shared = LXSourceManager()

    struct Script: Codable, Identifiable, Hashable {
        let id: UUID
        var info: LXScriptInfo
        var isEnabled: Bool
        var importedAt: Date
        /// Where it was downloaded from, when imported by link.
        var originURL: String?

        var displayName: String { info.name.isEmpty ? String(localized: "未命名音源") : info.name }
    }

    enum Status: Equatable {
        case disabled
        case loading
        case ready([LXRegisteredSource])
        case failed(String)

        var sources: [LXRegisteredSource] {
            if case .ready(let sources) = self { return sources }
            return []
        }
    }

    /// One searchable platform of one script — a chip on the search page.
    struct SearchSource: Identifiable, Hashable {
        let scriptID: UUID
        let platform: String
        let action: String
        let name: String

        var id: String { "\(scriptID.uuidString):\(platform)" }
    }

    struct SearchPage {
        let tracks: [Track]
        let isEnd: Bool
    }

    struct ResolvedURL {
        let url: URL
        /// "溯音音源 · 酷我音乐", for the now-playing source label.
        let provider: String
    }

    enum ManagerError: LocalizedError {
        case empty
        case tooLarge
        case download(String)
        case noProvider(String)
        case invalidURL

        var errorDescription: String? {
            switch self {
            case .empty: return String(localized: "脚本内容为空")
            case .tooLarge: return String(localized: "脚本过大")
            case .download(let message): return String(localized: "下载脚本失败：\(message)")
            case .noProvider(let platform): return String(localized: "没有可用于\(platform)的自定义音源")
            case .invalidURL: return String(localized: "音源返回的不是有效的播放链接")
            }
        }
    }

    @Published private(set) var scripts: [Script] = []
    @Published private(set) var statuses: [UUID: Status] = [:]
    @Published private(set) var updateAlerts: [UUID: LXUpdateAlert] = [:]
    /// The last lines each script printed, newest last, for its detail page.
    @Published private(set) var logs: [UUID: [String]] = [:]

    private var runtimes: [UUID: LXScriptRuntime] = [:]
    private var startTasks: [UUID: Task<Void, Never>] = [:]
    private var didBootstrap = false
    private let log = Logger(subsystem: "im.missuo.kumone", category: "lx-source")

    private static let maximumScriptSize = 8 * 1024 * 1024
    private static let maximumLogLines = 80

    private let directory: URL
    private var indexURL: URL { directory.appendingPathComponent("scripts.json") }
    private func fileURL(for id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).js") }

    init(directory: URL = KumonePaths.applicationSupport.appendingPathComponent("LXSources", isDirectory: true)) {
        self.directory = directory
    }

    // MARK: - Lifecycle

    /// Loads the saved scripts and starts the enabled ones. Idempotent.
    func bootstrap() {
        guard !didBootstrap else { return }
        didBootstrap = true
        if let data = try? Data(contentsOf: indexURL),
           let saved = try? JSONDecoder().decode([Script].self, from: data) {
            scripts = saved.filter { FileManager.default.fileExists(atPath: fileURL(for: $0.id).path) }
        }
        for script in scripts {
            if script.isEnabled { start(script) } else { statuses[script.id] = .disabled }
        }
    }

    private func start(_ script: Script) {
        stopRuntime(script.id)
        guard let text = try? String(contentsOf: fileURL(for: script.id), encoding: .utf8) else {
            statuses[script.id] = .failed(String(localized: "脚本文件丢失"))
            return
        }
        let runtime = LXScriptRuntime(script: text, info: script.info)
        let id = script.id
        runtime.onLog = { [weak self] level, message in
            Task { @MainActor in self?.appendLog("[\(level)] \(message)", for: id) }
        }
        runtime.onUpdateAlert = { [weak self] alert in
            Task { @MainActor in self?.updateAlerts[id] = alert }
        }
        runtimes[id] = runtime
        statuses[id] = .loading
        startTasks[id] = Task { [weak self] in
            do {
                let sources = try await runtime.start()
                guard let self, self.runtimes[id] === runtime else { return }
                self.statuses[id] = .ready(sources)
            } catch {
                guard let self, self.runtimes[id] === runtime else { return }
                self.statuses[id] = .failed(error.localizedDescription)
                self.log.error("script=\(script.displayName, privacy: .public) init failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func stopRuntime(_ id: UUID) {
        startTasks.removeValue(forKey: id)?.cancel()
        runtimes.removeValue(forKey: id)?.stop()
    }

    /// Lets a caller that arrives during launch wait for scripts still
    /// initialising instead of finding no provider.
    private func waitForStartingScripts() async {
        for task in startTasks.values {
            await task.value
        }
    }

    private func appendLog(_ line: String, for id: UUID) {
        var lines = logs[id] ?? []
        lines.append(String(line.prefix(500)))
        if lines.count > Self.maximumLogLines { lines.removeFirst(lines.count - Self.maximumLogLines) }
        logs[id] = lines
    }

    // MARK: - Managing scripts

    /// Adds a script, or replaces the one with the same name (that is how a
    /// newer version of a source is installed).
    @discardableResult
    func importScript(text: String, originURL: String? = nil) throws -> Script {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ManagerError.empty }
        guard trimmed.utf8.count <= Self.maximumScriptSize else { throw ManagerError.tooLarge }
        let info = LXScriptInfo.parse(trimmed)

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var script: Script
        if !info.name.isEmpty, let index = scripts.firstIndex(where: { $0.info.name == info.name }) {
            script = scripts[index]
            script.info = info
            script.importedAt = Date()
            script.originURL = originURL ?? script.originURL
            try Data(trimmed.utf8).write(to: fileURL(for: script.id), options: .atomic)
            scripts[index] = script
        } else {
            script = Script(id: UUID(), info: info, isEnabled: true, importedAt: Date(), originURL: originURL)
            try Data(trimmed.utf8).write(to: fileURL(for: script.id), options: .atomic)
            scripts.append(script)
        }
        logs[script.id] = nil
        updateAlerts[script.id] = nil
        saveIndex()
        if script.isEnabled { start(script) } else { statuses[script.id] = .disabled }
        return script
    }

    @discardableResult
    func importScript(fromFile url: URL) throws -> Script {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        guard data.count <= Self.maximumScriptSize else { throw ManagerError.tooLarge }
        return try importScript(text: String(decoding: data, as: UTF8.self))
    }

    @discardableResult
    func importScript(fromRemote url: URL) async throws -> Script {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let data: Data
        do {
            let (body, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw ManagerError.download("HTTP \(http.statusCode)")
            }
            data = body
        } catch let error as ManagerError {
            throw error
        } catch {
            throw ManagerError.download(error.localizedDescription)
        }
        guard data.count <= Self.maximumScriptSize else { throw ManagerError.tooLarge }
        return try importScript(text: String(decoding: data, as: UTF8.self), originURL: url.absoluteString)
    }

    func setEnabled(_ enabled: Bool, for id: UUID) {
        guard let index = scripts.firstIndex(where: { $0.id == id }), scripts[index].isEnabled != enabled else { return }
        scripts[index].isEnabled = enabled
        saveIndex()
        if enabled {
            start(scripts[index])
        } else {
            stopRuntime(id)
            statuses[id] = .disabled
        }
    }

    func reload(_ id: UUID) {
        guard let script = scripts.first(where: { $0.id == id }), script.isEnabled else { return }
        logs[id] = nil
        start(script)
    }

    func delete(_ id: UUID) {
        stopRuntime(id)
        scripts.removeAll { $0.id == id }
        statuses[id] = nil
        logs[id] = nil
        updateAlerts[id] = nil
        try? FileManager.default.removeItem(at: fileURL(for: id))
        saveIndex()
    }

    /// The list order is also the order scripts are asked for a URL.
    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        scripts.move(fromOffsets: source, toOffset: destination)
        saveIndex()
    }

    private func saveIndex() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(scripts).write(to: indexURL, options: .atomic)
        } catch {
            log.error("saving script index failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Queries

    private var readyScripts: [(script: Script, runtime: LXScriptRuntime, sources: [LXRegisteredSource])] {
        scripts.compactMap { script in
            guard let runtime = runtimes[script.id], case .ready(let sources)? = statuses[script.id] else { return nil }
            return (script, runtime, sources)
        }
    }

    /// Every platform an enabled script can search, in script order. A
    /// platform two scripts both search gets the script's name appended.
    var searchSources: [SearchSource] {
        var result: [SearchSource] = []
        for (script, _, sources) in readyScripts {
            for source in sources {
                guard let action = source.searchAction else { continue }
                result.append(SearchSource(scriptID: script.id, platform: source.id, action: action, name: source.name))
            }
        }
        let counts = Dictionary(grouping: result, by: \.name).mapValues(\.count)
        return result.map { source in
            guard counts[source.name, default: 0] > 1,
                  let script = scripts.first(where: { $0.id == source.scriptID }) else { return source }
            return SearchSource(scriptID: source.scriptID, platform: source.platform, action: source.action,
                                name: "\(source.name) · \(script.displayName)")
        }
    }

    func hasMusicURLProvider(for platform: String) -> Bool {
        readyScripts.contains { $0.sources.contains { $0.id == platform && $0.supportsMusicURL } }
    }

    var hasReadyScripts: Bool { !readyScripts.isEmpty }

    func search(_ source: SearchSource, keyword: String, page: Int, limit: Int) async throws -> SearchPage {
        await waitForStartingScripts()
        guard let entry = readyScripts.first(where: { $0.script.id == source.scriptID }) else {
            throw LXScriptError.notReady
        }
        let value = try await entry.runtime.call(
            source: source.platform,
            action: source.action,
            info: ["keyword": keyword, "page": page, "limit": limit, "pagesize": limit, "type": "music"],
            timeout: 30
        )
        let platformName = entry.sources.first(where: { $0.id == source.platform })?.name
            ?? LXPlatform.displayName(for: source.platform)
        let list: [Any]
        var isEnd: Bool?
        if let array = value.array {
            list = array
        } else if let object = value.dictionary {
            list = object["list"] as? [Any] ?? object["data"] as? [Any] ?? []
            isEnd = object["isEnd"] as? Bool
            if isEnd == nil, let total = (object["total"] as? NSNumber)?.intValue {
                isEnd = page * limit >= total
            }
        } else {
            throw LXScriptError.invalidResult
        }
        var seen = Set<Int>()
        let tracks = list.compactMap { $0 as? [String: Any] }
            .compactMap { LXMusicInfo.track(from: $0, platform: source.platform, platformName: platformName, scriptID: source.scriptID) }
            .filter { seen.insert($0.id).inserted }
        return SearchPage(tracks: tracks, isEnd: isEnd ?? (tracks.count < limit))
    }

    /// A stream URL for `track` from the scripts that serve its platform
    /// (`wy` for a NetEase song): the script that found it first, then the
    /// rest in list order.
    func musicURL(for track: Track, quality: AudioQuality) async throws -> ResolvedURL {
        await waitForStartingScripts()
        let platform = track.external?.platform ?? "wy"
        var candidates = readyScripts.filter { $0.sources.contains { $0.id == platform && $0.supportsMusicURL } }
        if let preferred = track.external?.scriptID,
           let index = candidates.firstIndex(where: { $0.script.id == preferred }) {
            candidates.insert(candidates.remove(at: index), at: 0)
        }
        guard !candidates.isEmpty else { throw ManagerError.noProvider(LXPlatform.displayName(for: platform)) }

        let musicInfo = LXMusicInfo.musicInfo(for: track)
        var lastError: Error = ManagerError.invalidURL
        for (script, runtime, sources) in candidates {
            let source = sources.first { $0.id == platform }
            let qualityName = LXMusicInfo.quality(for: quality, supported: source?.qualities ?? [])
            do {
                let value = try await runtime.call(
                    source: platform,
                    action: "musicUrl",
                    info: ["type": qualityName, "musicInfo": musicInfo],
                    timeout: 45
                )
                guard let string = value.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                      string.count <= 4096,
                      let url = URL(string: string),
                      let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
                    throw ManagerError.invalidURL
                }
                let platformName = source?.name ?? LXPlatform.displayName(for: platform)
                return ResolvedURL(url: url, provider: "\(script.displayName) · \(platformName)")
            } catch {
                lastError = error
                appendLog("[musicUrl] \(platform) \(track.name): \(error.localizedDescription)", for: script.id)
            }
        }
        throw lastError
    }

    /// Lyrics for an external song, from a script that offers `lyric` for
    /// its platform.
    func lyrics(for track: Track) async -> LyricResponse? {
        guard let external = track.external else { return nil }
        await waitForStartingScripts()
        var candidates = readyScripts.filter { $0.sources.contains { $0.id == external.platform && $0.supportsLyric } }
        if let index = candidates.firstIndex(where: { $0.script.id == external.scriptID }) {
            candidates.insert(candidates.remove(at: index), at: 0)
        }
        for (_, runtime, _) in candidates {
            guard let value = try? await runtime.call(
                source: external.platform,
                action: "lyric",
                info: ["musicInfo": external.musicInfoObject],
                timeout: 20
            ) else { continue }
            let object = value.dictionary ?? [:]
            let lyric = object["lyric"] as? String ?? value.string
            guard let lyric, !lyric.isEmpty else { continue }
            func body(_ key: String) -> LyricResponse.LyricBody? {
                (object[key] as? String).flatMap { $0.isEmpty ? nil : LyricResponse.LyricBody(lyric: $0) }
            }
            return LyricResponse(
                lrc: LyricResponse.LyricBody(lyric: lyric), tlyric: body("tlyric"), romalrc: body("rlyric"),
                yrc: nil, ytlrc: nil, yromalrc: nil, lyricUser: nil, transUser: nil, nolyric: nil, uncollected: nil
            )
        }
        return nil
    }
}
