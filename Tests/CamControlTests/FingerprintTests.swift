import CryptoKit
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

        XCTAssertEqual(MessageHeaders.value("Server", in: reply), "Dahua Rtsp Server/2.0")
        XCTAssertEqual(DeviceFingerprint.vendor(in: reply), "Dahua")
    }

    /// Header names are case-insensitive, and vendors disagree about the casing.
    func testMatchesHeaderNamesRegardlessOfCase() {
        let reply = "RTSP/1.0 401 Unauthorized\r\nserver: Hipcam RealServer/V1.0\r\n\r\n"
        XCTAssertEqual(MessageHeaders.value("Server", in: reply), "Hipcam RealServer/V1.0")
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
            MessageHeaders.parameter("realm", in: "Basic realm=IPCam Login, charset=UTF-8"),
            "IPCam Login"
        )
    }

    func testIgnoresAChallengeWithNoRealm() {
        XCTAssertNil(MessageHeaders.parameter("realm", in: "Negotiate"))
        XCTAssertNil(MessageHeaders.parameter("realm", in: #"Digest realm="""#))
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

/// The RTSP status line and header grammar the probe reads its answers from.
final class MessageHeaderTests: XCTestCase {

    func testReadsTheStatusOfAnRTSPReply() {
        XCTAssertEqual(MessageHeaders.statusCode(in: "RTSP/1.0 200 OK\r\nCSeq: 1\r\n\r\n"), 200)
        XCTAssertEqual(MessageHeaders.statusCode(in: "RTSP/1.0 401 Unauthorized\r\n\r\n"), 401)
        XCTAssertEqual(MessageHeaders.statusCode(in: "RTSP/1.0 404 Stream Not Found\r\n\r\n"), 404)
    }

    /// A camera that answers with something that is not RTSP at all — a web
    /// server on the port, say — must not be read as a stream.
    func testRejectsAReplyThatIsNotAStatusLine() {
        XCTAssertNil(MessageHeaders.statusCode(in: "<html><body>hello</body></html>"))
        XCTAssertNil(MessageHeaders.statusCode(in: ""))
        XCTAssertNil(MessageHeaders.statusCode(in: "RTSP/1.0"))
    }

    func testReadsBothQuotedAndBareParameters() {
        let challenge = #"Digest realm="IP Camera(C1234)", nonce="abc123", stale=FALSE"#
        XCTAssertEqual(MessageHeaders.parameter("realm", in: challenge), "IP Camera(C1234)")
        XCTAssertEqual(MessageHeaders.parameter("nonce", in: challenge), "abc123")
        XCTAssertEqual(MessageHeaders.parameter("stale", in: challenge), "FALSE")
    }
}

/// Answering a camera's authentication challenge, in RTSP or HTTP.
///
/// The digest is pinned to a value computed independently: getting it subtly
/// wrong produces a 401 that is indistinguishable from a wrong password, which
/// is the single most confusing failure this app can show.
final class RTSPAuthorizationTests: XCTestCase {

    private let credentials = CameraCredentials(username: "admin", password: "s3cret")
    private let target = "rtsp://192.168.1.10:554/stream1"

    func testComputesTheDigestResponseRFC2617Prescribes() throws {
        let header = try XCTUnwrap(WWWAuthenticate.authorization(
            for: #"Digest realm="IP Camera(C1234)", nonce="abc123""#,
            method: "DESCRIBE",
            target: target,
            credentials: credentials
        ))

        XCTAssertTrue(header.hasPrefix("Digest "))
        XCTAssertEqual(
            MessageHeaders.parameter("response", in: header),
            "b3885c1ffc33f1e6b69ca34819b2fa52"
        )
        // The URI in the header has to be the one on the request line, or the
        // camera computes a different digest and rejects a correct password.
        XCTAssertEqual(MessageHeaders.parameter("uri", in: header), target)
        XCTAssertEqual(MessageHeaders.parameter("username", in: header), "admin")
    }

    func testAnswersABasicChallenge() {
        XCTAssertEqual(
            WWWAuthenticate.authorization(
                for: #"Basic realm="IPCam""#,
                method: "DESCRIBE",
                target: target,
                credentials: credentials
            ),
            "Basic YWRtaW46czNjcmV0"
        )
    }

    /// A challenge naming a scheme we cannot answer, or a digest missing the
    /// nonce, must produce no header rather than a malformed one.
    func testDeclinesAChallengeItCannotAnswer() {
        XCTAssertNil(WWWAuthenticate.authorization(
            for: "Negotiate", method: "DESCRIBE", target: target, credentials: credentials
        ))
        XCTAssertNil(WWWAuthenticate.authorization(
            for: #"Digest realm="IPCam""#, method: "DESCRIBE", target: target, credentials: credentials
        ))
    }

    /// Credentials belong in the `Authorization` header, never on the request
    /// line — and the digest is computed over the address without them.
    func testStripsCredentialsFromTheRequestTarget() throws {
        let url = try XCTUnwrap(URL(string: "rtsp://admin:s3cret@192.168.1.10:554/stream1"))
        XCTAssertEqual(RTSPProbe.withoutCredentials(url).absoluteString, target)
    }

    func testLeavesAnAddressWithoutCredentialsAlone() throws {
        let url = try XCTUnwrap(URL(string: target))
        XCTAssertEqual(RTSPProbe.withoutCredentials(url).absoluteString, target)
    }
}

/// The RFC 2617 form, for the cameras that ask for it.
///
/// The client nonce is random by definition, so the response cannot be pinned to
/// a constant. It is re-derived here from the header's own `cnonce` instead,
/// which checks the formula rather than one sample of it.
final class RTSPDigestQopTests: XCTestCase {

    func testFoldsTheClientNonceAndCounterIntoTheResponse() throws {
        let credentials = CameraCredentials(username: "admin", password: "s3cret")
        let target = "rtsp://192.168.1.10:554/stream1"
        let header = try XCTUnwrap(WWWAuthenticate.authorization(
            for: #"Digest realm="IPCam", nonce="dead10cc", qop="auth,auth-int", opaque="xyz""#,
            method: "DESCRIBE",
            target: target,
            credentials: credentials
        ))

        XCTAssertEqual(MessageHeaders.parameter("qop", in: header), "auth")
        XCTAssertEqual(MessageHeaders.parameter("nc", in: header), "00000001")
        XCTAssertEqual(MessageHeaders.parameter("opaque", in: header), "xyz")

        // `nonce` must be the camera's, not the eight bytes we just invented.
        XCTAssertEqual(MessageHeaders.parameter("nonce", in: header), "dead10cc")
        let clientNonce = try XCTUnwrap(MessageHeaders.parameter("cnonce", in: header))
        XCTAssertEqual(clientNonce.count, 16)
        XCTAssertNotEqual(clientNonce, "dead10cc")

        let ha1 = md5("admin:IPCam:s3cret")
        let ha2 = md5("DESCRIBE:\(target)")
        XCTAssertEqual(
            MessageHeaders.parameter("response", in: header),
            md5("\(ha1):dead10cc:00000001:\(clientNonce):auth:\(ha2)")
        )
    }

    /// `auth-int` digests a request body, and a DESCRIBE has none.
    func testNeverClaimsAuthInt() throws {
        let header = try XCTUnwrap(WWWAuthenticate.authorization(
            for: #"Digest realm="IPCam", nonce="n", qop="auth-int,auth""#,
            method: "DESCRIBE",
            target: "rtsp://h/s",
            credentials: CameraCredentials(username: "u", password: "p")
        ))
        XCTAssertEqual(MessageHeaders.parameter("qop", in: header), "auth")
    }

    private func md5(_ text: String) -> String {
        Insecure.MD5.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Recognising a picture on a camera's web port.
///
/// This is the family the app used to be blind to entirely: cameras that never
/// implemented RTSP and put the video on HTTP instead. Reading the content type
/// wrongly here either misses them or plays an error page as though it were a
/// stream.
final class HTTPVideoProbeTests: XCTestCase {

    private func reply(_ status: Int, _ contentType: String) -> String {
        "HTTP/1.1 \(status) OK\r\nServer: cam\r\nContent-Type: \(contentType)\r\n\r\n"
    }

    func testRecognisesAMultipartStreamAsMovingPicture() {
        let content = HTTPVideoProbe.classify(
            reply(200, "multipart/x-mixed-replace; boundary=ipcamera"),
            status: 200
        )
        XCTAssertEqual(content, .motionJPEG)
        XCTAssertEqual(content?.isMoving, true)
    }

    func testRecognisesAPlaylist() {
        XCTAssertEqual(
            HTTPVideoProbe.classify(reply(200, "application/vnd.apple.mpegurl"), status: 200),
            .playlist
        )
    }

    /// A still image is worth having, but it is a different thing and the player
    /// has to know which it is.
    func testSeparatesAStillImageFromAStream() {
        let content = HTTPVideoProbe.classify(reply(200, "image/jpeg"), status: 200)
        XCTAssertEqual(content, .stillImage)
        XCTAssertEqual(content?.isMoving, false)
    }

    /// A camera's 404 page is HTML and its redirect carries nothing at all.
    func testRefusesEverythingThatIsNotAPicture() {
        XCTAssertNil(HTTPVideoProbe.classify(reply(200, "text/html; charset=utf-8"), status: 200))
        XCTAssertNil(HTTPVideoProbe.classify(reply(404, "image/jpeg"), status: 404))
        XCTAssertNil(HTTPVideoProbe.classify(reply(302, "image/jpeg"), status: 302))
        XCTAssertNil(HTTPVideoProbe.classify("HTTP/1.1 200 OK\r\n\r\n", status: 200))
    }

    /// An HTTP request line carries the path, never the whole address — and the
    /// digest is computed over that same string, so the two must agree.
    func testBuildsTheRequestTargetFromPathAndQuery() throws {
        XCTAssertEqual(
            HTTPVideoProbe.requestTarget(of: try XCTUnwrap(URL(string: "http://192.168.1.10/snapshot.cgi"))),
            "/snapshot.cgi"
        )
        XCTAssertEqual(
            HTTPVideoProbe.requestTarget(of: try XCTUnwrap(URL(string: "http://192.168.1.10:8080/cgi-bin/api.cgi?cmd=Snap&channel=0"))),
            "/cgi-bin/api.cgi?cmd=Snap&channel=0"
        )
        XCTAssertEqual(
            HTTPVideoProbe.requestTarget(of: try XCTUnwrap(URL(string: "http://192.168.1.10"))),
            "/"
        )
    }

    /// The credentials ride in the URL for the decoder's benefit, so the catalog
    /// has to put them there — and the query must survive intact.
    func testBuildsCandidatesWithCredentialsAndAnIntactQuery() throws {
        let candidates = HTTPVideoCatalog.candidates(
            host: "192.168.1.10",
            port: 8080,
            credentials: CameraCredentials(username: "admin", password: "s3cret")
        )
        XCTAssertTrue(candidates.allSatisfy { $0.scheme == "http" && $0.port == 8080 })
        XCTAssertTrue(candidates.allSatisfy { $0.user == "admin" })
        XCTAssertFalse(candidates.contains { $0.absoluteString.contains("%3F") })

        let reolink = try XCTUnwrap(candidates.first { $0.path == "/cgi-bin/api.cgi" })
        XCTAssertEqual(reolink.query, "cmd=Snap&channel=0")
    }

    /// Moving pictures must be offered before still ones, or a camera that has
    /// both gets reduced to the lesser.
    func testPutsEveryMovingAddressAheadOfEveryStillOne() {
        let candidates = HTTPVideoCatalog.candidates(host: "h", port: 80, credentials: nil)
        let lastMoving = candidates.lastIndex { HTTPVideoCatalog.movingPaths.contains($0.path) }
        let firstStill = candidates.firstIndex { HTTPVideoCatalog.stillPaths.contains($0.path) }
        XCTAssertNotNil(lastMoving)
        XCTAssertNotNil(firstStill)
        if let lastMoving, let firstStill { XCTAssertLessThan(lastMoving, firstStill) }
    }
}
