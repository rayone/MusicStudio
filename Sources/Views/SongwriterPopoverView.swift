import SwiftUI

public struct SongwriterPopoverView: View {
    @ObservedObject var vm: StudioViewModel
    @State private var query = ""
    @State private var sortColumn: SortColumn = .timestamp
    @State private var sortAscending = false

    private enum SortColumn {
        case timestamp, title, genre, bpm, type
    }

    private var songs: [SongwriterSongSummary] {
        let filtered = query.isEmpty ? vm.songwriterSongs : vm.songwriterSongs.filter {
            $0.title.localizedCaseInsensitiveContains(query) ||
            $0.summary.localizedCaseInsensitiveContains(query) ||
            $0.genre.localizedCaseInsensitiveContains(query)
        }
        return filtered.sorted { lhs, rhs in
            let comparison: ComparisonResult
            switch sortColumn {
            case .timestamp:
                comparison = timestampValue(lhs).compare(timestampValue(rhs))
            case .title:
                comparison = lhs.title.localizedStandardCompare(rhs.title)
            case .genre:
                comparison = lhs.genre.localizedStandardCompare(rhs.genre)
            case .bpm:
                let left = lhs.bpm ?? 0
                let right = rhs.bpm ?? 0
                comparison = left == right ? .orderedSame : (left < right ? .orderedAscending : .orderedDescending)
            case .type:
                comparison = typeLabel(lhs).localizedStandardCompare(typeLabel(rhs))
            }
            if comparison == .orderedSame {
                return lhs.id < rhs.id
            }
            return sortAscending ? comparison == .orderedAscending : comparison == .orderedDescending
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            searchField
            content
            footer
        }
        .padding(16)
        .frame(width: 760, height: 580, alignment: .topLeading)
        .background(Theme.bgFloat)
        .onAppear { if vm.isSongwriterEnabled && vm.songwriterSongs.isEmpty { vm.loadSongwriterSongs() } }
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
            Button(action: { vm.loadSongwriterSongs() }) {
                Image(systemName: "arrow.clockwise").frame(width: 28, height: 28).contentShape(Rectangle())
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
        }
    }

    private var searchField: some View {
        TextField("Search title, summary, or genre", text: $query)
            .textFieldStyle(.plain)
            .padding(8)
            .background(Theme.bgDark)
            .cornerRadius(6)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
            .disabled(vm.isLoadingSongwriter || vm.songwriterError != nil)
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
        } else if vm.isLoadingSongwriter {
            stateView(icon: "arrow.triangle.2.circlepath", title: "Connecting to Songwriter",
                      message: "Loading ready songs from \(SongwriterAPI.configuredBaseURL)…",
                      color: Theme.purple, showsProgress: true)
        } else if let error = vm.songwriterError {
            stateView(icon: "exclamationmark.triangle.fill", title: "Songwriter unavailable",
                      message: error, color: Theme.red, primaryTitle: "Retry",
                      primaryAction: { vm.loadSongwriterSongs() }, secondaryTitle: "Settings",
                      secondaryAction: { vm.showSongwriterPopover = false; vm.settingsTab = .api; vm.showSettingsSheet = true })
        } else if songs.isEmpty {
            stateView(icon: query.isEmpty ? "music.note.list" : "magnifyingglass",
                      title: query.isEmpty ? "No ready songs" : "No matching songs",
                      message: query.isEmpty ? "Create or mark a song ready in Songwriter, then refresh." : "Try a different title, summary, or genre.",
                      color: Theme.comment, primaryTitle: query.isEmpty ? "Refresh" : nil,
                      primaryAction: query.isEmpty ? { vm.loadSongwriterSongs() } : nil)
        } else {
            VStack(spacing: 0) {
                tableHeader
                Divider().background(Theme.border)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(songs) { song in
                            songRow(song)
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

    private var tableHeader: some View {
        HStack(spacing: 0) {
            sortHeader("Crafted", column: .timestamp, width: 145, alignment: .leading)
            sortHeader("Title", column: .title, width: 245, alignment: .leading)
            sortHeader("Genre", column: .genre, width: 110, alignment: .leading)
            sortHeader("BPM", column: .bpm, width: 55, alignment: .trailing)
            sortHeader("Type", column: .type, width: 90, alignment: .leading)
            Text("Rev")
                .font(Theme.smallBold).foregroundColor(Theme.comment)
                .frame(width: 45, alignment: .trailing)
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

    private func songRow(_ song: SongwriterSongSummary) -> some View {
        Button(action: { vm.importSongwriterSong(song) }) {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(timestampText(song)).font(Theme.mono).foregroundColor(Theme.fg)
                    Text(song.created_at == nil ? "Updated" : "Created")
                        .font(.system(size: 9)).foregroundColor(song.created_at == nil ? Theme.yellow : Theme.comment)
                }
                .frame(width: 145, alignment: .leading)

                VStack(alignment: .leading, spacing: 2) {
                    Text(song.title).font(Theme.smallMedium).foregroundColor(Theme.fg).lineLimit(1)
                    Text(song.summary).font(.system(size: 9)).foregroundColor(Theme.comment).lineLimit(1)
                }
                .frame(width: 245, alignment: .leading)

                Text(song.genre.isEmpty ? "—" : song.genre)
                    .font(Theme.small).foregroundColor(Theme.fgDark).lineLimit(1)
                    .frame(width: 110, alignment: .leading)
                Text(song.bpm.map(String.init) ?? "—")
                    .font(Theme.mono).foregroundColor(Theme.fgDark)
                    .frame(width: 55, alignment: .trailing)
                Text(typeLabel(song))
                    .font(Theme.small).foregroundColor(song.instrumental ? Theme.cyan : Theme.purple)
                    .frame(width: 90, alignment: .leading)
                Text("r\(song.revision)")
                    .font(Theme.mono).foregroundColor(Theme.comment)
                    .frame(width: 45, alignment: .trailing)
            }
            .padding(.horizontal, 10)
            .frame(height: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        HStack {
            Text("\(songs.count) song\(songs.count == 1 ? "" : "s")")
                .font(.system(size: 9)).foregroundColor(Theme.comment)
            if let connected = vm.songwriterLastConnectedAt {
                Label("Connected \(connected.formatted(date: .omitted, time: .shortened))", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 9)).foregroundColor(Theme.green)
            }
            Spacer()
            if vm.selectedSongwriterId != nil {
                Button("Clear imported song") { vm.clearSongwriterSelection() }
                    .buttonStyle(.plain).font(Theme.small).foregroundColor(Theme.comment)
            }
        }
    }

    private func toggleSort(_ column: SortColumn) {
        if sortColumn == column { sortAscending.toggle() }
        else {
            sortColumn = column
            sortAscending = column != .timestamp
        }
    }

    private func typeLabel(_ song: SongwriterSongSummary) -> String {
        song.instrumental ? "Instrumental" : "Vocal"
    }

    private func timestampValue(_ song: SongwriterSongSummary) -> Date {
        parseDate(song.created_at ?? song.updated_at) ?? .distantPast
    }

    private func timestampText(_ song: SongwriterSongSummary) -> String {
        let date = timestampValue(song)
        guard date != .distantPast else { return "Unknown" }
        return date.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
    }

    private func parseDate(_ value: String) -> Date? {
        let utcDate = ISO8601DateFormatter().date(from: value)
        guard let utcDate, utcDate > Date().addingTimeInterval(300) else {
            return utcDate
        }

        // Songwriter currently emits local wall-clock values with a trailing `Z`.
        // Creation times cannot be in the future, so reinterpret only malformed future
        // values in the workstation timezone. Correct UTC values remain untouched.
        let localValue = value.hasSuffix("Z") ? String(value.dropLast()) : value
        for format in ["yyyy-MM-dd'T'HH:mm:ss.SSSSSS", "yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = .current
            formatter.dateFormat = format
            if let localDate = formatter.date(from: localValue) {
                return localDate
            }
        }
        return utcDate
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
