import Foundation

/// Where a camera session is in its lifecycle. Views switch on this rather than
/// juggling separate `isLoading` / `error` / `isConnected` flags, so an
/// impossible combination (connected *and* failed) cannot be represented.
enum ConnectionState: Equatable {
    case idle
    case connecting(stage: Stage)
    case streaming
    case needsCredentials
    case failed(message: String, recovery: String?)

    /// Sub-steps of a connection, surfaced so the user sees why a slow camera is slow.
    enum Stage: String, Equatable {
        case handshake = "Connexion à la caméra…"
        case capabilities = "Lecture des capacités…"
        case profiles = "Récupération des profils vidéo…"
        case stream = "Ouverture du flux…"
    }

    var isStreaming: Bool { self == .streaming }
}

/// Everything that can go wrong talking ONVIF, with messages written for the
/// person holding the phone rather than for a log file.
enum ONVIFError: LocalizedError, Equatable {
    case noServiceURL
    case unauthorized
    case httpStatus(Int)
    case malformedResponse(String)
    case soapFault(String)
    case noVideoProfile
    case unsupported(String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .noServiceURL:
            return "Aucun service ONVIF sur cette caméra."
        case .unauthorized:
            return "Identifiants refusés par la caméra."
        case .httpStatus(let code):
            return "La caméra a répondu avec une erreur HTTP \(code)."
        case .malformedResponse(let detail):
            return "Réponse illisible de la caméra (\(detail))."
        case .soapFault(let reason):
            return reason
        case .noVideoProfile:
            return "Cette caméra n'expose aucun profil vidéo."
        case .unsupported(let feature):
            return "\(feature) n'est pas pris en charge par cette caméra."
        case .timedOut:
            return "La caméra n'a pas répondu à temps."
        }
    }

    /// Shown under the error as the concrete next step.
    var recoverySuggestion: String? {
        switch self {
        case .unauthorized:
            return "Vérifiez le nom d'utilisateur et le mot de passe ONVIF — ils sont souvent différents de ceux de l'app du fabricant."
        case .noServiceURL, .unsupported:
            return "Activez ONVIF dans les réglages de la caméra, puis relancez un scan."
        case .timedOut, .httpStatus:
            return "Vérifiez que l'appareil est bien sur le même réseau WiFi, puis réessayez."
        case .noVideoProfile:
            return "Créez un profil vidéo dans l'interface web de la caméra."
        case .malformedResponse, .soapFault:
            return "Réessayez ; si le problème persiste, la caméra utilise une variante ONVIF non standard."
        }
    }
}
