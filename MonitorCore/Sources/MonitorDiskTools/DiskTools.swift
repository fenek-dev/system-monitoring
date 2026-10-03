import os

/// Storage scan / classify / clean engine (ICR 018). Foundation + Darwin only: anything AppKit-bound arrives as
/// `StoragePlatform` closures. Every filesystem step under a scan root goes through `TrustedRoot`.
public enum DiskTools {
    /// One line per detached / trashed / evicted path (spec §7.4), plus probe and cleanup failures.
    public static let log = Logger(subsystem: "dev.telltale", category: "storage")
}
