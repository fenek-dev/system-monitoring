// W0b stub (ARCHITECTURE §5.6). W1 replaces this file.

public struct CrashCanary: Sendable {
    public static let standard = CrashCanary()
    public static let none = CrashCanary()
}
