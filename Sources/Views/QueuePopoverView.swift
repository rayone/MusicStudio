import SwiftUI

public struct QueuePopoverView: View {
    @ObservedObject var vm: StudioViewModel

    public init(vm: StudioViewModel) {
        self.vm = vm
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "list.bullet.rectangle.fill")
                        .foregroundColor(Theme.blue)
                    Text("GENERATION QUEUE (\(vm.queueJobs.count))")
                        .font(Theme.smallBold)
                        .foregroundColor(Theme.fg)
                }

                Spacer()

                if vm.queueJobs.contains(where: { $0.status == "queued" || $0.status == "running" }) {
                    Button(action: {
                        if vm.isQueuePaused { vm.resumeQueue() }
                        else { vm.pauseQueue() }
                    }) {
                        Image(systemName: vm.isQueuePaused ? "play.fill" : "pause.fill")
                            .foregroundColor(vm.isQueuePaused ? Theme.green : Theme.yellow)
                    }
                    .buttonStyle(.plain)
                    .help(vm.isQueuePaused ? "Resume queue" : "Pause queue")

                    Button(action: { vm.clearQueue() }) {
                        Image(systemName: "trash.fill")
                            .foregroundColor(Theme.red)
                    }
                    .buttonStyle(.plain)
                    .help("Permanently remove every pending item")
                }
                if vm.queueJobs.contains(where: { $0.status == "error" }) {
                    Button(action: { vm.dismissFailedJobs() }) {
                        Image(systemName: "trash.fill").foregroundColor(Theme.red)
                    }
                    .buttonStyle(.plain)
                    .help("Dismiss failed jobs")
                }
            }

            // Queue-total ETA: finish clock while active; duration remaining while paused.
            if !vm.queueJobs.isEmpty && !vm.queueFinishEtaString.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: vm.isQueuePaused ? "pause.circle.fill" : "clock.fill")
                        .font(.system(size: 10))
                        .foregroundColor(vm.isQueuePaused ? Theme.yellow : Theme.blue)
                    Text(vm.isQueuePaused ? vm.queueFinishEtaString : "All done \(vm.queueFinishEtaString)")
                        .font(Theme.mono)
                        .foregroundColor(vm.isQueuePaused ? Theme.yellow : Theme.blue)
                }
            }

            Divider().background(Theme.border)

            if vm.queueJobs.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray")
                        .font(.system(size: 24))
                        .foregroundColor(Theme.comment)
                    Text("Queue is empty. Generations will appear here.")
                        .font(Theme.small)
                        .foregroundColor(Theme.comment)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(Array(vm.queueJobs.enumerated()), id: \.element.id) { idx, job in
                            let isRunning = job.status == "running"
                            let isFailed = job.status == "error"
                            // Cumulative wall-clock until THIS job finishes: the running/first
                            // job's live-or-full estimate plus a full estimate for each job ahead.
                            let rowEta = cumulativeEta(upToIndex: idx)
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 8) {
                                    Image(systemName: isFailed ? "exclamationmark.triangle.fill" : (isRunning ? "waveform.circle.fill" : "clock.badge.plus"))
                                        .foregroundColor(isFailed ? Theme.red : (isRunning ? Theme.green : Theme.blue))
                                        .font(Theme.small)

                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 6) {
                                            Text("#\(job.id)")
                                                .font(Theme.mono)
                                                .foregroundColor(Theme.cyan)
                                            Text(isFailed ? "FAILED" : (isRunning ? "RUNNING" : "QUEUED"))
                                                .font(.system(size: 9, weight: .bold))
                                                .foregroundColor(isFailed ? Theme.red : (isRunning ? Theme.green : Theme.blue))
                                                .padding(.horizontal, 4)
                                                .padding(.vertical, 1)
                                                .background((isFailed ? Theme.red : (isRunning ? Theme.green : Theme.blue)).opacity(0.15))
                                                .cornerRadius(3)
                                            Text(job.model)
                                                .font(Theme.small)
                                                .foregroundColor(Theme.comment)
                                        }
                                        Text(job.title)
                                            .font(Theme.small)
                                            .foregroundColor(Theme.fg)
                                            .lineLimit(1)
                                        if isFailed, let error = job.error {
                                            Text(error)
                                                .font(.system(size: 9, design: .monospaced))
                                                .foregroundColor(Theme.red)
                                                .lineLimit(3)
                                                .help(error)
                                        }
                                    }

                                    Spacer()

                                    VStack(alignment: .trailing, spacing: 2) {
                                        Text(isFailed
                                             ? "Needs attention"
                                             : (isRunning
                                                ? (vm.isEtaOverrun ? "Finishing…" : "~\(StudioViewModel.humanDuration(vm.liveRemainingSeconds)) left")
                                                : "in ~\(StudioViewModel.humanDuration(rowEta))"))
                                            .font(Theme.mono)
                                            .foregroundColor(isFailed ? Theme.red : (isRunning ? Theme.green : Theme.comment))
                                            .frame(width: 90, alignment: .trailing)
                                        Text("\(Int(job.duration))s • \(job.steps)st")
                                            .font(.system(size: 9, design: .monospaced))
                                            .foregroundColor(Theme.comment)
                                    }

                                    Button(action: { vm.stopJob(id: job.id, isRunning: isRunning) }) {
                                        Image(systemName: isRunning ? "stop.circle.fill" : (isFailed ? "xmark.circle.fill" : "trash.circle.fill"))
                                            .font(Theme.small)
                                            .foregroundColor(Theme.red)
                                            .frame(width: 28, height: 28)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .help(isRunning ? "Stop and remove this running job" : (isFailed ? "Dismiss failed job" : "Remove this queued job"))
                                }

                                // Live progress bar for the running song only.
                                if isRunning {
                                    ProgressView(value: vm.liveProgressFraction)
                                        .tint(Theme.green)
                                    HStack {
                                        Text(vm.liveStage.isEmpty ? "Working…" : vm.liveStage)
                                            .font(.system(size: 9, design: .monospaced))
                                            .foregroundColor(Theme.cyan)
                                        Spacer()
                                        Text(vm.isEtaOverrun ? "99%+" : "\(Int(vm.liveProgressFraction * 100))%")
                                            .font(.system(size: 9, design: .monospaced))
                                            .foregroundColor(Theme.green)
                                    }
                                }
                            }
                            .padding(8)
                            .background(isFailed ? Theme.red.opacity(0.06) : Theme.bgDark)
                            .cornerRadius(6)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke((isFailed ? Theme.red : (isRunning ? Theme.green : Theme.border)).opacity(0.5), lineWidth: 1))
                        }
                    }
                }
                .frame(maxHeight: 260)
            }
        }
        .padding(12)
        .frame(width: 420)
        .background(Theme.bgFloat)
    }

    /// Cumulative wall-clock seconds until the job at `index` finishes: the running/first
    /// job's live-or-full remaining, plus a full per-model estimate for each job ahead of it.
    private func cumulativeEta(upToIndex index: Int) -> Double {
        var total = 0.0
        for i in 0...index {
            let job = vm.queueJobs[i]
            if job.status == "error" { continue }
            if job.status == "running" {
                total += vm.liveRemainingSeconds > 0 ? vm.liveRemainingSeconds
                                                     : vm.estimateSongSeconds(modelId: job.modelId, audioDuration: job.duration)
            } else {
                total += vm.estimateSongSeconds(modelId: job.modelId, audioDuration: job.duration)
            }
        }
        return total
    }
}
