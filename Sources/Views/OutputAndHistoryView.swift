import SwiftUI
import AppKit

public struct AudioPlayerBarView: View {
    @ObservedObject var vm: StudioViewModel

    public init(vm: StudioViewModel) {
        self.vm = vm
    }

    /// Player-bar label. VST3 previews play from a temp file, so show the track and
    /// plugin name instead of the temp filename.
    private var playingLabel: String {
        guard let path = vm.currentPlayingFile else { return "No track loaded" }
        let name = URL(fileURLWithPath: path).lastPathComponent
        if name.hasPrefix("musicstudio_preview_"), let track = vm.selectedTrack {
            let trackName = URL(fileURLWithPath: track.output_file).lastPathComponent
            return "\(trackName) · \(vm.loadedPlugin?.name ?? "effect") preview"
        }
        return name
    }

    public var body: some View {
        HStack(spacing: 12) {
            Button(action: {
                vm.togglePlayPause()
            }) {
                Image(systemName: vm.isPlayingAudio ? "pause.fill" : "play.fill")
                    .font(Theme.body)
                    .foregroundColor(vm.currentPlayingFile == nil ? Theme.comment : Theme.green)
                    .frame(width: 30, height: 30)
                    .background(Theme.bgHighlight)
                    .cornerRadius(15)
            }
            .buttonStyle(.plain)
            .disabled(vm.currentPlayingFile == nil && vm.history.isEmpty)

            Text(playingLabel)
                .font(Theme.smallMedium)
                .foregroundColor(vm.currentPlayingFile == nil ? Theme.comment : Theme.fg)
                .lineLimit(1)
                .frame(maxWidth: 220, alignment: .leading)

            Text(formatTime(vm.audioProgress))
                .font(Theme.mono)
                .foregroundColor(Theme.comment)

            Slider(
                value: $vm.audioProgress,
                in: 0...max(vm.audioDuration, 1.0),
                onEditingChanged: { editing in
                    if editing {
                        vm.beginSeek()
                    } else {
                        vm.endSeek(to: vm.audioProgress)
                    }
                }
            )
            .tint(Theme.green)
            .disabled(vm.currentPlayingFile == nil)

            Text(formatTime(vm.audioDuration))
                .font(Theme.mono)
                .foregroundColor(Theme.comment)

            if let path = vm.currentPlayingFile {
                Button(action: {
                    NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
                }) {
                    Image(systemName: "folder")
                        .font(Theme.small)
                        .foregroundColor(Theme.blue)
                }
                .buttonStyle(.plain)
                .help("Reveal track in Finder")
            }

            // Output Folder Reveal
            Button(action: {
                let outDir = UserDefaults.standard.string(forKey: "outputDirectory") ?? SetupManager.defaultOutputDirectory.path
                NSWorkspace.shared.open(URL(fileURLWithPath: outDir))
            }) {
                Image(systemName: "tray.and.arrow.down")
                    .font(Theme.small)
                    .foregroundColor(Theme.comment)
            }
            .buttonStyle(.plain)
            .help("Open Output Folder")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.bgFloat)
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
    }

    private func formatTime(_ sec: Double) -> String {
        let m = Int(sec) / 60
        let s = Int(sec) % 60
        return String(format: "%d:%02d", m, s)
    }
}

public struct OutputAndHistoryView: View {
    @ObservedObject var vm: StudioViewModel
    @State private var itemToDelete: GenerationHistoryItem? = nil
    @State private var showDeleteConfirm: Bool = false
    @State private var selectedSongBench: SongBenchEvaluation? = nil

    public init(vm: StudioViewModel) {
        self.vm = vm
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "clock.arrow.circlepath")
                        .foregroundColor(Theme.purple)
                    Text("GENERATION HISTORY")
                        .font(Theme.smallBold)
                        .foregroundColor(Theme.comment)
                }

                Spacer()

                Text("\(vm.history.count) tracks")
                    .font(Theme.small)
                    .foregroundColor(Theme.comment)

                Button(action: {
                    let outDir = UserDefaults.standard.string(forKey: "outputDirectory") ?? SetupManager.defaultOutputDirectory.path
                    NSWorkspace.shared.open(URL(fileURLWithPath: outDir))
                }) {
                    Image(systemName: "folder")
                        .font(Theme.small)
                        .foregroundColor(Theme.blue)
                }
                .buttonStyle(.plain)
                .help("Open Output Folder in Finder")
            }

            // History tracks list
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(vm.history) { item in
                        historyRow(item)
                    }

                    if vm.history.isEmpty {
                        VStack(spacing: 6) {
                            Image(systemName: "music.note")
                                .font(.system(size: 24))
                                .foregroundColor(Theme.comment)
                            Text("Add a song to the queue to render your first track.")
                                .font(Theme.small)
                                .foregroundColor(Theme.comment)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                    }
                }
            }
            .frame(minHeight: 180, maxHeight: .infinity)


            // Audio Player Bar
            AudioPlayerBarView(vm: vm)
        }
        .padding(12)
        .background(Theme.bgFloat)
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
        .alert(isPresented: $showDeleteConfirm) {
            Alert(
                title: Text("Delete Track"),
                message: Text("Are you sure you want to permanently delete this rendered song?"),
                primaryButton: .destructive(Text("Delete")) {
                    if let it = itemToDelete {
                        vm.deleteGeneration(it)
                    }
                },
                secondaryButton: .cancel()
            )
        }
    }

    private func historyRow(_ item: GenerationHistoryItem) -> some View {
        let isCurrent = vm.currentPlayingFile == item.output_file
        let isSelected = vm.selectedTrack?.id == item.id
        let isYuE = item.model.lowercased().contains("yue2")
        let modelShort = item.model.components(separatedBy: ":").last ?? item.model
        return HStack(spacing: 8) {
            Button(action: {
                if isCurrent && vm.isPlayingAudio {
                    vm.togglePlayPause()
                } else {
                    vm.selectTrack(item)
                    vm.playAudio(path: item.output_file)
                }
            }) {
                Image(systemName: (isCurrent && vm.isPlayingAudio) ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 22))
                    .foregroundColor(isCurrent ? Theme.green : Theme.blue)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(URL(fileURLWithPath: item.output_file).lastPathComponent)
                        .font(Theme.smallMedium)
                        .foregroundColor(isCurrent ? Theme.green : Theme.fg)
                        .lineLimit(1)

                    Text(modelShort)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(isYuE ? Theme.purple : Theme.cyan)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background((isYuE ? Theme.purple : Theme.cyan).opacity(0.15))
                        .cornerRadius(3)

                    if let sidecar = item.sidecar_file, !sidecar.isEmpty {
                        Button(action: {
                            if let score = try? String(contentsOfFile: sidecar, encoding: .utf8) {
                                vm.abcScoreText = score
                            }
                        }) {
                            HStack(spacing: 2) {
                                Image(systemName: "music.quarternote.3")
                                Text("ABC")
                            }
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(Theme.yellow)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Theme.yellow.opacity(0.15))
                            .cornerRadius(3)
                        }
                        .buttonStyle(.plain)
                        .help("Load generated ABC score into editor")
                    }

                    evaluationPill(item)
                }

                HStack(spacing: 8) {
                    Text("\(Int(item.duration))s • \(item.steps)st")
                        .font(Theme.mono)
                        .foregroundColor(Theme.comment)
                    Text(String(format: "%.1f MB", item.size_mb))
                        .font(Theme.mono)
                        .foregroundColor(Theme.comment)

                    // Seed display and reuse (FR-010)
                    Button(action: {
                        vm.lockedSeedString = String(item.seed)
                        vm.isSeedLocked = true
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(String(item.seed), forType: .string)
                        vm.appendLog(component: .ui, level: .info, message: "Reused seed #\(item.seed) from generation", detail: "seed=\(item.seed)")
                    }) {
                        HStack(spacing: 3) {
                            Image(systemName: "number")
                                .font(.system(size: 8))
                            Text("\(item.seed)")
                                .font(Theme.mono)
                        }
                        .foregroundColor(Theme.blue)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Theme.bgHighlight)
                        .cornerRadius(3)
                    }
                    .buttonStyle(.plain)
                    .help("Click to copy and lock seed #\(item.seed)")

                    Text(item.timestamp)
                        .font(Theme.small)
                        .foregroundColor(Theme.comment)
                }
            }

            Spacer()

            Button(action: {
                vm.loadFromHistory(item)
            }) {
                Image(systemName: "arrow.uturn.left.circle")
                    .font(Theme.small)
                    .foregroundColor(Theme.blue)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Reload this song's settings (model, caption, lyrics, seed, params, ABC) into the Create tab")

            Button(action: {
                NSWorkspace.shared.selectFile(item.output_file, inFileViewerRootedAtPath: "")
            }) {
                Image(systemName: "folder")
                    .font(Theme.small)
                    .foregroundColor(Theme.comment)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Reveal file in Finder")

            Button(action: {
                itemToDelete = item
                showDeleteConfirm = true
            }) {
                Image(systemName: "trash")
                    .font(Theme.small)
                    .foregroundColor(Theme.comment)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Delete track")
        }
        .padding(6)
        .background(isSelected ? Theme.purple.opacity(0.14) : (isCurrent ? Theme.green.opacity(0.08) : Theme.bgDark))
        .cornerRadius(6)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(isSelected ? Theme.purple.opacity(0.5) : (isCurrent ? Theme.green.opacity(0.3) : Theme.border.opacity(0.4)), lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { vm.selectTrack(item) }
    }
    @ViewBuilder
    private func evaluationPill(_ item: GenerationHistoryItem) -> some View {
        let evaluation = item.songbench
        let isBusy = vm.isEvaluationRunning
        let retryHelp = isBusy ? "Another evaluation is already running" : "Run SongBench evaluation"

        Button(action: {
            if evaluation?.status == "completed" {
                selectedSongBench = evaluation
            } else if !isBusy {
                vm.evaluateGeneration(item)
            }
        }) {
            HStack(spacing: 3) {
                if evaluation?.status == "installing" || evaluation?.status == "evaluating" {
                    ProgressView()
                        .controlSize(.mini)
                        .frame(width: 10, height: 10)
                } else {
                    Image(systemName: evaluationIcon(evaluation))
                        .font(.system(size: 8, weight: .bold))
                }
                Text(evaluationLabel(evaluation, generationId: Int(item.id)))
                    .font(.system(size: 9, weight: .bold))
            }
            .foregroundColor(evaluationColor(evaluation))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(evaluationColor(evaluation).opacity(0.15))
            .cornerRadius(3)
        }
        .buttonStyle(.plain)
        .disabled(isBusy && evaluation?.status != "completed")
        .help(evaluation?.status == "completed" ? "Click to view all seven SongBench scores" : (isBusy ? retryHelp : (evaluation?.status == "failed" ? (evaluation?.error ?? retryHelp) : retryHelp)))
        .popover(isPresented: Binding(
            get: { selectedSongBench?.generationId == evaluation?.generationId && evaluation?.status == "completed" },
            set: { if !$0 { selectedSongBench = nil } }
        ), arrowEdge: .bottom) {
            if let score = selectedSongBench {
                SongBenchPopoverView(evaluation: score)
            }
        }
    }

    private func evaluationIcon(_ evaluation: SongBenchEvaluation?) -> String {
        switch evaluation?.status {
        case "failed": return "exclamationmark.triangle.fill"
        case "completed": return "star.fill"
        default: return "chart.bar.xaxis"
        }
    }

    private func evaluationLabel(_ evaluation: SongBenchEvaluation?, generationId: Int?) -> String {
        switch evaluation?.status {
        case "installing":
            if vm.evaluatingGenerationId == generationId, !vm.evalInstallStage.isEmpty {
                return "\(vm.evalInstallStage) \(Int(vm.evalInstallFraction * 100))%"
            }
            return "Installing"
        case "evaluating": return "Scoring"
        case "failed": return "Eval failed"
        case "completed": return String(format: "%.1f/10", evaluation?.overall ?? 0)
        default: return "Eval"
        }
    }

    private func evaluationColor(_ evaluation: SongBenchEvaluation?) -> Color {
        guard evaluation?.status == "completed", let overall = evaluation?.overall else {
            return evaluation?.status == "failed" ? Theme.red : Theme.purple
        }
        if overall >= 8 { return Theme.green }
        if overall >= 6 { return Theme.yellow }
        return Theme.orange
    }
}

private struct SongBenchPopoverView: View {
    let evaluation: SongBenchEvaluation

    private var dimensions: [(String, String, Double?)] {
        let instrumentalIcon = NSImage(systemSymbolName: "guitars.fill", accessibilityDescription: nil) == nil ? "pianokeys" : "guitars.fill"
        return [
            ("Melody", "music.note", evaluation.melody),
            ("Arrangement", "square.stack.3d.up.fill", evaluation.arrangement),
            ("Musicality", "sparkles", evaluation.musicality),
            ("Vocal", "mic.fill", evaluation.vocal),
            ("Instrumental", instrumentalIcon, evaluation.instrumental),
            ("Mixing", "slider.horizontal.3", evaluation.mixing),
            ("Structure", "rectangle.3.group.fill", evaluation.structure),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "star.fill").foregroundColor(Theme.yellow)
                Text("SongBench").font(Theme.bodyBold).foregroundColor(Theme.fg)
                Spacer()
                Text(String(format: "%.1f/10", evaluation.overall ?? 0))
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundColor(overallColor)
            }
            ForEach(dimensions, id: \.0) { name, icon, value in
                HStack(spacing: 7) {
                    Image(systemName: icon)
                        .font(.system(size: 10))
                        .foregroundColor(Theme.purple)
                        .frame(width: 14)
                    Text(name).font(Theme.small).foregroundColor(Theme.fgDark).frame(width: 72, alignment: .leading)
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.bgHighlight)
                            Capsule().fill(Theme.purple).frame(width: proxy.size.width * CGFloat((value ?? 0) / 10.0))
                        }
                    }
                    .frame(height: 6)
                    Text(String(format: "%.2f", value ?? 0))
                        .font(Theme.mono)
                        .foregroundColor(Theme.fg)
                        .frame(width: 34, alignment: .trailing)
                }
            }
            Text("\(evaluation.evaluatorVersion) · \(evaluation.device ?? "unknown") · \(String(format: "%.1fs", evaluation.elapsedSec))")
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(Theme.comment)
        }
        .padding(14)
        .frame(width: 320)
        .background(Theme.bgFloat)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
    }

    private var overallColor: Color {
        let overall = evaluation.overall ?? 0
        if overall >= 8 { return Theme.green }
        if overall >= 6 { return Theme.yellow }
        return Theme.orange
    }
}
