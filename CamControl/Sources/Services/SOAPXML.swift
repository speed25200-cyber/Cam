import Foundation
import CryptoKit

/// Minimal helpers for building ONVIF SOAP 1.2 requests with WS-Security
/// UsernameToken (digest) auth, and for pulling values out of the XML replies
/// without pulling in a full XML parsing dependency.
enum SOAPXML {

    /// Builds the WS-Security header ONVIF cameras expect for authenticated calls.
    static func securityHeader(username: String, password: String) -> String {
        let nonceBytes = (0..<16).map { _ in UInt8.random(in: 0...255) }
        let nonceData = Data(nonceBytes)
        let created = ISO8601DateFormatter().string(from: Date())

        var digestInput = Data()
        digestInput.append(nonceData)
        digestInput.append(Data(created.utf8))
        digestInput.append(Data(password.utf8))
        let digest = Insecure.SHA1.hash(data: digestInput)
        let passwordDigest = Data(digest).base64EncodedString()
        let nonceBase64 = nonceData.base64EncodedString()

        return """
        <Security xmlns="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd" \
        xmlns:u="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd">
          <UsernameToken>
            <Username>\(xmlEscape(username))</Username>
            <Password Type="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-username-token-profile-1.0#PasswordDigest">\(passwordDigest)</Password>
            <Nonce EncodingType="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-soap-message-security-1.0#Base64Binary">\(nonceBase64)</Nonce>
            <u:Created>\(created)</u:Created>
          </UsernameToken>
        </Security>
        """
    }

    static func envelope(header: String, body: String) -> Data {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope">
          <s:Header>\(header)</s:Header>
          <s:Body>\(body)</s:Body>
        </s:Envelope>
        """
        return Data(xml.utf8)
    }

    static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Returns the text content of the first element matching a local (namespace-free) tag name.
    static func firstValue(_ xml: String, tag: String) -> String? {
        // Matches <tag ...>value</tag> or <ns:tag ...>value</ns:tag>
        let pattern = "<(?:\\w+:)?\(NSRegularExpression.escapedPattern(for: tag))(?:\\s[^>]*)?>([^<]*)</(?:\\w+:)?\(NSRegularExpression.escapedPattern(for: tag))>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(xml.startIndex..., in: xml)
        guard let match = regex.firstMatch(in: xml, range: range), let valueRange = Range(match.range(at: 1), in: xml) else {
            return nil
        }
        return String(xml[valueRange]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Returns every top-level block for a repeated element, e.g. all `<trt:Profiles>...</trt:Profiles>`.
    static func allBlocks(_ xml: String, tag: String) -> [String] {
        let pattern = "<(?:\\w+:)?\(NSRegularExpression.escapedPattern(for: tag))(?:\\s[^>]*)?>([\\s\\S]*?)</(?:\\w+:)?\(NSRegularExpression.escapedPattern(for: tag))>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(xml.startIndex..., in: xml)
        return regex.matches(in: xml, range: range).compactMap {
            guard let r = Range($0.range(at: 1), in: xml) else { return nil }
            return String(xml[r])
        }
    }

    /// Returns the value of an attribute on the first element matching the given tag, e.g. token="...".
    static func firstAttribute(_ xml: String, tag: String, attribute: String) -> String? {
        let pattern = "<(?:\\w+:)?\(NSRegularExpression.escapedPattern(for: tag))\\s[^>]*\(attribute)=\"([^\"]*)\""
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(xml.startIndex..., in: xml)
        guard let match = regex.firstMatch(in: xml, range: range), let r = Range(match.range(at: 1), in: xml) else { return nil }
        return String(xml[r])
    }
}
