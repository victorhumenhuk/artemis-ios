//  Haptics.swift
//  Calm, subtle haptics. Soft single taps, never a buzzy notification pattern.

import UIKit

enum Haptics {
    static func tap() {
        let g = UIImpactFeedbackGenerator(style: .soft)
        g.prepare(); g.impactOccurred(intensity: 0.6)
    }

    static func action() {
        let g = UIImpactFeedbackGenerator(style: .medium)
        g.prepare(); g.impactOccurred(intensity: 0.7)
    }

    /// When a verdict card appears. A touch firmer for emergency, still a single
    /// soft tap, never an alarm.
    static func verdict(_ tier: TriageTier) {
        let g = UIImpactFeedbackGenerator(style: .soft)
        g.prepare(); g.impactOccurred(intensity: tier == .emergency ? 0.95 : 0.6)
    }
}
