import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct PersonalPlatformConfiguration: Equatable, Sendable {
    public let platformBaseURL: URL
    public let calorieBaseURL: URL

    public init(platformBaseURL: URL, calorieBaseURL: URL) {
        self.platformBaseURL = platformBaseURL
        self.calorieBaseURL = calorieBaseURL
    }
}

public enum PersonalPlatformError: LocalizedError, Equatable, Sendable {
    case invalidResponse
    case invalidAppleCredential
    case missingBearerSession
    case signedOut
    case secureStorage
    case server(status: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse: "Personal Platform returned an invalid response."
        case .invalidAppleCredential: "Apple did not return a usable identity credential."
        case .missingBearerSession: "The identity service did not create a bearer session."
        case .signedOut: "Connect this app to Pace first."
        case .secureStorage: "The secure session could not be updated."
        case let .server(_, message): message
        }
    }
}

public actor PersonalPlatformClient {
    private let configuration: PersonalPlatformConfiguration
    private let urlSession: URLSession
    private let sessionStore: any PersonalSessionStoring

    public init(
        configuration: PersonalPlatformConfiguration,
        urlSession: URLSession = .shared,
        sessionStore: any PersonalSessionStoring
    ) {
        self.configuration = configuration
        self.urlSession = urlSession
        self.sessionStore = sessionStore
    }

    public func restoreSession() async throws -> PersonalPlatformSession? {
        guard let session = try await sessionStore.load() else { return nil }
        guard !session.isExpired else {
            try await sessionStore.delete()
            return nil
        }
        return session
    }

    public func signInWithApple(
        _ credential: AppleIdentityCredential,
        device: PersonalDevice,
        scopes: [PersonalPlatformScope]
    ) async throws -> PersonalPlatformSession {
        let calorieToken = try await exchangeAppleCredential(credential)
        let exchange = AuthExchangeRequest(scopes: scopes, device: device)
        let response: PlatformExchangeResponse = try await request(
            baseURL: configuration.platformBaseURL,
            path: "/v1/auth/exchange",
            method: "POST",
            bearer: calorieToken,
            bodyData: try Self.encoder.encode(exchange)
        )
        let session = PersonalPlatformSession(
            token: response.token,
            calorieToken: calorieToken,
            expiresAt: response.expiresAt,
            scopes: response.scopes,
            identity: response.identity
        )
        try await sessionStore.save(session)
        return session
    }

    public func get<ResponseBody: Decodable & Sendable>(
        path: String,
        includesCalorieCredential: Bool = false
    ) async throws -> ResponseBody {
        guard let session = try await restoreSession() else {
            throw PersonalPlatformError.signedOut
        }
        return try await request(
            baseURL: configuration.platformBaseURL,
            path: path,
            method: "GET",
            bearer: session.token,
            calorieBearer: includesCalorieCredential ? session.calorieToken : nil,
            bodyData: nil
        )
    }

    public func send<ResponseBody: Decodable & Sendable, Body: Encodable & Sendable>(
        path: String,
        method: String = "POST",
        body: Body,
        includesCalorieCredential: Bool = false
    ) async throws -> ResponseBody {
        guard let session = try await restoreSession() else {
            throw PersonalPlatformError.signedOut
        }
        return try await request(
            baseURL: configuration.platformBaseURL,
            path: path,
            method: method,
            bearer: session.token,
            calorieBearer: includesCalorieCredential ? session.calorieToken : nil,
            bodyData: try Self.encoder.encode(body)
        )
    }

    public func signOut() async {
        try? await sessionStore.delete()
    }

    private func exchangeAppleCredential(_ credential: AppleIdentityCredential) async throws -> String {
        let requestBody = AppleRequest(
            provider: "apple",
            idToken: AppleIDToken(
                token: credential.identityToken,
                nonce: credential.nonce,
                user: AppleUser(
                    email: credential.email,
                    name: AppleName(firstName: credential.firstName, lastName: credential.lastName)
                )
            )
        )
        let (_, response) = try await rawRequest(
            baseURL: configuration.calorieBaseURL,
            path: "/api/auth/sign-in/social",
            method: "POST",
            bearer: nil,
            calorieBearer: nil,
            bodyData: try Self.encoder.encode(requestBody)
        )
        guard let token = response.value(forHTTPHeaderField: "set-auth-token"), !token.isEmpty else {
            throw PersonalPlatformError.missingBearerSession
        }
        return token
    }

    private func request<ResponseBody: Decodable>(
        baseURL: URL,
        path: String,
        method: String,
        bearer: String?,
        calorieBearer: String? = nil,
        bodyData: Data?
    ) async throws -> ResponseBody {
        let response = try await rawRequest(
            baseURL: baseURL,
            path: path,
            method: method,
            bearer: bearer,
            calorieBearer: calorieBearer,
            bodyData: bodyData
        )
        let (data, httpResponse) = response
        guard !data.isEmpty else { throw PersonalPlatformError.invalidResponse }
        do {
            return try Self.decoder.decode(ResponseBody.self, from: data)
        } catch {
            throw PersonalPlatformError.server(
                status: httpResponse.statusCode,
                message: "Personal Platform returned data this app could not read."
            )
        }
    }

    private func rawRequest(
        baseURL: URL,
        path: String,
        method: String,
        bearer: String?,
        calorieBearer: String?,
        bodyData: Data?
    ) async throws -> (Data, HTTPURLResponse) {
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
            throw PersonalPlatformError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        if let calorieBearer {
            request.setValue("Bearer \(calorieBearer)", forHTTPHeaderField: "X-Calorie-Session")
        }
        if let bodyData {
            request.httpBody = bodyData
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PersonalPlatformError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let error = try? Self.decoder.decode(ErrorResponse.self, from: data)
            throw PersonalPlatformError.server(
                status: httpResponse.statusCode,
                message: error?.message ?? "Personal Platform could not complete the request."
            )
        }
        return (data, httpResponse)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()
}

private struct AuthExchangeRequest: Encodable {
    let scopes: [PersonalPlatformScope]
    let device: PersonalDevice
}

private struct PlatformExchangeResponse: Decodable {
    let token: String
    let expiresAt: Date
    let scopes: [PersonalPlatformScope]
    let identity: PersonalIdentity
}

private struct AppleRequest: Encodable {
    let provider: String
    let idToken: AppleIDToken
}

private struct AppleIDToken: Encodable {
    let token: String
    let nonce: String
    let user: AppleUser
}

private struct AppleUser: Encodable {
    let email: String?
    let name: AppleName
}

private struct AppleName: Encodable {
    let firstName: String?
    let lastName: String?
}

private struct ErrorResponse: Decodable {
    let message: String
}
