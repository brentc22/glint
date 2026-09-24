import AppKit
import SwiftUI

/// Click, press a combination, done. Esc cancels, ⌫ clears. Requires at least one of
/// ⌘ ⌃ ⌥ (or an F-key), so a bare letter can't hijack typing everywhere.
struct ShortcutRecorder: NSViewRepresentable {
    let combo: HotKeys.Combo?
    let onChange: (HotKeys.Combo?) -> Void

    func makeNSView(context: Context) -> RecorderButton {
        let button = RecorderButton()
        button.onChange = onChange
        return button
    }

    func updateNSView(_ button: RecorderButton, context: Context) {
        button.onChange = onChange
        button.combo = combo
    }
}

final class RecorderButton: NSButton {
    var onChange: (HotKeys.Combo?) -> Void = { _ in }
    var combo: HotKeys.Combo? { didSet { refresh() } }
    private var recording = false { didSet { refresh() } }
    private var monitor: Any?

    init() {
        super.init(frame: .zero)
        bezelStyle = .push
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(toggle)
        widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func refresh() {
        title = recording ? "Press keys…" : (combo?.symbol ?? "Click to record")
        contentTintColor = recording ? .controlAccentColor : nil
    }

    @objc private func toggle() {
        recording ? stop() : start()
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            let isFunctionKey = HotKeys.Combo.specialKeys[Int(event.keyCode)]?.hasPrefix("F") == true
            switch Int(event.keyCode) {
            case 53 where mods.isEmpty: self.stop()                                 // Esc: cancel
            case 51 where mods.isEmpty, 117 where mods.isEmpty: self.onChange(nil); self.stop()  // ⌫: clear
            default:
                guard isFunctionKey || !mods.subtracting(.shift).isEmpty else { NSSound.beep(); return nil }
                self.onChange(HotKeys.Combo(keyCode: Int(event.keyCode), modifiers: mods))
                self.stop()
            }
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
