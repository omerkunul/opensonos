import Foundation

public enum SonosError: Error, LocalizedError, Sendable {
    case unreachable(String, String)
    case badResponse(String)
    case timeout(String)
    case notFound(String)
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case let .unreachable(ip, detail): "\(ip) unreachable: \(detail)"
        case let .badResponse(detail): "Unexpected response: \(detail)"
        case let .timeout(detail): detail
        case let .notFound(key): "Not found: \(key)"
        case let .invalid(detail): detail
        }
    }
}

/// UPnP fault returned by a device. Sonos-specific 8xx codes are undocumented:
/// 800 usually means "not ready yet", 402 is a real rejection.
public struct UPnPError: Error, LocalizedError, Sendable {
    public let action: String
    public let code: Int?
    public let detail: String

    public var errorDescription: String? {
        "\(action): UPnP error \(code.map(String.init) ?? "?") \(detail)".trimmingCharacters(in: .whitespaces)
    }
}

public enum Service: String, Sendable {
    case avTransport = "AVTransport"
    case renderingControl = "RenderingControl"
    case deviceProperties = "DeviceProperties"
    case zoneGroupTopology = "ZoneGroupTopology"

    var controlPath: String {
        switch self {
        case .avTransport: "/MediaRenderer/AVTransport/Control"
        case .renderingControl: "/MediaRenderer/RenderingControl/Control"
        case .deviceProperties: "/DeviceProperties/Control"
        case .zoneGroupTopology: "/ZoneGroupTopology/Control"
        }
    }

    var urn: String { "urn:schemas-upnp-org:service:\(rawValue):1" }
}

/// Sonos's local UPnP/SOAP interface (port 1400).
public struct SOAPClient: Sendable {
    public static let port = 1400
    private let session: URLSession

    public init(timeout: TimeInterval = 8) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        session = URLSession(configuration: config)
    }

    public func call(_ ip: String, _ service: Service, _ action: String,
                     _ args: [(String, String)] = []) async throws -> [String: String] {
        let body = args.map { "<\($0.0)>\(Self.escape($0.1))</\($0.0)>" }.joined()
        let envelope = """
        <?xml version="1.0" encoding="utf-8"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" \
        s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>\
        <u:\(action) xmlns:u="\(service.urn)">\(body)</u:\(action)></s:Body></s:Envelope>
        """
        var request = URLRequest(url: URL(string: "http://\(ip):\(Self.port)\(service.controlPath)")!)
        request.httpMethod = "POST"
        request.httpBody = Data(envelope.utf8)
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"\(service.urn)#\(action)\"", forHTTPHeaderField: "SOAPACTION")

        let (data, response) = try await send(request, ip: ip, action: action)
        if (response as? HTTPURLResponse)?.statusCode != 200 {
            throw Self.fault(action, data)
        }
        return try Self.parseResponse(action, data)
    }

    public func get(_ ip: String, path: String) async throws -> Data {
        let request = URLRequest(url: URL(string: "http://\(ip):\(Self.port)\(path)")!)
        return try await send(request, ip: ip, action: path).0
    }

    private func send(_ request: URLRequest, ip: String, action: String) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            throw SonosError.unreachable(ip, "\(action): \(error.localizedDescription)")
        }
    }

    static func parseResponse(_ action: String, _ data: Data) throws -> [String: String] {
        let root = try XNode.parse(data)
        guard let resp = root.descendants("\(action)Response").first else { return [:] }
        return Dictionary(resp.children.map { ($0.name, $0.text) }, uniquingKeysWith: { a, _ in a })
    }

    static func fault(_ action: String, _ data: Data) -> UPnPError {
        let root = try? XNode.parse(data)
        let code = root?.descendants("errorCode").first.flatMap { Int($0.text) }
        let detail = root?.descendants("errorDescription").first?.text ?? ""
        return UPnPError(action: action, code: code, detail: detail)
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
