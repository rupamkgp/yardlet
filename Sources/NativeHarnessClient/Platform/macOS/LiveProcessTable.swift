import Darwin
import Foundation

/// The macOS process table through libproc: `proc_listallpids` for the running processes,
/// `proc_pidinfo(PROC_PIDTBSDINFO)` for each one's parent and start, and `proc_pid_rusage` for what
/// a counted process has used.
///
/// `proc_pid_rusage` (`RUSAGE_INFO_V2`) is used for usage instead of `PROC_PIDTASKINFO`: besides the
/// process's own user and system time it has the CPU time of the children the process collected
/// (`ri_child_user_time`, `ri_child_system_time`), which keeps commands that start and end between
/// samples in the count, and the memory footprint (`ri_phys_footprint`) that Activity Monitor's
/// Memory column shows, where resident size counts shared pages once per process. Its times are in
/// Mach absolute time units, as `PROC_PIDTASKINFO`'s are (nanoseconds on Intel, 125/3 ns per unit on
/// Apple silicon), converted here with the timebase.
struct LiveProcessTable: ProcessTableReading {
    private let timebaseNumerator: UInt64
    private let timebaseDenominator: UInt64

    init() {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        timebaseNumerator = UInt64(max(timebase.numer, 1))
        timebaseDenominator = UInt64(max(timebase.denom, 1))
    }

    func entries() -> [ProcessTableEntry] {
        let needed = proc_listallpids(nil, 0)
        guard needed > 0 else { return [] }
        // Room for processes that start between the two calls.
        var pids = [pid_t](repeating: 0, count: Int(needed) + 64)
        let count = pids.withUnsafeMutableBytes { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count))
        }
        guard count > 0 else { return [] }

        var entries: [ProcessTableEntry] = []
        entries.reserveCapacity(Int(count))
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        for pid in pids.prefix(Int(count)) where pid > 0 {
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { continue }
            entries.append(ProcessTableEntry(
                processID: pid,
                parentID: pid_t(bitPattern: info.pbi_ppid),
                startMicroseconds: Int64(info.pbi_start_tvsec) * 1_000_000 + Int64(info.pbi_start_tvusec)
            ))
        }
        return entries
    }

    func usage(of processID: Int32) -> ProcessUsageReading? {
        var info = rusage_info_v2()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(processID, RUSAGE_INFO_V2, $0)
            }
        }
        guard result == 0 else { return nil }
        return ProcessUsageReading(
            cpuNanoseconds: nanoseconds(info.ri_user_time &+ info.ri_system_time),
            endedChildrenCPUNanoseconds: nanoseconds(info.ri_child_user_time &+ info.ri_child_system_time),
            memoryBytes: info.ri_phys_footprint
        )
    }

    private func nanoseconds(_ machTime: UInt64) -> UInt64 {
        let (high, low) = machTime.multipliedFullWidth(by: timebaseNumerator)
        guard high < timebaseDenominator else { return .max }
        return timebaseDenominator.dividingFullWidth((high, low)).quotient
    }
}
