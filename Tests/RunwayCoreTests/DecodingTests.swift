import Foundation
import Testing
@testable import RunwayCore

func fixtureData() throws -> Data {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/usage-sample.json")
    return try Data(contentsOf: url)
}

func iso(_ s: String) -> Date { ISODate.parse(s)! }

@Suite struct DecodingTests {
    @Test func decodesRealFixture() throws {
        let response = try HTTPUsageClient.decode(try fixtureData())
        #expect(response.limits?.count == 3)
        #expect(response.fiveHour?.utilization == 18)

        let snap = UsageSnapshot(response: response, fetchedAt: Date())
        #expect(snap.session?.percent == 18)
        #expect(snap.session?.resetsAt == iso("2026-11-26T16:10:00.252515+00:00"))
        #expect(snap.weekly?.percent == 73)
        #expect(snap.scoped.count == 1)
        #expect(snap.scoped.first?.modelName == "Fable")
        #expect(snap.scoped.first?.percent == 0)
        #expect(snap.credits == UsageCredits(used: 30.80, limit: 30.00, currency: "EUR"))
        #expect(snap.credits?.isCapReached == true)
    }

    @Test func parsesSixDigitFractionalSeconds() {
        let date = ISODate.parse("2026-11-26T16:10:00.252515+00:00")
        let plain = ISODate.parse("2026-11-26T16:10:00+00:00")
        #expect(date != nil)
        #expect(abs(date!.timeIntervalSince(plain!) - 0.252515) < 0.0001)
        #expect(ISODate.parse("2026-11-26T16:10:00Z") == plain)
        #expect(ISODate.parse("garbage") == nil)
        #expect(ISODate.parse(nil) == nil)
    }

    @Test func toleratesMissingAndNullFields() throws {
        let json = #"""
        {
          "five_hour": {"utilization": 42.5, "resets_at": null},
          "seven_day": null,
          "extra_usage": null,
          "limits": null,
          "brand_new_key": {"whatever": [1, 2, 3]}
        }
        """#
        let response = try HTTPUsageClient.decode(Data(json.utf8))
        let snap = UsageSnapshot(response: response, fetchedAt: Date())
        #expect(snap.session?.percent == 42.5)
        #expect(snap.session?.resetsAt == nil)
        #expect(snap.weekly == nil)
        #expect(snap.scoped.isEmpty)
        #expect(snap.credits == nil)
    }

    @Test func emptyObjectDecodes() throws {
        let snap = UsageSnapshot(response: try HTTPUsageClient.decode(Data("{}".utf8)), fetchedAt: Date())
        #expect(snap.session == nil && snap.weekly == nil && snap.credits == nil)
    }

    @Test func wrongTypesBecomeNilInsteadOfFailing() throws {
        let json = #"""
        {
          "limits": [
            {"kind": "session", "percent": "55", "resets_at": 12, "scope": "weird"},
            "not-an-object",
            {"kind": "weekly_all", "percent": null},
            {"kind": "weekly_scoped", "percent": 10, "scope": {"model": {"display_name": null, "id": "opus"}}}
          ],
          "seven_day": {"utilization": 61, "resets_at": "2026-11-30T15:00:00+00:00"},
          "extra_usage": {"is_enabled": true, "used_credits": 150, "monthly_limit": null}
        }
        """#
        let snap = UsageSnapshot(response: try HTTPUsageClient.decode(Data(json.utf8)), fetchedAt: Date())
        #expect(snap.session?.percent == 55)
        #expect(snap.session?.resetsAt == nil)
        // weekly_all had no percent → falls back to seven_day
        #expect(snap.weekly?.percent == 61)
        #expect(snap.scoped.first?.modelName == "opus")
        #expect(snap.credits == UsageCredits(used: 1.5, limit: nil, currency: "USD"))
        #expect(snap.credits?.isCapReached == false)
    }

    @Test func limitsTakePriorityOverLegacyWindows() throws {
        let response = UsageResponse(
            fiveHour: RawWindow(utilization: 99, resetsAt: nil),
            limits: [RawLimit(kind: "session", percent: 12, resetsAt: "2026-11-26T16:10:00Z")])
        let snap = UsageSnapshot(response: response, fetchedAt: Date())
        #expect(snap.session?.percent == 12)
    }

    @Test func disabledCreditsAreHidden() {
        let response = UsageResponse(extraUsage: RawExtraUsage(isEnabled: false, monthlyLimit: 3000,
                                                               usedCredits: 100, currency: "EUR"))
        #expect(UsageSnapshot(response: response, fetchedAt: Date()).credits == nil)
    }

    @Test func topLevelGarbageThrowsDecodingError() {
        #expect(throws: UsageFetchError.decoding) { try HTTPUsageClient.decode(Data("[1,2]".utf8)) }
    }
}

@Suite struct CredentialsTests {
    @Test func parsesKeychainPayload() throws {
        let json = #"""
        {"claudeAiOauth": {"accessToken": "sk-ant-oat-SECRET", "refreshToken": "sk-ant-ort-SECRET",
          "expiresAt": 1764172800000, "refreshTokenExpiresAt": 1800000000000,
          "scopes": ["user:inference"], "subscriptionType": "team", "rateLimitTier": "default_claude_max_5x"}}
        """#
        let creds = try ClaudeCredentials.parse(Data(json.utf8))
        #expect(creds.accessToken == "sk-ant-oat-SECRET")
        #expect(creds.expiresAt == Date(timeIntervalSince1970: 1_764_172_800))
        #expect(creds.planName == "Max 5x")
        #expect(!creds.description.contains("SECRET"))
        #expect(!"\(creds)".contains("SECRET"))
        #expect(creds.isExpired(now: Date(timeIntervalSince1970: 1_764_172_801)))
        #expect(!creds.isExpired(now: Date(timeIntervalSince1970: 1_764_172_000)))
    }

    @Test func malformedPayloadThrows() {
        #expect(throws: CredentialsError.malformed) { try ClaudeCredentials.parse(Data("{}".utf8)) }
        #expect(throws: CredentialsError.malformed) { try ClaudeCredentials.parse(Data("nope".utf8)) }
    }

    @Test func planNames() {
        #expect(PlanName.from(rateLimitTier: "default_claude_max_20x", subscriptionType: "max") == "Max 20x")
        #expect(PlanName.from(rateLimitTier: "default_claude_pro", subscriptionType: "pro") == "Pro")
        #expect(PlanName.from(rateLimitTier: nil, subscriptionType: "team") == nil)
        #expect(PlanName.from(rateLimitTier: nil, subscriptionType: nil) == nil)
    }

    @Test func requestHeaders() {
        let r = HTTPUsageClient.makeRequest(accessToken: "tok")
        #expect(r.url?.absoluteString == "https://api.anthropic.com/api/oauth/usage")
        #expect(r.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        #expect(r.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
        #expect(r.value(forHTTPHeaderField: "User-Agent") == "runway/0.1")
    }

    @Test func statusMapping() {
        #expect(throws: UsageFetchError.unauthorized) { try HTTPUsageClient.check(status: 401, response: nil) }
        #expect(throws: UsageFetchError.server(status: 503)) { try HTTPUsageClient.check(status: 503, response: nil) }
        #expect(throws: UsageFetchError.rateLimited(retryAfter: nil)) { try HTTPUsageClient.check(status: 429, response: nil) }
        #expect(throws: Never.self) { try HTTPUsageClient.check(status: 200, response: nil) }
    }
}

@Suite struct DisplayedPercentTests {
    @Test func missingOrResetWindowsShowZero() {
        let t = iso("2026-11-26T12:00:00Z")
        let snap = UsageSnapshot(session: UsageLimit(kind: .session, percent: 97, resetsAt: t),
                                 weekly: nil, fetchedAt: t.addingTimeInterval(-3600))
        #expect(snap.sessionPercent(at: t.addingTimeInterval(-60)) == 97)
        #expect(snap.sessionPercent(at: t) == 0) // the window reset since the fetch
        #expect(snap.weeklyPercent(at: t) == 0)  // no weekly window in the payload
    }
}
