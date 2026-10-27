import Foundation
import YardletAgentTools

/// Values the vault filled into pages lately, kept in memory for 30 minutes so that no tool result
/// carries one back to the model (design §5.3, the way CI logs mask their secrets), in the spellings a
/// page or a result most often turns them into. Short values are left alone: they would blank out
/// ordinary text.
struct VaultScrubList {
    private var entries: [(value: String, until: Date)] = []
    static let keep: TimeInterval = 30 * 60
    static let shortest = 4

    mutating func add(_ value: String?, now: Date = Date()) {
        guard let value, value.count >= Self.shortest else { return }
        let until = now.addingTimeInterval(Self.keep)
        for form in Set(Self.forms(of: value)) {
            entries.removeAll { $0.until < now || $0.value == form }
            entries.append((form, until))
        }
    }

    /// The value as written, escaped in JSON (a script's result), and as base64 (plain, unpadded and
    /// URL-safe), percent-encoding and hex. A page can still make a spelling this misses; these keep the
    /// usual ones from passing for something else.
    static func forms(of value: String) -> [String] {
        let bytes = Data(value.utf8)
        let base64 = bytes.base64EncodedString()
        let unpadded = base64.trimmingCharacters(in: CharacterSet(charactersIn: "="))
        let urlSafe = unpadded.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let json = [JSONEncoder.OutputFormatting(), .withoutEscapingSlashes].compactMap { formatting -> String? in
            let encoder = JSONEncoder()
            encoder.outputFormatting = formatting
            return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) }.map { String($0.dropFirst().dropLast()) }
        }
        // What `encodeURIComponent` leaves as it is.
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
        let percent = value.addingPercentEncoding(withAllowedCharacters: unreserved)
        return [value, base64, unpadded, urlSafe, hex, hex.uppercased()] + json + (percent.map { [$0] } ?? [])
    }

    func scrub(_ text: String, now: Date = Date()) -> String {
        var text = text
        for entry in entries.sorted(by: { $0.value.count > $1.value.count }) where entry.until >= now {
            text = text.replacingOccurrences(of: entry.value, with: "[saved value]")
        }
        return text
    }

    func scrub(_ result: AgentToolResult, now: Date = Date()) -> AgentToolResult {
        guard entries.contains(where: { $0.until >= now }) else { return result }
        var result = result
        result.content = result.content.map { content in
            if case .text(let text) = content { return .text(scrub(text, now: now)) }
            return content
        }
        return result
    }
}

/// What the vault filled into a page: the isolated world that keeps the filled fields, the document it
/// is in, and where the event log stood (a main-frame navigation after it ends the fill).
struct BrowserAgentVaultFill {
    var contextID: Int64
    var loaderID: String
    var eventMark: Int
}

extension Notification.Name {
    /// The vault filled a value into a page for an agent; `userInfo[VaultFillNotice.tabKey]` is its tab.
    static let vaultFilled = Notification.Name("YardletVaultFilled")
}

enum VaultFillNotice {
    static let tabKey = "tab"
}

/// The person's side of the vault in a tab (design §8.3, §14): filling for them from the address field's
/// key button and the code bar, noticing that they signed in, to offer saving it, and noticing a
/// two-factor code field or setup QR code, to offer filling or saving the code.
@MainActor
enum VaultPageScripts {
    /// The binding the watch calls with a JSON object whose `kind` says what it saw:
    /// - `signIn`, with `username` and `password`: the person submitted a sign-in.
    /// - `codeField`, with `page`: a one-time code field showed.
    /// - `qr`, with `page`: a graphic the size and shape of a QR code showed; Yardlet reads the screen.
    /// - `setup`, with `page` and `text`: a link to set up a code (`otpauth://`).
    static let offerBinding = "__yardletVaultOffer"

    /// `isCodeField(e)`: whether an input takes a one-time code (design §5.2 step 3), for fills.
    /// `looksLikeCodeField(e)`: the stricter test for offering one, which leaves out other short
    /// numeric fields such as postal codes.
    static let codeFieldTests = """
        const codeTypes = ['text', 'tel', 'number', ''];
        const codeWords = /one.?time|otp|mfa|2fa|two.?factor|verification.?code|auth\\w*.?code|security.?code|passcode/i;
        const namesCode = e => codeWords.test([e.name, e.id, e.placeholder, e.getAttribute('aria-label')].join(' '));
        const isCodeField = e => e instanceof HTMLInputElement && codeTypes.includes(e.type)
          && ((e.autocomplete || '').includes('one-time-code') || (e.maxLength > 0 && e.maxLength <= 10)
            || e.inputMode === 'numeric' || namesCode(e));
        const looksLikeCodeField = e => e instanceof HTMLInputElement && codeTypes.includes(e.type) && !e.disabled && !e.readOnly
          && ((e.autocomplete || '').includes('one-time-code') || namesCode(e)
            || (e.maxLength > 0 && e.maxLength <= 8 && (e.inputMode === 'numeric' || e.type === 'tel' || e.type === 'number')));
        """

    /// Runs in the vault's isolated world of every document of a panel's tab. It listens for the person
    /// submitting a form whose password field they typed into (not one the vault filled) and tells
    /// Yardlet through the binding, once per submission. It also looks, at most twice a second while the
    /// page changes, for a one-time code field (told once while it shows) and for a QR code's square on
    /// screen (each element once, ten QR looks a document) and tells Yardlet; no value leaves the page
    /// that way.
    static let watchScript = """
        (() => {
          if (window.__yardletVaultWatch) return;
          window.__yardletVaultWatch = true;
          const send = message => { if (typeof window.__yardletVaultOffer === 'function') window.__yardletVaultOffer(JSON.stringify(message)); };
          const typed = new WeakSet();
          const textTypes = ['text', 'email', 'tel', ''];
          addEventListener('input', e => { if (e.isTrusted && e.target instanceof HTMLInputElement && e.target.type === 'password') typed.add(e.target); }, true);
          let last = '';
          const offer = scope => {
            const fields = Array.from((scope || document).querySelectorAll('input'));
            const pass = fields.find(e => e.type === 'password' && e.value && typed.has(e) && !(window.__yardletVault || []).includes(e));
            if (!pass) return;
            const user = fields.find(e => textTypes.includes(e.type) && (e.autocomplete || '').split(/\\s+/).includes('username') && e.value)
              || fields.slice(0, fields.indexOf(pass)).reverse().find(e => textTypes.includes(e.type) && e.value);
            const payload = JSON.stringify({ username: user ? user.value : '', password: pass.value });
            if (payload === last) return;
            last = payload;
            send({ kind: 'signIn', username: user ? user.value : '', password: pass.value });
          };
          addEventListener('submit', e => offer(e.target), true);
          addEventListener('click', e => { const b = e.target instanceof Element && e.target.closest('button, input[type=submit]');
            if (b) offer(b.form || b.closest('form')); }, true);
          addEventListener('keydown', e => { if (e.key === 'Enter' && e.target instanceof HTMLInputElement && e.target.type === 'password')
            offer(e.target.form || e.target.closest('form')); }, true);

          \(codeFieldTests)
          const onScreen = r => r.width > 0 && r.height > 0 && r.bottom > 0 && r.right > 0 && r.top < innerHeight && r.left < innerWidth;
          const toldFields = new WeakSet(), seenGraphics = new WeakSet(), seenLinks = new Set();
          let codeField = null, qrLooks = 0, pending = 0;
          const look = () => {
            pending = 0;
            // Once while a code field shows; again when a later step shows another.
            if (!codeField || !codeField.isConnected || !onScreen(codeField.getBoundingClientRect())) {
              const field = Array.from(document.querySelectorAll('input'))
                .find(e => !toldFields.has(e) && looksLikeCodeField(e) && onScreen(e.getBoundingClientRect()));
              if (field) { codeField = field; toldFields.add(field); send({ kind: 'codeField', page: location.href }); }
            }
            for (const link of document.querySelectorAll('a[href^="otpauth" i]')) {
              if (seenLinks.has(link.href)) continue;
              seenLinks.add(link.href);
              send({ kind: 'setup', page: location.href, text: link.href });
            }
            if (qrLooks >= 10) return;
            let square = false;
            for (const e of document.querySelectorAll('img, canvas, svg')) {
              if (seenGraphics.has(e) || (e.parentElement && e.parentElement.closest('svg'))) continue;
              if (e instanceof HTMLImageElement && !e.complete) { e.addEventListener('load', schedule, { once: true }); continue; }
              const r = e.getBoundingClientRect();
              // Not laid out or not on screen yet: looked at again when it is.
              if (!onScreen(r)) continue;
              seenGraphics.add(e);
              if (r.width >= 96 && r.width <= 640 && Math.abs(r.width - r.height) <= r.width * 0.15) square = true;
            }
            if (square) { qrLooks += 1; send({ kind: 'qr', page: location.href }); }
          };
          const schedule = () => { if (!pending) pending = setTimeout(look, 500); };
          new MutationObserver(schedule).observe(document, { subtree: true, childList: true, attributes: true,
            attributeFilter: ['src', 'class', 'style', 'hidden', 'open'] });
          addEventListener('scroll', schedule, true);
          addEventListener('resize', schedule);
          addEventListener('load', schedule);
          schedule();
        })();
        """

    /// The field the person's fill goes to: the focused field, else the page's first password field,
    /// else its first username field, else its first one-time code field. For the code bar
    /// (`codeOnly`), the focused code field, else the first code field.
    static func personTarget(codeOnly: Bool) -> String {
        """
        (() => {
          \(codeFieldTests)
          const visible = e => { const r = e.getBoundingClientRect(); return r.width > 0 && r.height > 0; };
          const focused = document.activeElement;
          const inputs = Array.from(document.querySelectorAll('input')).filter(visible);
          if (\(codeOnly)) {
            return isCodeField(focused) ? focused : inputs.find(looksLikeCodeField) || inputs.find(isCodeField) || null;
          }
          if (focused instanceof HTMLInputElement) return focused;
          return inputs.find(e => e.type === 'password') || inputs.find(e => (e.autocomplete || '').includes('username'))
            || inputs.find(looksLikeCodeField) || null;
        })()
        """
    }

    /// The person's fill with the target field as `this`: the code into a code field when the item has
    /// one, else the sign-in into the field's form.
    static let personFillFunction = """
        function(username, password, code) {
          \(codeFieldTests)
          const kind = typeof code === 'string' && (looksLikeCodeField(this) || (isCodeField(this) && typeof password !== 'string'))
            ? 'one_time_code' : 'login';
          return (\(BrowserAgentTools.fillFunction)).call(this, kind, username, password, code);
        }
        """

    /// The value the person typed in the page's username field, for "Add to Password Manager…".
    static let typedUsername = """
        (() => {
          const textTypes = ['text', 'email', 'tel', ''];
          const fields = Array.from(document.querySelectorAll('input'));
          const pass = fields.find(e => e.type === 'password');
          const user = fields.find(e => textTypes.includes(e.type) && (e.autocomplete || '').includes('username') && e.value)
            || (pass ? fields.slice(0, fields.indexOf(pass)).reverse().find(e => textTypes.includes(e.type) && e.value) : null);
          return user ? user.value : '';
        })()
        """

    /// The tab's main frame: its ID and origin as the browser reports them.
    static func mainFrame(_ cdp: any BrowserAgentCDP, timeout: Duration) async throws -> (id: String, origin: String) {
        let tree = try await cdp.send("Page.getFrameTree", [:], timeout: timeout)
        let frame = tree["frameTree"]?["frame"]
        let origin = frame?["securityOrigin"]?.stringValue.flatMap { $0.isEmpty || $0 == "null" ? nil : $0 }
            ?? frame?["url"]?.stringValue.flatMap(VaultSite.origin(of:)) ?? ""
        return (frame?["id"]?.stringValue ?? "", origin)
    }

    /// A context in the vault's isolated world of the tab's main frame.
    static func vaultWorld(_ cdp: any BrowserAgentCDP, frame: String, timeout: Duration) async throws -> Int64 {
        let world = try await cdp.send("Page.createIsolatedWorld", [
            "frameId": .string(frame), "worldName": .string(BrowserAgentTools.vaultWorldName)
        ], timeout: timeout)
        guard let context = world["executionContextId"]?.integerValue else { throw BrowserAgentToolError("no context") }
        return context
    }

    /// Starts the watch in a panel's tab: in every new document and in the one shown now.
    static func installWatch(_ cdp: any BrowserAgentCDP, timeout: Duration = .seconds(10)) async {
        _ = try? await cdp.send("Runtime.enable", [:], timeout: timeout)
        _ = try? await cdp.send("Page.enable", [:], timeout: timeout)
        _ = try? await cdp.send("Runtime.addBinding", [
            "name": .string(offerBinding), "executionContextName": .string(BrowserAgentTools.vaultWorldName)
        ], timeout: timeout)
        _ = try? await cdp.send("Page.addScriptToEvaluateOnNewDocument", [
            "source": .string(watchScript), "worldName": .string(BrowserAgentTools.vaultWorldName)
        ], timeout: timeout)
        if let frame = try? await mainFrame(cdp, timeout: timeout), !frame.id.isEmpty,
           let context = try? await vaultWorld(cdp, frame: frame.id, timeout: timeout) {
            _ = try? await cdp.send("Runtime.evaluate", ["expression": .string(watchScript), "contextId": .integer(context)],
                                    timeout: timeout)
        }
    }

    /// The person's fill from the key button (the focused field's form, the page's sign-in form, or its
    /// code field) or from the code bar (`codeOnly`: the code alone, into the page's code field).
    @discardableResult
    static func fillForPerson(_ cdp: any BrowserAgentCDP, username: String?, password: String?, code: String?,
                              codeOnly: Bool = false, timeout: Duration = .seconds(10)) async -> Bool {
        guard let frame = try? await mainFrame(cdp, timeout: timeout),
              let context = try? await vaultWorld(cdp, frame: frame.id, timeout: timeout),
              let target = try? await cdp.send("Runtime.evaluate", [
                  "expression": .string(personTarget(codeOnly: codeOnly)), "contextId": .integer(context)
              ], timeout: timeout),
              let objectID = target["result"]?["objectId"]?.stringValue else { return false }
        let values: [String?] = codeOnly ? [nil, nil, code] : [username, password, code]
        let filled = try? await cdp.send("Runtime.callFunctionOn", [
            "functionDeclaration": .string(personFillFunction), "objectId": .string(objectID),
            "arguments": .array(values.map { .object(["value": $0.map(JSONValue.string) ?? .null]) }),
            "returnByValue": .bool(true)
        ], timeout: timeout)
        return filled?["result"]?["value"]?["kinds"] != nil
    }

    /// Whether the page shows a field for a one-time code, read in the vault's world.
    static func hasCodeField(_ cdp: any BrowserAgentCDP, timeout: Duration = .seconds(10)) async -> Bool {
        guard let frame = try? await mainFrame(cdp, timeout: timeout),
              let context = try? await vaultWorld(cdp, frame: frame.id, timeout: timeout),
              let found = try? await cdp.send("Runtime.evaluate", [
                  "expression": .string("(() => { \(codeFieldTests) return Array.from(document.querySelectorAll('input'))"
                      + ".some(e => looksLikeCodeField(e) && e.getBoundingClientRect().width > 0); })()"),
                  "contextId": .integer(context), "returnByValue": .bool(true)
              ], timeout: timeout) else { return false }
        return found["result"]?["value"]?.boolValue == true
    }

    /// The value in the page's username field, read in the vault's world.
    static func typedUsername(_ cdp: any BrowserAgentCDP, timeout: Duration = .seconds(10)) async -> String {
        guard let frame = try? await mainFrame(cdp, timeout: timeout),
              let context = try? await vaultWorld(cdp, frame: frame.id, timeout: timeout),
              let value = try? await cdp.send("Runtime.evaluate", [
                  "expression": .string(typedUsername), "contextId": .integer(context), "returnByValue": .bool(true)
              ], timeout: timeout) else { return "" }
        return value["result"]?["value"]?.stringValue ?? ""
    }
}

extension BrowserAgentTools {
    /// The world Yardlet's vault code runs in: the page's own scripts cannot see or patch it.
    static let vaultWorldName = "yardlet-vault"

    /// `browser_fill_credential` (design §5.2).
    func fillCredential(_ arguments: JSONValue, on page: BrowserAgentPage, sessionID: UUID?) async throws -> AgentToolResult {
        guard let vault, let sessionID else {
            throw BrowserAgentToolError("Yardlet's password manager is not available in this build.")
        }
        guard let kind = VaultFillKind(rawValue: arguments["kind"]?.stringValue ?? VaultFillKind.login.rawValue) else {
            throw BrowserAgentToolError("kind must be login, one_time_code or passkey.")
        }
        let itemName = arguments["item"]?.stringValue
        if kind == .passkey {
            return try await armPasskey(itemName: itemName, on: page, sessionID: sessionID)
        }
        guard let ref = arguments["ref"]?.stringValue else {
            throw BrowserAgentToolError("browser_fill_credential needs the ref of a field in the sign-in form.")
        }
        let element = try element(ref, on: page)
        // The vault fills only the page's own fields: not a frame from another site (docs/BROWSER_VAULT_DESIGN.md, "How filling works"), as not a frame of
        // the page's own process (`ownerDocument` below).
        guard element.session == nil else {
            throw BrowserAgentToolError("\(ref) is inside a frame in the page; Yardlet fills only the page's own fields.")
        }
        let node = element.node
        let frame = try await mainFrame(of: page)
        let world = try await send(page, "Page.createIsolatedWorld", [
            "frameId": .string(frame.id), "worldName": .string(Self.vaultWorldName)
        ])
        guard let contextID = world["executionContextId"]?.integerValue else {
            throw BrowserAgentToolError("The browser did not open a context to fill the page in.")
        }
        let resolved = try await send(page, "DOM.resolveNode", [
            "backendNodeId": .integer(Int64(node)), "executionContextId": .integer(contextID)
        ], ref: ref)
        guard let objectID = resolved["object"]?["objectId"]?.stringValue else {
            throw BrowserAgentToolError("\(ref) could not be found on the page. Call browser_snapshot again.")
        }
        let onPage = try await callInVaultWorld(page, objectID,
            "function() { return this instanceof HTMLElement && this.ownerDocument === document; }")
        guard onPage.boolValue == true else {
            throw BrowserAgentToolError("\(ref) is inside a frame in the page; Yardlet fills only the page's own fields.")
        }

        let request = VaultFillRequest(sessionID: sessionID, itemName: itemName, kind: kind, origin: frame.origin)
        let grant: VaultFillGrant
        switch await vault.authorize(request) {
        case .success(let allowed): grant = allowed
        case .failure(let refusal): throw BrowserAgentToolError(refusal.message)
        }
        // The page may have moved on while the person was asked.
        guard (try? await mainFrame(of: page))?.loaderID == frame.loaderID else {
            vault.record(grant, for: request, filled: [], failure: "The page navigated before the fill.")
            throw BrowserAgentToolError("The page navigated before Yardlet could fill it; nothing was filled.")
        }
        let filled = try await callInVaultWorld(page, objectID, Self.fillFunction, arguments: [
            .string(kind.rawValue),
            grant.username.map(JSONValue.string) ?? .null,
            grant.password.map(JSONValue.string) ?? .null,
            grant.code.map(JSONValue.string) ?? .null
        ])
        if let failure = filled["error"]?.stringValue {
            let message = Self.fillFailure(failure, ref: ref)
            vault.record(grant, for: request, filled: [], failure: message)
            throw BrowserAgentToolError(message)
        }
        let kinds = filled["kinds"]?.arrayValue?.compactMap(\.stringValue) ?? []
        vaultScrub.add(grant.password)
        vaultScrub.add(grant.code)
        if kinds.contains("password") || kinds.contains("one_time_code") {
            page.vaultFill = BrowserAgentVaultFill(contextID: contextID, loaderID: frame.loaderID, eventMark: page.cdp.eventLog.count)
            page.vaultFilledDocuments.insert(frame.loaderID)
        }
        vault.record(grant, for: request, filled: kinds)
        NotificationCenter.default.post(name: .vaultFilled, object: nil, userInfo: [VaultFillNotice.tabKey: page.tabID])

        var submitted = false
        if arguments["submit"]?.boolValue == true {
            let viaForm = try await callInVaultWorld(page, objectID, Self.submitFunction)
            if viaForm.boolValue != true, let enter = BrowserAgentKeyPress.parse("Enter") {
                try await dispatch(enter, on: page)
            }
            submitted = true
        }
        let what: String
        switch (kinds.contains("username"), kinds.contains("password"), kinds.contains("one_time_code")) {
        case (true, true, _): what = "the username and password"
        case (false, true, _): what = "the password"
        case (true, false, _): what = "the username"
        default: what = "the one-time code"
        }
        let host = VaultSite.host(of: frame.origin)
        return .text("Filled \(what) of “\(grant.item.name)” into the form on \(host)"
            + (submitted ? " and submitted it." : ".") + " The values are not shown to you.")
    }

    /// Whether the vault filled a password or a code into the document the page shows now (design §5.3):
    /// the one it filled last, until the main frame opens another by a navigation or a reload, or one it
    /// filled earlier that going back brought again. A page can copy what it was given, so an emptied field
    /// does not end it. While it holds, the page's scripts are not run for the agent.
    func vaultFilledDocument(_ page: BrowserAgentPage) -> Bool {
        guard let fill = page.vaultFill else { return false }
        let log = page.cdp.eventLog
        guard log.count > fill.eventMark, let shown = log[fill.eventMark...].last(where: {
            $0.method == "Page.frameNavigated" && $0.params["frame"]?["parentId"] == nil
        }) else { return true }
        return shown.params["frame"]?["loaderId"]?.stringValue.map(page.vaultFilledDocuments.contains) ?? false
    }

    /// Whether a value the vault filled is still in its field on the page, for screenshots to cover.
    func vaultValueIsLive(on page: BrowserAgentPage) async -> Bool {
        guard vaultFilledDocument(page), let fill = page.vaultFill else { return false }
        let live = try? await send(page, "Runtime.evaluate", [
            "expression": .string("(window.__yardletVault || []).some(e => e.isConnected && e.value !== '')"),
            "contextId": .integer(fill.contextID), "returnByValue": .bool(true)
        ])
        return live?["result"]?["value"]?.boolValue == true
    }

    /// Hides the filled values that the page would draw as text (a shown password, a code), for one
    /// screenshot; `restoreVaultFields` puts them back.
    func coverVaultFields(on page: BrowserAgentPage) async -> Bool {
        guard await vaultValueIsLive(on: page), let fill = page.vaultFill else { return false }
        let covered = try? await send(page, "Runtime.evaluate", [
            "expression": .string("""
                (() => {
                  const shown = (window.__yardletVault || []).filter(e => e.isConnected && e.value !== '' && e.type !== 'password');
                  window.__yardletVaultCovered = shown.map(e => [e, ['color', '-webkit-text-fill-color']
                    .map(p => [p, e.style.getPropertyValue(p), e.style.getPropertyPriority(p)])]);
                  shown.forEach(e => { e.style.setProperty('color', 'transparent', 'important');
                    e.style.setProperty('-webkit-text-fill-color', 'transparent', 'important'); });
                  return shown.length;
                })()
                """),
            "contextId": .integer(fill.contextID), "returnByValue": .bool(true)
        ])
        return (covered?["result"]?["value"]?.integerValue ?? 0) > 0
    }

    func restoreVaultFields(on page: BrowserAgentPage) async {
        guard let fill = page.vaultFill else { return }
        _ = try? await send(page, "Runtime.evaluate", [
            "expression": .string("""
                (window.__yardletVaultCovered || []).forEach(([e, props]) => props.forEach(([p, v, prio]) =>
                  v ? e.style.setProperty(p, v, prio) : e.style.removeProperty(p))); window.__yardletVaultCovered = [];
                """),
            "contextId": .integer(fill.contextID)
        ])
    }

    // MARK: Pieces

    /// The page's main frame as the browser reports it: its ID, the document it shows, and its origin.
    private func mainFrame(of page: BrowserAgentPage) async throws -> (id: String, loaderID: String, origin: String) {
        let tree = try await send(page, "Page.getFrameTree")
        let frame = tree["frameTree"]?["frame"]
        guard let id = frame?["id"]?.stringValue else { throw BrowserAgentToolError("The browser did not describe the page.") }
        let origin = frame?["securityOrigin"]?.stringValue.flatMap { $0.isEmpty || $0 == "null" ? nil : $0 }
            ?? frame?["url"]?.stringValue.flatMap(VaultSite.origin(of:)) ?? ""
        return (id, frame?["loaderId"]?.stringValue ?? "", origin)
    }

    private func callInVaultWorld(_ page: BrowserAgentPage, _ objectID: String, _ function: String,
                                  arguments: [JSONValue] = []) async throws -> JSONValue {
        let result = try await send(page, "Runtime.callFunctionOn", [
            "functionDeclaration": .string(function), "objectId": .string(objectID),
            "arguments": .array(arguments.map { .object(["value": $0]) }), "returnByValue": .bool(true)
        ])
        if result["exceptionDetails"] != nil {
            throw BrowserAgentToolError("The fill did not run on this page.")
        }
        return result["result"]?["value"] ?? .null
    }

    private static func fillFailure(_ code: String, ref: String) -> String {
        switch code {
        case "no sign-in field": "\(ref) is not in a form with a username or password field."
        case "nothing to fill": "The item has no value for the fields of this form."
        case "not a code field": "\(ref) is not a one-time code field."
        case "not enough code boxes": "The code boxes after \(ref) are fewer than the code's digits."
        default: "The fill did not run on this page."
        }
    }

    /// Runs in the vault's isolated world with the field as `this`. A password goes only into a
    /// password field, a username into a text field of the same form, a code into a code field
    /// (design §5.2 step 3). The fields that took a secret (a password, a code; not the username) are
    /// kept in this world for `vaultValueIsLive` and the screenshot cover.
    static let fillFunction = """
        function(kind, username, password, code) {
          const target = this;
          const visible = e => { const r = e.getBoundingClientRect(); const s = getComputedStyle(e);
            return r.width > 0 && r.height > 0 && s.visibility !== 'hidden' && s.display !== 'none'; };
          const textTypes = ['text', 'email', 'tel', 'url', ''];
          const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
          const put = (e, v) => {
            e.focus();
            setter.call(e, v);
            e.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertReplacementText' }));
            e.dispatchEvent(new Event('change', { bubbles: true }));
          };
          const isInput = e => e instanceof HTMLInputElement;
          const secret = [], kinds = [];
          if (kind === 'login') {
            const scope = (isInput(target) && target.form) || target.closest('form') || document;
            const inputs = Array.from(scope.querySelectorAll('input')).filter(e => !e.disabled && !e.readOnly && visible(e));
            const passwordField = isInput(target) && target.type === 'password' ? target : inputs.find(e => e.type === 'password');
            let userField = null;
            if (isInput(target) && target.type !== 'password' && textTypes.includes(target.type)) {
              userField = target;
            } else {
              userField = inputs.find(e => textTypes.includes(e.type) && (e.autocomplete || '').split(/\\s+/).includes('username'))
                || (passwordField ? inputs.slice(0, inputs.indexOf(passwordField)).reverse().find(e => textTypes.includes(e.type)) : null);
            }
            if (!passwordField && !userField) return { error: 'no sign-in field' };
            if (typeof password === 'string' && passwordField) { put(passwordField, password); secret.push(passwordField); kinds.push('password'); }
            if (typeof username === 'string' && userField) { put(userField, username); kinds.push('username'); }
            if (!kinds.length) return { error: 'nothing to fill' };
          } else if (kind === 'one_time_code') {
            \(VaultPageScripts.codeFieldTests)
            if (!isCodeField(target) || typeof code !== 'string') return { error: 'not a code field' };
            if (target.maxLength === 1) {
              const scope = target.form || target.closest('form') || document;
              const boxes = Array.from(scope.querySelectorAll('input')).filter(e => e.maxLength === 1 && visible(e));
              const run = boxes.slice(boxes.indexOf(target), boxes.indexOf(target) + code.length);
              if (run.length < code.length) return { error: 'not enough code boxes' };
              run.forEach((e, i) => { put(e, code[i]); secret.push(e); });
            } else {
              put(target, code); secret.push(target);
            }
            kinds.push('one_time_code');
          }
          window.__yardletVault = (window.__yardletVault || []).concat(secret);
          return { kinds };
        }
        """

    /// Submits the field's form as a click on its submit button would (handlers that listen for the
    /// click still run); false when the field is in no form.
    static let submitFunction = """
        function() {
          const form = (this instanceof HTMLInputElement && this.form) || this.closest('form');
          if (!form) return false;
          const button = Array.from(form.querySelectorAll('button, input[type=submit], input[type=image]'))
            .find(b => (b.type || 'submit') === 'submit' && !b.disabled);
          if (button) button.click(); else if (form.requestSubmit) form.requestSubmit(); else form.submit();
          return true;
        }
        """
}
