import Foundation

/// multipart/form-data を自前で組む（ライブラリ無し）。
struct MultipartForm {
    let boundary: String
    private(set) var body = Data()

    init(boundary: String = "ZundaNavi-" + UUID().uuidString) {
        self.boundary = boundary
    }

    var contentType: String {
        return "multipart/form-data; boundary=" + boundary
    }

    mutating func addField(_ name: String, _ value: String) {
        append("--" + boundary + "\r\n")
        append("Content-Disposition: form-data; name=\"" + name + "\"\r\n")
        append("Content-Type: text/plain; charset=utf-8\r\n\r\n")
        append(value)
        append("\r\n")
    }

    mutating func addFile(_ name: String, filename: String, mimeType: String, data: Data) {
        append("--" + boundary + "\r\n")
        append("Content-Disposition: form-data; name=\"" + name + "\"; filename=\"" + filename + "\"\r\n")
        append("Content-Type: " + mimeType + "\r\n\r\n")
        body.append(data)
        append("\r\n")
    }

    func finalized() -> Data {
        var d = body
        d.append(Data(("--" + boundary + "--\r\n").utf8))
        return d
    }

    private mutating func append(_ s: String) {
        body.append(Data(s.utf8))
    }
}
