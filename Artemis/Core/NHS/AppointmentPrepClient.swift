//  AppointmentPrepClient.swift
//  Turns her recent days into a midwife script via the Worker (gpt-4o). Falls
//  back to the offline templated AdvocacyBuilder when the server is unreachable,
//  so the appointment prep always works.

import Foundation

enum AppointmentPrepClient {
    /// Returns the AI script lines (in her language), or nil to use the fallback.
    static func generate(context: String, language: String) async -> [String]? {
        let url = RealtimeConfig.serverBaseURL.appendingPathComponent("summary")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["context": context, "language": language])
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            struct R: Decodable { let text: String? }
            let text = (try? JSONDecoder().decode(R.self, from: data))?.text ?? ""
            let lines = text
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && $0.count > 2 }
            return lines.count >= 2 ? lines : nil
        } catch {
            ArtemisLog.info("AppointmentPrep: AI summary unavailable, using templated script.")
            return nil
        }
    }
}
