import SwiftUI

public struct SongwriterPopoverView: View {
    @ObservedObject var vm: StudioViewModel
    @State private var query = ""
    @State private var sortColumn: SortColumn = .timestamp
    @State private var sortAscending = false
    @State private var hoveredRowId: String?

    private enum SortColumn {
        case timestamp, title, genre, bpm, key, meter, type, duration, abc
    }

    /// Every song the API returned, one row each (the current take of each song). Takes of
    /// one song share a server-assigned `take_group`; standalone songs are a group of one.
    /// Rows are labelled "<title> (Take N of M)" when M > 1.
    private var takes: [SongwriterSongSummary] {
        let filtered = query.isEmpty ? vm.songwriterSongs : vm.songwriterSongs.filter {
            $0.title.localizedCaseInsensitiveContains(query) ||
                $0.summary.localizedCaseInsensitiveContains(query) ||
                $0.genre.localizedCaseInsensitiveContains(query) ||
                $0.subgenre.localizedCaseInsensitiveContains(query) ||
                ($0.key ?? "").localizedCaseInsensitiveContains(query) ||
                String($0.bpm ?? 0).contains(query) ||
                "take \($0.revision)".localizedCaseInsensitiveContains(query)
        }
        return filtered.sorted { lhs, rhs in
            let comparison: ComparisonResult
            switch sortColumn {
            case .timestamp:
                comparison = timestampValue(lhs).compare(timestampValue(rhs))
            case .title:
                let byTitle = lhs.title.localizedStandardCompare(rhs.title)
                comparison = byTitle == .orderedSame
                    ? (lhs.revision == rhs.revision ? .orderedSame : (lhs.revision < rhs.revision ? .orderedAscending : .orderedDescending))
                    : byTitle
            case .genre:
                comparison = lhs.genre.localizedStandardCompare(rhs.genre)
            case .bpm:
                let left = lhs.bpm ?? 0, right = rhs.bpm ?? 0
                comparison = left == right ? .orderedSame : (left < right ? .orderedAscending : .orderedDescending)
            case .key:
                comparison = (lhs.key ?? "").localizedStandardCompare(rhs.key ?? "")
            case .meter:
                comparison = (lhs.time_signature ?? "").localizedStandardCompare(rhs.time_signature ?? "")
            case .type:
                comparison = typeLabel(lhs).localizedStandardCompare(typeLabel(rhs))
            case .duration:
                let left = lhs.duration_hint_sec ?? 0, right = rhs.duration_hint_sec ?? 0
                comparison = left == right ? .orderedSame : (left < right ? .orderedAscending : .orderedDescending)
            case .abc:
                let left = lhs.has_abc == true ? 1 : 0, right = rhs.has_abc == true ? 1 : 0
                comparison = left == right ? .orderedSame : (left < right ? .orderedAscending : .orderedDescending)
            }
            if comparison == .orderedSame {
                return lhs.uniqueId < rhs.uniqueId
            }
            return sortAscending ? comparison == .orderedAscending : comparison == .orderedDescending
        }
    }

    /// All takes that share a song's `take_group`, newest-first.
    private func groupTakes(_ s: SongwriterSongSummary) -> [SongwriterSongSummary] {
        vm.songwriterSongs
            .filter { $0.takeGroup == s.takeGroup }
            .sorted { $0.takeNumber > $1.takeNumber }
    }

    /// Queue every listed song in one action (each row, whatever its group).
    private func queueAllListed() {
        let items = takes.map { (id: $0.id, revision: $0.revision, title: $0.title) }
        vm.queueSongs(items, label: "all \(items.count) listed")
    }

    /// Queue every take of the given row's song (its whole take_group).
    private func queueAllTakes(of s: SongwriterSongSummary) {
        let group = groupTakes(s)
        let items = (group.isEmpty ? [s] : group).map { (id: $0.id, revision: $0.revision, title: $0.title) }
        vm.queueSongs(items, label: "\(items.count) takes of \(s.title)")
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            searchField
            content
            footer
        }
        .padding(16)
        .frame(width: 1060, height: 600, alignment: .topLeading)
        .background(Theme.bgFloat)
        .onAppear {
            if vm.isSongwriterEnabled {
                vm.loadSongwriterSongs(allRevisions: true)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "wand.and.stars").foregroundColor(Theme.purple)
            VStack(alignment: .leading, spacing: 1) {
                Text("SONGWRITER").font(Theme.smallBold).foregroundColor(Theme.fg)
                Text(SongwriterAPI.configuredBaseURL)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(Theme.comment)
                    .lineLimit(1)
            }

            Spacer()

            if !takes.isEmpty {
                Button(action: { queueAllListed() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "text.badge.plus").font(.system(size: 11))
                        Text("Queue all \(takes.count)").font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundColor(Theme.green)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(Theme.green.opacity(0.16)).cornerRadius(5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Queue every song currently listed (\(takes.count))")
            }

            Button(action: { vm.loadSongwriterSongs(allRevisions: true) }) {
                if vm.isLoadingSongwriter {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 28, height: 28)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
            }
            .buttonStyle(.plain)
            .disabled(vm.isLoadingSongwriter)
            .help("Refresh ready songs")

            Button(action: {
                vm.showSongwriterPopover = false
                vm.settingsTab = .api
                vm.showSettingsSheet = true
            }) {
                Image(systemName: "gearshape.fill").frame(width: 28, height: 28).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundColor(Theme.comment)
            .help("Songwriter connection settings")

            Button(action: { vm.showSongwriterPopover = false }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundColor(Theme.comment)
            .keyboardShortcut(.cancelAction)
            .help("Close Songwriter")
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(Theme.comment)
                .font(Theme.small)
            TextField("Search title, brief, genre, key, BPM, or take...", text: $query)
                .textFieldStyle(.plain)
                .font(Theme.body)
            if !query.isEmpty {
                Button(action: { query = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(Theme.comment)
                        .font(Theme.small)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Theme.bgDark)
        .cornerRadius(6)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
        .disabled(vm.isLoadingSongwriter && vm.songwriterSongs.isEmpty)
    }

    @ViewBuilder
    private var content: some View {
        if !vm.isSongwriterEnabled {
            stateView(icon: "network.slash", title: "Songwriter Integration Disabled",
                      message: "Songwriter is disabled in Settings. Enable and configure the API endpoint to import ready songs.",
                      color: Theme.comment, primaryTitle: "Open Settings",
                      primaryAction: {
                          vm.showSongwriterPopover = false
                          vm.settingsTab = .api
                          vm.showSettingsSheet = true
                      })
        } else if vm.isLoadingSongwriter && vm.songwriterSongs.isEmpty {
            stateView(icon: "arrow.triangle.2.circlepath", title: "Connecting to Songwriter",
                      message: "Loading ready songs from \(SongwriterAPI.configuredBaseURL)…",
                      color: Theme.purple, showsProgress: true)
        } else if let error = vm.songwriterError, vm.songwriterSongs.isEmpty {
            stateView(icon: "exclamationmark.triangle.fill", title: "Songwriter unavailable",
                      message: error, color: Theme.red, primaryTitle: "Retry",
                      primaryAction: { vm.loadSongwriterSongs(allRevisions: true) }, secondaryTitle: "Settings",
                      secondaryAction: { vm.showSongwriterPopover = false; vm.settingsTab = .api; vm.showSettingsSheet = true })
        } else if takes.isEmpty {
            stateView(icon: query.isEmpty ? "music.note.list" : "magnifyingglass",
                      title: query.isEmpty ? "No ready songs" : "No matching takes",
                      message: query.isEmpty ? "Create or mark a song ready in Songwriter, then refresh." : "Try a different title, summary, genre, key, or take.",
                      color: Theme.comment, primaryTitle: query.isEmpty ? "Refresh" : nil,
                      primaryAction: query.isEmpty ? { vm.loadSongwriterSongs(allRevisions: true) } : nil)
        } else {
            VStack(spacing: 0) {
                tableHeader
                Divider().background(Theme.border)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(takes, id: \.uniqueId) { take in
                            takeRow(take)
                            Divider().background(Theme.border.opacity(0.45))
                        }
                    }
                }
            }
            .background(Theme.bgDark.opacity(0.45))
            .cornerRadius(7)
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.border, lineWidth: 1))
        }
    }

    // Column widths shared by the header and rows so everything lines up.
    private enum Col {
        static let crafted: CGFloat = 120
        static let title: CGFloat = 230
        static let genre: CGFloat = 110
        static let bpm: CGFloat = 44
        static let key: CGFloat = 56
        static let meter: CGFloat = 46
        static let type: CGFloat = 56
        static let length: CGFloat = 50
        static let abc: CGFloat = 40
        static let queue: CGFloat = 240
    }

    private var tableHeader: some View {
        HStack(spacing: 0) {
            sortHeader("Crafted", column: .timestamp, width: Col.crafted, alignment: .leading)
            sortHeader("Song & Take", column: .title, width: Col.title, alignment: .leading)
            sortHeader("Genre", column: .genre, width: Col.genre, alignment: .leading)
            sortHeader("BPM", column: .bpm, width: Col.bpm, alignment: .center)
            sortHeader("Key", column: .key, width: Col.key, alignment: .center)
            sortHeader("Meter", column: .meter, width: Col.meter, alignment: .center)
            sortHeader("Type", column: .type, width: Col.type, alignment: .center)
            sortHeader("Length", column: .duration, width: Col.length, alignment: .center)
            sortHeader("ABC", column: .abc, width: Col.abc, alignment: .center)
            Text("")
                .frame(width: Col.queue, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(Theme.bgDark)
    }

    private func sortHeader(_ title: String, column: SortColumn, width: CGFloat, alignment: Alignment) -> some View {
        Button(action: { toggleSort(column) }) {
            HStack(spacing: 3) {
                Text(title)
                if sortColumn == column {
                    Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                }
            }
            .font(Theme.smallBold)
            .foregroundColor(sortColumn == column ? Theme.purple : Theme.comment)
            .frame(width: width, alignment: alignment)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Take row (one per take)

    private func takeRow(_ take: SongwriterSongSummary) -> some View {
        let rowId = take.uniqueId
        return HStack(spacing: 0) {
            // Crafted (local time)
            VStack(alignment: .leading, spacing: 2) {
                Text(timestampText(take))
                    .font(Theme.mono)
                    .foregroundColor(Theme.fg)
                    .lineLimit(1)
                Text(take.created_at == nil ? "Updated" : "Created")
                    .font(.system(size: 9))
                    .foregroundColor(take.created_at == nil ? Theme.yellow : Theme.comment)
            }
            .frame(width: Col.crafted, alignment: .leading)

            // "<title> (Take N of M)" when the song has multiple takes; just the title
            // otherwise. Take number/count come from the server's take_group.
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(take.takeCount > 1 ? "\(take.title) (Take \(take.takeNumber) of \(take.takeCount))" : take.title)
                        .font(Theme.smallMedium)
                        .foregroundColor(Theme.fg)
                        .lineLimit(1)
                    if take.takeCount > 1 && take.takeNumber == take.takeCount {
                        Text("latest")
                            .font(.system(size: 9, weight: .semibold)).foregroundColor(Theme.green)
                    }
                }
                Text(take.summary)
                    .font(.system(size: 9))
                    .foregroundColor(Theme.comment)
                    .lineLimit(1)
            }
            .frame(width: Col.title, alignment: .leading)

            // Genre / subgenre
            VStack(alignment: .leading, spacing: 1) {
                Text(take.genre.isEmpty ? "—" : take.genre)
                    .font(Theme.small)
                    .foregroundColor(Theme.fgDark)
                    .lineLimit(1)
                if !take.subgenre.isEmpty {
                    Text(take.subgenre)
                        .font(.system(size: 9))
                        .foregroundColor(Theme.comment)
                        .lineLimit(1)
                }
            }
            .frame(width: Col.genre, alignment: .leading)

            Text(take.bpm.map(String.init) ?? "—")
                .font(Theme.mono).foregroundColor(Theme.fg)
                .frame(width: Col.bpm, alignment: .center)

            // Key + scale
            VStack(spacing: 1) {
                Text(take.key ?? "—")
                    .font(Theme.small).foregroundColor(Theme.fgDark).lineLimit(1)
                if let scale = take.scale, !scale.isEmpty {
                    Text(scale)
                        .font(.system(size: 9)).foregroundColor(Theme.comment).lineLimit(1)
                }
            }
            .frame(width: Col.key, alignment: .center)

            Text(take.time_signature ?? "4/4")
                .font(Theme.mono).foregroundColor(Theme.comment)
                .frame(width: Col.meter, alignment: .center)

            Text(typeLabel(take))
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(take.instrumental ? Theme.cyan : Theme.purple)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background((take.instrumental ? Theme.cyan : Theme.purple).opacity(0.16))
                .cornerRadius(4)
                .frame(width: Col.type, alignment: .center)

            Text(durationText(take))
                .font(Theme.mono).foregroundColor(Theme.comment)
                .frame(width: Col.length, alignment: .center)

            Group {
                if take.has_abc == true {
                    Text("ABC")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(Theme.yellow)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Theme.yellow.opacity(0.18))
                        .cornerRadius(3)
                } else {
                    Text("—").font(Theme.mono).foregroundColor(Theme.comment.opacity(0.4))
                }
            }
            .frame(width: Col.abc, alignment: .center)

            // Per-row actions. take_count comes from the song's take_group, so "Queue all
            // N takes" queues every take of this song in one click; "Queue take" queues
            // just this one; "Load" imports it into the editor.
            HStack(spacing: 6) {
                if take.takeCount > 1 {
                    Button(action: { queueAllTakes(of: take) }) {
                        HStack(spacing: 3) {
                            Image(systemName: "text.badge.plus").font(.system(size: 9))
                            Text("Queue all \(take.takeCount)").font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundColor(Theme.green)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Theme.green.opacity(0.18)).cornerRadius(4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Queue all \(take.takeCount) takes of \(take.title)")
                }

                Button(action: { vm.queueSongs([(id: take.id, revision: take.revision, title: take.title)], label: take.title) }) {
                    Text(take.takeCount > 1 ? "Queue take" : "Queue").font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Theme.green)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Theme.green.opacity(0.10)).cornerRadius(4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(take.takeCount > 1 ? "Queue only Take \(take.takeNumber) of \(take.title)" : "Queue \(take.title)")

                Button(action: { vm.importSongwriterSong(take, revision: take.revision) }) {
                    Text("Load").font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Theme.blue)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Theme.blue.opacity(0.12)).cornerRadius(4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Import \(take.title) into the editor")
            }
            .frame(width: Col.queue, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .frame(height: 48)
        .background(rowBackground(take))
        .contentShape(Rectangle())
        .onHover { hovering in setHover(rowId, hovering) }
        .onTapGesture { vm.importSongwriterSong(take, revision: take.revision) }
    }

    private var footer: some View {
        HStack {
            Text("\(takes.count) take\(takes.count == 1 ? "" : "s")")
                .font(.system(size: 9)).foregroundColor(Theme.comment)

            if let connected = vm.songwriterLastConnectedAt {
                Label("Connected \(connected.formatted(date: .omitted, time: .shortened))", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 9)).foregroundColor(Theme.green)
            }

            Spacer()

            if let curTitle = vm.selectedSongwriterTitle, let curId = vm.selectedSongwriterId {
                HStack(spacing: 6) {
                    Text("Imported: \(curTitle) (\(curId))" + (vm.selectedSongwriterRevision.map { " Take \($0)" } ?? ""))
                        .font(Theme.small)
                        .foregroundColor(Theme.purple)
                    Button("Clear") { vm.clearSongwriterSelection() }
                        .buttonStyle(.plain)
                        .font(Theme.small)
                        .foregroundColor(Theme.comment)
                }
            }
        }
    }

    // MARK: - Helpers

    private func setHover(_ id: String, _ hovering: Bool) {
        if hovering {
            hoveredRowId = id
        } else if hoveredRowId == id {
            hoveredRowId = nil
        }
    }

    // A take is selected when both its song id and revision match the imported selection.
    private func rowBackground(_ take: SongwriterSongSummary) -> Color {
        if vm.selectedSongwriterId == take.id && vm.selectedSongwriterRevision == take.revision {
            return Theme.bgHighlight.opacity(0.35)
        }
        if hoveredRowId == take.uniqueId { return Theme.bgHighlight.opacity(0.18) }
        return Color.clear
    }

    private func toggleSort(_ column: SortColumn) {
        if sortColumn == column { sortAscending.toggle() }
        else {
            sortColumn = column
            sortAscending = column != .timestamp
        }
    }

    private func typeLabel(_ song: SongwriterSongSummary) -> String {
        song.instrumental ? "Inst" : "Vocal"
    }

    private func durationText(_ song: SongwriterSongSummary) -> String {
        guard let sec = song.duration_hint_sec, sec > 0 else { return "—" }
        let m = Int(sec) / 60
        let s = Int(sec) % 60
        return String(format: "%d:%02d", m, s)
    }

    private func timestampValue(_ song: SongwriterSongSummary) -> Date {
        parseDate(song.created_at ?? song.updated_at) ?? .distantPast
    }

    // Always render in the device's current local time zone.
    private func timestampText(_ song: SongwriterSongSummary) -> String {
        let date = timestampValue(song)
        guard date != .distantPast else { return "—" }
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "MMM d, HH:mm"
        return formatter.string(from: date)
    }

    // Parse server timestamps. ISO-8601 (with or without fractional seconds and zone)
    // is treated as absolute time; bare values are interpreted as UTC. Either way the
    // Date is absolute, and the formatter above renders it in the local zone.
    private func parseDate(_ value: String) -> Date? {
        let isoFractional = ISO8601DateFormatter()
        isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = isoFractional.date(from: value) { return d }

        let isoStandard = ISO8601DateFormatter()
        isoStandard.formatOptions = [.withInternetDateTime]
        if let d = isoStandard.date(from: value) { return d }

        for format in [
            "yyyy-MM-dd'T'HH:mm:ss.SSSSSSZ",
            "yyyy-MM-dd'T'HH:mm:ss.SSSZ",
            "yyyy-MM-dd'T'HH:mm:ssZ",
            "yyyy-MM-dd'T'HH:mm:ss.SSSSSS",
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy-MM-dd HH:mm:ss"
        ] {
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.calendar = Calendar(identifier: .gregorian)
            df.timeZone = TimeZone(secondsFromGMT: 0)
            df.dateFormat = format
            if let d = df.date(from: value) { return d }
        }
        return nil
    }

    @ViewBuilder
    private func stateView(icon: String, title: String, message: String, color: Color,
                           showsProgress: Bool = false, primaryTitle: String? = nil,
                           primaryAction: (() -> Void)? = nil, secondaryTitle: String? = nil,
                           secondaryAction: (() -> Void)? = nil) -> some View {
        VStack(spacing: 12) {
            if showsProgress { ProgressView().controlSize(.regular).tint(color) }
            else { Image(systemName: icon).font(.system(size: 28)).foregroundColor(color) }
            Text(title).font(Theme.bodyBold).foregroundColor(Theme.fg)
            Text(message).font(Theme.small).foregroundColor(Theme.comment).multilineTextAlignment(.center).frame(maxWidth: 420)
            HStack(spacing: 10) {
                if let secondaryTitle, let secondaryAction { Button(secondaryTitle, action: secondaryAction).buttonStyle(.bordered) }
                if let primaryTitle, let primaryAction { Button(primaryTitle, action: primaryAction).buttonStyle(.borderedProminent).tint(color) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
        .background(Theme.bgDark.opacity(0.45))
        .cornerRadius(8)
    }
}
