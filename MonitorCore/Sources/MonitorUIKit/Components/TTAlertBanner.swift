import MonitorModel
import SwiftUI

// W0b placeholder (ARCHITECTURE §5.12). W3 replaces this file.

public struct TTAlertBanner: View {
    public init(title: String, message: String, level: AlertLevel, actions: [BannerAction]) {}

    public var body: some View { EmptyView() }
}

public struct BannerAction: Identifiable {
    public var id: String
    public var title: String
    public var role: ButtonRole?
    public var perform: @MainActor () -> Void

    public init(id: String, title: String, role: ButtonRole? = nil, perform: @escaping @MainActor () -> Void) {
        self.id = id
        self.title = title
        self.role = role
        self.perform = perform
    }
}
