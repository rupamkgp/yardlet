// Samples a process tree with proc_pid_rusage: physical footprint, resident size, CPU time and
// wakeups, twice over an interval, and prints one JSON object.
// usage: sampler <root pid> <label> [interval seconds]
import Darwin
import Foundation

let arguments = CommandLine.arguments
guard arguments.count >= 3, let root = pid_t(arguments[1]) else {
    FileHandle.standardError.write("usage: sampler <root pid> <label> [interval]\n".data(using: .utf8)!)
    exit(2)
}
let label = arguments[2]
let interval = arguments.count > 3 ? Double(arguments[3]) ?? 3 : 3

func children(of pid: pid_t) -> [pid_t] {
    var buffer = [pid_t](repeating: 0, count: 512)
    let count = proc_listchildpids(pid, &buffer, Int32(buffer.count * MemoryLayout<pid_t>.size))
    guard count > 0 else { return [] }
    return Array(buffer.prefix(Int(count)))
}

func tree(_ pid: pid_t) -> [pid_t] {
    [pid] + children(of: pid).flatMap(tree)
}

func path(_ pid: pid_t) -> String {
    var buffer = [CChar](repeating: 0, count: 4096)
    let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
    guard length > 0 else { return "?" }
    return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

struct Usage {
    let footprint: UInt64
    let resident: UInt64
    let cpuNanoseconds: UInt64
    let idleWakeups: UInt64
    let interruptWakeups: UInt64
}

func usage(_ pid: pid_t) -> Usage? {
    var info = rusage_info_v4()
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
            proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
        }
    }
    guard result == 0 else { return nil }
    var timebase = mach_timebase_info_data_t()
    mach_timebase_info(&timebase)
    let cpu = (info.ri_user_time + info.ri_system_time) * UInt64(timebase.numer) / UInt64(timebase.denom)
    return Usage(footprint: info.ri_phys_footprint, resident: info.ri_resident_size,
                 cpuNanoseconds: cpu, idleWakeups: info.ri_pkg_idle_wkups,
                 interruptWakeups: info.ri_interrupt_wkups)
}

let first = Dictionary(uniqueKeysWithValues: tree(root).compactMap { pid in usage(pid).map { (pid, $0) } })
Thread.sleep(forTimeInterval: interval)
let pids = tree(root)
var processes: [[String: Any]] = []
var totalFootprint: UInt64 = 0
for pid in pids {
    guard let now = usage(pid) else { continue }
    totalFootprint += now.footprint
    var entry: [String: Any] = [
        "pid": pid,
        "path": path(pid),
        "footprintMiB": Double(now.footprint) / 1_048_576,
        "residentMiB": Double(now.resident) / 1_048_576
    ]
    if let before = first[pid] {
        entry["cpuPercent"] = Double(now.cpuNanoseconds - before.cpuNanoseconds) / (interval * 1e9) * 100
        entry["wakeupsPerSecond"] = Double((now.idleWakeups + now.interruptWakeups)
            - (before.idleWakeups + before.interruptWakeups)) / interval
    }
    processes.append(entry)
}
let output: [String: Any] = [
    "label": label,
    "rootPid": root,
    "processCount": processes.count,
    "totalFootprintMiB": Double(totalFootprint) / 1_048_576,
    "intervalSeconds": interval,
    "processes": processes
]
let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
print(String(decoding: data, as: UTF8.self))
