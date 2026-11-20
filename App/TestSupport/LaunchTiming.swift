#if DEBUG || UITEST_HOOKS
    import Darwin
    import Foundation

    /// How long the launch took, for the launch performance test: from the process's start (the
    /// kernel's record of it) to now.
    enum LaunchTiming {
        static func millisecondsSinceProcessStart() -> Double? {
            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.stride
            var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
            guard sysctl(&name, u_int(name.count), &info, &size, nil, 0) == 0, size > 0 else {
                return nil
            }
            let start = info.kp_proc.p_un.__p_starttime
            let started = Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000
            return (Date().timeIntervalSince1970 - started) * 1000
        }
    }
#endif
