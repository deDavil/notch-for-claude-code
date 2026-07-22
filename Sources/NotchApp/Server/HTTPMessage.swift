import Foundation

/// A parsed HTTP/1.1 request. Minimal: method, path, headers (lowercased keys), body.
struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    func header(_ name: String) -> String? { headers[name.lowercased()] }
}

/// Incremental request parser for one connection. Feed bytes; once `complete`
/// is true, `request` is available. Handles a single request (no keep-alive).
final class HTTPRequestParser {
    private var buffer = Data()
    private var headerEnd: Int? = nil
    private var contentLength = 0
    private(set) var request: HTTPRequest?

    /// Returns true when a full request has been parsed. Throws on malformed input.
    func feed(_ data: Data) throws -> Bool {
        buffer.append(data)

        if headerEnd == nil {
            if let range = buffer.range(of: Data("\r\n\r\n".utf8)) {
                headerEnd = range.upperBound
                try parseHead(upTo: range.lowerBound)
            } else if buffer.count > 64 * 1024 {
                throw HTTPError.headersTooLarge
            } else {
                return false // need more
            }
        }

        guard let headerEnd else { return false }
        let bodyAvailable = buffer.count - headerEnd
        if bodyAvailable < contentLength { return false }

        let body = buffer.subdata(in: headerEnd..<(headerEnd + contentLength))
        if let (method, path, headers) = parsedHead {
            request = HTTPRequest(method: method, path: path, headers: headers, body: body)
            return true
        }
        return false
    }

    private var parsedHead: (String, String, [String: String])?

    private func parseHead(upTo end: Data.Index) throws {
        let headData = buffer.subdata(in: buffer.startIndex..<end)
        guard let headText = String(data: headData, encoding: .utf8) else {
            throw HTTPError.badRequest
        }
        let lines = headText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { throw HTTPError.badRequest }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { throw HTTPError.badRequest }
        let method = String(parts[0])
        let path = String(parts[1])

        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }
        contentLength = Int(headers["content-length"] ?? "0") ?? 0
        parsedHead = (method, path, headers)
    }
}

enum HTTPError: Error {
    case badRequest
    case headersTooLarge
}

/// A minimal HTTP/1.1 response.
struct HTTPResponse {
    var status: Int
    var reason: String
    var contentType: String
    var body: Data

    static func json(_ status: Int, _ body: Data) -> HTTPResponse {
        HTTPResponse(status: status, reason: reasonPhrase(status),
                     contentType: "application/json", body: body)
    }

    static func text(_ status: Int, _ text: String) -> HTTPResponse {
        HTTPResponse(status: status, reason: reasonPhrase(status),
                     contentType: "text/plain; charset=utf-8", body: Data(text.utf8))
    }

    /// 200 with an empty body — used for "no opinion" (Claude falls back to its prompt).
    static func empty(_ status: Int) -> HTTPResponse {
        HTTPResponse(status: status, reason: reasonPhrase(status),
                     contentType: "application/json", body: Data())
    }

    func serialized() -> Data {
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n"
        head += "\r\n"
        var data = Data(head.utf8)
        data.append(body)
        return data
    }

    static func reasonPhrase(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 500: return "Internal Server Error"
        default: return "Status"
        }
    }
}
