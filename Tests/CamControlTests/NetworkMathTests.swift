import XCTest
@testable import CamControl

/// Subnet enumeration decides both how long a scan takes and whose network it
/// touches, so its bounds are pinned down here rather than trusted.
final class NetworkMathTests: XCTestCase {

    // MARK: - Address conversion

    func testParsesAndFormatsIPv4() {
        XCTAssertEqual(LocalNetworkInfo.ipv4Value("192.168.1.64"), 0xC0A80140)
        XCTAssertEqual(LocalNetworkInfo.ipv4String(0xC0A80140), "192.168.1.64")
    }

    func testRejectsMalformedAddresses() {
        XCTAssertNil(LocalNetworkInfo.ipv4Value("192.168.1"))
        XCTAssertNil(LocalNetworkInfo.ipv4Value("192.168.1.256"))
        XCTAssertNil(LocalNetworkInfo.ipv4Value("192.168.1.1.1"))
        XCTAssertNil(LocalNetworkInfo.ipv4Value("not an address"))
        XCTAssertNil(LocalNetworkInfo.ipv4Value(""))
    }

    // MARK: - Private ranges

    func testRecognisesPrivateRanges() {
        XCTAssertTrue(LocalNetworkInfo.isPrivate("192.168.1.1"))
        XCTAssertTrue(LocalNetworkInfo.isPrivate("10.0.0.5"))
        XCTAssertTrue(LocalNetworkInfo.isPrivate("172.16.0.1"))
        XCTAssertTrue(LocalNetworkInfo.isPrivate("172.31.255.254"))
        XCTAssertTrue(LocalNetworkInfo.isPrivate("169.254.3.4"))
    }

    /// Scanning a public range would mean probing machines that are not the
    /// user's, so this boundary is a safety property, not a detail.
    func testRejectsPublicAndNearMissRanges() {
        XCTAssertFalse(LocalNetworkInfo.isPrivate("8.8.8.8"))
        XCTAssertFalse(LocalNetworkInfo.isPrivate("172.15.0.1"))
        XCTAssertFalse(LocalNetworkInfo.isPrivate("172.32.0.1"))
        XCTAssertFalse(LocalNetworkInfo.isPrivate("192.169.0.1"))
    }

    // MARK: - Host enumeration

    func testEnumeratesEveryHostInASlash24ExceptItselfAndTheEdges() {
        let hosts = LocalNetworkInfo.hostAddresses(address: "192.168.1.64", prefixLength: 24)

        XCTAssertEqual(hosts.count, 253)                 // 254 usable, minus our own
        XCTAssertFalse(hosts.contains("192.168.1.64"))   // never probe ourselves
        XCTAssertFalse(hosts.contains("192.168.1.0"))    // network address
        XCTAssertFalse(hosts.contains("192.168.1.255"))  // broadcast
        XCTAssertTrue(hosts.contains("192.168.1.1"))
        XCTAssertTrue(hosts.contains("192.168.1.254"))
        XCTAssertEqual(Set(hosts).count, hosts.count)    // no duplicates
    }

    /// Nearby addresses come first because a router hands out neighbouring
    /// leases, so the cameras usually surface in the first second of a sweep.
    func testOrdersAddressesOutwardFromOurOwn() {
        let hosts = LocalNetworkInfo.hostAddresses(address: "192.168.1.64", prefixLength: 24)
        XCTAssertEqual(Array(hosts.prefix(4)), [
            "192.168.1.63", "192.168.1.65", "192.168.1.62", "192.168.1.66"
        ])
    }

    /// A phone on a corporate /16 must not queue 65 000 connections.
    func testCapsTheSweepOnVeryLargeSubnets() {
        let hosts = LocalNetworkInfo.hostAddresses(address: "10.0.5.20", prefixLength: 16)
        XCTAssertLessThanOrEqual(hosts.count, 1022)
        XCTAssertFalse(hosts.isEmpty)
    }

    func testRespectsSmallSubnets() {
        let hosts = LocalNetworkInfo.hostAddresses(address: "192.168.1.66", prefixLength: 29)
        XCTAssertEqual(Set(hosts), [
            "192.168.1.65", "192.168.1.67", "192.168.1.68",
            "192.168.1.69", "192.168.1.70"
        ])
    }

    func testReturnsNothingForUnusableInputs() {
        XCTAssertTrue(LocalNetworkInfo.hostAddresses(address: "192.168.1.1", prefixLength: 31).isEmpty)
        XCTAssertTrue(LocalNetworkInfo.hostAddresses(address: "192.168.1.1", prefixLength: 32).isEmpty)
        XCTAssertTrue(LocalNetworkInfo.hostAddresses(address: "garbage", prefixLength: 24).isEmpty)
    }
}
