import Foundation

/// Why the OAuth access token could not be read.
public enum CredentialError: LocalizedError, Equatable, Sendable {
    case notFound
    case expired
    case malformed

    public var errorDescription: String? {
        switch self {
        case .notFound:
            return "Aucun jeton Claude Code trouvé. Connecte-toi une fois avec « claude »."
        case .expired:
            return "Le jeton Claude Code a expiré. Lance « claude » une fois pour le renouveler."
        case .malformed:
            return "Les identifiants Claude Code enregistrés sont illisibles."
        }
    }
}

/// Why a read of Anthropic's gauge failed.
public enum QuotaError: LocalizedError, Equatable, Sendable {
    /// HTTP 401 — the token was refused.
    case unauthorized
    /// HTTP 429, with the `Retry-After` delay in seconds when the response carried one.
    case rateLimited(retryAfter: TimeInterval?)
    /// Any other non-2xx status.
    case http(Int)
    /// A 2xx body that carries no usable meter.
    case malformed
    /// The service refused the call because the minimum spacing or the 429 backoff
    /// has not elapsed and no snapshot is cached yet.
    case throttled(until: Date)

    public var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "Anthropic a refusé le jeton (401). Lance « claude » une fois pour le renouveler."
        case .rateLimited:
            return "Anthropic limite les lectures (429). Les chiffres affichés sont les derniers connus."
        case .http(let code):
            return "Les compteurs Anthropic ont répondu HTTP \(code)."
        case .malformed:
            return "Les compteurs Anthropic ont renvoyé une réponse inattendue."
        case .throttled:
            return "Lecture trop rapprochée des compteurs Anthropic. Réessaie dans un instant."
        }
    }
}
