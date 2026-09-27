import Foundation

/// A FIFO with no writer parks `open()` for reading, the way a TCC-denied folder or a stalled share does.
public enum FIFOFixture {
    /// Opened read-write, then unlinked: a parked or later `open()` either goes through or fails, never outliving the test.
    public static func release(_ url: URL) {
        let descriptor = open(url.path, O_RDWR | O_NONBLOCK)
        unlink(url.path)
        if descriptor >= 0 { close(descriptor) }
    }
}
