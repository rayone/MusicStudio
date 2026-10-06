import SwiftUI

public struct ParameterView: View {
    @ObservedObject var vm: StudioViewModel

    public init(vm: StudioViewModel) {
        self.vm = vm
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("GENERATION PARAMETERS")
                    .font(Theme.smallBold)
                    .foregroundColor(Theme.comment)
                Spacer()

                Button(action: {
                    vm.toggleInstrumental()
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: vm.isInstrumental ? "checkmark.square.fill" : "square")
                        Text("Instrumental")
                    }
                    .font(Theme.small)
                    .foregroundColor(vm.isInstrumental ? Theme.green : Theme.comment)
                }
                .buttonStyle(.plain)
                .help("Generate an instrumental track with no vocals (collapses the Lyrics pane)")

                Text(vm.selectedModelFamily.displayName)
                    .font(Theme.smallMedium)
                    .foregroundColor(Theme.blue)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Theme.blue.opacity(0.12))
                    .cornerRadius(4)
            }

            // Line 1: Duration & Steps
            HStack(alignment: .top, spacing: 16) {
                // Duration
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Duration")
                            .font(Theme.small)
                            .foregroundColor(Theme.fgDark)
                        Spacer()
                        Text("\(Int(vm.duration))s")
                            .font(Theme.monoBody)
                            .foregroundColor(Theme.cyan)
                    }
                    Slider(value: $vm.duration, in: 10...360, step: 5)
                        .tint(Theme.cyan)

                    HStack(spacing: 6) {
                        ForEach([30, 60, 90, 120, 180, 240], id: \.self) { sec in
                            Button("\(sec)s") {
                                vm.duration = Double(sec)
                            }
                            .buttonStyle(.plain)
                            .font(Theme.small)
                            .foregroundColor(Int(vm.duration) == sec ? Theme.blue : Theme.comment)
                        }
                    }
                }
                .frame(maxWidth: .infinity)

                // Steps (Flow vs NAR)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(vm.selectedModelFamily == .minimax_music3 ? "Steps (DiT Flow)" : "Steps (NAR Midpoint)")
                            .font(Theme.small)
                            .foregroundColor(Theme.fgDark)
                        Spacer()
                        Text("\(vm.steps)")
                            .font(Theme.monoBody)
                            .foregroundColor(Theme.purple)
                    }

                    if vm.selectedModelFamily == .minimax_music3 {
                        Slider(value: Binding(
                            get: { Double(vm.steps) },
                            set: { vm.steps = Int($0) }
                        ), in: 1...30, step: 1)
                        .tint(Theme.purple)

                        HStack(spacing: 6) {
                            ForEach([10, 20, 25, 30], id: \.self) { st in
                                Button("\(st)") { vm.steps = st }
                                    .buttonStyle(.plain)
                                    .font(Theme.small)
                                    .foregroundColor(vm.steps == st ? Theme.purple : Theme.comment)
                            }
                        }
                    } else {
                        Slider(value: Binding(
                            get: { Double(vm.steps) },
                            set: { vm.steps = Int($0) }
                        ), in: 8...64, step: 4)
                        .tint(Theme.purple)

                        HStack(spacing: 6) {
                            ForEach([16, 24, 32, 48, 64], id: \.self) { st in
                                Button("\(st)") { vm.steps = st }
                                    .buttonStyle(.plain)
                                    .font(Theme.small)
                                    .foregroundColor(vm.steps == st ? Theme.purple : Theme.comment)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }

            // Line 2: Guidance & Planning Mode (YuE2) or Seed
            // Line 2: Guidance & Run Controls (Seed / Format / Batch)
            HStack(alignment: .top, spacing: 16) {
                // Guidance / CFG Scale (+ CoT Mode for YuE2)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(vm.selectedModelFamily == .minimax_music3 ? "Guidance (DiT CFG)" : "CFG Scale")
                            .font(Theme.small)
                            .foregroundColor(Theme.fgDark)
                        Spacer()
                        Text(String(format: "%.2f", vm.guidance))
                            .font(Theme.monoBody)
                            .foregroundColor(Theme.yellow)
                    }
                    Slider(value: $vm.guidance, in: 1.0...3.0, step: 0.05)
                        .tint(Theme.yellow)

                    HStack(spacing: 6) {
                        let presets = vm.selectedModelFamily == .minimax_music3 ? [1.2, 1.5, 1.7, 2.0, 2.5] : [1.0, 1.05, 1.2, 1.5, 2.0]
                        ForEach(presets, id: \.self) { g in
                            Button(String(format: "%.1f", g)) {
                                vm.guidance = g
                            }
                            .buttonStyle(.plain)
                            .font(Theme.small)
                            .foregroundColor(abs(vm.guidance - g) < 0.02 ? Theme.yellow : Theme.comment)
                        }
                    }

                    if vm.selectedModelFamily == .yue2 {
                        HStack {
                            Text("CoT Mode:")
                                .font(Theme.small)
                                .foregroundColor(Theme.fgDark)
                            Picker("", selection: $vm.cotMode) {
                                ForEach(CoTMode.allCases) { mode in
                                    Text(mode.displayName).tag(mode)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(maxWidth: .infinity)
                        }
                        .padding(.top, 2)
                    }
                }
                .frame(maxWidth: .infinity)
                // Column 2: Seed, Format, Batch (FR-010 / Formatting)
                VStack(alignment: .leading, spacing: 4) {
                    // 1st Row: Labels
                    HStack(spacing: 8) {
                        Text("Seed")
                            .font(Theme.small)
                            .foregroundColor(Theme.fgDark)
                            .frame(width: 105, alignment: .leading)

                        Spacer()

                        Text("Format")
                            .font(Theme.small)
                            .foregroundColor(Theme.fgDark)
                            .frame(width: 75, alignment: .leading)

                        Spacer()

                        Text("Batch")
                            .font(Theme.small)
                            .foregroundColor(Theme.fgDark)
                            .frame(width: 55, alignment: .trailing)
                    }

                    // 2nd Row: Controls (Seed 1/4 size + lock, format dropdown, batch count)
                    HStack(spacing: 8) {
                        // Seed input + lock
                        HStack(spacing: 4) {
                            if vm.isSeedLocked {
                                TextField("Seed", text: $vm.lockedSeedString)
                                    .textFieldStyle(.plain)
                                    .font(Theme.mono)
                                    .foregroundColor(Theme.fg)
                                    .frame(width: 65)
                            } else {
                                Text("Random")
                                    .font(Theme.small)
                                    .foregroundColor(Theme.green)
                                    .frame(width: 65, alignment: .leading)
                            }

                            Button(action: {
                                if vm.isSeedLocked {
                                    vm.isSeedLocked = false
                                    vm.lockedSeedString = ""
                                } else {
                                    let newSeed = Int.random(in: 100_000...999_999_999)
                                    vm.lockedSeedString = String(newSeed)
                                    vm.isSeedLocked = true
                                }
                            }) {
                                Image(systemName: vm.isSeedLocked ? "lock.fill" : "lock.open.fill")
                                    .font(.system(size: 10))
                                    .foregroundColor(vm.isSeedLocked ? Theme.yellow : Theme.comment)
                            }
                            .buttonStyle(.plain)
                            .help(vm.isSeedLocked ? "Seed is locked. Click to unlock (random per track)." : "Click to lock seed for reproducible generations.")
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .frame(width: 105)
                        .background(Theme.bgDark)
                        .cornerRadius(5)
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(vm.isSeedLocked ? Theme.yellow : Theme.border, lineWidth: 1)
                        )

                        Spacer()

                        // Format Dropdown
                        Picker("", selection: $vm.outputFormat) {
                            ForEach(AudioFormat.allCases) { fmt in
                                Text(fmt.rawValue.uppercased()).tag(fmt)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 75)

                        Spacer()

                        // Batch Count — explicit label avoids the macOS menu picker's "--" state.
                        Menu {
                            ForEach(1...8, id: \.self) { count in
                                Button("\(count)x") { vm.batchCount = count }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text("\(vm.batchCount)x")
                                    .font(Theme.smallMedium)
                                    .foregroundColor(Theme.fg)
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 8))
                                    .foregroundColor(Theme.comment)
                            }
                            .frame(width: 55, height: 22)
                            .background(Theme.bgDark)
                            .cornerRadius(5)
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.border, lineWidth: 1))
                            .contentShape(Rectangle())
                        }
                        .menuStyle(.borderlessButton)
                        .frame(width: 55)
                    }

                    // Sub-caption describing seed mode behavior
                    HStack {
                        if vm.isSeedLocked {
                            Text("Locked: track 1 uses \(vm.lockedSeedString.isEmpty ? "specified" : vm.lockedSeedString); batch derives deterministically.")
                                .font(.system(size: 9))
                                .foregroundColor(Theme.yellow)
                                .lineLimit(1)
                        } else {
                            Text("Random: fresh cryptographically independent seed per track.")
                                .font(.system(size: 9))
                                .foregroundColor(Theme.comment)
                                .lineLimit(1)
                        }
                    }
                    .padding(.top, 1)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(12)
        .background(Theme.bgFloat)
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
    }
}
