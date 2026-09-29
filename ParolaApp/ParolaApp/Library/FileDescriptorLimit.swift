import Darwin

/// A GUI app starts with 256 descriptors, and a watched folder holds one for every folder inside it.
enum FileDescriptorLimit {
    static let ceiling: rlim_t = 10_240

    @discardableResult
    static func raise() -> rlim_t? {
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else { return nil }
        let target = min(limit.rlim_max, ceiling)
        guard limit.rlim_cur < target else { return limit.rlim_cur }
        limit.rlim_cur = target
        return setrlimit(RLIMIT_NOFILE, &limit) == 0 ? target : nil
    }
}
