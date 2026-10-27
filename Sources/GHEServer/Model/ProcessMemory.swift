import Darwin
import Foundation

/// Process memory for the status bar (the real footprint).
enum ProcessMemory {
    /// Physical footprint in bytes, as Activity Monitor's "Memory" column shows it.
    static func footprint() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? info.phys_footprint : nil
    }

    static var text: String {
        guard let b = footprint() else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .memory)
    }
}
