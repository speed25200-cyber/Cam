import XCTest
@testable import CamControl

final class PTZVectorTests: XCTestCase {

    func testClampsComponentsToTheProtocolRange() {
        let vector = PTZVector(pan: 4, tilt: -9, zoom: 0.5)
        XCTAssertEqual(vector.pan, 1)
        XCTAssertEqual(vector.tilt, -1)
        XCTAssertEqual(vector.zoom, 0.5)
    }

    func testRejectsNonFiniteInput() {
        let vector = PTZVector(pan: .nan, tilt: .infinity)
        XCTAssertEqual(vector.pan, 0)
        XCTAssertEqual(vector.tilt, 0)
    }

    func testJoystickCentreProducesNoMovement() {
        XCTAssertTrue(PTZVector.fromJoystick(offset: .zero, radius: 100).isStopped)
    }

    /// Screen coordinates grow downward, ONVIF tilt grows upward: dragging up
    /// must tilt up, or the camera moves the wrong way.
    func testJoystickInvertsTheVerticalAxis() {
        let up = PTZVector.fromJoystick(offset: CGSize(width: 0, height: -100), radius: 100)
        XCTAssertGreaterThan(up.tilt, 0)

        let down = PTZVector.fromJoystick(offset: CGSize(width: 0, height: 100), radius: 100)
        XCTAssertLessThan(down.tilt, 0)
    }

    /// A squared response keeps small movements gentle; a linear one makes
    /// framing a distant subject nearly impossible.
    func testJoystickResponseIsFinerNearTheCentre() {
        let half = PTZVector.fromJoystick(offset: CGSize(width: 50, height: 0), radius: 100)
        let full = PTZVector.fromJoystick(offset: CGSize(width: 100, height: 0), radius: 100)
        XCTAssertEqual(half.pan, 0.25, accuracy: 0.001)
        XCTAssertEqual(full.pan, 1.0, accuracy: 0.001)
    }

    func testConstrainKeepsTheKnobInsideThePad() {
        let constrained = PTZVector.constrain(offset: CGSize(width: 300, height: 400), radius: 100)
        let distance = sqrt(constrained.width * constrained.width + constrained.height * constrained.height)
        XCTAssertEqual(distance, 100, accuracy: 0.001)
    }

    func testConstrainLeavesInteriorPointsUntouched() {
        let offset = CGSize(width: 30, height: 40)
        XCTAssertEqual(PTZVector.constrain(offset: offset, radius: 100), offset)
    }
}

final class ImagingRangeTests: XCTestCase {

    func testNormalizesAndDenormalizesTheStandardRange() {
        let range = ImagingRange.standard
        XCTAssertEqual(range.normalize(50), 0.5, accuracy: 0.0001)
        XCTAssertEqual(range.denormalize(0.5), 50, accuracy: 0.0001)
    }

    /// Cameras report ranges other than 0–100; assuming otherwise writes values
    /// the device rejects outright.
    func testHandlesNonStandardDeviceRanges() {
        let range = ImagingRange(minimum: -128, maximum: 127)
        XCTAssertEqual(range.normalize(-128), 0, accuracy: 0.0001)
        XCTAssertEqual(range.normalize(127), 1, accuracy: 0.0001)
        XCTAssertEqual(range.denormalize(0), -128, accuracy: 0.0001)
        XCTAssertEqual(range.denormalize(1), 127, accuracy: 0.0001)
    }

    func testClampsOutOfBoundsValues() {
        let range = ImagingRange.standard
        XCTAssertEqual(range.normalize(500), 1)
        XCTAssertEqual(range.normalize(-500), 0)
        XCTAssertEqual(range.denormalize(9), 100, accuracy: 0.0001)
    }

    func testDegenerateRangeDoesNotDivideByZero() {
        let range = ImagingRange(minimum: 5, maximum: 5)
        XCTAssertTrue(range.normalize(5).isFinite)
    }
}

final class LiveFilterTests: XCTestCase {

    func testNeutralSettingsResolveToNoChange() {
        let resolved = LiveFilterSettings.neutral.resolved
        XCTAssertEqual(resolved.brightness, 0, accuracy: 0.0001)
        XCTAssertEqual(resolved.contrast, 1, accuracy: 0.0001)
        XCTAssertEqual(resolved.saturation, 1, accuracy: 0.0001)
    }

    func testPresetComposesWithManualAdjustment() {
        var settings = LiveFilterSettings.neutral
        settings.preset = .noir
        settings.brightness = 0.1
        let resolved = settings.resolved

        XCTAssertEqual(resolved.saturation, 0, accuracy: 0.0001)   // noir wins on colour
        XCTAssertEqual(resolved.brightness, 0.1, accuracy: 0.0001) // manual lift survives
    }

    func testOnlyTintedPresetsReportATint() {
        XCTAssertTrue(LiveFilterSettings.FilterPreset.sepia.hasTint)
        XCTAssertTrue(LiveFilterSettings.FilterPreset.cool.hasTint)
        XCTAssertFalse(LiveFilterSettings.FilterPreset.none.hasTint)
        XCTAssertFalse(LiveFilterSettings.FilterPreset.noir.hasTint)
    }
}

final class CameraModelTests: XCTestCase {

    func testDisplayNamePrefersTheUsersOwnName() {
        var camera = Camera(host: "192.168.1.9", manufacturer: "Hikvision", model: "DS-2CD")
        XCTAssertEqual(camera.displayName, "Hikvision DS-2CD")

        camera.customName = "Portail"
        XCTAssertEqual(camera.displayName, "Portail")
    }

    func testDisplayNameFallsBackToTheAddress() {
        XCTAssertEqual(Camera(host: "192.168.1.9").displayName, "Caméra 192.168.1.9")
    }

    func testBlankCustomNameDoesNotHideTheRealName() {
        let camera = Camera(host: "192.168.1.9", manufacturer: "Dahua", customName: "   ")
        XCTAssertEqual(camera.displayName, "Dahua")
    }

    /// A DHCP lease change must not create a second entry for a camera the user
    /// has already named and stored credentials for.
    func testMatchesBySerialNumberAcrossAnAddressChange() {
        let saved = Camera(host: "192.168.1.50", serialNumber: "SN-1234")
        let rediscovered = Camera(host: "192.168.1.77", serialNumber: "SN-1234")
        XCTAssertTrue(saved.matches(rediscovered))
    }

    func testDifferentSerialsAtTheSameAddressAreDifferentCameras() {
        let first = Camera(host: "192.168.1.50", serialNumber: "SN-1")
        let second = Camera(host: "192.168.1.50", serialNumber: "SN-2")
        XCTAssertFalse(first.matches(second))
    }

    func testFallsBackToHostWhenNoSerialIsKnown() {
        XCTAssertTrue(Camera(host: "192.168.1.50").matches(Camera(host: "192.168.1.50")))
        XCTAssertFalse(Camera(host: "192.168.1.50").matches(Camera(host: "192.168.1.51")))
    }

    func testMergingKeepsUserDataAndTakesNetworkData() {
        let saved = Camera(host: "192.168.1.50", kind: .onvif, customName: "Jardin")
        let discovered = Camera(
            host: "192.168.1.77",
            kind: .onvif,
            manufacturer: "Reolink",
            model: "RLC-810A",
            serialNumber: "SN-9",
            openPorts: [80, 554]
        )

        let merged = saved.merging(discovered: discovered)
        XCTAssertEqual(merged.id, saved.id)             // identity is never replaced
        XCTAssertEqual(merged.customName, "Jardin")     // the user's name survives
        XCTAssertEqual(merged.host, "192.168.1.77")     // the new address is taken
        XCTAssertEqual(merged.manufacturer, "Reolink")
        XCTAssertEqual(merged.openPorts, [80, 554])
        XCTAssertNotNil(merged.lastSeen)
    }

    func testMergingDoesNotDowngradeAKnownProtocol() {
        let saved = Camera(host: "192.168.1.50", kind: .onvif)
        let seenOnlyAsOpenPort = Camera(host: "192.168.1.50", kind: .unknown, openPorts: [80])
        XCTAssertEqual(saved.merging(discovered: seenOnlyAsOpenPort).kind, .onvif)
    }

    func testCredentialsKeyIsStableAcrossAddressChanges() {
        var camera = Camera(host: "192.168.1.50")
        let key = camera.credentialsKey
        camera.host = "192.168.1.99"
        XCTAssertEqual(camera.credentialsKey, key)
    }

    func testRoundTripsThroughJSON() throws {
        let camera = Camera(
            host: "192.168.1.50",
            onvifServiceURL: URL(string: "http://192.168.1.50/onvif/device_service"),
            kind: .onvif,
            manufacturer: "Axis",
            customName: "Entrée",
            openPorts: [80],
            capabilities: Camera.Capabilities(hasMedia: true, hasPTZ: true, hasImaging: false),
            isSaved: true
        )
        let data = try JSONEncoder().encode(camera)
        let decoded = try JSONDecoder().decode(Camera.self, from: data)

        // `==` only compares identity, so the fields are checked explicitly.
        XCTAssertEqual(decoded.id, camera.id)
        XCTAssertFalse(decoded.differsInDeviceData(from: camera))
        XCTAssertEqual(decoded.customName, "Entrée")
        XCTAssertEqual(decoded.onvifServiceURL, camera.onvifServiceURL)
        XCTAssertTrue(decoded.capabilities.hasPTZ)
        XCTAssertTrue(decoded.isSaved)
    }

    func testDiffersInDeviceDataIgnoresUserOwnedFields() {
        var original = Camera(host: "192.168.1.10", kind: .onvif)
        var renamed = original
        renamed.customName = "Cuisine"
        XCTAssertFalse(renamed.differsInDeviceData(from: original))

        original.firmwareVersion = "5.7.1"
        XCTAssertTrue(renamed.differsInDeviceData(from: original))
    }
}
