import SwiftUI

public struct FlowLayout: Layout {
    public var spacing: CGFloat = 4

    public init(spacing: CGFloat = 4) {
        self.spacing = spacing
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var rowHeight: CGFloat = 0
        var total = CGSize(width: 0, height: 0)

        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + spacing + s.width > maxWidth {
                total.height += rowHeight + spacing
                total.width = max(total.width, x)
                x = s.width
                rowHeight = s.height
            } else {
                x += (x > 0 ? spacing : 0) + s.width
                rowHeight = max(rowHeight, s.height)
            }
        }
        total.height += rowHeight
        total.width = max(total.width, x)
        return total
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
        }
    }
}

public struct StyleLibraryView: View {
    @ObservedObject var vm: StudioViewModel
    @State private var showFilters: Bool = false
    @State private var showNewTemplateModal: Bool = false
    @State private var templateToDelete: PromptTemplate? = nil
    @State private var showDeleteConfirm: Bool = false
    private let keyOptions = ["All", "C", "C#", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"]
    private let scaleOptions = ["All", "major", "minor"]
    private let vocalOptions = ["All", "male", "female", "duet", "choir", "instrumental", "unknown"]

    public init(vm: StudioViewModel) {
        self.vm = vm
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header
            HStack(spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "music.note.list")
                        .foregroundColor(Theme.blue)
                    Text("STYLE & PRESET LIBRARY")
                        .font(Theme.smallBold)
                        .foregroundColor(Theme.comment)
                }

                Spacer()

                if !vm.templateLoadNote.isEmpty {
                    Text(vm.templateLoadNote)
                        .font(Theme.small)
                        .foregroundColor(Theme.yellow)
                        .lineLimit(1)
                } else {
                    Text("\(vm.filteredTemplates.count) of \(vm.templates.count) presets")
                        .font(Theme.small)
                        .foregroundColor(Theme.comment)
                }

                Button(action: {
                    showNewTemplateModal = true
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .bold))
                        Text("New Preset")
                            .font(Theme.smallBold)
                    }
                    .foregroundColor(Theme.blue)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Theme.blue.opacity(0.12))
                    .cornerRadius(4)
                }
                .buttonStyle(.plain)
                .help("Create and save a new style preset")
            }

            // Search Bar (Keyword vs Semantic AI)
            HStack(spacing: 6) {
                Image(systemName: vm.isSemanticSearch ? "sparkles" : "magnifyingglass")
                    .font(Theme.small)
                    .foregroundColor(vm.isSemanticSearch ? Theme.purple : Theme.comment)

                TextField(vm.isSemanticSearch
                          ? "Semantic AI Search (e.g. dark cyberpunk synth, sad piano ballad)..."
                          : "Search title, genre, subgenre, mood, instruments (e.g. trap influences)...",
                          text: $vm.searchQuery)
                    .textFieldStyle(.plain)
                    .font(Theme.body)
                    .foregroundColor(Theme.fg)
                    .onSubmit {
                        if vm.isSemanticSearch {
                            vm.performAiSearch()
                        } else {
                            vm.filterTemplates()
                        }
                    }

                if !vm.searchQuery.isEmpty {
                    Button(action: {
                        vm.searchQuery = ""
                        vm.filterTemplates()
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(Theme.small)
                            .foregroundColor(Theme.comment)
                    }
                    .buttonStyle(.plain)
                }

                Button(action: {
                    vm.isSemanticSearch.toggle()
                    if vm.isSemanticSearch && !vm.searchQuery.isEmpty {
                        vm.performAiSearch()
                    } else {
                        vm.filterTemplates()
                    }
                }) {
                    HStack(spacing: 3) {
                        Image(systemName: vm.isSemanticSearch ? "sparkles" : "text.magnifyingglass")
                        Text(vm.isSemanticSearch ? "AI Search" : "Text Match")
                    }
                    .font(Theme.smallMedium)
                    .foregroundColor(vm.isSemanticSearch ? Theme.purple : Theme.comment)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(vm.isSemanticSearch ? Theme.purple.opacity(0.18) : Theme.bgDark)
                    .cornerRadius(4)
                }
                .buttonStyle(.plain)
                .help(vm.isSemanticSearch ? "Switch to exact multi-term keyword search" : "Switch to Qwen3 semantic vector search")

                Button(action: {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        showFilters.toggle()
                    }
                }) {
                    Image(systemName: showFilters ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                        .font(Theme.small)
                        .foregroundColor(showFilters ? Theme.blue : Theme.comment)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Theme.bgDark)
            .cornerRadius(6)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))

            // Keyword Tags Filter Bar
            keywordBar

            // Dropdown filters
            if showFilters {
                filterRow
            }

            // Presets Table
            tableHeader

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(vm.filteredTemplates) { pt in
                            presetRow(pt)
                                .id(pt.id)
                        }
                    }
                }
                .frame(minHeight: 120, maxHeight: .infinity)
                .layoutPriority(1)
                .background(Theme.bgDark)
                .cornerRadius(6)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
            }

            // Prompt / Caption Editor
            HStack(spacing: 6) {
                Text(vm.selectedModelFamily == .yue2 ? "STYLE TAGLINE (YuE2)" : "MUSIC PROMPT (MiniMax)")
                    .font(Theme.smallBold)
                    .foregroundColor(Theme.comment)
                Spacer()

                if vm.selectedModelFamily == .yue2 {
                    Button("Convert from Caption") {
                        if let pt = vm.selectedTemplate {
                            vm.caption = vm.buildYuE2Tagline(from: pt)
                        } else {
                            vm.caption = vm.renderStyleTagline(from: vm.caption)
                        }
                    }
                    .buttonStyle(.plain)
                    .font(Theme.small)
                    .foregroundColor(Theme.blue)
                }
                Button("Save as Preset") {
                    showNewTemplateModal = true
                }
                .buttonStyle(.plain)
                .font(Theme.small)
                .foregroundColor(Theme.cyan)
                .help("Save current prompt editor text as a new preset")

                Text("\(vm.caption.count) chars")
                    .font(Theme.small)
                    .foregroundColor(Theme.comment)

                Button("Clear") {
                    vm.caption = ""
                }
                .buttonStyle(.plain)
                .font(Theme.small)
                .foregroundColor(Theme.red)
            }

            ResizableEditor(
                text: $vm.caption,
                height: $vm.promptEditorHeight,
                minHeight: 120,
                maxHeight: 900,
                defaultHeight: 240
            )
        }
        .sheet(isPresented: $showNewTemplateModal) {
            NewTemplateSheet(vm: vm, isPresented: $showNewTemplateModal)
        }
        .alert(isPresented: $showDeleteConfirm) {
            Alert(
                title: Text("Delete Preset"),
                message: Text("Are you sure you want to permanently delete preset '\(templateToDelete?.title ?? "")'?"),
                primaryButton: .destructive(Text("Delete")) {
                    if let pt = templateToDelete {
                        vm.deleteTemplate(id: pt.id)
                    }
                },
                secondaryButton: .cancel()
            )
        }
    }

    private var tableHeader: some View {
        HStack(spacing: 6) {
            Button(action: { toggleSort("title") }) {
                HStack(spacing: 2) {
                    Text("TITLE")
                    if vm.sortColumn == "title" {
                        Image(systemName: vm.sortAscending ? "chevron.up" : "chevron.down")
                    }
                }
                .font(Theme.smallBold)
                .foregroundColor(vm.sortColumn == "title" ? Theme.cyan : Theme.comment)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: { toggleSort("genre") }) {
                HStack(spacing: 2) {
                    Text("GENRE")
                    if vm.sortColumn == "genre" {
                        Image(systemName: vm.sortAscending ? "chevron.up" : "chevron.down")
                    }
                }
                .font(Theme.smallBold)
                .foregroundColor(vm.sortColumn == "genre" ? Theme.purple : Theme.comment)
            }
            .buttonStyle(.plain)
            .frame(width: 110, alignment: .leading)

            Button(action: { toggleSort("bpm") }) {
                HStack(spacing: 2) {
                    Text("BPM")
                    if vm.sortColumn == "bpm" {
                        Image(systemName: vm.sortAscending ? "chevron.up" : "chevron.down")
                    }
                }
                .font(Theme.smallBold)
                .foregroundColor(vm.sortColumn == "bpm" ? Theme.yellow : Theme.comment)
            }
            .buttonStyle(.plain)
            .frame(width: 44, alignment: .trailing)

            Text("KEY")
                .font(Theme.smallBold)
                .foregroundColor(Theme.comment)
                .frame(width: 60, alignment: .leading)

            Text("VOCAL")
                .font(Theme.smallBold)
                .foregroundColor(Theme.comment)
                .frame(width: 70, alignment: .leading)

            Text("")
                .frame(width: 22)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Theme.bgFloat)
        .cornerRadius(4)
    }

    private func presetRow(_ pt: PromptTemplate) -> some View {
        let isSelected = vm.selectedTemplate?.id == pt.id
        return Button(action: {
            vm.selectTemplate(pt)
        }) {
            HStack(spacing: 6) {
                Text(pt.title)
                    .font(Theme.body)
                    .foregroundColor(isSelected ? Theme.blue : Theme.fg)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if pt.is_user {
                    Text("USER")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(Theme.yellow)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Theme.yellow.opacity(0.15))
                        .cornerRadius(3)
                }

                Text(pt.genre.isEmpty ? pt.subgenre : pt.genre)
                    .font(Theme.small)
                    .foregroundColor(Theme.comment)
                    .lineLimit(1)
                    .frame(width: 110, alignment: .leading)

                Text(pt.bpm.map { "\($0)" } ?? "—")
                    .font(Theme.mono)
                    .foregroundColor(Theme.comment)
                    .frame(width: 44, alignment: .trailing)

                Text(pt.key != nil ? "\(pt.key!) \(pt.scale ?? "")" : "—")
                    .font(Theme.mono)
                    .foregroundColor(Theme.comment)
                    .lineLimit(1)
                    .frame(width: 60, alignment: .leading)

                Text(pt.vocal.isEmpty ? "—" : pt.vocal)
                    .font(Theme.small)
                    .foregroundColor(Theme.comment)
                    .lineLimit(1)
                    .frame(width: 70, alignment: .leading)

                Button(action: {
                    templateToDelete = pt
                    showDeleteConfirm = true
                }) {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundColor(isSelected ? Theme.red : Theme.comment.opacity(0.6))
                }
                .buttonStyle(.plain)
                .help("Delete preset '\(pt.title)'")
                .frame(width: 22, alignment: .center)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(isSelected ? Theme.blue.opacity(0.15) : (Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive, action: {
                templateToDelete = pt
                showDeleteConfirm = true
            }) {
                Label("Delete Preset", systemImage: "trash")
            }
        }
    }

    private var keywordBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !vm.activeKeywords.isEmpty {
                HStack(spacing: 6) {
                    FlowLayout(spacing: 4) {
                        ForEach(vm.activeKeywords, id: \.self) { term in
                            Button(action: { vm.removeKeyword(term) }) {
                                HStack(spacing: 4) {
                                    Text(term).font(Theme.small)
                                    Image(systemName: "xmark").font(.system(size: 8))
                                }
                                .foregroundColor(Theme.bgDark)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Theme.blue)
                                .cornerRadius(10)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    Button("Clear Tags") {
                        vm.activeKeywords.removeAll()
                        vm.filterTemplates()
                    }
                    .buttonStyle(.plain)
                    .font(Theme.small)
                    .foregroundColor(Theme.red)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Theme.bgDark)
                    .cornerRadius(4)
                }
            }
        }
    }

    private var filterRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    Text("Key:").font(Theme.small).foregroundColor(Theme.fgDark)
                    Picker("", selection: $vm.selectedKey) {
                        ForEach(keyOptions, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 60)
                }

                HStack(spacing: 4) {
                    Text("Scale:").font(Theme.small).foregroundColor(Theme.fgDark)
                    Picker("", selection: $vm.selectedScale) {
                        ForEach(scaleOptions, id: \.self) { Text($0.capitalized).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 75)
                }

                HStack(spacing: 4) {
                    Text("Vocal:").font(Theme.small).foregroundColor(Theme.fgDark)
                    Picker("", selection: $vm.selectedVocal) {
                        ForEach(vocalOptions, id: \.self) { Text($0.capitalized).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 90)
                }

                Spacer()

                Button("Reset All") {
                    vm.searchQuery = ""
                    vm.activeKeywords.removeAll()
                    vm.selectedKey = "All"
                    vm.selectedScale = "All"
                    vm.selectedVocal = "All"
                    vm.selectedTimeSignature = "All"
                    vm.selectedVocalRegister = "All"
                    vm.selectedLanguage = "All"
                    vm.filterTemplates()
                }
                .buttonStyle(.plain)
                .font(Theme.small)
                .foregroundColor(Theme.blue)
            }

            // Second filter row for Musical Metadata (FR-004)
            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    Text("Meter:").font(Theme.small).foregroundColor(Theme.fgDark)
                    Picker("", selection: $vm.selectedTimeSignature) {
                        ForEach(["All", "4/4", "3/4", "12/8", "6/8"], id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 65)
                }

                HStack(spacing: 4) {
                    Text("Register:").font(Theme.small).foregroundColor(Theme.fgDark)
                    Picker("", selection: $vm.selectedVocalRegister) {
                        ForEach(["All", "tenor", "baritone", "soprano", "mezzo-soprano", "alto", "bass", "choir", "none"], id: \.self) { Text($0.capitalized).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 100)
                }

                HStack(spacing: 4) {
                    Text("Lang:").font(Theme.small).foregroundColor(Theme.fgDark)
                    Picker("", selection: $vm.selectedLanguage) {
                        ForEach(["All", "english", "mandarin", "cantonese", "instrumental"], id: \.self) { Text($0.capitalized).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 85)
                }

                Spacer()
            }
        }
        .padding(8)
        .background(Theme.bgDark)
        .cornerRadius(6)
        .onChange(of: vm.selectedKey) { _, _ in vm.filterTemplates() }
        .onChange(of: vm.selectedScale) { _, _ in vm.filterTemplates() }
        .onChange(of: vm.selectedVocal) { _, _ in vm.filterTemplates() }
        .onChange(of: vm.selectedTimeSignature) { _, _ in vm.filterTemplates() }
        .onChange(of: vm.selectedVocalRegister) { _, _ in vm.filterTemplates() }
        .onChange(of: vm.selectedLanguage) { _, _ in vm.filterTemplates() }
    }

    private func toggleSort(_ col: String) {
        if vm.sortColumn == col {
            vm.sortAscending.toggle()
        } else {
            vm.sortColumn = col
            vm.sortAscending = true
        }
        vm.sortTemplates()
    }
}
