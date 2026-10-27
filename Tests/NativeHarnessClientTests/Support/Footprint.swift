import Darwin
import Foundation

/// The test process's physical memory footprint, what Activity Monitor shows as its memory.
enum Footprint {
    static func current() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    /// The largest footprint seen while work runs, sampled every 2 ms from its own thread.
    final class Sampler: @unchecked Sendable {
        private let lock = NSLock()
        private var peak: UInt64 = Footprint.current()
        private var running = true

        init() {
            let thread = Thread { [self] in
                while lock.withLock({ running }) {
                    let now = Footprint.current()
                    lock.withLock { peak = max(peak, now) }
                    usleep(2_000)
                }
            }
            thread.start()
        }

        /// Stops sampling and returns the peak.
        func stop() -> UInt64 {
            let now = Footprint.current()
            return lock.withLock {
                running = false
                peak = max(peak, now)
                return peak
            }
        }
    }
}
