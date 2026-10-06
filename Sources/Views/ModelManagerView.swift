import SwiftUI
import AppKit

public struct ModelManagerView: View {
    @ObservedObject var vm: StudioViewModel
    @ObservedObject var hf = HuggingFaceClient.shared
    @Environment(\.dismiss) private var dismiss
    @State private var searchQuery = ""
    @State private var selectedTab = 0 // 0 = Catalog, 1 = HuggingFace Hub
    public init(vm: StudioViewModel) {
        self.vm = vm
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Model Manager")
                        .font(Theme.bodyBold)
                        .foregroundColor(Theme.fg)
                    Text("Manage MiniMax Music 3 and YuE2-3B weights on Apple Silicon")
                        .font(Theme.small)
                        .foregroundColor(Theme.comment)
                }

                Spacer()

                Button(action: {
                    NSWorkspace.shared.open(ModelCatalog.modelsDirectory)
                }) {
                    Label("Reveal Models Folder", systemImage: "folder")
                        .font(Theme.small)
                }
                .buttonStyle(.bordered)
                .tint(Theme.blue)

                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.blue)
                .controlSize(.small)
            }
            .padding(16)
            .background(Theme.bgFloat)

            Divider().background(Theme.border)

            // Segmented Tab Picker
            Picker("", selection: $selectedTab) {
                Text("Standard Catalog").tag(0)
                Text("Hugging Face Hub").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider().background(Theme.border)

            if selectedTab == 0 {
                catalogListView
            } else {
                huggingFaceHubView
            }
        }
        .frame(minWidth: 700, minHeight: 520)
        .background(Theme.bgDark)
    }

    // MARK: - Standard Catalog List
    private var catalogListView: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(spacing: 14) {
                // System profile banner
                HStack(spacing: 12) {
                    Image(systemName: "cpu")
                        .foregroundColor(Theme.cyan)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(SystemProfile.current.chipName) • \(SystemProfile.current.memoryDisplay) Unified Memory")
                            .font(Theme.bodyBold)
                            .foregroundColor(Theme.fg)
                        Text(SystemProfile.current.tierNotes)
                            .font(Theme.small)
                            .foregroundColor(Theme.comment)
                    }
                    Spacer()
                }
                .padding(12)
                .background(Theme.bgFloat)
                .cornerRadius(8)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))

                // Models grouped by family
                ForEach(ModelFamily.allCases) { family in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Image(systemName: family.iconName)
                                .foregroundColor(Theme.purple)
                            Text(family.displayName.uppercased())
                                .font(Theme.smallBold)
                                .foregroundColor(Theme.fg)
                            Spacer()
                            Text(family.shortDescription)
                                .font(Theme.small)
                                .foregroundColor(Theme.comment)
                        }

                        let familyModels = ModelCatalog.models(for: family)
                        ForEach(familyModels) { model in
                            modelCard(model: model)
                        }
                    }
                    .padding(12)
                    .background(Theme.bgFloat.opacity(0.6))
                    .cornerRadius(8)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border.opacity(0.6), lineWidth: 1))
                }
            }
            .padding(16)
        }
    }

    private func modelCard(model: ModelDefinition) -> some View {
        let isLocal = model.isAvailableLocally
        let isSelected = vm.selectedModel == model.id
        let downloadKey = "\(model.repo_id):\(model.subfolder ?? "root")"
        let downloadState = hf.activeDownloads[downloadKey]

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(model.name)
                            .font(Theme.bodyBold)
                            .foregroundColor(Theme.fg)

                        if model.recommended {
                            Text("RECOMMENDED")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(Theme.yellow)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Theme.yellow.opacity(0.15))
                                .cornerRadius(3)
                        }

                        if isLocal {
                            Text("READY ON DISK")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(Theme.green)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Theme.green.opacity(0.15))
                                .cornerRadius(3)
                        } else {
                            Text("NOT DOWNLOADED")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(Theme.comment)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Theme.border)
                                .cornerRadius(3)
                        }
                    }

                    Text(model.repo_id + (model.subfolder != nil ? " (\(model.subfolder!))" : ""))
                        .font(Theme.mono)
                        .foregroundColor(Theme.comment)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text(String(format: "%.2f GB", model.size_gb))
                        .font(Theme.monoBody)
                        .foregroundColor(Theme.fg)
                    Text("Min RAM: \(model.recommended_min_ram_gb) GB")
                        .font(Theme.small)
                        .foregroundColor(SystemProfile.current.physicalMemoryGB >= Double(model.recommended_min_ram_gb) ? Theme.cyan : Theme.red)
                }
            }

            // Progress bar if downloading
            if let dl = downloadState, !dl.isComplete {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: dl.progressFraction)
                        .tint(Theme.blue)
                    HStack {
                        Text("Downloading \(dl.currentFile)... (\(dl.filesCompleted)/\(dl.totalFiles) files)")
                            .font(Theme.small)
                            .foregroundColor(Theme.fgDark)
                        Spacer()
                        Text(String(format: "%.1f MB/s • %.0f%%", dl.speedBytesPerSec / (1024 * 1024), dl.progressFraction * 100))
                            .font(Theme.mono)
                            .foregroundColor(Theme.cyan)
                    }
                }
                .padding(8)
                .background(Theme.bgDark)
                .cornerRadius(6)
            }

            HStack {
                if isLocal {
                    Button(action: {
                        vm.selectModel(id: model.id)
                    }) {
                        Text(isSelected ? "Active Model" : "Select Model")
                            .font(Theme.smallMedium)
                            .foregroundColor(isSelected ? Theme.green : Theme.fg)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(isSelected ? Theme.green.opacity(0.2) : Theme.bgDark)
                            .cornerRadius(5)
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(isSelected ? Theme.green : Theme.border, lineWidth: 1))
                    }
                    .buttonStyle(.plain)

                    Button(action: {
                        NSWorkspace.shared.open(model.localPathURL)
                    }) {
                        Image(systemName: "folder")
                            .font(Theme.small)
                            .foregroundColor(Theme.comment)
                    }
                    .buttonStyle(.plain)
                } else {
                    Button(action: {
                        Task {
                            let dest = model.localPathURL
                            try? await hf.downloadModel(
                                repoId: model.repo_id,
                                subfolder: model.subfolder,
                                destinationDir: dest,
                                onProgress: { _ in }
                            )
                            vm.refreshModels()
                        }
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.down.circle")
                            Text("Download (\(String(format: "%.1f GB", model.size_gb)))")
                        }
                        .font(Theme.smallMedium)
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Theme.blue)
                        .cornerRadius(5)
                    }
                    .buttonStyle(.plain)
                    .disabled(downloadState != nil && !(downloadState?.isComplete ?? true))
                }

                Spacer()
            }
        }
        .padding(12)
        .background(Theme.bgDark)
        .cornerRadius(6)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(isSelected ? Theme.blue : Theme.border, lineWidth: 1))
    }

    // MARK: - HuggingFace Hub View
    private var huggingFaceHubView: some View {
        VStack(spacing: 10) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(Theme.comment)
                TextField("Search Hugging Face models (e.g. minimax, yue2, mlx)...", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .font(Theme.body)
                    .foregroundColor(Theme.fg)
                    .onSubmit {
                        Task { try? await hf.searchModels(query: searchQuery) }
                    }

                if hf.isSearching {
                    ProgressView().scaleEffect(0.7)
                } else {
                    Button("Search") {
                        Task { try? await hf.searchModels(query: searchQuery) }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.blue)
                }
            }
            .padding(8)
            .background(Theme.bgFloat)
            .cornerRadius(6)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
            .padding(.horizontal, 16)
            .padding(.top, 10)

            List(hf.searchResults) { item in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(item.id)
                            .font(Theme.bodyBold)
                            .foregroundColor(Theme.fg)
                        Spacer()
                        if let dl = item.downloads {
                            Text("\(dl) downloads")
                                .font(Theme.small)
                                .foregroundColor(Theme.comment)
                        }
                        if let lk = item.likes {
                            Text("❤️ \(lk)")
                                .font(Theme.small)
                                .foregroundColor(Theme.comment)
                        }
                    }

                    if let tags = item.tags, !tags.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 4) {
                                ForEach(tags.prefix(6), id: \.self) { tag in
                                    Text(tag)
                                        .font(.system(size: 10))
                                        .foregroundColor(Theme.comment)
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 2)
                                        .background(Theme.bgDark)
                                        .cornerRadius(3)
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, 6)
            }
            .listStyle(.plain)
        }
        .onAppear {
            if hf.searchResults.isEmpty {
                Task { try? await hf.searchModels(query: "mlx music") }
            }
        }
    }
}
