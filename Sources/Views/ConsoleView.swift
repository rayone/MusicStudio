import SwiftUI
import AppKit

public struct ConsoleTextView: NSViewRepresentable {
    let entries: [LogEntry]
    let filterVersion: Int

    public init(entries: [LogEntry], filterVersion: Int = 0) {
        self.entries = entries
        self.filterVersion = filterVersion
    }

    public class Coordinator {
        var renderedCount = 0
        var lastFilterVersion = 0
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        guard let text = scroll.documentView as? NSTextView else { return scroll }
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.isRichText = true
        text.textContainerInset = NSSize(width: 8, height: 6)
        text.isHorizontallyResizable = false
        text.textContainer?.widthTracksTextView = true
        text.autoresizingMask = [.width]
        return scroll
    }

    public func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let text = scroll.documentView as? NSTextView,
              let storage = text.textStorage else { return }

        let coordinator = context.coordinator
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let boldFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)

        // Reset if filter changed or buffer cleared
        if coordinator.lastFilterVersion != filterVersion || entries.count < coordinator.renderedCount {
            storage.beginEditing()
            storage.setAttributedString(NSAttributedString())
            storage.endEditing()
            coordinator.renderedCount = 0
            coordinator.lastFilterVersion = filterVersion
        }

        if entries.isEmpty {
            if storage.length == 0 {
                storage.beginEditing()
                storage.setAttributedString(NSAttributedString(
                    string: "Ready. Verbose component-attributed logs stream here in real time.",
                    attributes: [.font: font, .foregroundColor: NSColor(Theme.comment)]
                ))
                storage.endEditing()
            }
            return
        }

        let newEntries = entries[coordinator.renderedCount...]
        guard !newEntries.isEmpty else { return }

        // Determine if user was already at or near bottom
        let isAtBottom: Bool = {
            guard let doc = scroll.contentView.documentView else { return true }
            let visible = scroll.contentView.bounds
            return (doc.bounds.height - (visible.origin.y + visible.height)) < 28
        }()

        let hasSelection = text.selectedRange().length > 0

        storage.beginEditing()
        // If we previously had the empty placeholder, clear it
        if coordinator.renderedCount == 0 && storage.string.starts(with: "Ready.") {
            storage.setAttributedString(NSAttributedString())
        }

        for entry in newEntries {
            let prefix = coordinator.renderedCount == 0 ? "" : "\n"
            let line = NSMutableAttributedString()
            if !prefix.isEmpty {
                line.append(NSAttributedString(string: prefix, attributes: [.font: font]))
            }

            // Timestamp (HH:mm:ss.SSS)
            line.append(NSAttributedString(string: entry.formattedTimestamp, attributes: [
                .font: font,
                .foregroundColor: NSColor(Theme.comment)
            ]))
            line.append(NSAttributedString(string: "  ", attributes: [.font: font]))

            // Component padded to 9
            let compPadded = entry.component.displayName.padding(toLength: 9, withPad: " ", startingAt: 0)
            line.append(NSAttributedString(string: compPadded, attributes: [
                .font: boldFont,
                .foregroundColor: NSColor(componentColor(entry.component))
            ]))
            line.append(NSAttributedString(string: "  ", attributes: [.font: font]))

            // Level padded to 5
            let lvlPadded = entry.level.displayName.padding(toLength: 5, withPad: " ", startingAt: 0)
            line.append(NSAttributedString(string: lvlPadded, attributes: [
                .font: font,
                .foregroundColor: NSColor(levelColor(entry.level))
            ]))
            line.append(NSAttributedString(string: "  ", attributes: [.font: font]))

            // Message
            line.append(NSAttributedString(string: entry.message, attributes: [
                .font: font,
                .foregroundColor: NSColor(Theme.fg)
            ]))

            // Detail
            if !entry.detail.isEmpty {
                line.append(NSAttributedString(string: "          " + entry.detail, attributes: [
                    .font: font,
                    .foregroundColor: NSColor(Theme.comment)
                ]))
            }

            storage.append(line)
            coordinator.renderedCount += 1
        }
        storage.endEditing()

        // Auto-scroll only if previously at bottom AND no active selection
        if isAtBottom && !hasSelection {
            let len = storage.length
            if len > 0 {
                text.scrollRangeToVisible(NSRange(location: len - 1, length: 1))
            }
        }
    }

    private func componentColor(_ component: LogComponent) -> Color {
        switch component {
        // Orchestration
        case .app, .worker: return Theme.blue
        case .ui: return Theme.cyan
        case .queue: return Theme.purple
        case .power: return Theme.green
        case .setup, .hf: return Theme.yellow

        // Generation pipeline
        case .model: return Theme.cyan
        case .tokenizer: return Theme.purple
        case .ar, .nar, .flow: return Theme.orange
        case .vae: return Theme.green
        case .cot: return Theme.yellow

        // Post-processing
        case .loudness: return Theme.green
        case .convert: return Theme.cyan
        case .tags: return Theme.blue
        case .stems: return Theme.purple
        case .sfx: return Theme.orange
        case .eq: return Theme.yellow
        case .eval: return Theme.purple

        // Data
        case .db: return Theme.purple
        case .search: return Theme.cyan
        case .embed: return Theme.blue
        case .template: return Theme.fgDark
        case .lyrics: return Theme.green
        case .abc: return Theme.yellow
        case .fs: return Theme.comment
        }
    }

    private func levelColor(_ level: LogLevel) -> Color {
        switch level {
        case .trace, .debug: return Theme.comment
        case .info: return Theme.fgDark
        case .warn: return Theme.yellow
        case .error: return Theme.red
        }
    }
}

public struct ConsoleView: View {
    @ObservedObject var vm: StudioViewModel
    @State private var filterVersion = 0

    public init(vm: StudioViewModel) {
        self.vm = vm
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header Bar
            HStack(spacing: 8) {
                Text("CONSOLE")
                    .font(Theme.smallBold)
                    .foregroundColor(Theme.comment)

                Text("\(vm.filteredLogEntries.count) / \(vm.logEntries.count)")
                    .font(Theme.mono)
                    .foregroundColor(Theme.comment)

                Spacer()

                // Level Filter
                Picker("Level", selection: $vm.selectedLogLevel) {
                    Text("Trace").tag(LogLevel.trace)
                    Text("Debug").tag(LogLevel.debug)
                    Text("Info").tag(LogLevel.info)
                    Text("Warn").tag(LogLevel.warn)
                    Text("Error").tag(LogLevel.error)
                }
                .pickerStyle(.menu)
                .font(Theme.small)
                .frame(width: 80)
                .onChange(of: vm.selectedLogLevel) { _, _ in filterVersion += 1 }
                // Component Filter Menu
                Menu {
                    Button("Select All") {
                        vm.selectedLogComponents = Set(LogComponent.allCases)
                        filterVersion += 1
                    }
                    Button("Clear All") {
                        vm.selectedLogComponents.removeAll()
                        filterVersion += 1
                    }
                    Button("Pipeline Only (AR/NAR/Flow/VAE/CoT)") {
                        vm.selectedLogComponents = Set([.model, .tokenizer, .ar, .nar, .flow, .vae, .cot])
                        filterVersion += 1
                    }
                    Button("Orchestration (Queue/Worker/App/Power)") {
                        vm.selectedLogComponents = Set([.app, .ui, .queue, .worker, .power, .setup, .hf])
                        filterVersion += 1
                    }
                    Divider()
                    ForEach(LogComponent.allCases, id: \.self) { comp in
                        Toggle(isOn: Binding(
                            get: { vm.selectedLogComponents.contains(comp) },
                            set: { on in
                                if on { vm.selectedLogComponents.insert(comp) }
                                else { vm.selectedLogComponents.remove(comp) }
                                filterVersion += 1
                            }
                        )) {
                            Text(comp.displayName)
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                        Text(componentFilterLabel)
                    }
                    .font(Theme.small)
                    .foregroundColor(Theme.fgDark)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 120)

                // Search Field
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .font(Theme.small)
                        .foregroundColor(Theme.comment)
                    TextField("Filter...", text: $vm.logSearchText)
                        .textFieldStyle(.plain)
                        .font(Theme.mono)
                        .foregroundColor(Theme.fg)
                        .onChange(of: vm.logSearchText) { _, _ in filterVersion += 1 }
                    if !vm.logSearchText.isEmpty {
                        Button(action: {
                            vm.logSearchText = ""
                            filterVersion += 1
                        }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(Theme.small)
                                .foregroundColor(Theme.comment)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Theme.bgDark)
                .cornerRadius(4)
                .frame(width: 110)

                // Copy Button
                Button(action: copyLogs) {
                    HStack(spacing: 3) {
                        Image(systemName: "doc.on.doc")
                        Text("Copy")
                    }
                    .font(Theme.small)
                    .foregroundColor(Theme.blue)
                }
                .buttonStyle(.plain)

                // Clear Button
                Button(action: {
                    vm.clearLogs()
                    filterVersion += 1
                }) {
                    HStack(spacing: 3) {
                        Image(systemName: "trash")
                        Text("Clear")
                    }
                    .font(Theme.small)
                    .foregroundColor(Theme.red)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 4)

            // Console TextView
            ConsoleTextView(entries: vm.filteredLogEntries, filterVersion: filterVersion)
                .frame(height: 180)
                .background(Theme.bgDark)
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Theme.border, lineWidth: 1)
                )
        }
    }

    private var componentFilterLabel: String {
        if vm.selectedLogComponents.count == LogComponent.allCases.count {
            return "All Components"
        } else if vm.selectedLogComponents.isEmpty {
            return "No Components"
        } else {
            return "\(vm.selectedLogComponents.count) Comp"
        }
    }

    private func copyLogs() {
        let text = vm.filteredLogEntries.map(\.plain).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
