import Darwin
import Testing
@testable import Parola

@Suite("File descriptor limit")
struct FileDescriptorLimitTests {
    @Test("launch raises the open-file limit to 10,240 or the hard limit, whichever is lower")
    func raisesTheSoftLimit() throws {
        let raised = try #require(FileDescriptorLimit.raise())
        var limit = rlimit()
        #expect(getrlimit(RLIMIT_NOFILE, &limit) == 0)
        #expect(limit.rlim_cur == raised)
        #expect(limit.rlim_cur >= min(limit.rlim_max, FileDescriptorLimit.ceiling))
    }
}
