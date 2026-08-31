import CryptoKit
import Foundation
import Security

/// One element of a parsed SOAP response, with its namespace prefix stripped.
///
/// ONVIF replies use different prefixes per vendor for the same schema
/// (`tt:`, `tds:`, `trt:`, sometimes none at all), so every lookup here is by
/// local name only.
struct SOAPNode {
    var name: String
    var attributes: [String: String]
    var text: String
    var children: [SOAPNode]

    /// Depth-first search for the first descendant with this local name.
    func first(_ name: String) -> SOAPNode? {
        for child in children {
            if child.name == name { return child }
            if let found = child.first(name) { return found }
        }
        return nil
    }

    /// Every descendant with this local name. Does not descend into a match,
    /// so nested elements of the same name yield only the outermost ones.
    func all(_ name: String) -> [SOAPNode] {
        var results: [SOAPNode] = []
        for child in children {
            if child.name == name {
                results.append(child)
            } else {
                results.append(contentsOf: child.all(name))
            }
        }
        return results
    }

    /// Text of the first descendant with this name, empty strings treated as absent.
    func value(_ name: String) -> String? {
        guard let node = first(name) else { return nil }
        let trimmed = node.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func doubleValue(_ name: String) -> Double? {
        value(name).flatMap { Double($0) }
    }

    var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// Builds ONVIF SOAP 1.2 requests and parses the replies.
enum SOAPXML {

    // MARK: - Request building

    static func envelope(header: String, body: String) -> Data {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" \
        xmlns:tt="http://www.onvif.org/ver10/schema">
        <s:Header>\(header)</s:Header>
        <s:Body>\(body)</s:Body>
        </s:Envelope>
        """
        return Data(xml.utf8)
    }

    /// WS-Security `UsernameToken` with a password digest — the scheme every
    /// ONVIF Profile S device accepts, and the only one that never puts the
    /// password itself on the wire.
    ///
    /// digest = Base64(SHA1(nonce + created + password)), with `nonce` as raw
    /// bytes rather than its Base64 text; sending the encoded form instead is the
    /// classic reason a camera answers 401 to correct credentials.
    static func securityHeader(username: String, password: String, clockOffset: TimeInterval = 0) -> String {
        var nonce = Data(count: 16)
        let generated: Bool = nonce.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return false }
            return SecRandomCopyBytes(kSecRandomDefault, buffer.count, base) == errSecSuccess
        }
        if !generated {
            nonce = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        }

        let created = iso8601.string(from: Date().addingTimeInterval(clockOffset))

        var digestInput = Data()
        digestInput.append(nonce)
        digestInput.append(Data(created.utf8))
        digestInput.append(Data(password.utf8))
        let digest = Data(Insecure.SHA1.hash(data: digestInput)).base64EncodedString()

        return """
        <wsse:Security s:mustUnderstand="1" \
        xmlns:wsse="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd" \
        xmlns:wsu="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd">\
        <wsse:UsernameToken>\
        <wsse:Username>\(escape(username))</wsse:Username>\
        <wsse:Password Type="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-username-token-profile-1.0#PasswordDigest">\(digest)</wsse:Password>\
        <wsse:Nonce EncodingType="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-soap-message-security-1.0#Base64Binary">\(nonce.base64EncodedString())</wsse:Nonce>\
        <wsu:Created>\(created)</wsu:Created>\
        </wsse:UsernameToken>\
        </wsse:Security>
        """
    }

    /// Cameras frequently have a badly wrong clock; ONVIF requires the `Created`
    /// timestamp to be within a few minutes of *device* time, so the offset
    /// between the two is measured once and reused.
    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    static func escape(_ value: String) -> String {
        var result = ""
        result.reserveCapacity(value.count)
        for character in value {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&apos;"
            default: result.append(character)
            }
        }
        return result
    }

    // MARK: - Response parsing

    /// Parses a SOAP response into its `<Body>` contents.
    /// Returns `nil` when the payload is not XML at all — some cameras answer a
    /// plain HTML error page with a 200 status.
    static func parse(_ data: Data) -> SOAPNode? {
        let parser = SOAPTreeParser()
        return parser.parse(data)
    }

    /// Extracts a human-readable reason from a SOAP fault, if the reply is one.
    static func faultReason(in node: SOAPNode) -> String? {
        guard let fault = node.first("Fault") else { return nil }
        if let text = fault.first("Reason")?.value("Text") { return text }
        if let string = fault.value("faultstring") { return string }
        if let code = fault.first("Code")?.value("Value") { return code }
        return "La caméra a renvoyé une erreur SOAP."
    }

    /// True when a fault says the credentials were rejected. Cameras signal this
    /// inconsistently — some with HTTP 401, others with a 200 and a fault whose
    /// subcode mentions the failed authentication — so both paths are checked.
    static func isAuthenticationFault(_ reason: String) -> Bool {
        let lowered = reason.lowercased()
        return lowered.contains("notauthorized")
            || lowered.contains("not authorized")
            || lowered.contains("unauthorized")
            || lowered.contains("authentication")
            || lowered.contains("sender not authorized")
    }
}

/// `XMLParser` delegate that builds a `SOAPNode` tree.
///
/// Namespace processing is on, so `elementName` arrives as the local name and
/// vendor prefix differences disappear before anything else sees them.
private final class SOAPTreeParser: NSObject, XMLParserDelegate {
    private var stack: [SOAPNode] = []
    private var root: SOAPNode?

    func parse(_ data: Data) -> SOAPNode? {
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = self
        guard parser.parse(), let root else { return nil }
        // Callers care about the Body payload; fall back to the whole document
        // for non-enveloped replies (WS-Discovery unicast answers, mostly).
        return root.first("Body") ?? root
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes attributeDict: [String: String]
    ) {
        stack.append(SOAPNode(name: elementName, attributes: attributeDict, text: "", children: []))
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard !stack.isEmpty else { return }
        stack[stack.count - 1].text += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?
    ) {
        guard let finished = stack.popLast() else { return }
        if stack.isEmpty {
            root = finished
        } else {
            stack[stack.count - 1].children.append(finished)
        }
    }
}
