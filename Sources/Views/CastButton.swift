import SwiftUI
import AppKit

/// Cast button for the player bar. Shows the current output state at a glance and opens
/// a menu to pick a discovered receiver, adjust volume, stop, switch back to local, and
/// configure the cross-VLAN scan range (receivers on another subnet aren't reachable by
/// multicast). Selecting a receiver redirects playback to it and stops local output.
struct CastButton: View {
    @ObservedObject var vm: StudioViewModel
    @ObservedObject private var net: NetAudioController
    @State private var showMenu = false
    @State private var showRangeField = false
    @State private var scanRangeDraft = ""

    init(vm: StudioViewModel) {
        self.vm = vm
        self._net = ObservedObject(wrappedValue: vm.netAudio)
    }

    var body: some View {
        Button(action: {
            if net.receivers.isEmpty && !net.isDiscovering { vm.discoverReceivers() }
            scanRangeDraft = net.scanRanges
            showMenu.toggle()
        }) {
            Image(systemName: iconName)
                .font(Theme.body)
                .foregroundColor(iconColor)
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.plain)
        .help(helpText)
        .popover(isPresented: $showMenu, arrowEdge: .top) {
            menuContent
        }
    }

    private var menuContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("NETWORK OUTPUT")
                    .font(Theme.smallBold)
                    .foregroundColor(Theme.comment)
                Spacer()
                Button(action: { vm.discoverReceivers() }) {
                    if net.isDiscovering {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise").font(Theme.small)
                    }
                }
                .buttonStyle(.plain)
                .foregroundColor(Theme.blue)
                .disabled(net.isDiscovering)
            }

            Divider().background(Theme.border)

            // Local output option
            outputRow(title: "This Mac (local)",
                      subtitle: "Built-in / system output",
                      icon: "laptopcomputer",
                      active: !vm.isCasting,
                      action: { vm.stopCasting() })

            if net.receivers.isEmpty {
                Text(net.isDiscovering ? "Scanning…" : "No receivers found")
                    .font(Theme.small)
                    .foregroundColor(Theme.comment)
                    .padding(.vertical, 4)
            } else {
                ForEach(net.receivers) { r in
                    outputRow(title: r.name,
                              subtitle: "\(r.protocolLabel)\(r.model.map { " · \($0)" } ?? "")",
                              icon: icon(for: r.protocol),
                              active: net.activeReceiverID == r.id,
                              enabled: r.available,
                              action: { vm.castTo(r) })
                }
            }

            if net.state == .streaming || net.state == .reconnecting {
                Divider().background(Theme.border)
                HStack(spacing: 8) {
                    Image(systemName: "speaker.fill").font(Theme.small).foregroundColor(Theme.comment)
                    Slider(value: Binding(
                        get: { net.activeVolume },
                        set: { vm.netAudio.setVolume($0) }
                    ), in: 0...1)
                    .tint(Theme.green)
                    Text("\(Int(net.activeVolume * 100))%")
                        .font(Theme.mono).foregroundColor(Theme.comment)
                        .frame(width: 34, alignment: .trailing)
                }
            }

            Divider().background(Theme.border)

            // Cross-VLAN scan range (receivers on another subnet need unicast probing).
            DisclosureGroup(isExpanded: $showRangeField) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Receivers on a different VLAN aren't found by multicast. Enter their IP range to scan them directly.")
                        .font(.system(size: 10))
                        .foregroundColor(Theme.comment)
                    HStack(spacing: 6) {
                        TextField("10.2.0.0/24", text: $scanRangeDraft)
                            .textFieldStyle(.plain)
                            .font(Theme.mono)
                            .padding(6)
                            .background(Theme.bgDark)
                            .cornerRadius(5)
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.border, lineWidth: 1))
                            .onSubmit { applyRange() }
                        Button("Scan") { applyRange() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
                .padding(.top, 4)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "network")
                    Text("Scan range (cross-VLAN)")
                }
                .font(Theme.small)
                .foregroundColor(Theme.blue)
            }
        }
        .padding(12)
        .frame(width: 320)
        .background(Theme.bgFloat)
    }

    private func applyRange() {
        net.setScanRanges(scanRangeDraft.trimmingCharacters(in: .whitespacesAndNewlines))
        vm.discoverReceivers()
    }

    private func outputRow(title: String, subtitle: String, icon: String,
                           active: Bool, enabled: Bool = true,
                           action: @escaping () -> Void) -> some View {
        Button(action: { action(); showMenu = false }) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .foregroundColor(active ? Theme.green : Theme.comment)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(Theme.smallMedium)
                        .foregroundColor(enabled ? Theme.fg : Theme.comment)
                        .lineLimit(1)
                    Text(subtitle).font(.system(size: 10))
                        .foregroundColor(Theme.comment).lineLimit(1)
                }
                Spacer()
                if active {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(Theme.green)
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .background(active ? Theme.green.opacity(0.08) : Color.clear)
            .cornerRadius(5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }

    private func icon(for proto: String) -> String {
        switch proto {
        case "airplay": return "airplayaudio"
        case "cast": return "tv"
        case "dlna": return "network"
        case "heos": return "hifispeaker.2.fill"
        default: return "hifispeaker"
        }
    }

    private var iconName: String {
        switch net.state {
        case .streaming: return "airplayaudio.circle.fill"
        case .connecting, .reconnecting: return "airplayaudio"
        default: return "airplayaudio"
        }
    }

    private var iconColor: Color {
        switch net.state {
        case .streaming: return Theme.green
        case .connecting, .reconnecting: return Theme.yellow
        case .error: return Theme.red
        default: return Theme.comment
        }
    }

    private var helpText: String {
        switch net.state {
        case .streaming:
            return "Streaming to \(net.activeReceiverName ?? "receiver"). Click to switch or stop."
        case .reconnecting: return "Reconnecting to network output…"
        default: return "Cast audio to a network receiver"
        }
    }
}
