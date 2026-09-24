import AppKit
import Foundation
import MonitorMocks
import MonitorScreens
import MonitorUIKit
import SwiftUI

// telltale-render: offscreen @2x renders of screens (ScreenCatalog × MockScenario) and UIKit gallery items,
// plus side-by-side comparison sheets against the design reference PNGs (ARCHITECTURE §8 "Design verification").

let usage = """
usage: telltale-render [options]
  --list                          list screens, scenarios and gallery components
  --screen <id> [--scenario <s>]  render one screen (default scenario: calm)
  --all [--scenario <s>]          render every screen (into --out directory)
  --gallery                       render the component gallery sheet
  --component <id>                render one gallery component
  --image <png>                   use an existing PNG as "ours" (with --compare)
  --compare <ref.png>             write [reference | ours | 50% overlay] instead of the render
  --crop x,y,w,h                  crop (points, @2x applied) before writing/comparing
  --path hosting|imageRenderer    render path (default hosting)
  --out <path>                    output file (or directory with --all); default .build/renders/<name>.png
"""

struct Options {
    var list = false, all = false, gallery = false
    var screen: String?, scenario = "calm", component: String?, image: String?, compare: String?, out: String?
    var crop: CGRect?
    var path: SnapshotRenderer.Path = .hosting
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(2)
}

func parse(_ args: [String]) -> Options {
    var o = Options()
    var i = 0
    func value() -> String {
        i += 1
        guard i < args.count else { fail("missing value for \(args[i - 1])\n\(usage)") }
        return args[i]
    }
    while i < args.count {
        switch args[i] {
        case "--list": o.list = true
        case "--all": o.all = true
        case "--gallery": o.gallery = true
        case "--screen": o.screen = value()
        case "--scenario": o.scenario = value()
        case "--component": o.component = value()
        case "--image": o.image = value()
        case "--compare": o.compare = value()
        case "--out": o.out = value()
        case "--crop":
            let parts = value().split(separator: ",").compactMap { Double($0) }
            guard parts.count == 4 else { fail("--crop expects x,y,w,h") }
            o.crop = CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
        case "--path":
            o.path = value() == "imageRenderer" ? .imageRenderer : .hosting
        case "-h", "--help":
            print(usage)
            exit(0)
        default: fail("unknown option \(args[i])\n\(usage)")
        }
        i += 1
    }
    return o
}

@MainActor func renderScreen(_ id: String, scenario: String, path: SnapshotRenderer.Path) -> CGImage {
    guard let entry = ScreenCatalog.entries.first(where: { $0.id == id }) else {
        fail("unknown screen \(id); known: \(ScreenCatalog.entries.map(\.id).joined(separator: ", "))")
    }
    guard let sc = MockScenario(rawValue: scenario) else {
        fail("unknown scenario \(scenario); known: \(MockScenario.allCases.map(\.rawValue).joined(separator: ", "))")
    }
    guard let image = SnapshotRenderer.render(entry.make(sc), size: entry.size, path: path) else {
        fail("render failed: \(id)")
    }
    return image
}

@MainActor func renderComponent(_ id: String, path: SnapshotRenderer.Path) -> CGImage {
    guard let item = TTGallery.item(id) else {
        fail("unknown component \(id); known: \(TTGallery.items.map(\.id).joined(separator: ", "))")
    }
    guard let image = SnapshotRenderer.render(item.make(), size: item.size, path: path) else { fail("render failed: \(id)") }
    return image
}

func cropped(_ image: CGImage, _ crop: CGRect?) -> CGImage {
    guard let crop else { return image }
    let px = CGRect(x: crop.minX * 2, y: crop.minY * 2, width: crop.width * 2, height: crop.height * 2)
    guard let c = SnapshotImage.crop(image, px) else { fail("crop outside image") }
    return c
}

@MainActor func write(_ image: CGImage, _ path: String) {
    let url = URL(fileURLWithPath: path)
    do {
        try SnapshotRenderer.writePNG(image, to: url)
        print("wrote \(url.path) (\(image.width)×\(image.height))")
    } catch {
        fail("cannot write \(path): \(error)")
    }
}

@MainActor func run() {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)
    NSApp.appearance = NSAppearance(named: .darkAqua)

    let o = parse(Array(CommandLine.arguments.dropFirst()))
    let defaultDir = ".build/renders"

    if o.list {
        print("screens: " + ScreenCatalog.entries.map(\.id).joined(separator: ", "))
        print("scenarios: " + MockScenario.allCases.map(\.rawValue).joined(separator: ", "))
        print("components: " + TTGallery.items.map(\.id).joined(separator: ", "))
        return
    }

    if o.all {
        let dir = o.out ?? defaultDir
        if ScreenCatalog.entries.isEmpty { print("no screens in ScreenCatalog yet") }
        for entry in ScreenCatalog.entries {
            write(renderScreen(entry.id, scenario: o.scenario, path: o.path), "\(dir)/\(entry.id)-\(o.scenario).png")
        }
        return
    }

    var ours: CGImage
    var name: String
    if let image = o.image {
        guard let img = SnapshotRenderer.readPNG(URL(fileURLWithPath: image)) else { fail("cannot read \(image)") }
        ours = img
        name = URL(fileURLWithPath: image).deletingPathExtension().lastPathComponent
    } else if let screen = o.screen {
        ours = renderScreen(screen, scenario: o.scenario, path: o.path)
        name = "\(screen)-\(o.scenario)"
    } else if let component = o.component {
        ours = renderComponent(component, path: o.path)
        name = "component-\(component)"
    } else if o.gallery {
        let sheet = TTGallery.sheet()
        guard let img = SnapshotRenderer.render(sheet.view, size: sheet.size, path: o.path) else { fail("gallery render failed") }
        ours = img
        name = "gallery"
    } else {
        print(usage)
        exit(2)
    }

    if let ref = o.compare {
        guard let refImage = SnapshotRenderer.readPNG(URL(fileURLWithPath: ref)) else { fail("cannot read \(ref)") }
        let r = cropped(refImage, o.crop)
        let a = cropped(ours, o.crop)
        guard let sheet = SnapshotImage.comparisonSheet(reference: r, ours: a, background: CGColor(red: 0.07, green: 0.07, blue: 0.08, alpha: 1))
        else { fail("compare failed") }
        let diff = SnapshotImage.compare(r, a)
        if !diff.sizeMismatch { print(String(format: "pixels differing (>8/255): %.2f%%", diff.fraction * 100)) }
        write(sheet, o.out ?? "\(defaultDir)/\(name)-compare.png")
    } else {
        write(cropped(ours, o.crop), o.out ?? "\(defaultDir)/\(name).png")
    }
}

MainActor.assumeIsolated { run() }
