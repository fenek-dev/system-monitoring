import Foundation
import Testing
@testable import MixerCore

struct VolumeStoreTests {
    let defaults = UserDefaults(suiteName: "VolumeStoreTests-\(UUID().uuidString)")!

    @Test func unknownAppIsFullVolume() {
        let store = VolumeStore(defaults: defaults)
        #expect(store.volume(for: "com.example.a") == AppVolume(volume: 1, muted: false))
        #expect(store.volume(for: "com.example.a").isDefault)
    }

    @Test func roundTripsAcrossInstances() {
        VolumeStore(defaults: defaults).set(AppVolume(volume: 0.4, muted: true), for: "com.example.a")
        #expect(VolumeStore(defaults: defaults).volume(for: "com.example.a") == AppVolume(volume: 0.4, muted: true))
    }

    @Test func muteAtFullVolumeIsStored() {
        let store = VolumeStore(defaults: defaults)
        store.set(AppVolume(volume: 1, muted: true), for: "com.example.a")
        #expect(store.all["com.example.a"] == AppVolume(volume: 1, muted: true))
    }

    @Test func defaultValueIsRemoved() {
        let store = VolumeStore(defaults: defaults)
        store.set(AppVolume(volume: 0.5), for: "com.example.a")
        store.set(AppVolume(volume: 1), for: "com.example.a")
        #expect(store.all.isEmpty)
    }

    @Test func clampsOutOfRangeAndNaN() {
        #expect(AppVolume(volume: 1.7).volume == 1.5)
        #expect(AppVolume(volume: -0.3).volume == 0)
        #expect(AppVolume(volume: .nan).volume == 1)
    }

    @Test func clampsOutOfRangeSavedData() {
        defaults.set(Data(#"{"com.example.a":{"volume":5,"muted":false}}"#.utf8), forKey: "appVolumes")
        #expect(VolumeStore(defaults: defaults).volume(for: "com.example.a").volume == 1.5)
    }

    @Test func boostIsNotDefaultAndIsStored() {
        #expect(AppVolume(volume: 1.3).isDefault == false)
        let store = VolumeStore(defaults: defaults)
        store.set(AppVolume(volume: 1.3), for: "com.example.a")
        #expect(VolumeStore(defaults: defaults).volume(for: "com.example.a").volume == 1.3)
    }

    @Test func hiddenAppsRoundTrip() {
        let store = VolumeStore(defaults: defaults)
        store.setHidden(true, for: "com.example.a")
        store.setHidden(true, for: "com.example.b")
        store.setHidden(false, for: "com.example.b")
        #expect(VolumeStore(defaults: defaults).hidden == ["com.example.a"])
    }

    @Test func hidingDoesNotTouchVolumes() {
        let store = VolumeStore(defaults: defaults)
        store.set(AppVolume(volume: 0.5), for: "com.example.a")
        store.setHidden(true, for: "com.example.a")
        #expect(VolumeStore(defaults: defaults).volume(for: "com.example.a").volume == 0.5)
    }

    @Test func garbageSavedDataFallsBackToEmpty() {
        defaults.set(Data([1, 2, 3]), forKey: "appVolumes")
        #expect(VolumeStore(defaults: defaults).all.isEmpty)
        defaults.set("junk", forKey: "appVolumes")
        #expect(VolumeStore(defaults: defaults).all.isEmpty)
    }
}
