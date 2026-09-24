import MonitorModel
import SwiftUI

// W0b placeholder (ARCHITECTURE §5.12). W3 replaces this file with every DESIGN §1.1 token.

public enum TTColor {
    public static func category(_ c: MonitorModel.Category) -> Color { .gray }
    public static func level(_ l: AlertLevel) -> Color { .gray }
}
