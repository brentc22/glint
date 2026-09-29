import AppKit
import GlintCore
import QuickLookThumbnailing
import SwiftUI

/// Every capture in the save folder, newest first — and searchable by the text inside
/// them. The text is read on-device, once per file, and kept in the cache folder, so
/// "that screenshot with the invoice number" is a search away.
@MainActor
enum HistoryWindow {
    private static var window: NSWindow?
    private static var model: HistoryModel?

    static func show(open: @escaping (URL) -> Void, pin: @escaping (URL) -> Void) {
        if window == nil {
            let model = HistoryModel(open: open, pin: pin)
            let host = NSHostingController(rootView: HistoryView(model: model))
            let w = NSWindow(contentViewController: host)
            w.title = "Capture History"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.setContentSize(CGSize(width: 860, height: 600))
            w.minSize = CGSize(width: 480, height: 360)
            w.isReleasedWhenClosed = false
            w.setFrameAutosaveName("GlintHistory")
            w.center()
            window = w
            self.model = model
        }
        model?.reload()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// A new capture landed: refresh if the window is up.
    static func refresh() {
        if window?.isVisible == true { model?.reload() }
    }
}

struct HistoryItem: Identifiable, Hashable {
    let url: URL
    let modified: Date
    var id: URL { url }
    var isVideo: Bool { url.pathExtension.lowercased() == "mp4" }
    var isImage: Bool { HistoryModel.imageTypes.contains(url.pathExtension.lowercased()) }
}

@MainActor
final class HistoryModel: ObservableObject {
    nonisolated static let imageTypes: Set<String> = ["png", "jpg", "jpeg", "gif"]
    nonisolated static let types = imageTypes.union(["mp4"])

    @Published private(set) var items: [HistoryItem] = []
    @Published private(set) var thumbnails: [URL: NSImage] = [:]
    @Published private(set) var pending = 0
    @Published var query = ""
    @Published var selection: URL?

    let open: (URL) -> Void
    let pin: (URL) -> Void
    private var texts: [String: String] = [:]
    private var indexing: Task<Void, Never>?

    init(open: @escaping (URL) -> Void, pin: @escaping (URL) -> Void) {
        self.open = open
        self.pin = pin
        texts = Self.loadCache()
    }

    var visible: [HistoryItem] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return items }
        return items.filter { HistorySearch.matches(query, name: $0.url.lastPathComponent, text: text(for: $0)) }
    }

    /// Sections by day, newest first.
    var days: [(title: String, items: [HistoryItem])] {
        let calendar = Calendar.current
        let groups = Dictionary(grouping: visible) { calendar.startOfDay(for: $0.modified) }
        return groups.keys.sorted(by: >).map { day in
            let title = calendar.isDateInToday(day) ? "Today"
                : calendar.isDateInYesterday(day) ? "Yesterday"
                : day.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
            return (title, groups[day] ?? [])
        }
    }

    func reload() {
        let folder = Prefs.saveFolder
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []
        items = files
            .filter { Self.types.contains($0.pathExtension.lowercased()) }
            .map { HistoryItem(url: $0, modified: (try? $0.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast) }
            .sorted { $0.modified > $1.modified }
        thumbnails = thumbnails.filter { url, _ in items.contains { $0.url == url } }
        index()
    }

    func thumbnail(for item: HistoryItem) {
        guard thumbnails[item.url] == nil else { return }
        let request = QLThumbnailGenerator.Request(fileAt: item.url, size: CGSize(width: 320, height: 220),
                                                   scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .thumbnail)
        let url = item.url
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
            guard let image = rep?.nsImage else { return }
            Task { @MainActor in self.thumbnails[url] = image }
        }
    }

    private func text(for item: HistoryItem) -> String? {
        texts[HistorySearch.key(path: item.url.path, modified: item.modified)]
    }

    /// Reads the text of every image that hasn't been read yet, newest first, one at a
    /// time in the background. Videos are searched by name only.
    private func index() {
        indexing?.cancel()
        let todo = items.filter { $0.isImage && text(for: $0) == nil }
        pending = todo.count
        guard !todo.isEmpty else { return }
        indexing = Task {
            for item in todo {
                guard !Task.isCancelled else { return }
                let text = await Self.read(item.url)
                texts[HistorySearch.key(path: item.url.path, modified: item.modified)] = text
                pending -= 1
                if pending % 10 == 0 { Self.saveCache(texts) }
            }
            Self.saveCache(texts)
            objectWillChange.send()  // a search typed while indexing now sees everything
        }
    }

    private static func read(_ url: URL) async -> String {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return "" }
        return await TextRecognizer.text(in: image)
    }

    // MARK: Actions

    func copy(_ item: HistoryItem) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([item.url as NSURL])
        if item.isImage, let image = NSImage(contentsOf: item.url) { pb.writeObjects([image]) }
        Toast.show("Copied to clipboard")
    }

    func reveal(_ item: HistoryItem) { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }

    func trash(_ item: HistoryItem) {
        NSWorkspace.shared.recycle([item.url]) { _, _ in Task { @MainActor in self.reload() } }
    }

    // MARK: Cache

    private static var cacheURL: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(Bundle.main.bundleIdentifier ?? "Glint").appendingPathComponent("history-text.json")
    }

    private static func loadCache() -> [String: String] {
        guard let data = try? Data(contentsOf: cacheURL) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    private static func saveCache(_ texts: [String: String]) {
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(texts).write(to: cacheURL, options: .atomic)
    }
}

// MARK: - Views

private struct HistoryView: View {
    @ObservedObject var model: HistoryModel
    private let columns = [GridItem(.adaptive(minimum: 190, maximum: 260), spacing: 14)]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search names and the text in your screenshots", text: $model.query)
                        .textFieldStyle(.plain)
                    if !model.query.isEmpty {
                        Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06)))
                if model.pending > 0 {
                    ProgressView().controlSize(.small)
                    Text("Reading \(model.pending) left").foregroundStyle(.secondary).font(.callout).monospacedDigit()
                }
                Button { NSWorkspace.shared.open(Prefs.saveFolder) } label: { Image(systemName: "folder") }
                    .help("Show in Finder")
            }
            .padding(12)
            Divider()
            if model.items.isEmpty {
                empty("No captures yet", "Screenshots and recordings saved to \(Prefs.saveFolder.lastPathComponent) show up here.")
            } else if model.visible.isEmpty {
                empty("Nothing matches “\(model.query)”", model.pending > 0 ? "Still reading \(model.pending) screenshots." : "Glint searches file names and the text inside each screenshot.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18, pinnedViews: [.sectionHeaders]) {
                        ForEach(model.days, id: \.title) { day in
                            Section {
                                LazyVGrid(columns: columns, spacing: 14) {
                                    ForEach(day.items) { HistoryCell(item: $0, model: model) }
                                }
                                .padding(.horizontal, 14)
                            } header: {
                                Text(day.title).font(.headline)
                                    .padding(.horizontal, 14).padding(.vertical, 6)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(.bar)
                            }
                        }
                    }
                    .padding(.bottom, 14)
                }
            }
        }
        .frame(minWidth: 480, minHeight: 360)
    }

    private func empty(_ title: String, _ detail: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "photo.on.rectangle.angled").font(.system(size: 36)).foregroundStyle(.tertiary)
            Text(title).font(.title3.weight(.semibold))
            Text(detail).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct HistoryCell: View {
    let item: HistoryItem
    @ObservedObject var model: HistoryModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05))
                if let thumb = model.thumbnails[item.url] {
                    Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fit).padding(6)
                } else {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if item.isVideo {
                    Label("Video", systemImage: "play.fill").font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Capsule().fill(.black.opacity(0.6))).foregroundStyle(.white).padding(8)
                }
            }
            .frame(height: 140)
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(model.selection == item.url ? Color.accentColor : Color.primary.opacity(0.08),
                              lineWidth: model.selection == item.url ? 2 : 0.5))
            Text(item.modified.formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onAppear { model.thumbnail(for: item) }
        .onTapGesture(count: 2) { model.open(item.url) }
        .onTapGesture { model.selection = item.url }
        .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
        .help(item.url.lastPathComponent)
        .contextMenu {
            Button(item.isVideo ? "Open" : "Annotate") { model.open(item.url) }
            if item.isImage { Button("Pin to Screen") { model.pin(item.url) } }
            Button("Copy") { model.copy(item) }
            Button("Show in Finder") { model.reveal(item) }
            Divider()
            Button("Move to Trash", role: .destructive) { model.trash(item) }
        }
    }
}
