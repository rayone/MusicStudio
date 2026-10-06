import SwiftUI
import AppKit

public struct AbcEditorView: View {
    @ObservedObject var vm: StudioViewModel

    public init(vm: StudioViewModel) {
        self.vm = vm
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header bar
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "music.note.list")
                        .foregroundColor(Theme.yellow)
                    Text("ABC SYMBOLIC SCORE")
                        .font(Theme.smallBold)
                        .foregroundColor(Theme.comment)
                }

                Spacer()

                // Action buttons
                Button(action: {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = []
                    panel.allowsMultipleSelection = false
                    panel.prompt = "Load .abc Score"
                    if panel.runModal() == .OK, let url = panel.url {
                        if let text = try? String(contentsOf: url, encoding: .utf8) {
                            vm.abcScoreText = text
                        }
                    }
                }) {
                    Label("Import", systemImage: "square.and.arrow.down")
                        .font(Theme.small)
                }
                .buttonStyle(.plain)
                .foregroundColor(Theme.blue)

                Button(action: {
                    let panel = NSSavePanel()
                    panel.nameFieldStringValue = "song.abc"
                    panel.prompt = "Export Score"
                    if panel.runModal() == .OK, let url = panel.url {
                        try? vm.abcScoreText.write(to: url, atomically: true, encoding: .utf8)
                    }
                }) {
                    Label("Export", systemImage: "square.and.arrow.up")
                        .font(Theme.small)
                }
                .buttonStyle(.plain)
                .foregroundColor(Theme.blue)
                .disabled(vm.abcScoreText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button(action: {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(vm.abcScoreText, forType: .string)
                }) {
                    Label("Copy", systemImage: "doc.on.doc")
                        .font(Theme.small)
                }
                .buttonStyle(.plain)
                .foregroundColor(Theme.blue)
                .disabled(vm.abcScoreText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button(action: {
                    vm.abcScoreText = ""
                }) {
                    Text("Clear")
                        .font(Theme.small)
                }
                .buttonStyle(.plain)
                .foregroundColor(Theme.comment)
            }

            // Compact single-row ABC editor
            ResizableEditor(
                text: $vm.abcScoreText,
                height: $vm.abcEditorHeight,
                minHeight: 40,
                maxHeight: 600,
                defaultHeight: 60,
                dimmed: false
            )

            if !vm.abcScoreText.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(Theme.green)
                        .font(.system(size: 10))
                    Text("Active score — Add to Queue snapshots and renders it (CoT Full/Melody)")
                        .font(Theme.small)
                        .foregroundColor(Theme.green)
                        .lineLimit(1)
                    Spacer()
                }
            }
        }
    }
}
