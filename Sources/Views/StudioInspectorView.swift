import SwiftUI

/// Studio tab detail pane: full metadata inspector + mel-spectrogram for the selected track.
public struct StudioInspectorView: View {
    @ObservedObject var vm: StudioViewModel
    /// Expands the raw 0..1 controls for plugins that report no real labels.
    @State private var showRawControls = false

    public init(vm: StudioViewModel) {
        self.vm = vm
    }

    public var body: some View {
        Group {
            if let item = vm.selectedTrack {
                inspector(item)
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bgFloat)
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform.and.magnifyingglass")
                .font(.system(size: 28))
                .foregroundColor(Theme.comment)
            Text("Select a track to inspect its metadata and spectrogram.")
                .font(Theme.small)
                .foregroundColor(Theme.comment)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func inspector(_ item: GenerationHistoryItem) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header(item)
                spectrogram(item)
                if let a = item.analysis {
                    if !a.standard.isEmpty { group("Metadata", a.standard, Theme.blue) }
                    if !a.gen.isEmpty { group("Generation", a.gen, Theme.cyan) }
                    if !a.target.isEmpty { group("Target (intended)", a.target, Theme.orange) }
                    if !a.dsp.isEmpty { group("Acoustic (DSP)", a.dsp, Theme.purple) }
                    if !a.norm.isEmpty { group("Loudness / Dynamics", a.norm, Theme.green) }
                    if !a.sb.isEmpty { group("SongBench", a.sb, Theme.yellow) }
                } else {
                    fallbackFromItem(item)
                }
                pluginSection(item)
            }
            .padding(14)
        }
    }

    private func header(_ item: GenerationHistoryItem) -> some View {
        let name = URL(fileURLWithPath: item.output_file).lastPathComponent
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "waveform")
                    .foregroundColor(Theme.purple)
                Text("TRACK INSPECTOR")
                    .font(Theme.smallBold)
                    .foregroundColor(Theme.comment)
            }
            Text(name)
                .font(Theme.bodyBold)
                .foregroundColor(Theme.fg)
                .lineLimit(2)
                .textSelection(.enabled)
            HStack(spacing: 8) {
                Text(item.format.uppercased())
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(Theme.cyan)
                Text(String(format: "%.1f MB", item.size_mb))
                    .font(Theme.mono)
                    .foregroundColor(Theme.comment)
                Text("\(Int(item.duration))s")
                    .font(Theme.mono)
                    .foregroundColor(Theme.comment)
            }
        }
    }

    @ViewBuilder
    private func spectrogram(_ item: GenerationHistoryItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("SPECTROGRAM")
                .font(Theme.smallBold)
                .foregroundColor(Theme.comment)
            if let png = vm.spectrogramPaths[item.output_file],
               let img = NSImage(contentsOfFile: png) {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .cornerRadius(6)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Theme.bgDark)
                        .frame(height: 160)
                    VStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Rendering spectrogram…")
                            .font(Theme.small)
                            .foregroundColor(Theme.comment)
                    }
                }
                .onAppear { vm.requestSpectrogram(for: item.output_file) }
            }
        }
    }

    private func group(_ title: String, _ pairs: [String: String], _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(Theme.smallBold)
                .foregroundColor(color)
            VStack(spacing: 0) {
                ForEach(pairs.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                    HStack(alignment: .top, spacing: 8) {
                        Text(prettyKey(key))
                            .font(Theme.mono)
                            .foregroundColor(Theme.comment)
                            .frame(width: 150, alignment: .leading)
                        Text(value)
                            .font(Theme.mono)
                            .foregroundColor(Theme.fg)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 3)
                    .padding(.horizontal, 6)
                    .background(Theme.bgDark.opacity(0.5))
                }
            }
            .cornerRadius(5)
        }
    }

    /// Older tracks predating the tagging work carry no analysis; show the DB basics.
    private func fallbackFromItem(_ item: GenerationHistoryItem) -> some View {
        var basics: [String: String] = [
            "model": item.model,
            "seed": String(item.seed),
            "steps": String(item.steps),
            "guidance": String(format: "%.2f", item.guidance),
            "duration_s": String(Int(item.duration)),
        ]
        if let sb = item.songbench, let overall = sb.overall {
            basics["songbench_overall"] = String(format: "%.2f", overall)
        }
        return VStack(alignment: .leading, spacing: 6) {
            group("Generation", basics, Theme.cyan)
            Text("No embedded tags yet. Run reconcile or re-render to populate full metadata.")
                .font(Theme.small)
                .foregroundColor(Theme.comment)
        }
    }

    // MARK: - VST / AU Plugin
    @ViewBuilder
    private func pluginSection(_ item: GenerationHistoryItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("EFFECT PLUGIN (VST3 / AU)")
                    .font(Theme.smallBold)
                    .foregroundColor(Theme.orange)
                Spacer()
                Button(action: { vm.chooseAndLoadPlugin() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "slider.horizontal.3")
                        Text(vm.loadedPlugin == nil ? "Load Plugin…" : "Change…")
                    }
                    .font(Theme.small)
                    .foregroundColor(Theme.blue)
                }
                .buttonStyle(.plain)
                .disabled(vm.pluginBusy)
            }

            if let plugin = vm.loadedPlugin {
                HStack(spacing: 6) {
                    Image(systemName: plugin.isEffect ? "waveform.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundColor(plugin.isEffect ? Theme.green : Theme.yellow)
                    Text(plugin.name)
                        .font(Theme.bodyBold)
                        .foregroundColor(Theme.fg)
                    if !plugin.manufacturer.isEmpty {
                        Text(plugin.manufacturer)
                            .font(Theme.small)
                            .foregroundColor(Theme.comment)
                    }
                    Spacer()
                    Button(action: { vm.clearPlugin() }) {
                        Image(systemName: "xmark.circle")
                            .foregroundColor(Theme.comment)
                    }
                    .buttonStyle(.plain)
                    .help("Remove plugin")
                }

                engineModeBanner()

                if plugin.isEffect {
                    // AU: its own window drives the same live node in our playback chain.
                    if vm.pluginEngineMode == .realtimeAU && vm.pluginLiveActive {
                        Button(action: { vm.showPluginWindow() }) {
                            HStack(spacing: 5) {
                                Image(systemName: "macwindow")
                                Text("Show Plugin Window")
                            }
                            .font(Theme.small)
                            .foregroundColor(Theme.blue)
                        }
                        .buttonStyle(.plain)
                        .help("Open \(plugin.name)'s own controls. Audio still plays through MusicStudio.")
                    }

                    if plugin.hasRealLabels {
                        ForEach($vm.pluginParameters) { $param in
                            if !param.isHidden { parameterRow($param) }
                        }
                    } else {
                        // AU with no VST3 build installed: only raw 0..1 values are available,
                        // so keep them out of the way and point to the plugin's own window.
                        Text("This plugin reports raw values only. Use its window for real controls.")
                            .font(Theme.small)
                            .foregroundColor(Theme.comment)
                            .fixedSize(horizontal: false, vertical: true)
                        DisclosureGroup(isExpanded: $showRawControls) {
                            ForEach($vm.pluginParameters) { $param in
                                if !param.isHidden { parameterRow($param) }
                            }
                        } label: {
                            Text("Advanced (raw values)")
                                .font(Theme.small)
                                .foregroundColor(Theme.fgDark)
                        }
                    }

                    // Save the processed audio with a format choice. Live AU renders offline
                    // at the node's current values; everything else renders via pedalboard.
                    if vm.pluginEngineMode != .none {
                        Button(action: {
                            if vm.pluginEngineMode == .realtimeAU { vm.saveAUToFile() }
                            else { vm.saveVSTToFile() }
                        }) {
                            HStack(spacing: 5) {
                                Image(systemName: "square.and.arrow.down")
                                Text("Save Audio…")
                            }
                            .font(Theme.smallBold)
                            .foregroundColor(Theme.bg)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(vm.pluginBusy ? Theme.comment : Theme.green)
                            .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                        .disabled(vm.pluginBusy || (vm.pluginEngineMode == .realtimeAU && !vm.pluginLiveActive))
                        .help("Write this track with the effect applied at the current settings")
                        .padding(.top, 2)
                    }
                }
            } else {
                Text("Load a VST3 or Audio Unit effect to hear it on this track. Audio Units preview live; VST3 updates when you pause.")
                    .font(Theme.small)
                    .foregroundColor(Theme.comment)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !vm.pluginStatus.isEmpty {
                HStack(spacing: 5) {
                    if vm.pluginBusy { ProgressView().controlSize(.small) }
                    Text(vm.pluginStatus)
                        .font(Theme.small)
                        .foregroundColor(Theme.comment)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(10)
        .background(Theme.bgDark.opacity(0.4))
        .cornerRadius(6)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border.opacity(0.5), lineWidth: 1))
    }

    @ViewBuilder
    private func engineModeBanner() -> some View {
        switch vm.pluginEngineMode {
        case .realtimeAU:
            Label("Real-time (Audio Unit) — changes are heard instantly.",
                  systemImage: "bolt.fill")
                .font(Theme.small)
                .foregroundColor(Theme.green)
        case .offline:
            Label("Offline preview — re-renders shortly after you change a value.",
                  systemImage: "clock.arrow.circlepath")
                .font(Theme.small)
                .foregroundColor(Theme.yellow)
        case .none:
            EmptyView()
        }
    }

    @ViewBuilder
    private func parameterRow(_ param: Binding<VSTParameter>) -> some View {
        let p = param.wrappedValue
        HStack(spacing: 8) {
            Text(p.label)
                .font(Theme.mono)
                .foregroundColor(Theme.fgDark)
                .frame(width: 120, alignment: .leading)
                .lineLimit(1)
                .help(p.name)
            if p.isSwitch {
                Toggle("", isOn: Binding(
                    get: { param.wrappedValue.stepIndex(for: param.wrappedValue.raw) == 1 },
                    set: { setRaw(param, param.wrappedValue.value(forStep: $0 ? 1 : 0)) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(Theme.orange)
                Spacer()
            } else if p.isChoice && !p.steps.isEmpty && p.steps.count <= 24 {
                Picker("", selection: Binding(
                    get: { param.wrappedValue.stepIndex(for: param.wrappedValue.raw) ?? 0 },
                    set: { setRaw(param, param.wrappedValue.value(forStep: $0)) }
                )) {
                    ForEach(Array(p.steps.enumerated()), id: \.offset) { i, step in
                        Text(step.label).tag(i)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 200, alignment: .leading)
                Spacer()
            } else if p.isChoice && p.steps.count > 24 {
                // Long fixed list (e.g. hundreds of frequencies): slider that snaps to entries.
                Slider(
                    value: Binding(
                        get: { Double(param.wrappedValue.stepIndex(for: param.wrappedValue.raw) ?? 0) },
                        set: {
                            let i = min(max(Int($0.rounded()), 0), param.wrappedValue.steps.count - 1)
                            if param.wrappedValue.stepIndex(for: param.wrappedValue.raw) != i {
                                setRaw(param, param.wrappedValue.value(forStep: i))
                            }
                        }
                    ),
                    in: 0...Double(p.steps.count - 1)
                )
                .tint(Theme.orange)
                valueLabel(p.display)
            } else {
                Slider(
                    value: Binding(
                        get: { param.wrappedValue.raw },
                        set: { setRaw(param, $0) }
                    ),
                    in: 0...1
                )
                .tint(Theme.orange)
                valueLabel(p.display)
            }
        }
    }

    private func valueLabel(_ text: String) -> some View {
        Text(text)
            .font(Theme.mono)
            .foregroundColor(Theme.orange)
            .frame(width: 84, alignment: .trailing)
            .lineLimit(1)
    }

    /// Write a normalized value and tell the engine (live AU set, or offline re-render).
    private func setRaw(_ param: Binding<VSTParameter>, _ value: Double) {
        let v = min(max(value, 0), 1)
        guard abs(param.wrappedValue.raw - v) > 1e-9 else { return }
        param.wrappedValue.raw = v
        vm.pluginParameterChanged(param.wrappedValue.name)
    }

    private func prettyKey(_ key: String) -> String {
        key.replacingOccurrences(of: "_", with: " ")
    }
}
