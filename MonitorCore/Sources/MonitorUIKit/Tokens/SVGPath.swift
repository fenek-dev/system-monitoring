import CoreGraphics
import Foundation
import SwiftUI

/// Minimal SVG path-data parser (M L H V C S Q T A Z, absolute + relative) → SwiftUI `Path`.
/// Used once per icon (results cached), never per frame.
public enum SVGPath {
    public static func parse(_ d: String) -> Path {
        var path = Path()
        var scanner = Tokenizer(d)
        var current = CGPoint.zero
        var start = CGPoint.zero
        var lastControl: CGPoint?
        var lastCommand: Character = " "
        var command: Character = " "

        while let token = scanner.nextCommandOrNumber() {
            if case .command(let c) = token {
                command = c
                if c == "Z" || c == "z" {
                    path.closeSubpath()
                    current = start
                    lastControl = nil
                    lastCommand = c
                    continue
                }
            } else {
                scanner.pushBack()
                // Implicit repetition; after M, implicit commands are L.
                if command == "M" { command = "L" } else if command == "m" { command = "l" }
            }
            let rel = command.isLowercase
            let base = rel ? current : .zero
            func pt() -> CGPoint? {
                guard let x = scanner.number(), let y = scanner.number() else { return nil }
                return CGPoint(x: base.x + x, y: base.y + y)
            }
            switch command.uppercased().first! {
            case "M":
                guard let p = pt() else { return path }
                path.move(to: p)
                current = p
                start = p
                lastControl = nil
            case "L":
                guard let p = pt() else { return path }
                path.addLine(to: p)
                current = p
                lastControl = nil
            case "H":
                guard let x = scanner.number() else { return path }
                current = CGPoint(x: rel ? current.x + x : x, y: current.y)
                path.addLine(to: current)
                lastControl = nil
            case "V":
                guard let y = scanner.number() else { return path }
                current = CGPoint(x: current.x, y: rel ? current.y + y : y)
                path.addLine(to: current)
                lastControl = nil
            case "C":
                guard let c1 = pt(), let c2 = pt(), let p = pt() else { return path }
                path.addCurve(to: p, control1: c1, control2: c2)
                lastControl = c2
                current = p
            case "S":
                let c1 = reflect(lastControl, around: current, if: "CcSs".contains(lastCommand))
                guard let c2 = pt(), let p = pt() else { return path }
                path.addCurve(to: p, control1: c1, control2: c2)
                lastControl = c2
                current = p
            case "Q":
                guard let c = pt(), let p = pt() else { return path }
                path.addQuadCurve(to: p, control: c)
                lastControl = c
                current = p
            case "T":
                let c = reflect(lastControl, around: current, if: "QqTt".contains(lastCommand))
                guard let p = pt() else { return path }
                path.addQuadCurve(to: p, control: c)
                lastControl = c
                current = p
            case "A":
                guard let rx = scanner.number(), let ry = scanner.number(), let rot = scanner.number(),
                      let large = scanner.flag(), let sweep = scanner.flag(), let p = pt() else { return path }
                addArc(to: &path, from: current, to: p, rx: rx, ry: ry, rotation: rot, largeArc: large, sweep: sweep)
                current = p
                lastControl = nil
            default:
                return path
            }
            lastCommand = command
        }
        return path
    }

    private static func reflect(_ control: CGPoint?, around p: CGPoint, if ok: Bool) -> CGPoint {
        guard ok, let c = control else { return p }
        return CGPoint(x: 2 * p.x - c.x, y: 2 * p.y - c.y)
    }

    /// SVG endpoint arc → center parametrization (SVG 1.1 F.6.5), emitted as cubic segments.
    static func addArc(to path: inout Path, from p0: CGPoint, to p1: CGPoint, rx rx0: Double, ry ry0: Double,
                       rotation: Double, largeArc: Bool, sweep: Bool) {
        if p0 == p1 { return }
        var rx = abs(rx0), ry = abs(ry0)
        if rx == 0 || ry == 0 {
            path.addLine(to: p1)
            return
        }
        let phi = rotation * .pi / 180
        let cosPhi = cos(phi), sinPhi = sin(phi)
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1p = cosPhi * dx + sinPhi * dy
        let y1p = -sinPhi * dx + cosPhi * dy
        let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 {
            rx *= lambda.squareRoot()
            ry *= lambda.squareRoot()
        }
        let num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
        let den = rx * rx * y1p * y1p + ry * ry * x1p * x1p
        var coef = (max(0, num) / den).squareRoot()
        if largeArc == sweep { coef = -coef }
        let cxp = coef * rx * y1p / ry
        let cyp = -coef * ry * x1p / rx
        let cx = cosPhi * cxp - sinPhi * cyp + (p0.x + p1.x) / 2
        let cy = sinPhi * cxp + cosPhi * cyp + (p0.y + p1.y) / 2

        func angle(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double {
            let a = atan2(ux * vy - uy * vx, ux * vx + uy * vy)
            return a
        }
        let theta1 = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
        var dTheta = angle((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
        if !sweep && dTheta > 0 { dTheta -= 2 * .pi } else if sweep && dTheta < 0 { dTheta += 2 * .pi }

        let segments = max(1, Int((abs(dTheta) / (.pi / 2)).rounded(.up)))
        let delta = dTheta / Double(segments)
        let t = 4.0 / 3.0 * tan(delta / 4)
        var a = theta1
        func point(_ ang: Double) -> CGPoint {
            let x = rx * cos(ang), y = ry * sin(ang)
            return CGPoint(x: cosPhi * x - sinPhi * y + cx, y: sinPhi * x + cosPhi * y + cy)
        }
        func deriv(_ ang: Double) -> CGPoint {
            let x = -rx * sin(ang), y = ry * cos(ang)
            return CGPoint(x: cosPhi * x - sinPhi * y, y: sinPhi * x + cosPhi * y)
        }
        for i in 0..<segments {
            let b = a + delta
            let s = point(a), e = i == segments - 1 ? p1 : point(b)
            let d1 = deriv(a), d2 = deriv(b)
            path.addCurve(to: e,
                          control1: CGPoint(x: s.x + t * d1.x, y: s.y + t * d1.y),
                          control2: CGPoint(x: e.x - t * d2.x, y: e.y - t * d2.y))
            a = b
        }
    }

    private struct Tokenizer {
        enum Token { case command(Character), number }
        let chars: [Character]
        var i = 0
        var lastStart = 0

        init(_ s: String) { chars = Array(s) }

        mutating func skipSeparators() {
            while i < chars.count, chars[i] == " " || chars[i] == "," || chars[i] == "\n" || chars[i] == "\t" { i += 1 }
        }

        mutating func nextCommandOrNumber() -> Token? {
            skipSeparators()
            guard i < chars.count else { return nil }
            lastStart = i
            let c = chars[i]
            if c.isLetter && c != "e" && c != "E" {
                i += 1
                return .command(c)
            }
            return .number
        }

        mutating func pushBack() { i = lastStart }

        mutating func flag() -> Bool? {
            skipSeparators()
            guard i < chars.count else { return nil }
            let c = chars[i]
            guard c == "0" || c == "1" else { return nil }
            i += 1
            return c == "1"
        }

        mutating func number() -> Double? {
            skipSeparators()
            guard i < chars.count else { return nil }
            var s = ""
            var seenDot = false, seenExp = false
            if chars[i] == "-" || chars[i] == "+" {
                s.append(chars[i])
                i += 1
            }
            while i < chars.count {
                let c = chars[i]
                if c.isNumber {
                    s.append(c)
                } else if c == "." && !seenDot && !seenExp {
                    seenDot = true
                    s.append(c)
                } else if (c == "e" || c == "E") && !seenExp {
                    seenExp = true
                    s.append(c)
                    if i + 1 < chars.count, chars[i + 1] == "-" || chars[i + 1] == "+" {
                        i += 1
                        s.append(chars[i])
                    }
                } else {
                    break
                }
                i += 1
            }
            return Double(s)
        }
    }
}
