import XCTest
@testable import CamControl

final class ProbeMatchTests: XCTestCase {

    private func parse(_ xml: String) -> ONVIFDiscovery.Hit? {
        ONVIFDiscovery.parseProbeMatch(Data(xml.utf8))
    }

    func testReadsAddressAndScopesFromARealProbeMatch() {
        let hit = parse("""
        <?xml version="1.0" encoding="UTF-8"?>
        <SOAP-ENV:Envelope xmlns:SOAP-ENV="http://www.w3.org/2003/05/soap-envelope"
                           xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery">
          <SOAP-ENV:Body>
            <d:ProbeMatches>
              <d:ProbeMatch>
                <d:Types>dn:NetworkVideoTransmitter</d:Types>
                <d:Scopes>onvif://www.onvif.org/name/Reolink onvif://www.onvif.org/hardware/RLC-810A</d:Scopes>
                <d:XAddrs>http://192.168.1.64/onvif/device_service</d:XAddrs>
                <d:MetadataVersion>1</d:MetadataVersion>
              </d:ProbeMatch>
            </d:ProbeMatches>
          </SOAP-ENV:Body>
        </SOAP-ENV:Envelope>
        """)

        XCTAssertEqual(hit?.host, "192.168.1.64")
        XCTAssertEqual(hit?.serviceURL.absoluteString, "http://192.168.1.64/onvif/device_service")
        XCTAssertEqual(hit?.name, "Reolink")
        XCTAssertEqual(hit?.hardware, "RLC-810A")
    }

    /// Vendors use their own namespace prefixes; the v1 parser looked for the
    /// literal string "<d:XAddrs>" and missed every camera that used another.
    func testHandlesAnyNamespacePrefix() {
        let hit = parse("""
        <s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"
                    xmlns:wsdd="http://schemas.xmlsoap.org/ws/2005/04/discovery">
          <s:Body><wsdd:ProbeMatches><wsdd:ProbeMatch>
            <wsdd:XAddrs>http://10.0.0.12:8000/onvif/device_service</wsdd:XAddrs>
          </wsdd:ProbeMatch></wsdd:ProbeMatches></s:Body>
        </s:Envelope>
        """)

        XCTAssertEqual(hit?.host, "10.0.0.12")
        XCTAssertEqual(hit?.serviceURL.port, 8000)
    }

    /// Multi-homed cameras list every interface. Loopback is never reachable
    /// from the phone, so the next candidate has to win.
    func testSkipsUnreachableAddressesInAMultiHomedList() {
        let hit = parse("""
        <Envelope><Body><ProbeMatches><ProbeMatch>
          <XAddrs>http://127.0.0.1/onvif/device_service http://192.168.1.80/onvif/device_service</XAddrs>
        </ProbeMatch></ProbeMatches></Body></Envelope>
        """)

        XCTAssertEqual(hit?.host, "192.168.1.80")
    }

    func testPercentDecodesScopeValues() {
        let hit = parse("""
        <Envelope><Body><ProbeMatches><ProbeMatch>
          <Scopes>onvif://www.onvif.org/name/Front%20Door</Scopes>
          <XAddrs>http://192.168.1.81/onvif/device_service</XAddrs>
        </ProbeMatch></ProbeMatches></Body></Envelope>
        """)

        XCTAssertEqual(hit?.name, "Front Door")
    }

    func testIgnoresRepliesThatAreNotProbeMatches() {
        XCTAssertNil(parse("<Envelope><Body><Hello/></Body></Envelope>"))
        XCTAssertNil(parse("<Envelope><Body><ProbeMatches><ProbeMatch/></ProbeMatches></Body></Envelope>"))
        XCTAssertNil(ONVIFDiscovery.parseProbeMatch(Data("garbage".utf8)))
    }
}

@MainActor
final class CameraStoreTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CamControlTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testPersistsCamerasAcrossInstances() {
        let store = CameraStore(directory: directory)
        store.add(Camera(host: "192.168.1.10", kind: .onvif, customName: "Garage"))

        let reloaded = CameraStore(directory: directory)
        XCTAssertEqual(reloaded.cameras.count, 1)
        XCTAssertEqual(reloaded.cameras.first?.customName, "Garage")
        XCTAssertTrue(reloaded.cameras.first?.isSaved == true)
    }

    func testAddingTheSameCameraTwiceDoesNotDuplicateIt() {
        let store = CameraStore(directory: directory)
        let first = store.add(Camera(host: "192.168.1.10", kind: .onvif))
        let second = store.add(Camera(host: "192.168.1.10", kind: .onvif, manufacturer: "Axis"))

        XCTAssertEqual(store.cameras.count, 1)
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(store.cameras.first?.manufacturer, "Axis")
    }

    func testReconcileFollowsACameraToANewAddress() {
        let store = CameraStore(directory: directory)
        let saved = store.add(Camera(host: "192.168.1.10", kind: .onvif, serialNumber: "SN-7", customName: "Cour"))

        store.reconcile(with: [Camera(host: "192.168.1.55", kind: .onvif, serialNumber: "SN-7")])

        XCTAssertEqual(store.cameras.count, 1)
        XCTAssertEqual(store.cameras.first?.id, saved.id)
        XCTAssertEqual(store.cameras.first?.host, "192.168.1.55")
        XCTAssertEqual(store.cameras.first?.customName, "Cour")
    }

    func testRenameStoresATrimmedNameAndClearsAnEmptyOne() {
        let store = CameraStore(directory: directory)
        let camera = store.add(Camera(host: "192.168.1.10", manufacturer: "Axis"))

        store.rename(camera, to: "  Terrasse  ")
        XCTAssertEqual(store.cameras.first?.customName, "Terrasse")

        store.rename(camera, to: "   ")
        XCTAssertNil(store.cameras.first?.customName)
        XCTAssertEqual(store.cameras.first?.displayName, "Axis")
    }

    func testRemoveTakesTheCameraOutOfTheSavedFileToo() {
        let store = CameraStore(directory: directory)
        let camera = store.add(Camera(host: "192.168.1.10"))
        store.remove(camera)

        XCTAssertTrue(store.isEmpty)
        XCTAssertTrue(CameraStore(directory: directory).isEmpty)
    }

    /// A corrupt file must not brick the app, and must not be destroyed silently.
    func testRecoversFromACorruptLibraryFile() throws {
        let fileURL = directory.appendingPathComponent("cameras.json")
        try Data("{ not json".utf8).write(to: fileURL)

        let store = CameraStore(directory: directory)
        XCTAssertTrue(store.isEmpty)
        XCTAssertNotNil(store.persistenceError)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.appendingPathExtension("corrupt").path))
    }
}
