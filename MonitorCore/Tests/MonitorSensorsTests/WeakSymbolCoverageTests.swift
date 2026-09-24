import Foundation
import Testing

/// S-I1: every `weak_import` private symbol that Swift code calls must be checked by its header's
/// `tt_*_available()`. A symbol missing from the check resolves to NULL on a future macOS and crashes the sampler
/// (a crash loop, since the canary is already cleared) instead of making the sensor `.unavailable`.
/// Source-level check over `CPrivate/include/*.h` and every Swift file under `Sources/` and `App/`.
struct WeakSymbolCoverageTests {
    static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// Declared weak symbols of one header (function names and extern constants).
    static func weakSymbols(in header: String) -> [String] {
        let fnName = try! NSRegularExpression(pattern: #"([A-Za-z_]\w*)\s*\("#)
        let lastIdent = try! NSRegularExpression(pattern: #"([A-Za-z_]\w*)\s*$"#)
        var out: [String] = []
        for decl in header.components(separatedBy: ";") where decl.contains("__attribute__((weak_import))") {
            // Declarations are one line each: take that line, not the comments/macros before it.
            let line = decl.components(separatedBy: "\n").last { $0.contains("__attribute__((weak_import))") } ?? decl
            let head = String(line[..<line.range(of: "__attribute__((weak_import))")!.lowerBound])
            let ns = head as NSString
            if let m = fnName.firstMatch(in: head, range: NSRange(location: 0, length: ns.length)) {
                out.append(ns.substring(with: m.range(at: 1)))
            } else if let m = lastIdent.firstMatch(in: head, range: NSRange(location: 0, length: ns.length)) {
                out.append(ns.substring(with: m.range(at: 1)))
            }
        }
        return out
    }

    /// Symbols tested (`&name != NULL`) inside the header's `tt_*_available()` functions.
    static func checkedSymbols(in header: String) -> Set<String> {
        let body = try! NSRegularExpression(pattern: #"tt_\w+_available\s*\(void\)\s*\{(.*?)\}"#,
                                            options: .dotMatchesLineSeparators)
        let addr = try! NSRegularExpression(pattern: #"&\s*([A-Za-z_]\w*)"#)
        let ns = header as NSString
        var out = Set<String>()
        for m in body.matches(in: header, range: NSRange(location: 0, length: ns.length)) {
            let b = ns.substring(with: m.range(at: 1))
            let bns = b as NSString
            for a in addr.matches(in: b, range: NSRange(location: 0, length: bns.length)) {
                out.insert(bns.substring(with: a.range(at: 1)))
            }
        }
        return out
    }

    /// Every identifier-like token in the Swift sources (comments included: stricter, never weaker).
    static func swiftIdentifiers() throws -> Set<Substring> {
        var out = Set<Substring>()
        for dir in [packageRoot.appendingPathComponent("Sources"),
                    packageRoot.deletingLastPathComponent().appendingPathComponent("App")] {
            guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in e where url.pathExtension == "swift" {
                let text = try String(contentsOf: url, encoding: .utf8)
                out.formUnion(text.split { !($0.isLetter || $0.isNumber || $0 == "_") })
            }
        }
        return out
    }

    @Test func parserFindsDeclarations() {
        let h = """
        void A(int x, void (^b)(void)) __attribute__((weak_import));
        extern const CFStringRef kKey __attribute__((weak_import));
        static inline bool tt_x_available(void) { return &A != NULL; }
        """
        #expect(Self.weakSymbols(in: h) == ["A", "kKey"])
        #expect(Self.checkedSymbols(in: h) == ["A"])
    }

    @Test func everyWeakSymbolCalledFromSwiftIsAvailabilityChecked() throws {
        let include = Self.packageRoot.appendingPathComponent("Sources/CPrivate/include")
        let headers = try FileManager.default.contentsOfDirectory(at: include, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "h" }
        let swift = try Self.swiftIdentifiers()
        var declared = 0, used = 0
        var uncovered: [String] = []
        for h in headers {
            let text = try String(contentsOf: h, encoding: .utf8)
            let weak = Self.weakSymbols(in: text)
            declared += weak.count
            let checked = Self.checkedSymbols(in: text)
            for name in weak where swift.contains(Substring(name)) {
                used += 1
                if !checked.contains(name) { uncovered.append("\(h.lastPathComponent): \(name)") }
            }
        }
        #expect(declared >= 30, "parser found only \(declared) weak declarations")
        #expect(used >= 25, "only \(used) weak symbols referenced from Swift — parser or source scan broken?")
        #expect(uncovered.isEmpty, "weak symbols called from Swift but not in tt_*_available(): \(uncovered)")
    }
}
