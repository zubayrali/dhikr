import XCTest
@testable import DhikrCore

/// Live-hardware smoke tests for the device manager. These exercise real CoreAudio
/// state on the machine running the tests — they verify enumeration, resolution,
/// and mode logic without requiring any specific device to be present.
final class AudioDeviceManagerTests: XCTestCase {

    override func tearDown() {
        // tests persist mode in UserDefaults — reset so the app never inherits test state
        UserDefaults.standard.removeObject(forKey: "audioInputMode")
        UserDefaults.standard.removeObject(forKey: "audioInputDeviceUID")
        UserDefaults.standard.removeObject(forKey: "audioInputDeviceModelUID")
        super.tearDown()
    }

    func testEnumeratesInputDevices() {
        let mgr = AudioDeviceManager()
        XCTAssertFalse(mgr.devices.isEmpty, "every mac has at least one input device")
        for d in mgr.devices {
            XCTAssertFalse(d.uid.isEmpty)
            XCTAssertFalse(d.name.isEmpty)
        }
    }

    func testSystemDefaultResolution() {
        let mgr = AudioDeviceManager()
        mgr.selectSystemDefault()
        let uid = mgr.resolveTargetUID()
        XCTAssertNotNil(uid, "system default input must resolve")
        // the resolved uid must be a real enumerated device
        XCTAssertTrue(mgr.devices.contains { $0.uid == uid })
    }

    func testCustomPinResolvesToDeviceAndFallsBack() {
        let mgr = AudioDeviceManager()
        guard let first = mgr.devices.first else {
            XCTFail("no input devices")
            return
        }
        mgr.selectDevice(uid: first.uid)
        XCTAssertEqual(mgr.resolveTargetUID(), first.uid)
        XCTAssertEqual(mgr.resolveTargetName(), first.name)

        // pin a device that does NOT exist — must fall back to system default, not nil
        UserDefaults.standard.set("custom", forKey: "audioInputMode")
        UserDefaults.standard.set("nonexistent-uid-xyz", forKey: "audioInputDeviceUID")
        let mgr2 = AudioDeviceManager()
        XCTAssertNotNil(mgr2.resolveTargetUID())
        XCTAssertNotEqual(mgr2.resolveTargetUID(), "nonexistent-uid-xyz")
    }

    func testModePersistsAcrossInstances() {
        let mgr = AudioDeviceManager()
        guard let first = mgr.devices.first else { return }
        mgr.selectDevice(uid: first.uid)
        let mgr2 = AudioDeviceManager()
        if case .custom(let uid, _) = mgr2.mode {
            XCTAssertEqual(uid, first.uid)
        } else {
            XCTFail("custom mode did not persist")
        }
        mgr2.selectSystemDefault()
        let mgr3 = AudioDeviceManager()
        XCTAssertEqual(mgr3.mode, .systemDefault)
    }
}
