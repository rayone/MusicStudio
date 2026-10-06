import Foundation
import Metal

public struct SystemProfile: Equatable {
    public let physicalMemoryBytes: UInt64
    public let physicalMemoryGB: Double
    public let usableGPUBudgetGB: Double
    public let chipName: String
    public let performanceCores: Int
    public let metalWorkingSetLimitBytes: UInt64
    public let hasUnifiedMemory: Bool
    public let wiredLimitMB: UInt64?

    public static let current: SystemProfile = {
        // Physical memory
        var memSize: UInt64 = 0
        var len = MemoryLayout<UInt64>.size
        if sysctlbyname("hw.memsize", &memSize, &len, nil, 0) != 0 {
            memSize = ProcessInfo.processInfo.physicalMemory
        }
        let memGB = Double(memSize) / 1_073_741_824.0

        // Usable memory formula: min(0.85 * RAM, RAM - 4.0 GB)
        let usableGB = max(1.0, min(0.85 * memGB, memGB - 4.0))

        // CPU Brand String
        var brand = "Apple Silicon"
        var brandLen = 0
        if sysctlbyname("machdep.cpu.brand_string", nil, &brandLen, nil, 0) == 0 && brandLen > 0 {
            var brandBuf = [CChar](repeating: 0, count: brandLen)
            if sysctlbyname("machdep.cpu.brand_string", &brandBuf, &brandLen, nil, 0) == 0 {
                brand = String(cString: brandBuf).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        // Logical Perf Cores
        var pCores: Int32 = 0
        var pCoresLen = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel0.logicalcpu", &pCores, &pCoresLen, nil, 0) != 0 {
            pCores = Int32(ProcessInfo.processInfo.processorCount)
        }

        // Wired limit if present
        var wiredMB: UInt64 = 0
        var wiredLen = MemoryLayout<UInt64>.size
        var wiredVal: UInt64? = nil
        if sysctlbyname("iogpu.wired_limit_mb", &wiredMB, &wiredLen, nil, 0) == 0 && wiredMB > 0 {
            wiredVal = wiredMB
        }

        // Metal default device
        let metalDev = MTLCreateSystemDefaultDevice()
        let metalLimit = metalDev?.recommendedMaxWorkingSetSize ?? memSize
        let unified = metalDev?.hasUnifiedMemory ?? true

        return SystemProfile(
            physicalMemoryBytes: memSize,
            physicalMemoryGB: memGB,
            usableGPUBudgetGB: usableGB,
            chipName: brand,
            performanceCores: Int(pCores),
            metalWorkingSetLimitBytes: metalLimit,
            hasUnifiedMemory: unified,
            wiredLimitMB: wiredVal
        )
    }()

    public var memoryDisplay: String {
        let rounded = Int(round(physicalMemoryGB))
        return "\(rounded) GB"
    }

    public var recommendedMiniMaxVariant: String? {
        if physicalMemoryGB < 14.0 {
            return nil // Unsupported
        } else if physicalMemoryGB < 22.0 {
            return "4bit"
        } else if physicalMemoryGB < 30.0 {
            return "6bit"
        } else if physicalMemoryGB < 60.0 {
            return "mxfp8"
        } else if physicalMemoryGB < 90.0 {
            return "8bit"
        } else {
            return "bf16"
        }
    }

    public var recommendedYuE2Variant: String {
        if physicalMemoryGB < 22.0 {
            return "4bit"
        } else if physicalMemoryGB < 44.0 {
            return "8bit"
        } else {
            return "bf16"
        }
    }

    public func recommendationBadge(for family: ModelFamily) -> String {
        switch family {
        case .minimax_music3:
            if let variant = recommendedMiniMaxVariant {
                return "✨ Recommended for \(memoryDisplay): \(variant)"
            } else {
                return "⚠️ \(memoryDisplay) RAM below 16 GB minimum"
            }
        case .yue2:
            let variant = recommendedYuE2Variant
            return "✨ Recommended for \(memoryDisplay): \(variant)"
        }
    }

    public var tierNotes: String {
        if physicalMemoryGB >= 90.0 {
            return "Host has \(memoryDisplay) unified memory. Uncompressed bf16 models recommended for maximum acoustic fidelity with zero memory pressure."
        } else if physicalMemoryGB >= 44.0 {
            return "Host has \(memoryDisplay) unified memory. YuE2 bf16 and MiniMax 8bit/mxfp8 operate with high fidelity and generous headroom."
        } else if physicalMemoryGB >= 28.0 {
            return "Host has \(memoryDisplay) unified memory. mxfp8 and 8bit offer near-lossless acoustic fidelity and fast decode."
        } else if physicalMemoryGB >= 14.0 {
            return "Host has \(memoryDisplay) unified memory. 4bit quantization recommended to ensure smooth generation without memory pressure."
        } else {
            return "Host has \(memoryDisplay) unified memory. High memory pressure risk; 4bit YuE2 supported with clamped generation lengths."
        }
    }
}
