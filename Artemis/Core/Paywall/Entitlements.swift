//  Entitlements.swift
//  RevenueCat wrapper. Cosmetic for the MVP: isPremium only affects framing on
//  full trend history, kick & BP tracking, partner sharing and multilingual
//  voice. Safety features (triage, routing, advocacy, daily check-in, crisis)
//  are NEVER gated.

import Foundation
import Observation

@MainActor @Observable
final class Entitlements {
    var isPremium = false
    var showingPaywall = false

    /// Entitlement id configured in the RevenueCat dashboard.
    private let entitlementID = "premium"

    func configure() {
        #if canImport(RevenueCat)
        guard let key = Bundle.main.object(forInfoDictionaryKey: "RevenueCatAPIKey") as? String,
              !key.isEmpty, !key.hasPrefix("appl_REPLACE") else {
            // No key configured: stay cosmetic, never block anything.
            return
        }
        RevenueCatBridge.configure(apiKey: key, entitlementID: entitlementID) { [weak self] active in
            Task { @MainActor in self?.isPremium = active }
        }
        #endif
    }

    func showPaywall() { showingPaywall = true }
    func dismissPaywall() { showingPaywall = false }

    /// Cosmetic gate helper. Always returns true for safety-critical features;
    /// callers pass `safety: true` for those.
    func isUnlocked(_ feature: PremiumFeature) -> Bool {
        feature.isSafety ? true : isPremium
    }
}

enum PremiumFeature {
    case triage, routing, advocacy, dailyCheckin, crisis    // safety, never gated
    case fullHistory, kickTracking, bpTracking, partnerSharing, multilingualVoice

    var isSafety: Bool {
        switch self {
        case .triage, .routing, .advocacy, .dailyCheckin, .crisis: return true
        default: return false
        }
    }
}

#if canImport(RevenueCat)
import RevenueCat

enum RevenueCatBridge {
    static func configure(apiKey: String, entitlementID: String, onChange: @escaping (Bool) -> Void) {
        Purchases.configure(withAPIKey: apiKey)
        Task {
            if let info = try? await Purchases.shared.customerInfo() {
                onChange(info.entitlements[entitlementID]?.isActive == true)
            }
            for await info in Purchases.shared.customerInfoStream {
                onChange(info.entitlements[entitlementID]?.isActive == true)
            }
        }
    }
}
#endif
