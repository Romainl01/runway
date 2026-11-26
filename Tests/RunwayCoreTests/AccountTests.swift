import Foundation
import Testing
@testable import RunwayCore

struct AccountTests {
    @Test func teamAccountFromConfig() {
        let json = #"{"oauthAccount":{"emailAddress":"a@b.com","organizationType":"claude_team","organizationName":"Acme","accountUuid":"u1","organizationUuid":"o1"}}"#
        let account = ClaudeAccount.parse(Data(json.utf8))
        #expect(account == ClaudeAccount(email: "a@b.com", kind: .team, organizationName: "Acme", id: "u1|o1"))
    }

    @Test func personalPlansDropTheOrganization() {
        let json = #"{"oauthAccount":{"emailAddress":"a@b.com","organizationType":"claude_max","organizationName":"a@b.com's Organization"}}"#
        let account = ClaudeAccount.parse(Data(json.utf8))
        #expect(account?.kind == .personal)
        #expect(account?.organizationName == nil)
    }

    @Test func subscriptionTypeIsTheFallback() {
        let json = #"{"oauthAccount":{"emailAddress":"a@b.com"}}"#
        #expect(ClaudeAccount.parse(Data(json.utf8), subscriptionType: "enterprise")?.kind == .enterprise)
    }

    @Test func loggedOutIsNil() {
        #expect(ClaudeAccount.parse(Data("{}".utf8)) == nil)
    }
}
