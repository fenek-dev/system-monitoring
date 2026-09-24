import MonitorModel
import SwiftUI

/// Banner (MenuBarAlert@2x, inside the popover at (74, 87)), confirm dialog, toast.
@MainActor enum GalleryOverlays {
    static var items: [TTGallery.Item] {
        [
            .init(id: "alert-banner", size: CGSize(width: 348, height: 96)) { AnyView(BannerSample()) },
            .init(id: "confirm-dialog", size: CGSize(width: 640, height: 260)) { AnyView(DialogSample()) },
            .init(id: "toast", size: CGSize(width: 240, height: 28)) { AnyView(ToastSample()) },
        ]
    }
}

private struct BannerSample: View {
    var body: some View {
        TTAlertBanner(title: "Thermal pressure: Fair",
                      message: "Final Cut Pro is pushing the SoC to 85°C. Performance cores may slow down to cool off.",
                      level: .elevated,
                      actions: [BannerAction(id: "show", title: "Show Thermals") {},
                                BannerAction(id: "quit", title: "Quit Final Cut Pro") {}])
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color(hex: 0x28282C))
    }
}

private struct DialogSample: View {
    var body: some View {
        ZStack {
            TTColor.bgWindow
            TTConfirmDialog(title: "Force quit “Final Cut Pro”?",
                            message: "Unsaved changes will be lost. The process ends immediately without cleanup.",
                            confirmTitle: "Force Quit", onConfirm: {}, onCancel: {})
        }
    }
}

private struct ToastSample: View {
    var body: some View {
        TTToast("Final Cut Pro was force quit.")
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(TTColor.bgCard)
    }
}
