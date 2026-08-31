import XCTest
@testable import CamControl

/// The response parser is where vendor differences land, so it carries the most
/// tests: real cameras disagree on namespace prefixes, element nesting and how
/// they report failure.
final class SOAPXMLTests: XCTestCase {

    private func parse(_ xml: String) -> SOAPNode? {
        SOAPXML.parse(Data(xml.utf8))
    }

    // MARK: - Namespaces

    func testStripsVendorNamespacePrefixes() {
        let node = parse("""
        <?xml version="1.0"?>
        <SOAP-ENV:Envelope xmlns:SOAP-ENV="http://www.w3.org/2003/05/soap-envelope"
                           xmlns:tds="http://www.onvif.org/ver10/device/wsdl">
          <SOAP-ENV:Body>
            <tds:GetDeviceInformationResponse>
              <tds:Manufacturer>Reolink</tds:Manufacturer>
              <tds:Model>RLC-810A</tds:Model>
            </tds:GetDeviceInformationResponse>
          </SOAP-ENV:Body>
        </SOAP-ENV:Envelope>
        """)

        XCTAssertEqual(node?.value("Manufacturer"), "Reolink")
        XCTAssertEqual(node?.value("Model"), "RLC-810A")
    }

    func testParsesElementsWithNoNamespaceAtAll() {
        let node = parse("""
        <Envelope xmlns="http://www.w3.org/2003/05/soap-envelope">
          <Body><GetDeviceInformationResponse><Manufacturer>Generic</Manufacturer></GetDeviceInformationResponse></Body>
        </Envelope>
        """)
        XCTAssertEqual(node?.value("Manufacturer"), "Generic")
    }

    // MARK: - Structure

    /// The v1 parser read a wrapper element's own text, which is whitespace, and
    /// so never saw the `Mode` inside it. Every imaging toggle read as off.
    func testReadsModeNestedInsideWrapperElement() {
        let node = parse("""
        <s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"
                    xmlns:tt="http://www.onvif.org/ver10/schema">
          <s:Body>
            <ImagingSettings>
              <tt:BacklightCompensation>
                <tt:Mode>ON</tt:Mode>
                <tt:Level>50</tt:Level>
              </tt:BacklightCompensation>
              <tt:WideDynamicRange><tt:Mode>OFF</tt:Mode></tt:WideDynamicRange>
            </ImagingSettings>
          </s:Body>
        </s:Envelope>
        """)

        XCTAssertEqual(node?.first("BacklightCompensation")?.value("Mode"), "ON")
        XCTAssertEqual(node?.first("WideDynamicRange")?.value("Mode"), "OFF")
    }

    /// Profile tokens are attributes on repeated elements. The v1 helper searched
    /// for the attribute inside each block's *content*, so it only ever found the
    /// first profile's token, by accident.
    func testKeepsAttributesOnEveryRepeatedElement() {
        let node = parse("""
        <s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope">
          <s:Body>
            <trt:GetProfilesResponse xmlns:trt="http://www.onvif.org/ver10/media/wsdl">
              <trt:Profiles token="MainStream"><Name>Main</Name></trt:Profiles>
              <trt:Profiles token="SubStream"><Name>Sub</Name></trt:Profiles>
            </trt:GetProfilesResponse>
          </s:Body>
        </s:Envelope>
        """)

        let profiles = node?.all("Profiles") ?? []
        XCTAssertEqual(profiles.count, 2)
        XCTAssertEqual(profiles.map { $0.attributes["token"] }, ["MainStream", "SubStream"])
        XCTAssertEqual(profiles.last?.value("Name"), "Sub")
    }

    func testAllDoesNotDescendIntoItsOwnMatches() {
        let node = parse("""
        <Body><Group><Item>outer<Item>inner</Item></Item></Group></Body>
        """)
        XCTAssertEqual(node?.all("Item").count, 1)
    }

    func testEmptyElementIsTreatedAsAbsent() {
        let node = parse("<Body><Model>   </Model></Body>")
        XCTAssertNil(node?.value("Model"))
    }

    func testReturnsNilForNonXMLPayload() {
        XCTAssertNil(SOAPXML.parse(Data("<html><body>404 Not Found".utf8)))
    }

    // MARK: - Faults

    func testExtractsFaultReasonText() {
        let node = parse("""
        <s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope">
          <s:Body>
            <s:Fault>
              <s:Code><s:Value>s:Sender</s:Value></s:Code>
              <s:Reason><s:Text xml:lang="en">Sender not authorized</s:Text></s:Reason>
            </s:Fault>
          </s:Body>
        </s:Envelope>
        """)

        let reason = try? XCTUnwrap(node.flatMap(SOAPXML.faultReason(in:)))
        XCTAssertEqual(reason, "Sender not authorized")
        XCTAssertTrue(SOAPXML.isAuthenticationFault(reason ?? ""))
    }

    func testNonFaultResponseHasNoReason() {
        let node = parse("<Body><GetProfilesResponse/></Body>")
        XCTAssertNil(node.flatMap(SOAPXML.faultReason(in:)))
    }

    func testDistinguishesAuthenticationFaultsFromOtherFaults() {
        XCTAssertTrue(SOAPXML.isAuthenticationFault("ter:NotAuthorized"))
        XCTAssertTrue(SOAPXML.isAuthenticationFault("Authentication failed"))
        XCTAssertFalse(SOAPXML.isAuthenticationFault("ter:InvalidArgVal"))
    }

    // MARK: - Request building

    func testEscapesSpecialCharactersInCredentials() {
        let header = SOAPXML.securityHeader(username: "ad<min>&\"co", password: "p")
        XCTAssertTrue(header.contains("ad&lt;min&gt;&amp;&quot;co"))
        XCTAssertFalse(header.contains("<min>"))
    }

    /// The digest must be over the raw nonce bytes, not its Base64 text — the
    /// classic reason a camera rejects correct credentials.
    func testSecurityHeaderCarriesDistinctNonceEachTime() {
        let first = SOAPXML.securityHeader(username: "admin", password: "secret")
        let second = SOAPXML.securityHeader(username: "admin", password: "secret")
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(first.contains("PasswordDigest"))
    }

    func testEnvelopeIsWellFormedAndParsesBack() {
        let data = SOAPXML.envelope(header: "", body: "<GetProfiles/>")
        let node = SOAPXML.parse(data)
        XCTAssertNotNil(node?.first("GetProfiles"))
    }
}
