import AppKit
import GlintCore
import SwiftUI

/// The annotation window. Closing it keeps your edits — the file and clipboard get the
/// annotated version — because losing work to a stray ⌘W is worse than an extra undo.
@MainActor
final class EditorWindow: NSWindow, NSWindowDelegate {
    private static var open: [EditorWindow] = []
    private let model: EditorModel
    private let onPin: (Capture) -> Void

    static func show(_ capture: Capture, onPin: @escaping (Capture) -> Void) {
        let window = EditorWindow(capture: capture, onPin: onPin)
        open.append(window)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private init(capture: Capture, onPin: @escaping (Capture) -> Void) {
        model = EditorModel(capture: capture)
        self.onPin = onPin
        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let size = CGSize(width: min(max(capture.pointSize.width + 120, 900), screen.width * 0.9),
                          height: min(max(capture.pointSize.height + 160, 560), screen.height * 0.9))
        super.init(contentRect: CGRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2,
                                       width: size.width, height: size.height),
                   styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                   backing: .buffered, defer: false)
        title = "Glint"
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isReleasedWhenClosed = false
        minSize = CGSize(width: 820, height: 460)
        delegate = self

        let canvas = CanvasView(model: model)
        canvas.commands = .init(copy: { [weak self] in self?.copyImage() },
                                save: { [weak self] in self?.save() },
                                close: { [weak self] in self?.close() },
                                done: { [weak self] in self?.close() })
        let toolbar = NSHostingView(rootView: EditorToolbar(model: model, actions: .init(
            copy: { [weak self] in self?.copyImage() },
            save: { [weak self] in self?.save() },
            pin: { [weak self] in self?.pin() },
            copyText: { [weak self] in self?.copyText() },
            redact: { [weak self] in self?.redact() },
            done: { [weak self] in self?.close() })))

        let root = NSView()
        [toolbar, canvas].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; root.addSubview($0) }
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: root.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 76),  // clear of the traffic lights
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 52),
            canvas.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            canvas.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            canvas.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        contentView = root
        makeFirstResponder(canvas)
    }

    private var hasEdits: Bool { model.document.canUndo }

    private func apply() {
        if hasEdits { model.capture.update(model.export()) }
    }

    private func copyImage() {
        apply()
        model.capture.copy()
        Toast.show("Copied to clipboard")
    }

    private func save() {
        apply()
        if let url = try? model.capture.save() {
            Toast.show("Saved to \(url.deletingLastPathComponent().lastPathComponent)", symbol: "square.and.arrow.down.fill")
        }
    }

    private func pin() {
        apply()
        onPin(model.capture)
    }

    private func copyText() {
        Task {
            let text = await model.recognizedText()
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            Toast.show(text.isEmpty ? "No text found" : "Copied \(text.split(whereSeparator: \.isWhitespace).count) words",
                       symbol: text.isEmpty ? "text.magnifyingglass" : "text.viewfinder")
        }
    }

    private func redact() {
        Task {
            let count = await model.autoRedact()
            Toast.show(count == 0 ? "Nothing sensitive found" : "Redacted \(count) item\(count == 1 ? "" : "s")",
                       symbol: count == 0 ? "checkmark.shield" : "eye.slash.fill")
        }
    }

    func windowWillClose(_ notification: Notification) {
        apply()
        Self.open.removeAll { $0 === self }
    }
}

struct EditorActions {
    let copy: () -> Void
    let save: () -> Void
    let pin: () -> Void
    let copyText: () -> Void
    let redact: () -> Void
    let done: () -> Void
}

private struct EditorToolbar: View {
    @ObservedObject var model: EditorModel
    let actions: EditorActions

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                ForEach(Tool.allCases) { tool in
                    iconButton(tool.symbol, help: "\(tool.title) (\(tool.key.uppercased()))", active: model.tool == tool) {
                        model.tool = tool
                    }
                }
            }
            divider
            HStack(spacing: 5) {
                ForEach(RGBA.palette, id: \.self) { c in
                    Circle()
                        .fill(Color(cgColor: c.cgColor))
                        .frame(width: 16, height: 16)
                        .overlay(Circle().strokeBorder(.primary.opacity(model.color == c ? 0.9 : 0.15), lineWidth: model.color == c ? 2 : 1))
                        .padding(2)
                        .contentShape(Circle())
                        .onTapGesture { model.color = c }
                }
            }
            divider
            HStack(spacing: 2) {
                ForEach(StrokeSize.allCases) { s in
                    Button { model.size = s } label: {
                        Circle().frame(width: 4 + s.rawValue, height: 4 + s.rawValue)
                            .frame(width: 26, height: 26)
                            .background(model.size == s ? Color.primary.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .help("Stroke \(s == .small ? "thin" : s == .medium ? "medium" : "thick")")
                }
            }
            divider
            Button(action: actions.redact) {
                Label(model.isRedacting ? "Scanning…" : "Redact", systemImage: "eye.slash")
            }
            .disabled(model.isRedacting)
            .help("Find and pixelate emails, phone numbers, IBANs, card numbers, API keys and tokens — on-device")
            Menu {
                Button("None") { model.backdrop = nil }
                ForEach(Backdrop.presets.indices, id: \.self) { i in
                    Button(["Sunset", "Violet", "Ocean", "Graphite", "Paper"][i]) { model.backdrop = i }
                }
            } label: {
                Image(systemName: "photo.artframe")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Background")

            Spacer(minLength: 8)

            iconButton("arrow.uturn.backward", help: "Undo (⌘Z)", active: false, action: model.undo).disabled(!model.document.canUndo)
            iconButton("arrow.uturn.forward", help: "Redo (⇧⌘Z)", active: false, action: model.redo).disabled(!model.document.canRedo)
            iconButton("text.viewfinder", help: "Copy text (OCR)", active: false, action: actions.copyText)
            iconButton("pin", help: "Pin to screen", active: false, action: actions.pin)
            iconButton("square.and.arrow.down", help: "Save (⌘S)", active: false, action: actions.save)
            Button(action: actions.copy) { Label("Copy", systemImage: "doc.on.doc") }
                .help("Copy (⌘C)")
            Button("Done", action: actions.done)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.horizontal, 12)
        .frame(maxHeight: .infinity)
        .controlSize(.regular)
    }

    private var divider: some View { Divider().frame(height: 22) }

    private func iconButton(_ symbol: String, help: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 28, height: 28)
                .background(active ? Color.accentColor.opacity(0.9) : .clear, in: RoundedRectangle(cornerRadius: 7))
                .foregroundStyle(active ? Color.white : Color.primary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
