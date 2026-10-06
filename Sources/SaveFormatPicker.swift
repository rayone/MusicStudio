import AppKit
import UniformTypeIdentifiers

/// Accessory view for NSSavePanel: a "Format" menu (WAV / MP3 / M4A / FLAC) that keeps
/// the panel's allowed type and the filename extension in sync with the selection.
@MainActor
public final class SaveFormatPicker: NSObject {
    public let view: NSView
    public private(set) var selected: AudioFormat

    private weak var panel: NSSavePanel?
    private let popup: NSPopUpButton
    private let formats = AudioFormat.allCases

    public init(panel: NSSavePanel, baseName: String, initial: AudioFormat) {
        self.panel = panel
        self.selected = initial

        let label = NSTextField(labelWithString: "Format:")
        popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: formats.map(\.displayName))
        popup.selectItem(at: formats.firstIndex(of: initial) ?? 0)

        let stack = NSStackView(views: [label, popup])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 40))
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        self.view = container
        super.init()

        popup.target = self
        popup.action = #selector(formatChanged)
        panel.nameFieldStringValue = "\(baseName).\(initial.rawValue)"
        apply(initial)
    }

    @objc private func formatChanged() {
        let fmt = formats[max(0, popup.indexOfSelectedItem)]
        selected = fmt
        apply(fmt)
        // Swap the extension on whatever name the user has typed.
        if let panel {
            let stem = (panel.nameFieldStringValue as NSString).deletingPathExtension
            panel.nameFieldStringValue = "\(stem).\(fmt.rawValue)"
        }
    }

    private func apply(_ fmt: AudioFormat) {
        panel?.allowedContentTypes = [Self.contentType(for: fmt)]
    }

    static func contentType(for fmt: AudioFormat) -> UTType {
        switch fmt {
        case .wav: return .wav
        case .mp3: return .mp3
        case .m4a: return .mpeg4Audio
        case .flac: return UTType(filenameExtension: "flac") ?? .audio
        }
    }
}
