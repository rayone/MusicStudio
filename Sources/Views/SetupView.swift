import SwiftUI

public struct SetupView: View {
    @ObservedObject var setupManager: SetupManager
    var onComplete: () -> Void

    public init(setupManager: SetupManager, onComplete: @escaping () -> Void) {
        self.setupManager = setupManager
        self.onComplete = onComplete
    }

    public var body: some View {
        ZStack {
            Theme.bgDark.ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                VStack(spacing: 8) {
                    HStack(spacing: 12) {
                        Image(systemName: "music.note.house.fill")
                            .font(.system(size: 36))
                            .foregroundColor(Theme.blue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("MusicStudio")
                                .font(.system(size: 24, weight: .bold))
                                .foregroundColor(Theme.fg)
                            Text("Apple Silicon Dual-Model Workstation (MiniMax Music 3 & YuE2-3B)")
                                .font(Theme.body)
                                .foregroundColor(Theme.comment)
                        }
                        Spacer()
                    }
                }
                .padding(.horizontal, 32)
                .padding(.top, 28)
                .padding(.bottom, 20)

                Divider().background(Theme.border)

                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 20) {
                        // Hardware Profile Card
                        hardwareProfileCard

                        // Storage & Paths Card
                        storageConfigurationCard

                        // HuggingFace & Model Selection Card
                        modelSelectionCard

                        // Progress & Action Bar
                        actionSection
                    }
                    .padding(32)
                }
            }
        }
        .frame(minWidth: 780, minHeight: 620)
    }

    // MARK: - Hardware Profile Card
    private var hardwareProfileCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "cpu")
                    .foregroundColor(Theme.cyan)
                Text("Hardware Profile & Memory Tier")
                    .font(Theme.bodyBold)
                    .foregroundColor(Theme.fg)
                Spacer()
                Text(setupManager.profile.chipName)
                    .font(Theme.mono)
                    .foregroundColor(Theme.blue)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Theme.bgDark)
                    .cornerRadius(6)
            }

            HStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Total RAM")
                        .font(Theme.small)
                        .foregroundColor(Theme.comment)
                    Text(setupManager.profile.memoryDisplay)
                        .font(.system(size: 16, weight: .bold, design: .monospaced))
                        .foregroundColor(Theme.fg)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("GPU Budget")
                        .font(Theme.small)
                        .foregroundColor(Theme.comment)
                    Text(String(format: "%.1f GB", setupManager.profile.usableGPUBudgetGB))
                        .font(.system(size: 16, weight: .bold, design: .monospaced))
                        .foregroundColor(Theme.green)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Perf Cores")
                        .font(Theme.small)
                        .foregroundColor(Theme.comment)
                    Text("\(setupManager.profile.performanceCores)")
                        .font(.system(size: 16, weight: .bold, design: .monospaced))
                        .foregroundColor(Theme.purple)
                }

                Spacer()
            }
            .padding(12)
            .background(Theme.bgDark.opacity(0.6))
            .cornerRadius(8)

            // Recommendation Banner
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "sparkles")
                    .foregroundColor(Theme.yellow)
                    .font(.system(size: 14))
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text(setupManager.profile.recommendationBadge(for: .minimax_music3))
                        .font(Theme.bodyBold)
                        .foregroundColor(Theme.fg)
                    Text(setupManager.profile.tierNotes)
                        .font(Theme.small)
                        .foregroundColor(Theme.comment)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .background(Theme.yellow.opacity(0.1))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.yellow.opacity(0.3), lineWidth: 1))
            .cornerRadius(8)
        }
        .padding(16)
        .background(Theme.bgFloat)
        .cornerRadius(10)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border, lineWidth: 1))
    }

    // MARK: - Storage & Paths Card
    private var storageConfigurationCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "folder.badge.gearshape")
                    .foregroundColor(Theme.orange)
                Text("Storage Configuration")
                    .font(Theme.bodyBold)
                    .foregroundColor(Theme.fg)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Rendered Audio Output Folder")
                    .font(Theme.smallMedium)
                    .foregroundColor(Theme.fgDark)
                HStack {
                    TextField("Output Directory", text: $setupManager.outputDirectory)
                        .textFieldStyle(.plain)
                        .font(Theme.mono)
                        .foregroundColor(Theme.fg)
                        .padding(8)
                        .background(Theme.bgDark)
                        .cornerRadius(6)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))

                    Button("Browse...") {
                        setupManager.selectOutputDirectory()
                    }
                    .buttonStyle(.bordered)
                    .tint(Theme.blue)
                }
                Text("Rendered songs (WAV, MP3, M4A, FLAC) will be saved here. You can change this at any time.")
                    .font(Theme.small)
                    .foregroundColor(Theme.comment)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Model Cache Directory")
                    .font(Theme.smallMedium)
                    .foregroundColor(Theme.fgDark)
                HStack {
                    TextField("Models Directory", text: $setupManager.modelsDirectory)
                        .textFieldStyle(.plain)
                        .font(Theme.mono)
                        .foregroundColor(Theme.fg)
                        .padding(8)
                        .background(Theme.bgDark)
                        .cornerRadius(6)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))

                    Button("Browse...") {
                        setupManager.selectModelsDirectory()
                    }
                    .buttonStyle(.bordered)
                    .tint(Theme.blue)
                }
                Text("Stores downloaded weights for MiniMax Music 3 and YuE2-3B.")
                    .font(Theme.small)
                    .foregroundColor(Theme.comment)
            }
        }
        .padding(16)
        .background(Theme.bgFloat)
        .cornerRadius(10)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border, lineWidth: 1))
    }

    // MARK: - Model Selection & HuggingFace Card
    private var modelSelectionCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "arrow.down.circle")
                    .foregroundColor(Theme.green)
                Text("Model Selection & HuggingFace")
                    .font(Theme.bodyBold)
                    .foregroundColor(Theme.fg)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Primary Initial Model")
                    .font(Theme.smallMedium)
                    .foregroundColor(Theme.fgDark)

                Picker("", selection: $setupManager.selectedModelId) {
                    ForEach(ModelCatalog.bundledModels) { m in
                        HStack {
                            Text(m.name)
                            Spacer()
                            Text(String(format: "%.1f GB (min %d GB RAM)", m.size_gb, m.recommended_min_ram_gb))
                                .font(Theme.mono)
                                .foregroundColor(Theme.comment)
                        }
                        .tag(m.id)
                    }
                }
                .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("HuggingFace User Access Token (Optional)")
                    .font(Theme.smallMedium)
                    .foregroundColor(Theme.fgDark)
                SecureField("hf_...", text: $setupManager.hfToken)
                    .textFieldStyle(.plain)
                    .font(Theme.mono)
                    .foregroundColor(Theme.fg)
                    .padding(8)
                    .background(Theme.bgDark)
                    .cornerRadius(6)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
                Text("Required only for gated model downloads or higher API rate limits.")
                    .font(Theme.small)
                    .foregroundColor(Theme.comment)
            }
        }
        .padding(16)
        .background(Theme.bgFloat)
        .cornerRadius(10)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border, lineWidth: 1))
    }

    // MARK: - Action Section
    private var actionSection: some View {
        VStack(spacing: 14) {
            if setupManager.state == .installing {
                VStack(spacing: 8) {
                    ProgressView(value: setupManager.progress)
                        .tint(Theme.blue)
                    HStack {
                        Text(setupManager.statusMessage)
                            .font(Theme.small)
                            .foregroundColor(Theme.fgDark)
                        Spacer()
                        Text("\(Int(setupManager.progress * 100))%")
                            .font(Theme.mono)
                            .foregroundColor(Theme.blue)
                    }
                }
                .padding(12)
                .background(Theme.bgDark)
                .cornerRadius(8)
            } else if case .failed(let err) = setupManager.state {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(Theme.red)
                    Text(err)
                        .font(Theme.small)
                        .foregroundColor(Theme.red)
                    Spacer()
                }
                .padding(12)
                .background(Theme.red.opacity(0.1))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.red.opacity(0.3), lineWidth: 1))
                .cornerRadius(8)
            }

            HStack {
                Spacer()
                if setupManager.state == .ready {
                    Button(action: onComplete) {
                        HStack(spacing: 8) {
                            Text("Continue to Studio")
                                .font(Theme.bodyBold)
                            Image(systemName: "arrow.right")
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 10)
                        .background(Theme.blue)
                        .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                } else {
                    Button(action: {
                        Task {
                            await setupManager.runBootstrap()
                        }
                    }) {
                        HStack(spacing: 8) {
                            if setupManager.state == .installing {
                                ProgressView()
                                    .scaleEffect(0.8)
                                    .tint(.white)
                            }
                            Text(setupManager.state == .installing ? "Installing..." : "Start Setup")
                                .font(Theme.bodyBold)
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 10)
                        .background(setupManager.state == .installing ? Theme.comment : Theme.green)
                        .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                    .disabled(setupManager.state == .installing)
                }
            }
        }
        .padding(.top, 8)
    }
}
