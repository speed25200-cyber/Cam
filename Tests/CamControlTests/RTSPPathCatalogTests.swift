import XCTest
@testable import CamControl

/// The path list is what makes a non-ONVIF camera watchable at all, so its URL
/// construction is pinned down here — a malformed candidate silently costs the
/// user one failed attempt each time the player walks the list.
final class RTSPPathCatalogTests: XCTestCase {

    private let credentials = CameraCredentials(username: "admin", password: "s3cret")

    func testPutsAUserSuppliedAddressAheadOfEveryGuess() throws {
        var camera = Camera(host: "192.168.1.10", kind: .rtsp, openPorts: [554])
        camera.rtspURLOverride = URL(string: "rtsp://192.168.1.10:8554/custom/path")

        let candidates = RTSPPathCatalog.candidates(for: camera, credentials: nil)
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.absoluteString, "rtsp://192.168.1.10:8554/custom/path")
    }

    func testAddsCredentialsToAUserSuppliedAddressThatHasNone() throws {
        var camera = Camera(host: "192.168.1.10", kind: .rtsp, openPorts: [554])
        camera.rtspURLOverride = URL(string: "rtsp://192.168.1.10:554/stream")

        let url = try XCTUnwrap(RTSPPathCatalog.candidates(for: camera, credentials: credentials).first)
        XCTAssertEqual(url.user, "admin")
        XCTAssertEqual(url.password, "s3cret")
    }

    func testDoesNotOverwriteCredentialsAlreadyInTheAddress() throws {
        var camera = Camera(host: "192.168.1.10", kind: .rtsp, openPorts: [554])
        camera.rtspURLOverride = URL(string: "rtsp://bob:hunter2@192.168.1.10:554/stream")

        let url = try XCTUnwrap(RTSPPathCatalog.candidates(for: camera, credentials: credentials).first)
        XCTAssertEqual(url.user, "bob")
    }

    /// Knowing the vendor is the whole point: it should turn a fifteen-attempt
    /// walk into a first-try connection.
    func testLeadsWithTheManufacturersOwnPaths() throws {
        let camera = Camera(host: "192.168.1.10", kind: .rtsp, manufacturer: "Hikvision", openPorts: [554])
        let first = try XCTUnwrap(RTSPPathCatalog.candidates(for: camera, credentials: nil).first)
        XCTAssertEqual(first.path, "/Streaming/Channels/101")
    }

    func testMatchesTheManufacturerCaseInsensitivelyAndOnSubstrings() throws {
        let camera = Camera(host: "192.168.1.10", kind: .rtsp, manufacturer: "REOLINK DIGITAL", openPorts: [554])
        let first = try XCTUnwrap(RTSPPathCatalog.candidates(for: camera, credentials: nil).first)
        XCTAssertEqual(first.path, "/h264Preview_01_main")
    }

    /// Dahua's path carries a query string; percent-encoding the "?" turns it
    /// into a 404, which is exactly the kind of failure that reads as "the
    /// camera is broken".
    func testKeepsAQueryStringOutOfThePath() throws {
        let camera = Camera(host: "192.168.1.10", kind: .rtsp, manufacturer: "Dahua", openPorts: [554])
        let first = try XCTUnwrap(RTSPPathCatalog.candidates(for: camera, credentials: nil).first)

        XCTAssertEqual(first.path, "/cam/realmonitor")
        XCTAssertEqual(first.query, "channel=1&subtype=0")
        XCTAssertFalse(first.absoluteString.contains("%3F"))
        XCTAssertTrue(first.absoluteString.hasSuffix("/cam/realmonitor?channel=1&subtype=0"))
    }

    func testFallsBackToGenericPathsForAnUnknownVendor() {
        let camera = Camera(host: "192.168.1.10", kind: .rtsp, openPorts: [554])
        let candidates = RTSPPathCatalog.candidates(for: camera, credentials: nil)

        XCTAssertGreaterThan(candidates.count, 8)
        XCTAssertTrue(candidates.allSatisfy { $0.scheme == "rtsp" })
        XCTAssertTrue(candidates.allSatisfy { $0.host == "192.168.1.10" })
        XCTAssertTrue(candidates.allSatisfy { $0.port == 554 })
    }

    func testNeverRepeatsAPath() {
        // A vendor path that also appears in the generic list must not be tried
        // twice — the walk is slow enough already.
        let camera = Camera(host: "192.168.1.10", kind: .rtsp, manufacturer: "Hikvision", openPorts: [554])
        let paths = RTSPPathCatalog.candidates(for: camera, credentials: nil).map(\.absoluteString)
        XCTAssertEqual(Set(paths).count, paths.count)
    }

    func testUsesTheDiscoveredPortWhen554IsClosed() throws {
        let camera = Camera(host: "192.168.1.10", kind: .rtsp, openPorts: [8554])
        let first = try XCTUnwrap(RTSPPathCatalog.candidates(for: camera, credentials: nil).first)
        XCTAssertEqual(first.port, 8554)
    }

    func testEmbedsCredentialsInEveryGuessedCandidate() {
        let camera = Camera(host: "192.168.1.10", kind: .rtsp, openPorts: [554])
        let candidates = RTSPPathCatalog.candidates(for: camera, credentials: credentials)
        XCTAssertTrue(candidates.allSatisfy { $0.user == "admin" })
    }

    /// A camera whose RTSP port the scan never saw must still be asked on 554 —
    /// asking for video on its web port answers nothing at all.
    func testNeverAsksForVideoOnAnHTTPPort() throws {
        let camera = Camera(host: "192.168.1.10", kind: .unknown, openPorts: [80, 8080])
        let first = try XCTUnwrap(RTSPPathCatalog.candidates(for: camera, credentials: nil).first)
        XCTAssertEqual(first.port, 554)
    }

    func testPrefers554WhenBothRTSPPortsAreOpen() throws {
        let camera = Camera(host: "192.168.1.10", kind: .rtsp, openPorts: [554, 8554])
        let first = try XCTUnwrap(RTSPPathCatalog.candidates(for: camera, credentials: nil).first)
        XCTAssertEqual(first.port, 554)
    }
}
