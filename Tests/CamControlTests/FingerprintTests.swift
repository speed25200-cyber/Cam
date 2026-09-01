import XCTest
@testable import CamControl

/// The manufacturer lookup, which is what names a camera that answers nothing.
final class MACVendorTests: XCTestCase {

    func testRecognisesACameraMakerFromItsPrefix() {
        // 44:19:B6 is one of Hikvision's registered blocks.
        let match = MACVendors.lookup("44:19:B6:12:34:56")
        XCTAssertEqual(match?.name, "Hikvision")
        XCTAssertEqual(match?.makesOnlyCameras, true)
    }

    /// A maker of routers and plugs is worth naming but never worth treating as
    /// evidence that a device is a camera.
    func testMarksGeneralPurposeMakersAsWeakEvidence() {
        let match = MACVendors.lookup("50:C7:BF:00:11:22")
        XCTAssertEqual(match?.name, "TP-Link")
        XCTAssertEqual(match?.makesOnlyCameras, false)
    }

    func testAcceptsEveryCommonSeparator() {
        let expected = MACVendors.lookup("44:19:B6:12:34:56")
        XCTAssertNotNil(expected)
        XCTAssertEqual(MACVendors.lookup("4419b6123456"), expected)
        XCTAssertEqual(MACVendors.lookup("44-19-B6-12-34-56"), expected)
        XCTAssertEqual(MACVendors.lookup("4419.b612.3456"), expected)
    }

    /// iOS randomises the address a phone presents to a network, and the result
    /// is a locally administered prefix registered to nobody.
    func testReturnsNothingForAnUnregisteredPrefix() {
        XCTAssertNil(MACVendors.lookup("02:00:00:00:00:01"))
    }

    func testRejectsMalformedInput() {
        XCTAssertNil(MACVendors.lookup(""))
        XCTAssertNil(MACVendors.lookup("44:19:B6"))
        XCTAssertNil(MACVendors.lookup("not a mac address"))
    }
}

/// Parsing of the identification strings cameras hand out before authenticating.
final class DeviceFingerprintTests: XCTestCase {

    func testReadsTheServerHeaderOutOfAnRTSPReply() {
        let reply = [
            "RTSP/1.0 200 OK",
            "CSeq: 1",
            "Server: Dahua Rtsp Server/2.0",
            "Public: OPTIONS, DESCRIBE, SETUP, PLAY",
            "",
            ""
        ].joined(separator: "\r\n")

        XCTAssertEqual(DeviceFingerprint.headerValue("Server", in: reply), "Dahua Rtsp Server/2.0")
        XCTAssertEqual(DeviceFingerprint.vendor(in: reply), "Dahua")
    }

    /// Header names are case-insensitive, and vendors disagree about the casing.
    func testMatchesHeaderNamesRegardlessOfCase() {
        let reply = "RTSP/1.0 401 Unauthorized\r\nserver: Hipcam RealServer/V1.0\r\n\r\n"
        XCTAssertEqual(DeviceFingerprint.headerValue("Server", in: reply), "Hipcam RealServer/V1.0")
    }

    /// The realm of a rejection is the most reliable model string a camera gives
    /// away without credentials, so it is worth more than the reply's status.
    func testReadsTheRealmOutOfAnAuthenticationChallenge() {
        let reply = [
            "RTSP/1.0 401 Unauthorized",
            "CSeq: 1",
            #"WWW-Authenticate: Digest realm="IP Camera(C1234)", nonce="abc123", stale="FALSE""#,
            "",
            ""
        ].joined(separator: "\r\n")

        XCTAssertEqual(DeviceFingerprint.realm(in: reply), "IP Camera(C1234)")
    }

    func testReadsAnUnquotedRealm() {
        XCTAssertEqual(
            DeviceFingerprint.realmValue(in: "Basic realm=IPCam Login, charset=UTF-8"),
            "IPCam Login"
        )
    }

    func testIgnoresAChallengeWithNoRealm() {
        XCTAssertNil(DeviceFingerprint.realmValue(in: "Negotiate"))
        XCTAssertNil(DeviceFingerprint.realmValue(in: #"Digest realm="""#))
    }

    func testReadsThePageTitleOfALoginPage() {
        let html = Data("""
        <!DOCTYPE html><html><head>
        <meta charset="utf-8">
        <title>DS-2CD2042WD-I</title>
        </head><body>…</body></html>
        """.utf8)

        XCTAssertEqual(DeviceFingerprint.pageTitle(in: html), "DS-2CD2042WD-I")
        XCTAssertEqual(DeviceFingerprint.vendor(in: "DS-2CD2042WD-I"), "Hikvision")
    }

    /// `<title lang="en">` is still a title.
    func testReadsATitleCarryingAttributes() {
        let html = Data(#"<html><head><title lang="en"> NETCAM </title></head></html>"#.utf8)
        XCTAssertEqual(DeviceFingerprint.pageTitle(in: html), "NETCAM")
    }

    func testReturnsNoTitleWhenThereIsNone() {
        XCTAssertNil(DeviceFingerprint.pageTitle(in: Data("<html><body>hello</body></html>".utf8)))
        XCTAssertNil(DeviceFingerprint.pageTitle(in: Data()))
    }

    func testRecognisesGenericCameraWordingWithoutAVendorName() {
        XCTAssertTrue(DeviceFingerprint.looksLikeCamera("IPCam Login"))
        XCTAssertTrue(DeviceFingerprint.looksLikeCamera("Network Camera"))
        XCTAssertFalse(DeviceFingerprint.looksLikeCamera("OpenWrt"))
        XCTAssertFalse(DeviceFingerprint.looksLikeCamera("Synology DiskStation"))
    }
}

/// The two-tier port lists the sweep is built on.
final class PortPlanTests: XCTestCase {

    /// The common list runs against a thousand addresses. Every port added to it
    /// costs another thousand connection attempts, so it stays short on purpose.
    func testTheCommonListStaysSmall() {
        XCTAssertLessThanOrEqual(PortScanner.commonPorts.count, 5)
        XCTAssertTrue(PortScanner.commonPorts.contains(80))
        XCTAssertTrue(PortScanner.commonPorts.contains(554))
    }

    /// Probing the same port twice would double the work for nothing.
    func testTheTwoListsDoNotOverlap() {
        let common = Set(PortScanner.commonPorts)
        let extended = Set(PortScanner.extendedPorts)
        XCTAssertTrue(common.isDisjoint(with: extended))
    }

    /// An ONVIF probe is an HTTP request; aiming one at an RTSP or binary port
    /// wastes a round trip on every host that has one open.
    func testNoPortIsBothWorthAnONVIFProbeAndKnownNotToSpeakHTTP() {
        for port in PortScanner.onvifPorts {
            XCTAssertFalse(
                PortScanner.nonHTTPPorts.contains(port),
                "port \(port) is in both lists"
            )
        }
        for port in PortScanner.rtspPorts {
            XCTAssertTrue(PortScanner.nonHTTPPorts.contains(port))
        }
    }
}
