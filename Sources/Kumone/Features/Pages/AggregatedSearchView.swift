#if os(iOS)
import SwiftUI

/// Recent queries on the search page, newest first.
@MainActor
final class SearchHistoryStore: ObservableObject {
    static let shared = SearchHistoryStore()

    private static let key = "search.history"
    private static let limit = 24

    @Published private(set) var items: [String]

    private init() {
        items = UserDefaults.standard.stringArray(forKey: Self.key) ?? []
    }

    func record(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        items.removeAll { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
        items.insert(trimmed, at: 0)
        if items.count > Self.limit { items.removeLast(items.count - Self.limit) }
        save()
    }

    func remove(_ query: String) {
        items.removeAll { $0 == query }
        save()
    }

    func clear() {
        items = []
        save()
    }

    private func save() {
        UserDefaults.standard.set(items, forKey: Self.key)
    }
}

/// One query run against NetEase and every custom source that can search.
@MainActor
final class AggregatedSearchModel: ObservableObject {
    enum Scope: Hashable {
        case all
        case netease
        /// `LXSourceManager.SearchSource.id`
        case source(String)
    }

    struct Results {
        var tracks: [Track] = []
        var isLoading = false
        var error: String?
        var page = 0
        var isEnd = false
    }

    static let pageSize = 20

    @Published var scope: Scope = .all
    @Published private(set) var query = ""
    @Published private(set) var neteaseSongs = Results()
    @Published private(set) var results: [String: Results] = [:]
    /// Backs the 网易云 scope, which keeps NetEase's own tabs.
    let netease = SearchViewModel(query: "")
    private var generation = 0

    func submit(_ text: String, sources: [LXSourceManager.SearchSource], force: Bool = false) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard force || trimmed != query else { return }
        query = trimmed
        generation += 1
        netease.setQuery(trimmed)
        neteaseSongs = Results()
        results = [:]
        guard !trimmed.isEmpty else { return }
        loadNeteaseSongs()
        for source in sources {
            loadPage(of: source, reset: true)
        }
        if scope == .netease {
            let netease = netease
            Task { await netease.load(tab: netease.tab) }
        }
    }

    func loadNeteaseSongs() {
        let generation = generation
        let query = query
        neteaseSongs.isLoading = true
        neteaseSongs.error = nil
        Task {
            do {
                let songs = try await NeteaseAPI.search(query, type: .songs, limit: 30).songs ?? []
                guard generation == self.generation else { return }
                neteaseSongs = Results(tracks: songs, isLoading: false, error: nil, page: 1, isEnd: true)
            } catch {
                guard generation == self.generation else { return }
                neteaseSongs = Results(tracks: [], isLoading: false, error: error.localizedDescription, page: 0, isEnd: true)
            }
        }
    }

    /// The next page of `source`, or its first when `reset`.
    func loadPage(of source: LXSourceManager.SearchSource, reset: Bool = false) {
        var current = reset ? Results() : (results[source.id] ?? Results())
        guard !query.isEmpty, !current.isLoading, reset || !current.isEnd else { return }
        current.isLoading = true
        current.error = nil
        results[source.id] = current
        let generation = generation
        let query = query
        let page = current.page + 1
        Task {
            do {
                let result = try await LXSourceManager.shared.search(source, keyword: query, page: page, limit: Self.pageSize)
                guard generation == self.generation else { return }
                var updated = results[source.id] ?? Results()
                let known = Set(updated.tracks.map(\.id))
                updated.tracks += result.tracks.filter { !known.contains($0.id) }
                updated.page = page
                updated.isEnd = result.isEnd || result.tracks.isEmpty
                updated.isLoading = false
                results[source.id] = updated
            } catch {
                guard generation == self.generation else { return }
                var updated = results[source.id] ?? Results()
                updated.isLoading = false
                updated.error = error.localizedDescription
                results[source.id] = updated
            }
        }
    }
}

/// The iPhone search tab: NetEase plus every LX custom source that can
/// search, side by side. "全部" shows the top songs of each source; a source
/// chip shows that source alone, with paging. Without custom sources it is
/// the plain NetEase search it always was, plus search history.
struct AggregatedSearchView: View {
    @StateObject private var model = AggregatedSearchModel()
    @ObservedObject private var sourceManager = LXSourceManager.shared
    @ObservedObject private var history = SearchHistoryStore.shared
    @State private var searchText = ""
    @State private var confirmClearHistory = false

    private static let previewCount = 5

    private var sources: [LXSourceManager.SearchSource] { sourceManager.searchSources }
    private var hasQuery: Bool { !model.query.isEmpty }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    VStack(alignment: .leading, spacing: 24) {
                        if hasQuery {
                            results
                        } else {
                            idleContent
                        }
                    }
                    .padding(.top, 12)
                    PlayerClearanceSpacer()
                } header: {
                    if hasQuery, !sources.isEmpty {
                        scopeBar
                    }
                }
            }
        }
        .searchable(text: $searchText, prompt: "搜索歌曲、歌手、专辑、歌单")
        .autocorrectionDisabled()
        .onSubmit(of: .search) {
            history.record(searchText)
            model.submit(searchText, sources: sources, force: true)
        }
        .onChange(of: searchText) { newValue in
            if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                model.submit("", sources: sources)
                return
            }
            Task {
                // Custom sources make real requests per query; wait for a pause.
                try? await Task.sleep(nanoseconds: 700_000_000)
                guard searchText == newValue else { return }
                model.submit(newValue, sources: sources)
            }
        }
        .onChange(of: sources) { newSources in
            if case .source(let id) = model.scope, !newSources.contains(where: { $0.id == id }) {
                model.scope = .all
            }
        }
        .navigationTitle("搜索")
        .confirmationDialog("清除搜索历史？", isPresented: $confirmClearHistory, titleVisibility: .visible) {
            Button("清除", role: .destructive) { history.clear() }
            Button("取消", role: .cancel) {}
        }
    }

    // MARK: - Scope bar

    private var scopeBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                scopeChip("全部", scope: .all, isLoading: false)
                scopeChip("网易云音乐", scope: .netease, isLoading: model.neteaseSongs.isLoading)
                ForEach(sources) { source in
                    scopeChip(source.name, scope: .source(source.id), isLoading: model.results[source.id]?.isLoading == true)
                }
            }
            .padding(.horizontal, Theme.Layout.contentInset)
            .padding(.vertical, 8)
        }
        .background(.bar)
    }

    private func scopeChip(_ title: String, scope: AggregatedSearchModel.Scope, isLoading: Bool) -> some View {
        Button {
            withAnimation(AppAnimation.quick) { model.scope = scope }
        } label: {
            HStack(spacing: 5) {
                Text(LocalizedStringKey(title))
                if isLoading {
                    ProgressView()
                        .controlSize(.mini)
                }
            }
        }
        .buttonStyle(.chip(isSelected: model.scope == scope))
        .accessibilityAddTraits(model.scope == scope ? .isSelected : [])
    }

    // MARK: - Results

    @ViewBuilder
    private var results: some View {
        if sources.isEmpty {
            NeteaseSearchResults(model: model.netease)
                .task(id: model.query) {
                    await model.netease.load(tab: model.netease.tab)
                }
        } else {
            switch model.scope {
            case .all:
                allSourcesContent
            case .netease:
                NeteaseSearchResults(model: model.netease)
            case .source(let id):
                if let source = sources.first(where: { $0.id == id }) {
                    sourceContent(source)
                }
            }
        }
    }

    private var allSourcesContent: some View {
        VStack(alignment: .leading, spacing: 28) {
            sourceSection(
                title: "网易云音乐",
                results: model.neteaseSongs,
                retry: { model.loadNeteaseSongs() },
                showAll: { model.scope = .netease }
            )
            ForEach(sources) { source in
                sourceSection(
                    title: source.name,
                    results: model.results[source.id] ?? AggregatedSearchModel.Results(isLoading: true),
                    retry: { model.loadPage(of: source, reset: true) },
                    showAll: { model.scope = .source(source.id) }
                )
            }
        }
    }

    private func sourceSection(
        title: String,
        results: AggregatedSearchModel.Results,
        retry: @escaping () -> Void,
        showAll: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(
                title: LocalizedStringKey(title),
                subtitle: results.tracks.isEmpty ? nil : String(localized: "\(results.tracks.count) 首"),
                action: results.tracks.count > Self.previewCount ? showAll : nil
            )
            .padding(.horizontal, Theme.Layout.contentInset)

            if !results.tracks.isEmpty {
                TrackListView(tracks: Array(results.tracks.prefix(Self.previewCount)))
                    .padding(.horizontal, Theme.Layout.contentInset - 10)
            } else {
                sourceStatus(results, retry: retry)
                    .padding(.horizontal, Theme.Layout.contentInset)
            }
        }
    }

    @ViewBuilder
    private func sourceStatus(_ results: AggregatedSearchModel.Results, retry: @escaping () -> Void) -> some View {
        if results.isLoading {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("正在搜索…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(height: 44)
        } else if let error = results.error {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer(minLength: 8)
                Button("重试", action: retry)
                    .font(.subheadline.weight(.semibold))
            }
            .padding(.vertical, 10)
        } else {
            Text("没有找到相关歌曲")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(height: 44)
        }
    }

    @ViewBuilder
    private func sourceContent(_ source: LXSourceManager.SearchSource) -> some View {
        let results = model.results[source.id] ?? AggregatedSearchModel.Results(isLoading: true)
        if results.tracks.isEmpty {
            sourceStatus(results, retry: { model.loadPage(of: source, reset: true) })
                .frame(maxWidth: .infinity, minHeight: 240)
                .padding(.horizontal, Theme.Layout.contentInset)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                TrackListView(tracks: results.tracks)
                    .padding(.horizontal, Theme.Layout.contentInset - 10)

                if results.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                } else if let error = results.error {
                    Button {
                        model.loadPage(of: source)
                    } label: {
                        Label(String(localized: "加载失败，点按重试：\(error)"), systemImage: "arrow.clockwise")
                            .font(.subheadline)
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .padding(.horizontal, Theme.Layout.contentInset)
                } else if !results.isEnd {
                    Color.clear
                        .frame(height: 1)
                        .onAppear { model.loadPage(of: source) }
                }
            }
        }
    }

    // MARK: - Before a search

    @ViewBuilder
    private var idleContent: some View {
        if !history.items.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("搜索历史")
                        .font(.title3.weight(.semibold))
                    Spacer()
                    Button {
                        confirmClearHistory = true
                    } label: {
                        Image(systemName: "trash")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("清除搜索历史")
                }
                FlowLayout(spacing: 8) {
                    ForEach(history.items, id: \.self) { item in
                        Button {
                            searchText = item
                            history.record(item)
                            model.submit(item, sources: sources, force: true)
                        } label: {
                            Text(item)
                                .lineLimit(1)
                        }
                        .buttonStyle(.chip(isSelected: false))
                        .contextMenu {
                            Button(role: .destructive) {
                                history.remove(item)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, Theme.Layout.contentInset)
        }

        sourcesSummary
            .padding(.horizontal, Theme.Layout.contentInset)
    }

    @ViewBuilder
    private var sourcesSummary: some View {
        if sources.isEmpty {
            NavigationLink {
                LXSourcesSettingsView()
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: "square.stack.3d.up")
                        .font(.title2)
                        .foregroundStyle(Theme.accent)
                        .frame(width: 32)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("聚合更多音乐平台")
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text("导入 LX Music 格式的自定义音源后，可以在这里同时搜索多个平台")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(16)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous))
            }
            .buttonStyle(.plain)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text("搜索来源")
                    .font(.title3.weight(.semibold))
                FlowLayout(spacing: 8) {
                    sourceTag("网易云音乐")
                    ForEach(sources) { source in
                        sourceTag(source.name)
                    }
                }
                NavigationLink {
                    LXSourcesSettingsView()
                } label: {
                    Text("管理自定义音源")
                        .font(.subheadline)
                }
            }
        }
    }

    private func sourceTag(_ name: String) -> some View {
        Label(name, systemImage: "checkmark.circle.fill")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.quaternary.opacity(0.5), in: Capsule())
    }
}

/// Lays children out left to right, wrapping to a new line when the next one
/// would not fit.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = arrange(subviews, in: width)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        let usedWidth = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? usedWidth, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(subviews, in: bounds.width)
        for row in rows {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                let fitted = CGSize(width: min(size.width, bounds.width), height: size.height)
                subviews[index].place(
                    at: CGPoint(x: x, y: bounds.minY + row.y + (row.height - fitted.height) / 2),
                    proposal: ProposedViewSize(fitted)
                )
                x += fitted.width + spacing
            }
        }
    }

    private struct Row {
        var indices: [Int] = []
        var y: CGFloat = 0
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, in maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let width = min(size.width, maxWidth)
            let needed = current.indices.isEmpty ? width : current.width + spacing + width
            if needed > maxWidth, !current.indices.isEmpty {
                rows.append(current)
                current = Row(y: current.y + current.height + spacing)
            }
            current.width = current.indices.isEmpty ? width : current.width + spacing + width
            current.indices.append(index)
            current.height = max(current.height, size.height)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
#endif
