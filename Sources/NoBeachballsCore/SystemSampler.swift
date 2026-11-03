import Darwin
import Foundation

/// Samples CPU, memory, swap and thermal state. Not thread-safe; call from one serial queue.
public final class SystemSampler {
    private var previousTicks: [[UInt32]] = []
    private var previousSwapIns: UInt64 = 0
    private var previousSwapOuts: UInt64 = 0
    private var previousTime: UInt64 = 0
    // mach_host_self() acquires a send right on every call. Reuse one for the sampler's lifetime.
    private let host = mach_host_self()
    private let pageSize: UInt64
    private let memTotal: UInt64

    public init() {
        pageSize = UInt64(Self.sysctlInt("hw.pagesize") ?? 16384)
        memTotal = UInt64(Self.sysctlInt("hw.memsize") ?? 0)
    }

    deinit {
        mach_port_deallocate(mach_task_self_, host)
    }

    public func sample() -> SystemSample {
        let now = DispatchTime.now().uptimeNanoseconds
        let seconds = previousTime == 0 ? 0 : Double(now - previousTime) / 1e9
        previousTime = now

        let perCore = sampleCores()
        let cpuTotal = perCore.isEmpty ? 0 : perCore.reduce(0, +) / Double(perCore.count)

        var load = [Double](repeating: 0, count: 3)
        getloadavg(&load, 3)

        var vm = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        _ = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        let app = UInt64(vm.internal_page_count &- vm.purgeable_count) * pageSize
        let wired = UInt64(vm.wire_count) * pageSize
        let compressed = UInt64(vm.compressor_page_count) * pageSize

        var swapInRate = 0.0
        var swapOutRate = 0.0
        if seconds > 0, previousSwapOuts > 0 || previousSwapIns > 0 {
            swapInRate = Double(vm.swapins &- previousSwapIns) * Double(pageSize) / seconds
            swapOutRate = Double(vm.swapouts &- previousSwapOuts) * Double(pageSize) / seconds
        }
        previousSwapIns = vm.swapins
        previousSwapOuts = vm.swapouts

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0)

        let pressureRaw = Self.sysctlInt("kern.memorystatus_vm_pressure_level") ?? 1
        let pressure = MemoryPressure(rawValue: pressureRaw) ?? (pressureRaw >= 4 ? .critical : .normal)

        return SystemSample(
            timestamp: Date(),
            cpuTotal: cpuTotal,
            perCore: perCore,
            loadAverage: load,
            coreCount: perCore.count,
            memTotal: memTotal,
            memUsed: app + wired + compressed,
            memApp: app,
            memWired: wired,
            memCompressed: compressed,
            memAvailablePercent: Self.sysctlInt("kern.memorystatus_level") ?? 100,
            pressure: pressure,
            swapUsed: swap.xsu_used,
            swapTotal: swap.xsu_total,
            swapOutRate: max(swapOutRate, 0),
            swapInRate: max(swapInRate, 0),
            thermalState: ProcessInfo.processInfo.thermalState.rawValue
        )
    }

    private func sampleCores() -> [Double] {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let info else { return [] }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }

        let states = Int(CPU_STATE_MAX)
        var ticks: [[UInt32]] = []
        var usage: [Double] = []
        for core in 0..<Int(cpuCount) {
            let current = (0..<states).map { UInt32(bitPattern: info[core * states + $0]) }
            ticks.append(current)
            guard core < previousTicks.count else {
                usage.append(0)
                continue
            }
            let delta = zip(current, previousTicks[core]).map { Double($0 &- $1) }
            let total = delta.reduce(0, +)
            let idle = delta[Int(CPU_STATE_IDLE)]
            usage.append(total > 0 ? (total - idle) / total : 0)
        }
        previousTicks = ticks
        return usage
    }

    static func sysctlInt(_ name: String) -> Int? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        switch size {
        case 4: return Int(Int32(truncatingIfNeeded: value))
        default: return Int(value)
        }
    }
}
