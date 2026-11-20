import Darwin

/// The CPU time the calling thread has used so far. Unlike the wall clock it does not count the
/// time other tests of a parallel run hold the CPU, so a budget on it measures the work alone.
/// Only for synchronous work: an `await` can move a task to another thread.
public func threadCPUTime() -> Duration {
    var time = timespec()
    clock_gettime(CLOCK_THREAD_CPUTIME_ID, &time)
    return .seconds(time.tv_sec) + .nanoseconds(time.tv_nsec)
}

/// The CPU time `work` used on the calling thread (see `threadCPUTime()`).
public func measureCPU(_ work: () throws -> Void) rethrows -> Duration {
    let started = threadCPUTime()
    try work()
    return threadCPUTime() - started
}
