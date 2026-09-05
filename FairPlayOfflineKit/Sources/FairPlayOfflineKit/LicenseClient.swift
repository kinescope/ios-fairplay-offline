import Foundation

enum LicenseClientError: LocalizedError {
    case invalidResponse
    case httpStatus(Int, String?)
    case emptyCertificate
    case invalidCKC

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "The license server returned an invalid response."
        case .httpStatus(let statusCode, let message):
            let suffix = message.map { ": \($0)" } ?? ""
            return "The license server returned HTTP \(statusCode)\(suffix)."
        case .emptyCertificate:
            return "The FairPlay certificate is empty."
        case .invalidCKC:
            return "The license server response does not contain a valid CKC."
        }
    }
}

struct LicenseClient {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchCertificate(from url: URL) async throws -> Data {
        FairPlayLog.drm.info(
            "Certificate request endpoint=\(FairPlayLog.endpoint(url), privacy: .public)"
        )
        let (data, response) = try await session.data(from: url)
        FairPlayLog.drm.info(
            "Certificate response status=\((response as? HTTPURLResponse)?.statusCode ?? -1)"
        )
        try validate(response: response, data: data)

        guard !data.isEmpty else {
            throw LicenseClientError.emptyCertificate
        }
        FairPlayLog.drm.info("Certificate received bytes=\(data.count)")
        return data
    }

    func acquireCKC(from url: URL, spc: Data) async throws -> Data {
        FairPlayLog.drm.info(
            """
            CKC request endpoint=\(FairPlayLog.endpoint(url), privacy: .public) \
            spcBytes=\(spc.count)
            """
        )
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(
            LicenseRequest(spc: spc.base64EncodedString())
        )

        let (data, response) = try await session.data(for: request)
        FairPlayLog.drm.info(
            "CKC response status=\((response as? HTTPURLResponse)?.statusCode ?? -1)"
        )
        try validate(response: response, data: data)

        let payload = try JSONDecoder().decode(LicenseResponse.self, from: data)
        guard let ckc = Data(base64Encoded: payload.ckc), !ckc.isEmpty else {
            throw LicenseClientError.invalidCKC
        }
        FairPlayLog.drm.info("CKC received bytes=\(ckc.count)")
        return ckc
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LicenseClientError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8).map {
                String($0.prefix(512))
            }
            throw LicenseClientError.httpStatus(httpResponse.statusCode, message)
        }
    }
}

private struct LicenseRequest: Encodable {
    let spc: String
}

private struct LicenseResponse: Decodable {
    let ckc: String
}
