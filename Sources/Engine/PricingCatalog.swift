import Foundation

public struct ModelPricing: Sendable, Hashable {
    public let canonicalName: String
    /// USD per 1,000,000 tokens
    public let inputPerMillion: Double
    public let outputPerMillion: Double
    public let cacheReadPerMillion: Double
    public let cacheCreatePerMillion: Double
    public let isEstimated: Bool

    public func computeCost(
        input: Int64,
        output: Int64,
        cacheRead: Int64,
        cacheCreate: Int64,
        cacheCreate1h: Int64 = 0
    ) -> (costUSD: Double, cacheSavedUSD: Double) {
        let m = 1_000_000.0
        let inCost = Double(max(0, input)) / m * inputPerMillion
        let outCost = Double(max(0, output)) / m * outputPerMillion
        let crCost = Double(max(0, cacheRead)) / m * cacheReadPerMillion
        let cc5mCost = Double(max(0, cacheCreate)) / m * cacheCreatePerMillion
        // 1-hour ephemeral cache creation is 2.0x input price (vs 1.25x for 5m)
        let cc1hCost = Double(max(0, cacheCreate1h)) / m * (inputPerMillion * 2.0)
        let saved = Double(max(0, cacheRead)) / m * max(0, inputPerMillion - cacheReadPerMillion)
        return (inCost + outCost + crCost + cc5mCost + cc1hCost, saved)
    }
}

public enum PricingCatalog {
    /// Normalize Antigravity/Claude/Codex model variants to clean display + pricing names.
    public static func normalizeModelName(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return "unknown" }

        var cleaned = s.lowercased()
        if cleaned.hasPrefix("models/") {
            cleaned = String(cleaned.dropFirst("models/".count))
        }

        // Strip trailing 8-digit date tags (e.g. -20260901) BEFORE tier suffixes (-high/-low)
        // in a fixed-point loop so both "model-high-20260901" and "model-20260901-high" normalize cleanly.
        let suffixes = ["-xhigh", "-high", "-medium", "-low", "-n", "-d"]
        var didStrip = true
        while didStrip {
            didStrip = false
            if let range = cleaned.range(of: #"-\d{8}$"#, options: .regularExpression) {
                cleaned.removeSubrange(range)
                didStrip = true
            }
            for suffix in suffixes where cleaned.hasSuffix(suffix) {
                cleaned = String(cleaned.dropLast(suffix.count))
                didStrip = true
            }
        }
        return cleaned.isEmpty ? raw : cleaned
    }

    public static func pricing(for rawModel: String) -> ModelPricing {
        let m = normalizeModelName(rawModel)

        // Anthropic Claude family (public API list prices per 1M tokens)
        if m.contains("claude-opus-5") || m.contains("claude-opus-4-6") || m.contains("claude-opus-4-5") {
            return ModelPricing(
                canonicalName: m,
                inputPerMillion: 5.0,
                outputPerMillion: 25.0,
                cacheReadPerMillion: 0.50,
                cacheCreatePerMillion: 6.25,
                isEstimated: false
            )
        }
        if m.contains("claude-opus-4") || m.contains("claude-3-opus") {
            return ModelPricing(
                canonicalName: m,
                inputPerMillion: 15.0,
                outputPerMillion: 75.0,
                cacheReadPerMillion: 1.50,
                cacheCreatePerMillion: 18.75,
                isEstimated: false
            )
        }
        if m.contains("claude-sonnet") || m.contains("claude-3-5-sonnet") || m.contains("claude-3-7-sonnet") {
            return ModelPricing(
                canonicalName: m,
                inputPerMillion: 3.0,
                outputPerMillion: 15.0,
                cacheReadPerMillion: 0.30,
                cacheCreatePerMillion: 3.75,
                isEstimated: false
            )
        }
        if m.contains("claude-haiku-5") || m.contains("claude-haiku-4") || m.contains("claude-3-5-haiku") {
            return ModelPricing(
                canonicalName: m,
                inputPerMillion: 1.0,
                outputPerMillion: 5.0,
                cacheReadPerMillion: 0.10,
                cacheCreatePerMillion: 1.25,
                isEstimated: false
            )
        }
        if m.contains("claude-3-haiku") {
            return ModelPricing(
                canonicalName: m,
                inputPerMillion: 0.25,
                outputPerMillion: 1.25,
                cacheReadPerMillion: 0.03,
                cacheCreatePerMillion: 0.30,
                isEstimated: false
            )
        }

        // Google Gemini family (public generic prefixes; check flash variants before general pro/generation prefixes)
        if m.contains("flash-lite") {
            return ModelPricing(
                canonicalName: m,
                inputPerMillion: 0.10,
                outputPerMillion: 0.40,
                cacheReadPerMillion: 0.025,
                cacheCreatePerMillion: 0.10,
                isEstimated: false
            )
        }
        if m.contains("gemini") && m.contains("flash") {
            return ModelPricing(
                canonicalName: m,
                inputPerMillion: 0.30,
                outputPerMillion: 2.50,
                cacheReadPerMillion: 0.03,
                cacheCreatePerMillion: 0.30,
                isEstimated: false
            )
        }
        if m.contains("gemini-4") || m.contains("gemini-3") || m.contains("gemini-2.5-pro") {
            return ModelPricing(
                canonicalName: m,
                inputPerMillion: 1.25,
                outputPerMillion: 10.0,
                cacheReadPerMillion: 0.125,
                cacheCreatePerMillion: 1.25,
                isEstimated: m.contains("gemini-4")
            )
        }

        // OpenAI / Codex CLI family (public API list prices per 1M tokens)
        if m.contains("gpt-5") && m.contains("mini") {
            return ModelPricing(
                canonicalName: m,
                inputPerMillion: 0.25,
                outputPerMillion: 2.0,
                cacheReadPerMillion: 0.025,
                cacheCreatePerMillion: 0.25,
                isEstimated: false
            )
        }
        if m.contains("gpt-5") || m.contains("codex") {
            return ModelPricing(
                canonicalName: m,
                inputPerMillion: 1.25,
                outputPerMillion: 10.0,
                cacheReadPerMillion: 0.125,
                cacheCreatePerMillion: 1.25,
                isEstimated: false
            )
        }
        if m.contains("o4-mini") || m.contains("o3-mini") {
            return ModelPricing(
                canonicalName: m,
                inputPerMillion: 1.10,
                outputPerMillion: 4.40,
                cacheReadPerMillion: 0.275,
                cacheCreatePerMillion: 1.10,
                isEstimated: false
            )
        }
        if m.contains("o3") || m.contains("gpt-4.1") {
            return ModelPricing(
                canonicalName: m,
                inputPerMillion: 2.0,
                outputPerMillion: 8.0,
                cacheReadPerMillion: 0.50,
                cacheCreatePerMillion: 2.0,
                isEstimated: false
            )
        }
        if m.contains("gpt-4o-mini") {
            return ModelPricing(
                canonicalName: m,
                inputPerMillion: 0.15,
                outputPerMillion: 0.60,
                cacheReadPerMillion: 0.075,
                cacheCreatePerMillion: 0.15,
                isEstimated: false
            )
        }
        if m.contains("gpt-4o") {
            return ModelPricing(
                canonicalName: m,
                inputPerMillion: 2.50,
                outputPerMillion: 10.0,
                cacheReadPerMillion: 1.25,
                cacheCreatePerMillion: 2.50,
                isEstimated: false
            )
        }

        // Family fallback (never silently $0.00 — marks isEstimated = true)
        if m.contains("claude") {
            return ModelPricing(
                canonicalName: m,
                inputPerMillion: 3.0,
                outputPerMillion: 15.0,
                cacheReadPerMillion: 0.30,
                cacheCreatePerMillion: 3.75,
                isEstimated: true
            )
        }
        return ModelPricing(
            canonicalName: m,
            inputPerMillion: 1.25,
            outputPerMillion: 10.0,
            cacheReadPerMillion: 0.125,
            cacheCreatePerMillion: 1.25,
            isEstimated: true
        )
    }

    public static func modelSlug(forEnum value: UInt64) -> String {
        "model-\(value)"
    }
}
