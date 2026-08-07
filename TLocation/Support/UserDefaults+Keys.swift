import Foundation

extension UserDefaults {
    enum Keys {
        static let targetDeviceIP = "TunnelDeviceIP"
        /// `timeIntervalSince1970` of the signing expiry the user chose to stop being
        /// warned about. Keyed to the date rather than stored as a plain flag so that
        /// refreshing in SideStore — which mints a new certificate and a new expiry —
        /// brings the warning back next week instead of silencing it forever.
        static let suppressedExpiryWarning = "suppressedExpiryWarning"
    }
}
