import AppKit
import CoreImage.CIFilterBuiltins
import Foundation
import XCTest
@testable import NativeHarnessClient

/// The vault's contracts that would break without a visible sign (docs/BROWSER_VAULT_DESIGN.md):
/// which pages an item's sites cover, the RFC 6238 codes, the refusal of an item asked for on
/// another site, and the codes an authenticator app's export brings over.
@MainActor
final class VaultTests: XCTestCase {
    func testSitesCoverTheirSubdomainsOverHTTPSAndNothingThatOnlyLooksAlike() {
        let suffixes = PublicSuffixList.bundled
        XCTAssertEqual(VaultSite.suggestion(for: "https://www.github.com/login", suffixes: suffixes), "github.com")
        XCTAssertEqual(VaultSite.suggestion(for: "https://accounts.example.co.uk/x", suffixes: suffixes), "example.co.uk")
        // A site anyone can register under is not one person's site.
        XCTAssertEqual(VaultSite.suggestion(for: "https://alice.github.io/", suffixes: suffixes), "alice.github.io")
        XCTAssertNil(VaultSite.normalize("github.io", suffixes: suffixes))
        XCTAssertNil(VaultSite.normalize("com", suffixes: suffixes))
        XCTAssertNil(VaultSite.normalize("http://github.com", suffixes: suffixes))
        XCTAssertEqual(VaultSite.normalize("http://localhost:3000/login", suffixes: suffixes), "http://localhost:3000")

        for page in ["https://github.com", "https://www.github.com", "https://gist.github.com:443"] {
            XCTAssertTrue(VaultSite.matches("github.com", origin: page), page)
        }
        for page in ["http://github.com", "https://github-login.com", "https://evilgithub.com", "https://github.com.evil.io"] {
            XCTAssertFalse(VaultSite.matches("github.com", origin: page), page)
        }
        XCTAssertTrue(VaultSite.matches("http://localhost:3000", origin: "http://localhost:3000"))
        XCTAssertFalse(VaultSite.matches("http://localhost:3000", origin: "http://localhost:3001"))
    }

    func testOneTimeCodesMatchRFC6238() throws {
        let key = Data("12345678901234567890".utf8)
        XCTAssertEqual(OneTimeCodeSecret(setupText: "GEZD GNBV GY3T QOJQ GEZD GNBV GY3T QOJQ")?.key, key)
        let secret = OneTimeCodeSecret(key: key, digits: 8)
        XCTAssertEqual(OneTimeCode.code(for: secret, at: Date(timeIntervalSince1970: 59), hmac: MacVault.hmac), "94287082")
        XCTAssertEqual(OneTimeCode.code(for: secret, at: Date(timeIntervalSince1970: 1_111_111_109), hmac: MacVault.hmac),
                       "07081804")
        let fromAddress = try XCTUnwrap(OneTimeCodeSecret(
            setupText: "otpauth://totp/Example:ada?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ&digits=8&issuer=Example"))
        XCTAssertEqual(fromAddress, secret)
    }

    /// Google Authenticator's export (Transfer accounts: `otpauth-migration://`, protobuf), read from a
    /// picture with Vision: each time-based account becomes an item of its own with no site or password,
    /// a counter-based one is counted and left out, and importing again adds nothing. A site's setup
    /// address gives the same code as the export's account for it.
    func testAuthenticatorExportsBecomeItemsOfTheirOwn() throws {
        func varint(_ value: Int) -> [UInt8] {
            var value = value, bytes: [UInt8] = []
            repeat {
                bytes.append(UInt8(value & 0x7f) | (value > 0x7f ? 0x80 : 0))
                value >>= 7
            } while value > 0
            return bytes
        }
        func field(_ number: Int, _ bytes: [UInt8]) -> [UInt8] { varint(number << 3 | 2) + varint(bytes.count) + bytes }
        func field(_ number: Int, _ value: Int) -> [UInt8] { varint(number << 3) + varint(value) }
        func account(_ key: String, _ name: String, _ issuer: String, algorithm: Int, digits: Int, type: Int) -> [UInt8] {
            field(1, Array(key.utf8)) + field(2, Array(name.utf8)) + field(3, Array(issuer.utf8))
                + field(4, algorithm) + field(5, digits) + field(6, type)
        }
        let payload = field(1, account("12345678901234567890", "ada@example.test", "Example", algorithm: 1, digits: 1, type: 2))
            + field(1, account("another-test-key-000", "Second:grace@example.test", "", algorithm: 2, digits: 2, type: 2))
            + field(1, account("counter-test-key-000", "hotp@example.test", "Counter", algorithm: 1, digits: 1, type: 1))
            + field(2, 1)
        let export = "otpauth-migration://offline?data="
            + Data(payload).base64EncodedString().addingPercentEncoding(withAllowedCharacters: .alphanumerics)!

        let generator = CIFilter.qrCodeGenerator()
        generator.message = Data(export.utf8)
        let picture = try XCTUnwrap(generator.outputImage).transformed(by: CGAffineTransform(scaleX: 6, y: 6))
        let png = try XCTUnwrap(NSBitmapImageRep(ciImage: picture).representation(using: .png, properties: [:]))
        let found = VaultQRCodeReader.setups(in: VaultQRCodeReader.messages(in: png))
        XCTAssertEqual(found.unsupported, 1)
        XCTAssertEqual(found.setups.map(\.issuer), ["Example", "Second"])
        XCTAssertEqual(found.setups.map(\.account), ["ada@example.test", "grace@example.test"])
        XCTAssertEqual(found.setups.last?.secret,
                       OneTimeCodeSecret(key: Data("another-test-key-000".utf8), digits: 8, algorithm: .sha256))
        XCTAssertEqual(OneTimeCodeSetup.setups(in: "otpauth://totp/Example:ada@example.test"
            + "?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ&issuer=Example").setups, Array(found.setups.prefix(1)))

        let center = VaultCenter(environment: VaultCenter.Environment(
            secrets: InMemoryVaultSecretStore(), repository: InMemoryVaultRepository(), hmac: MacVault.hmac,
            isAllowedBuild: true, defaults: .vaultTests()))
        XCTAssertEqual(center.importOneTimeCodes(found.setups), 2)
        XCTAssertEqual(center.importOneTimeCodes(found.setups), 0)
        XCTAssertEqual(center.items.map(\.name), ["Example", "Second"])
        XCTAssertTrue(center.items.allSatisfy { $0.sites.isEmpty && $0.hasOneTimeCode && !$0.hasPassword })
    }

    func testAnItemAskedForOnAnotherSiteIsRefusedAndThePersonIsTold() async throws {
        let item = VaultItem(name: "GitHub", sites: ["github.com"], username: "ada", policy: .always)
        let center = VaultCenter(environment: VaultCenter.Environment(
            secrets: InMemoryVaultSecretStore([item.id: VaultSecret(password: "correct horse")]),
            repository: InMemoryVaultRepository(items: [item]), hmac: MacVault.hmac, isAllowedBuild: true,
            defaults: .vaultTests()))
        var notices: [String] = []
        center.notify = { title, _, _ in notices.append(title) }
        let task = UUID()

        let phishing = await center.authorize(VaultFillRequest(sessionID: task, itemName: "GitHub", kind: .login,
                                                               origin: "https://github-login.com"))
        guard case .failure = phishing else { return XCTFail("filled on another site") }
        XCTAssertEqual(notices.count, 1)

        let unnamed = await center.authorize(VaultFillRequest(sessionID: task, itemName: nil, kind: .login,
                                                              origin: "https://github-login.com"))
        guard case .failure = unnamed else { return XCTFail("filled on another site") }

        let own = await center.authorize(VaultFillRequest(sessionID: task, itemName: nil, kind: .login,
                                                          origin: "https://www.github.com"))
        guard case .success(let grant) = own else { return XCTFail("refused its own site") }
        XCTAssertEqual(grant.password, "correct horse")
        XCTAssertEqual(grant.confirmedBy, .always)

        center.isEnabled = false
        let off = await center.authorize(VaultFillRequest(sessionID: task, itemName: nil, kind: .login,
                                                          origin: "https://www.github.com"))
        guard case .failure = off else { return XCTFail("filled while off") }

        // Two accounts on one site under the site's name, as an import names them: the refusal tells them
        // apart by username, and the username names one.
        let other = VaultItem(name: "GitHub", sites: ["github.com"], username: "grace", policy: .always)
        let both = VaultCenter(environment: VaultCenter.Environment(
            secrets: InMemoryVaultSecretStore([item.id: VaultSecret(password: "correct horse"),
                                               other.id: VaultSecret(password: "battery staple")]),
            repository: InMemoryVaultRepository(items: [item, other]), hmac: MacVault.hmac, isAllowedBuild: true,
            defaults: .vaultTests()))
        for name in [nil, "GitHub"] {
            let refused = await both.authorize(VaultFillRequest(sessionID: task, itemName: name, kind: .login,
                                                                origin: "https://github.com"))
            guard case let .failure(refusal) = refused else { return XCTFail("filled one of two of that name") }
            XCTAssertTrue(refusal.message.contains("“GitHub” (ada)") && refusal.message.contains("“GitHub” (grace)"),
                          refusal.message)
        }
        let byUsername = await both.authorize(VaultFillRequest(sessionID: task, itemName: "grace", kind: .login,
                                                               origin: "https://github.com"))
        guard case let .success(chosen) = byUsername else { return XCTFail("the username did not name its item") }
        XCTAssertEqual(chosen.password, "battery staple")
    }
}

extension UserDefaults {
    /// An empty defaults domain of the test's own, so a test that turns the vault off leaves the
    /// shared one alone.
    static func vaultTests() -> UserDefaults {
        UserDefaults(suiteName: testDefaultsSuite("yardlet.vault.tests"))!
    }
}
