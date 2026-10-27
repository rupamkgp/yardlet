# Browser session isolation per task

Status: implemented (2026-10-24; the disk profile path was fixed the same day: section 7. On 2026-10-25 the cookie copy
that changed the shape of cookies was fixed: section 8. On 2026-10-26, importing sign-ins from another browser: section
10. On 2026-10-27, tasks follow the person's sign-ins: section 11). The browser host contract is in [BROWSER_HOST](BROWSER_HOST.md) section 3, "Profiles", and the vault is in
[BROWSER_VAULT_DESIGN](BROWSER_VAULT_DESIGN.md).

## 1. Background and goals

The need: an AI browser should share things like credentials, but keep values such as the currently signed-in account,
which cookies, sessions and local storage carry, separate for each session, so that work goes smoothly.

Before, the tabs of all tasks shared one profile (`~/Library/Application Support/Yardlet/Browser/Default`). Cookies,
storage and cache mixed between tasks, and when two tasks signed in to the same site with different accounts, they
overwrote each other. Now all tasks share the vault's credentials (passwords, TOTP, Yardlet passkeys) and Touch ID
passkeys, and each task keeps its own "current sign-in state" (cookies, localStorage, sessionStorage, IndexedDB, cache).

## 2. How the two apps and other browsers do it

The bundles were read as bytes only (not run). Aside and Ego were read through their makers' docs.

| Product | Sign-in state per task | Evidence |
|---|---|---|
| Claude app 3.1623.3 | Chosen with the "Keep cookies" setting: "Until quit" (default, not persistent, per working folder), "Shared" (shared by all sessions, `persist:launch-preview-cowork-shared`), "Per session" (`persist:launch-preview-session-<session ID>` for each session). Forking a session copies the parent's cookies (`seedForkedPreviewCookies`). Deleting a session clears that session's storage (`clearData`); archiving does not. The agent and the person use the same tab's storage | `app.asar` `index.chunk-DylQWxwC.js` (`launchPreviewStorage: "none" \| "shared" \| "session"`), the setting text in `ion-dist` |
| Codex app 26.1016 | None. All threads of the local built-in browser use the single `persist:codex-browser-app`. Only tab ownership and restore information differ per thread, and archiving or deleting does not clear the sign-in storage | `main-JI9qDiXp.js` (`session.fromPartition(Vu("app"))`), `src-CSKkIr_z.js` |
| Aside | Tasks share the default profile, and only "Incognito" tasks run without profile state. The vault (Aside Vault) shares credentials | Help page Run tasks |
| Claude app 3.6556.2 (import) | Behind the feature flag `desktop_ccd_chrome_import` there is "Import sign-ins from Chrome": choose a Chrome, Edge, Brave, Chromium or Firefox profile and then sites (registrable domains), and their cookies and localStorage go into the preview storage. Existing cookies are overwritten, not cleared, and there is a list of imported sites with a way to remove them (section 10) | `app.asar` `index.chunk-TCY6lWOp.js` (`runChromeImport`, `listChromeImportSites`) |
| ego(lite) | One BrowserContext per Space (task), with its own cookies and storage. Even so, the agent picks up the sign-ins already in the browser (the docs do not say how they are carried over). A Profile can also be assigned to a task | Docs Space, changelog 0.4.4.15 |

Yardlet combines the Claude app's "Per session" and ego(lite)'s Space: storage per task, new tasks start signed in, and
credentials are shared through the vault.

## 3. Decisions (the recommended options, taken while the user was away)

| Question | Decision | Reason |
|---|---|---|
| Disk folder or memory | A disk folder (`Browser/Task-<key>`, the `cache_path` of `CefRequestContext`). Chromium opens as a disk profile only a folder directly under the root cache | The host ends 60 seconds after it has no tabs. With an in-memory context, sign-ins would be lost every time |
| Does a new task start empty | It starts with a copy of the default profile's cookies. A child task starts with the parent task's cookies | Signing in again every time would bring new-device alerts and two-step verification in every task. The Claude app also copies the parent's cookies on fork. localStorage and IndexedDB are not copied (on such sites the vault signs in again) |
| When the person signs in in the panel | (Revised 2026-10-27, section 11) Whether with a password or with a passkey, "Sign in with Google" or single sign-on, that site's (registrable domain's) cookies go to the default profile and to every task that follows the site: at once to tasks with tabs open, to the rest when their tab next opens. A sign-in the person makes on a page the agent handed over goes the same way. A site a task signed in to itself (a sign-in its agent filled from the vault or typed) stays that task's and is not overwritten | As in the Codex app, every task normally uses the same sign-ins, and only a task that went in with another account keeps its own. From 2026-10-24 to 10-26 only password sign-ins went to the default profile, and running tasks stayed as they were |
| Do child tasks inherit | When first opened, they copy the parent's cookies. After that they are separate | Same as the Claude app's fork |
| Tabs on the new task screen | The new task screen has its own profile key, and the task its tab moves to keeps using that key. The new task screen gets a new key | The moved tab's page stays as it is, so its storage must stay the same too |
| Archive and delete | Both delete that task's folder. When the host does not have the folders open (when the host ends), folders that belong to no remaining task are deleted, along with the record of that profile that Chromium left in `Local State` | So that nothing is left behind after removal. The Claude app deletes only on delete |
| Turning it on and off | Settings › General "Keep cookies": "Per task" (default) / "Shared by all tasks" (as before) | A setting in the same place as the Claude app's "Keep cookies". "Until quit" was left out, because it would mean something different in Yardlet, whose host ends often |
| Sign-ins from another browser (2026-10-26) | The cookies of the sites the person chose from the page menu of the browser panel go into the default profile and that task's profile. The cookies those sites had before are deleted | So that sites whose passkey exists only in another browser can be used in Yardlet (section 10). Since 2026-10-27 it counts as the person's sign-in, so the tasks that follow those sites take it too (section 11) |
| Touch ID passkeys | The default profile's `webauthn.touchid.metadata_secret` is put into each new task profile | Chromium reads Touch ID passkey metadata per profile with this key. Without it, the passkeys would not show in each task |

## 4. Structure

- **CEF bridge:** It creates one request context per folder path (`cef_request_context_create_context`, which also
  stores session cookies) and keeps it while browsers or cookie copies use that folder. When the last one ends, it
  releases the context. A cookie copy reads all of the source's cookies (`visit_all_cookies`), asks the source again
  with each cookie's address (`visit_url_cookies`, which answers only unpartitioned cookies) and puts only the cookies
  in that answer into the target (`set_cookie`; a host-only cookie goes in with an empty domain, so it stays host-only).
  When done, it writes the target store to disk (`flush_store`) and then reports (section 8). There are at most 16
  browsers in total (the host limit) and 32 contexts.
- **Host:** It takes the `profile` (`key`, `seedFrom`) of the `open` command and opens the tab in
  `<root cache>/Task-<key>`. It accepts only keys in UUID form, so a key cannot point at another folder. Chromium reads
  disk profiles asynchronously, so the browser is created after that profile is ready
  (`on_request_context_initialized`). When the folder is new, it puts in the Touch ID key, opens the tab at about:blank,
  copies the starting cookies and then opens the requested address (navigation and DevTools messages that arrive while
  it waits for the profile or copies wait until it is done). The `copyCookies` command moves one site's cookies from
  one profile to another, and with `replace` first deletes the target's cookies of that site. The `importCookies` command
  replaces the chosen sites' cookies in one profile with cookies imported from another browser (section 10). When the
  `open` command's `profile` has `follow` (a list of sites) or `fill`, the tab opens at about:blank, takes those sites
  from the default profile in place of its own, fills in the sites it has no cookie of, and then opens the address. The
  `cookieDigest` command answers a sum of hashes of one profile's cookies of one site (section 11).
- **Yardlet:** `BrowserTaskProfiles` handles the task's key (the task ID; for a task that came from the new task screen,
  that screen's key), the source of the starting cookies (the parent task's folder if there is one, otherwise the
  default profile), the setting and cleanup. `BrowserHostClient` attaches the profile every time it opens a task's tab,
  reports when a tab moves to another task, and calls cleanup when the host ends. Cleanup runs only after the saved task
  list has been read in full. Chromium writes every profile it opens into `Local State` (`profile.info_cache`,
  `profile.profiles_order`, `variations_google_groups`) and does not remove them when the folder disappears, so cleanup
  also removes `Task-` names without a folder from there.
- **The person's sign-in (revised 2026-10-27):** `BrowserLoginFollow` finds sign-ins and passes the person's to the
  default profile and the tasks that follow the site; how it finds them and the rules are in section 11. The vault's
  watcher (submission of a form with a password field the person typed into, a one-time code field) runs with "Per
  task" even when the vault is off, and what it reports is used to find sign-ins too.

## 5. Costs and limits

- **Memory (2026-10-24 QA, disk profiles after the fix in section 7, 8 windowless tabs, the same QA page):** With a
  profile per task, the process tree total was 1,162 MiB (browser process 232); with the same tabs opened in the single
  default profile, 1,113 MiB (browser process 197). The difference is about 49 MiB, around 6 MiB per profile, and most
  of it is in the browser process (per-profile services). There was one renderer per tab (10) in both cases. The first
  measurement, before the fix (1,134 MiB), was taken with in-memory profiles. What grows a lot as tabs increase is the
  frame surfaces the tabs draw (one helper's footprint 86 → 504 MiB, resident memory unchanged), which has nothing to do
  with isolation.
- **Limits:** At most 16 browsers in total (the host limit, 9 per task) and 32 profile contexts. One browser process
  handles them.
- New tasks receive only cookies. Sites that keep sign-in tokens in localStorage or IndexedDB need a new sign-in in a
  new task (with an "Always" vault item, the agent does it).
- Partitioned cookies (CHIPS: cookies that a page embedded in another site keeps only under that top-level site) are not
  moved. CEF's cookie manager does not take a partition key, so inserting one would make a cookie that every top-level
  site receives (section 8). In a new task, embedded widgets start as if seen for the first time.
- A moved cookie keeps, instead of the scheme and port of whatever set it, those of the address the copy used (https:443
  if Secure, otherwise http:80). CEF does not report the original values. CEF 154 does not bind cookies to schemes (QA
  `schemeBoundCookies: false`), so sending them makes no difference. The Claude app's copy uses the same addresses.
- Finding the person's sign-in (section 11) needs a moment that starts one (a password field, a one-time code field, a
  passkey window, a popup, leaving for another site). A sign-in without such a moment (a sign-in link opened outside
  Yardlet, for example) is not passed on. Until 2026-10-26 only password sign-ins were passed on.
- When an archived task is restored, that task's browser starts again with the default profile's cookies.
- Changing the setting leaves already open tabs as they are. Tabs opened after that follow it.

## 6. QA

`run-check.sh … --ui-fixture-browser-check-only=isolation` (`BrowserHostIsolationQA`) checks on a real CEF host: whether
a new task starts with the default profile's cookies; whether two tasks keep separate cookies and localStorage on the
same site; whether a task's sign-in does not leak into the default profile; whether a child task starts with the
parent's cookies; whether copying the person's sign-in reaches only tasks started afterwards; whether the Touch ID key
goes into a new profile; whether, after the host ends and starts again, a task's cookies (session cookies included) and
localStorage remain and it does not receive the starting cookies again; whether switching to "Shared by all tasks" uses
the default profile; whether the folders of tasks that no longer exist and their `Local State` records are deleted.
Whether cookies move in the shape Chromium stored them (section 8): whether the QA server's sign-in check across two
sites (`/cookie-check`, console 127.0.0.1 and account site localhost) is `ok` both in the default profile and in a new
task; whether Google-shaped cookies planted with DevTools in the default profile (a host-only cookie and a `__Host-`
cookie on `accounts.example.com`, Secure and non-Secure cookies on `.example.com`, a partitioned cookie under another
top-level site) go into a new task with the same domain and Secure flag, and the partitioned cookie does not become a
top-level cookie; whether, after a sign-in done again in a task is moved to the default profile, the account site
receives each name once with the new value (both in the default profile and in tasks after it). Adding
`--ui-fixture-isolation-cookies` runs only this check. Since 2026-10-27 the checks of the sign-ins tasks follow
(section 11) run too, and adding `--ui-fixture-isolation-follow` runs only those. Every check uses a new task and decides first which values it
will read (the cookie check first deletes cookies of the same name from earlier runs), so state that earlier QA left in
the same QA home does not matter. Each step measures the process tree's memory (adding `--ui-fixture-isolation-shared`
opens the same tabs in the single default profile and measures that). 2026-10-24 results (after the fix in section 7):
all 9 passed in a new QA home; all 9 also passed in a QA home where the full check and the isolation check had run
first; the 30 vault QA checks passed; "profile keeps cookies across host restarts" in the full `run-check.sh` passed.

## 7. Fix: task profiles were in memory (2026-10-24)

- **Symptom:** After this feature was merged, "profile keeps cookies across host restarts" in the full QA failed with
  `cookies ""`. The reason is that the panel's tab uses the task's (`…F401`) profile.
- **Cause:** CEF 154 (Chrome bootstrap) opens a disk profile only when the request context's `cache_path` is the root
  cache or directly under it; otherwise it logs "Cannot create profile at path" and uses an in-memory (OffTheRecord)
  profile. The first implementation's `Browser/Tasks/<key>` was one level deeper, so every task profile was in memory.
  Within one host, isolation and the starting cookie copy still worked, and 8 isolation QA checks passed, but when the
  host ended, all of a task's sign-ins were gone (the folder held only the `Preferences` that Yardlet wrote). The first
  memory measurement in section 5 was also taken with in-memory profiles.
- **Fix:** The folder moved to `Browser/Task-<key>` (host `TaskProfiles`, app `BrowserTaskProfiles`, saved file
  `Browser/TaskProfiles.json`). Disk profiles are read asynchronously, and `create_browser_sync` cannot create a browser
  in a context that has not been read yet (it returns NULL), so the bridge creates the browser after it receives
  `on_request_context_initialized` for each context, and the host treats tabs in between like tabs that copy the
  starting cookies. The record that Chromium leaves in `Local State` for each disk profile (about 400 bytes per profile,
  kept even when the folder is deleted) is removed at cleanup. A host restart and a `Local State` check were added to
  the isolation QA.
- **The old `Browser/Tasks` folder:** This feature never shipped in an installed build (not on main, and no `Tasks` in
  `Browser` of this Mac's installed app), so no code to move or delete the folder was added. Homes that used an
  `integration` development build may have an unused `Browser/Tasks`, which can be deleted.

## 8. Fix: copying changed the shape of cookies (2026-10-25)

- **Symptom:** In the panel of a task where the user was signed in to a Google account, opening the Google Cloud console
  (`console.cloud.google.com/auth/…`) and the OAuth consent address
  (`accounts.google.com/o/oauth2/v2/auth?…prompt=select_account`) went to `accounts.google.com/CookieMismatch` every
  time ("found a problem with your cookie settings"). Search Console opened in the same tab. That step was done in
  another browser.
- **Cause:** When the copy inserted a cookie, it passed the source's domain value as it was. Chromium stores the domain
  of a host-only cookie without a dot (`accounts.google.com`), but CEF's `set_cookie` makes a host-only cookie only when
  the domain is empty, and with any value it makes a domain cookie (`.accounts.google.com`, which also goes to
  subdomains) (the description of `cef_cookie_t.domain` in `cef_types.h`). So every host-only cookie became a domain
  cookie, and the `__Host-` cookies, which must not have a domain attribute, were rejected by Chromium and went missing.
  Also, `visit_all_cookies`, which reads all cookies, returns partitioned cookies too, but CEF's cookie struct has no
  partition key, so the partitioned cookies went in as unpartitioned cookies.
- **What happened with Google (installed build records; values not looked at):** At 00:37, when that task's profile was
  created, the copy from the default profile turned 3 host-only sign-in cookies of `accounts.google.com` into
  `.accounts.google.com` and dropped 3 `__Host-` cookies. At 17:20, when Google set new sign-in cookies in that panel (2
  host-only, 3 `__Host-`), two copies of each same-name cookie (the 00:37 copy and the 17:20 original) went to
  `accounts.google.com` from then on. Flows that pass through the Google account site (the console's sign-in check,
  OAuth consent) sent this back as `CookieMismatch`. Search Console opens with `.google.com` domain cookies (those
  cookies were copied as they were), which is taken to be why it worked (inferred). At the same 17:20, copying the
  person's sign-in also made duplicates in the default profile (the default profile's host-only original is from 10-23,
  the copy from 17:20), so tasks created after that start in the same state. The 16:49 update restart was not the
  trigger: the folder was not newly created (cookie DB created at 00:37, no alias), no cookies were copied again (every
  copy is from 00:37), and all the Google cookies are persistent cookies.
- **Other facts from the installed build:** The cookie DB is Chromium 154's schema 24 (`top_frame_site_key`,
  `source_scheme`, `source_port`, `source_type` and others). Cookies that a copy created stay as `source_type` 3
  (cookies set through the API), which tells them apart from originals (1: HTTP response, 2: script). A task copied from
  the default profile had 0 host-only cookies and 0 `__Host-` cookies, and all 7 partitioned cookies of the default
  profile were in it without partitions. In the default profile, other sites also have a host-only original and a domain
  copy with the same name side by side (Google 3, other sites 3), and there are 45 domain copies whose originals appear
  to be host-only. The cookie settings in `Preferences` (`profile.cookie_controls_mode`, third-party blocking, cookie
  exceptions) are not written in the default profile or in the task profiles, so they are Chrome's defaults, and
  `chromium.log` has no cookie lines.
- **Third-party cookies and the user agent are not the cause (QA):** In a frame of another site, a
  `SameSite=None; Secure` cookie and a partitioned cookie are both stored and read, and `hasStorageAccess()` is true
  (the same as the default of a regular Chrome profile). What sites receive is the `Chrome/154.0.0.0` user agent and
  `Sec-CH-UA: "Not A(Brand";v="99", "Chromium";v="154"` (Chromium instead of Chrome's "Google Chrome" brand; this fits
  Search Console working in the same tab).
- **Fix:** The cookie copy in `YardletCEFBridge.c`. Host-only cookies are inserted with an empty domain, by the
  address's host alone (the same method as the Claude app's copy). After reading all of the source's cookies, it asks
  the source again with each cookie's address (`visit_url_cookies`; CEF returns only unpartitioned cookies) and inserts
  only the cookies in that answer. Partitioned cookies are not moved (section 5). With a default profile holding 300
  cookies (150 hosts; about 186 remain because of Chromium's per-site limit), a new task took 0.21 seconds to open a
  page (a temporary measurement, not committed).
- **The two apps (bundle bytes, not run):** The Claude app 3.1623.3 reads with `cookies.get({})` when it forks a session
  and inserts with `cookies.set`, leaving out `domain` for host-only cookies (`bgi`:
  `...e.hostOnly?{}:{domain:e.domain}`; the address is https when `secure`, otherwise http). It does not handle
  partition keys. In the Codex app 26.1016 all threads share one store (`persist:codex-browser-app`), so there is no
  copy between profiles. In neither app was a switch or setting found that changes the third-party cookie policy.
- **Cookies already changed (one-time cleanup, `BrowserCookieCopyRepair`):** The fixed copy does not repair copies that
  are already stored, so Yardlet cleans up once, just before it first starts the browser host (it cannot while the host
  has the cookie DB open). In the `Cookies` of the default profile and of the `Task-<UUID>` profiles, it deletes only
  the domain cookies that a copy created (`source_type` 3, `.host`) that duplicate a host-only cookie with the same
  name, path and partition that the site created itself (`source_type` 1 or 2). The copy before the fix never created
  host-only cookies of a registrable domain, so the host-only side of such a duplicate is always the site's own. The
  site's own duplicates, copies with no pair, and duplicates of sites that the fixed copy moved (both sides are copies)
  remain. Only for DBs with something to delete, it first copies `Cookies` and `-journal` and `-wal` to
  `~/.Trash/Yardlet cookie backup <date time>/<profile>/`, and leaves a profile untouched if its backup fails. It
  deletes in a single transaction. When everything is done, it leaves `CookieCopyRepair.json` (only the run time and the
  number deleted per profile) in the root cache, so it does not run again. If the host holds the DB (the PID in
  `SingletonLock` is alive), the DB cannot be read (a journal that needs a rollback and the like), or the backup or
  deletion fails, it leaves no record and runs again at the next start. The Trash is the one of `NSHomeDirectory()`
  (FileManager's Trash does not follow the home that QA sets, so in the first QA the backup went to the person's Trash).
  Those sites may need a new sign-in.
- **QA:** The cookie checks in section 6. In a build before the fix (with only the QA added), a new task's two-site
  check gave `CookieMismatch` (`__Host-qa_signin` missing, the partitioned cookie leaking to the top-level site), the
  new task's `qa_signin` was on `.accounts.example.com`, and the default profile's `qa_signin` after a new sign-in was
  moved there had two copies (A, B). In the fixed build all 4 passed, and all 13 isolation QA checks passed. The
  one-time cleanup was verified with `BrowserCookieCopyRepairTests` (DBs in a temporary folder) and by starting the app
  five times in a QA home: in an empty home only the record is left; after planting duplicates and deleting the record,
  it deletes only those duplicates and backs up to the QA home's Trash; with the record present, it does not run again.

## 9. Fix: duplicate copies spread again after the cleanup (2026-10-26)

- **Symptom:** When the user signed in to Sentry with Google in a task, it was `/CookieMismatch` again. This was after
  the one-time cleanup of section 8 (10-26 03:48 KST, 3 in the default profile and 5 in two tasks).
- **Cause:** The fixed copy of section 8 kept the shape of cookies but did not do two things. (1) When the sending
  profile had domain cookies that the old copy made (`LSID`, `ACCOUNT_CHOOSER` and `OTZ` on `.accounts.google.com`,
  `source_type` 3) next to the site's host-only cookies, it moved both. (2) When the receiving profile had the same
  cookie in another shape, it did not delete it but added the new one. The one-time cleanup deleted only in profiles
  that had pairs, so when a sign-in was moved again from a profile left with only the domain cookies and no pair, the
  default profile got duplicates (10-26 14:17), and tasks created after that started with duplicates. As of 10-26 14:00,
  the default profile, the ERP task and the open-source task (40F6679B) had duplicates.
- **Fix:** The copy (`set_copied_cookies`) leaves out, on the sending side, domain cookies that have a host-only cookie
  with the same host, name and path, and for each cookie first deletes the other shape on the receiving side (a domain
  cookie for a host-only one, a host-only cookie for a domain one). CEF has no call that deletes exactly one cookie, so
  it writes a cookie with the same name, domain and path that has already expired. Chromium deletes just that one cookie
  (`cookie_monster.cc` `DELETE_COOKIE_EXPIRED_OVERWRITE`, 154.0.8037.58 source). The one-time cleanup runs once more as
  round 2 (`round` 2 in `CookieCopyRepair.json`).
- **QA:** In the last step of section 6, domain cookies of the old copy (`.accounts.example.com` `qa_signin=OLD`) were
  planted in both the default profile and task F. The default profile and task G, created after it, sent only one
  `qa_signin`, `B`, and all 13 isolation QA checks passed. The 22 password QA checks also passed.
- **Round 3 (same day):** Round 2 deleted 3 each in the ERP task and the Mobi CS task at 22:57 KST, but left 6 pairs in
  the default profile and pairs in two tasks (5 pairs, 3 pairs). In the remaining pairs the host-only side was a copy
  too (`source_type` 3). Duplicates from before the cleanup had moved back and forth between profiles until both sides
  were copies. The old copy never created host-only cookies, so the host-only side of a pair has the site's shape,
  whatever its source. So round 3 deletes every copied domain cookie that pairs with a host-only cookie. Pairs where the
  site itself created both (for example `_ga` on `search.google.com`) stay.

## 10. Importing sign-ins from another browser (2026-10-26; more browsers on 2026-10-27)

- **Background:** Sites that sign in only with passkeys cannot be signed in to in the Yardlet browser when the passkey
  exists only in another browser (iCloud Keychain, Whale, Chrome). Importing that browser's sign-in cookies lets Yardlet
  enter the site, and after one more Yardlet passkey is registered in the site's settings, Yardlet alone is enough from
  then on. This is ④, which "Aside and Ego compared" in [BROWSER_VAULT_DESIGN](BROWSER_VAULT_DESIGN.md) deferred.
- **What the person does:** Right-click on the page in the browser panel → "Import Sign-ins from Another Browser…" →
  choose the browser and profile → check the sites (the current page's site is at the top, already checked) → Import →
  allow in the macOS keychain prompt ("Yardlet wants to use your confidential information stored in 'Whale Safe Storage'
  in your keychain."). When it is done, the panel shows "Imported the sign-in for … from Whale", and reloads the page if
  it is on that site.
- **Browsers it looks for (more on 2026-10-27):** In `~/Library/Application Support` it looks, in this order, for the
  Chromium family Whale, Chrome, Edge, Brave, Arc, Comet, Vivaldi, Opera, Opera GX, Yandex, Helium and Chromium, and the
  Firefox family Firefox, Zen, Floorp, LibreWolf and Waterfox. Folder and keychain names and the evidence are in the
  table below. Only profiles with a cookie DB on this Mac are shown, and the sheet shows the app bundle's icon when that
  browser app is on the Mac, and a globe symbol otherwise (`NSWorkspace.urlForApplication(withBundleIdentifier:)`,
  without running the app).
  - Chromium family: profiles are read from `Local State` (the names in `profile.info_cache`, `profiles_order`,
    `last_used` first), and only profiles with a cookie DB (`<profile>/Network/Cookies`, otherwise `<profile>/Cookies`:
    Whale and Comet use the latter) are shown. When the browser folder itself is the first profile, as with Opera (a
    cookie DB directly under the folder), it is shown too, under the browser name alone. Keychain items are found by
    service name only (one item per browser; the account name differs per browser, and some could not be confirmed).
  - Firefox family: from the `[Profile…]` sections of `profiles.ini` (`Name`, `Path`, under the browser folder when
    `IsRelative=1`), only profiles with `cookies.sqlite` are shown. The profile that the install uses (`Default` in
    `[Install…]`) comes first, then `Default=1`, then the rest in file order. The keychain is not used.
- **macOS 27's browser folder protection (confirmed 2026-10-27):** A rule set in macOS 27's `/usr/libexec/sandboxd`
  (`defaultRules-3`) opens the Chrome (`Google/Chrome`), Brave (`BraveSoftware/Brave-Browser`), Edge (`Microsoft Edge`)
  and Firefox (`Firefox`) folders only to that browser's own team ID and signing ID and to Safari's import service
  (`com.apple.Safari.BrowserDataImportingService`, Chrome and Firefox only). When another app reads them, it gets
  `Operation not permitted` with no prompt (confirmed by listing the Chrome folder from this task's shell and by the
  `sandboxd` log "TCC denied kTCCServiceSystemPolicyAppDataDetailed for com.google.Chrome"; the DTS answer "intentional
  change" in Apple Developer Forums 847030). The same report says apps with Full Disk Access can read them. So a browser
  whose list file (`Local State`, `profiles.ini`) exists but cannot be read is not put in the list, and below the sheet
  only its name is given, as "macOS lets only apps with Full Disk Access read Chrome's data, so it is not listed." There
  is no prompt that asks for the permission and no settings button. `NativeMessagingHosts` and Chrome's
  `ChromeFeatureState` and `Crashpad` are left out of the rule. The folders of Whale, Arc, Comet, Vivaldi, Opera,
  Yandex, Helium and the Gecko browsers other than Firefox are not in the rule. Whether Yardlet (a signed app) is also
  refused without a prompt when it reads them was not tested, because a prompt might appear on the user's screen (the
  forum and Claude Code issue 81453 both report "refused without a prompt").
- **Safari is not included:** macOS opens Safari's cookies
  (`~/Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies`) only to apps with "Full Disk
  Access". That permission covers all of other apps' data, so Yardlet does not ask for it just for this one feature.
- **Site list:** From the copy of the cookie DB, only `host_key` and the last-used time are read (values are not read).
  Partitioned cookies (those with a non-empty `top_frame_site_key`) and expired cookies are not counted. Hosts are
  grouped by registrable domain (the Public Suffix List, the same list the vault uses), and IP addresses and `localhost`
  stay as they are. The order is most recently used first.
- **Decryption (Chromium on macOS):** An AES-128 key is derived from the keychain password with PBKDF2-HMAC-SHA1 (salt
  "saltysalt", 1003 iterations, 16 bytes), and what follows the `v10` prefix is decrypted with AES-128-CBC (an IV of 16
  spaces, PKCS#7). When the `meta` version is 24 or higher, the first 32 bytes of the decrypted value must be the
  SHA-256 of `host_key` (otherwise that cookie is dropped), and the rest is the value. If none decrypts, the key is
  taken not to belong to that profile and nothing is inserted. An unencrypted `value` is accepted too.
- **Reading Firefox (2026-10-27):** `cookies.sqlite` (in WAL mode, so recent cookies are in `-wal`) is copied the same
  way, and `moz_cookies` is read as plain text. The conversion follows Firefox 158's source
  `netwerk/cookie/CookiePersistentStorage.cpp` (schema 17): a leading dot in `host` means a domain cookie, `isSecure`
  and `isHttpOnly` carry over as they are, and `expiry` is **milliseconds** since 1970 from schema 16 on (seconds before
  that, told apart by `PRAGMA user_version`), so it is converted to Chromium's microseconds since 1601. SameSite maps
  `nsICookie`'s 0 None, 1 Lax, 2 Strict and 256 unspecified to CEF's 1, 2, 3 and 0, and a None that is not Secure is
  left unspecified, because Chromium does not accept it (before schema 15, `rawSameSite` None and `sameSite` Lax are
  also left unspecified). Firefox has no priority, so it is medium. Only cookies with an empty `originAttributes` are
  accepted: those with `partitionKey` (partitioned), `userContextId` (containers) or `privateBrowsingId` are a different
  identity and are not inserted. Firefox does not keep session cookies in the file, so sign-ins that end when the
  browser closes cannot be imported. `lastAccessed` (microseconds since 1970) is used only to order the sites.
- **Inserting:** The app sends the cookies of the chosen sites (and their subdomains) to the host with the
  `importCookies` command. The host deletes all cookies of those sites in the target profile (the delete flag of
  `visit_all_cookies`, partitioned cookies included) and inserts them through the insert path of sections 8 and 9
  (`set_copied_cookies`): host-only cookies go in with an empty domain, so they stay host-only; Secure, HttpOnly,
  SameSite, priority and expiry (Chromium's microseconds since 1601, unchanged) are kept; domain cookies that have a
  host-only cookie with the same host, name and path are left out; and, for each cookie, the other shape on the
  receiving side is deleted. As in round 3 of section 9, the host-only side of a pair remains. Then the host writes the
  store to disk (`flush_store`) and replies. The targets are the default profile and the profile of the panel's task. A
  task profile whose folder does not exist yet is not touched (it receives the cookies from the default profile when its
  first tab opens). With "Shared by all tasks", the target is the default profile alone.
- **Why delete and then insert:** If the other browser's sign-in mixes with cookies of the same site already in Yardlet,
  the cookies of two sessions go to one site. The Google account site blocked such a state with `/CookieMismatch`
  (sections 8 and 9). The Claude app's import overwrites without deleting.
- **Security:** For the Chromium family, the keychain is read once, at the moment the person presses Import
  (`SecItemCopyMatching`, service name only, on a background thread), and the password and key are used only in memory
  and then zeroed. The Firefox family does not read the keychain. The browser may be writing to the cookie DB, so the DB
  is copied with `-journal` and `-wal` to a private folder (0700) in `$TMPDIR` and opened read-only; if the copy was
  taken mid-write and does not open, it is copied again after 0.3 seconds (up to three times). The copy is deleted right
  after reading (it is not sent to the Trash, even though the values are still encrypted). The original is never opened.
  Cookie values travel only through the pipe between the app and the host, and stay out of the screen, logs, the model
  and files (the host's command log records only command names). There is no agent tool.
- **Limits:** Sites that keep the sign-in in localStorage or IndexedDB do not come along (the Claude app's import moves
  localStorage as well). Chromium shortens the expiry of inserted cookies to at most 400 days from insertion (source
  evidence, not measured with QA). Imported cookies share that browser's session, so on some sites signing out on one
  side also ends the other. Since 2026-10-27 an import is the person's sign-in, so the tasks that follow those sites take
  it from the default profile too (section 11).
- **QA:** `run-check.sh … --ui-fixture-browser-check-only=import` (`BrowserHostLoginImportQA`). It creates a fake Whale
  folder in the QA home's Application Support (two profiles, cookies encrypted with a test password: a host-only cookie
  and a `__Host-` cookie on `accounts.example.com`, Secure and non-Secure cookies on `.example.com`, a partitioned
  cookie, an expired cookie, a `localhost` cookie, and a `www.other.test` cookie that will not be chosen) and passes
  that password in place of the keychain. It first plants the old copy's domain cookies and other cookies of the site in
  the default profile, and that task's sign-in in the panel's task. 2026-10-27 results (ad-hoc debug bundle, new QA
  home): all 9 passed. The site list is `example.com`, `localhost` and `other.test` (no site with only partitioned or
  expired cookies); the page menu has the item, and the sheet opens with `localhost` checked (image `import-sheet.png`);
  the default profile, the panel's task and a task created afterwards all send one imported value each of `qa_signin`,
  `__Host-qa_signin` and `qa_session` to `accounts.example.com`, and the earlier `OLD`, `Y` and `T` and `qa_leftover`
  are gone; the stored shapes are `__Host-qa_signin accounts.example.com Secure HttpOnly Lax`,
  `qa_plain .example.com non-Secure Lax session`, `qa_session .example.com Secure HttpOnly None`,
  `qa_signin accounts.example.com Secure HttpOnly None`; `keep.test` stays as it was and `other.test` does not come in;
  the panel page reloads and sees `qa_local`; no values in the app or host logs. No leftover processes or crash reports.
  **More browsers on 2026-10-27:** In the same QA home it adds a fake Firefox folder (two profiles in `profiles.ini`,
  where the one the install uses differs from `Default=1`; a schema 17 `cookies.sqlite` left in WAL: a host-only Strict
  cookie on `accounts.example.net`, SameSite-unspecified, Secure None and non-Secure None cookies on `.example.net`, a
  container cookie with the same name, a partitioned cookie, an expired cookie) and a fake Chrome folder whose
  `Local State` cannot be read. After Whale, it imports Firefox without the keychain. Results (ad-hoc debug bundle,
  `$TMPDIR/browser-host-qa/import-more-browsers/`): 13 passed in both the light screen `run-import` and the dark screen
  `run-import-dark`. The profile order is `Whale · Work`, `Whale · Person 1`, `Firefox · default-release`,
  `Firefox · old`, and the unreadable browser `Chrome`; the Firefox site, read through the WAL, is `example.net`; the
  Firefox cookie shapes stored in the default profile are `qa_ff_signin accounts.example.net Secure HttpOnly Strict`,
  `qa_ff_session .example.net Secure HttpOnly (unspecified)`, `qa_ff_cross .example.net Secure HttpOnly None`,
  `qa_ff_plain .example.net non-Secure (unspecified)` (all with an expiry); the panel's task sends the same four values
  and no container value; the panel notice is "Imported the sign-in for example.net from Firefox."; no values in the app
  or host logs; no leftover processes or crash reports. The sheet image (`import-sheet.png`) shows the installed Whale's
  icon and the Chrome notice line. The globe symbol shows only when the menu is open, so it is not in the image.

### Supported browsers and evidence (2026-10-27)

Folders are under `~/Library/Application Support/`, and keychain entries are services (in parentheses, the account seen
in the same place). "Download" means a dmg, tar.xz or pkg from the vendor's server, attached read-only or unpacked
without installing, with only Info.plist and bytes read (the app was not run); "installed" means the app bundle on this
Mac. For the Chromium family, the byte evidence is the service and account constants placed right after Chromium's
cookie key salt `saltysalt`, or the default folder value next to `chrome_paths`. Several browsers carry import tables
for other browsers (Brave source; Comet, Dia, Vivaldi, Yandex and Opera bytes), and these were used to cross-check.

| Browser | Folder | Keychain | Bundle ID | Evidence |
|---|---|---|---|---|
| Whale | `Naver/Whale` | Whale Safe Storage (Whale) | `com.naver.Whale` | Installed 5.39.412.57 bytes, this Mac's folder (`<profile>/Cookies`) |
| Chrome | `Google/Chrome` | Chrome Safe Storage (Chrome) | `com.google.Chrome` | Installed 155.0.8059.86 bytes, Chromium source. macOS 27 protection |
| Edge | `Microsoft Edge` | Microsoft Edge Safe Storage (Microsoft Edge) | `com.microsoft.edgemac` | Download pkg 156.0.4314.42 bytes; the folder from the `sandboxd` rule and the Dia and Yandex tables. macOS 27 protection |
| Brave | `BraveSoftware/Brave-Browser` | Brave Safe Storage | `com.brave.Browser` | Download 156.1.98.60 `CrProductDirName`, brave-core `keychain_password_mac.mm` default. macOS 27 protection |
| Arc | `Arc/User Data` | Arc Safe Storage | `company.thebrowser.Browser` | Download 1.170.0 ArcCore bytes (`%s Safe Storage` and arc→Arc), the Comet, Vivaldi and Opera tables, this Mac's `Arc/User Data/Local State` |
| Comet | `Comet` | Comet Safe Storage | `ai.perplexity.comet` | Download 155.0.8059.148 bytes, this Mac's `Comet/Local State` and `Default/Cookies` |
| Vivaldi | `Vivaldi` | Vivaldi Safe Storage (Vivaldi) | `com.vivaldi.Vivaldi` | Download 8.2.4133.94 bytes; the folder from the Dia table and the Vivaldi forum |
| Opera | `com.operasoftware.Opera` (the folder itself is the first profile) | Opera Safe Storage (Opera) | `com.operasoftware.Opera` | Download 138.0.6044.24 bytes; the folder from the Dia and Yandex tables; the first profile's location from an Opera forum moderator's answer |
| Opera GX | `com.operasoftware.OperaGX` | Opera Safe Storage (Opera) | `com.operasoftware.OperaGX` | Download 138.0.6044.45 bytes (the GX build has the same constants, and `com.operasoftware.OperaGX` 9 times), the Dia and Yandex tables. Only the Vivaldi table says "Opera GX Safe Storage", so GX's own bytes were followed |
| Yandex | `Yandex/YandexBrowser` | Yandex Safe Storage (Yandex) | `ru.yandex.desktop.yandex-browser` | Download 26.8.3.1016 bytes, Brave source. Whether its cookies are encrypted with `v10` is not confirmed (if not, the import ends with "The browser's cookies could not be decrypted with its key.") |
| Helium | `net.imput.helium` | Helium Storage Key (Helium) | `net.imput.helium` | Download 0.20.1.1 bytes, the helium-macos patches `change-keychain-name` and `change-product-dir-name` |
| Chromium | `Chromium` | Chromium Safe Storage (Chromium) | `org.chromium.Chromium` | Chromium source `keychain_password_mac.mm`, `chrome_paths_mac.mm` and `BRANDING` |
| Firefox | `Firefox` | None | `org.mozilla.firefox` | Download 158.0.1 `application.ini` (`Name=Firefox`), Gecko `nsXREDirProvider::AppendProfilePath` (on macOS `Profile`, otherwise `Name`). macOS 27 protection |
| Zen | `zen` | None | `app.zen-browser.zen` | Download 1.23.4b `Profile=zen` |
| Floorp | `Floorp` | None | `app.floorp.Floorp` | Download 12.20.2 `Profile=Floorp` |
| LibreWolf | `librewolf` | None | `net.librewolf.librewolf` | Download 158.0.1-2 `Profile=librewolf` |
| Waterfox | `Waterfox` | None | `net.waterfox.waterfox` | Download 6.7.6 `Profile=Waterfox` |

Not included: **Dia** (the ArcCore in download 1.54.2, `company.thebrowser.dia`, has only the `%s Safe Storage` format
and no folder or service string of its own. Comet's table says "Dia Safe Storage", but the folder could not be
confirmed), **ChatGPT Atlas** (OpenAI help "ChatGPT Atlas retirement": it is retired and no longer updated, and for
cookies the help says to sign in again in the new browser. For reference, the built-in Chromium of the 1.2026.189.1
bundle is `com.openai.atlas.web`, "ChatGPT Safe Storage"/"ChatGPT"), **Sidekick** (service ended on 2025-08-03, and the
team moved to Perplexity), **Thorium** (Thorium-MacOS releases ship without macOS files from M144 (2026-06), the last
M138 was in 2026-02, and the Homebrew cask is disabled too), **Safari** (above).

## 11. Tasks follow the person's sign-ins (2026-10-27)

- **Why:** The user: "sign-in state is not shared well". Under the rules in section 3, only the person's password
  sign-ins went to the default profile, and nothing reached tasks already open. When the user signed in to Cloudflare in
  one task, the agents of other tasks kept seeing it signed out.
- **Decision (approved by the user):** Only the sites a task signed in to itself (its agent's vault fill or typed
  sign-in) stay that task's; on every other site
  all tasks follow the user's latest sign-in. Normally, as in the Codex app, every task uses the same sign-ins, and only
  a task that went in with another account keeps its own. The two choices of Settings › General "Keep cookies" stay as
  they are; this rule lives within "Per task".
- **Finding sign-ins (`BrowserLoginFollow`):** A cookie change alone cannot tell a sign-in from a site renewing its
  cookies (Google renews them all the time while in use). So only when a moment that starts a sign-in occurs does it
  measure a sum of hashes of that site's cookies (the FNV-1a of name, domain, path and value, added up; the host
  computes it and no value leaves the host), and a different value measured again within three minutes is a sign-in.
  - Moments: the page's password field takes focus (the host's `passwordField`), a one-time code field shows on a
    panel's page (the vault's watcher), Chromium's passkey window opens over the tab (the host says which tab each window
    is over: [BROWSER_HOST](BROWSER_HOST.md) section 3, "Chromium's windows and tabs"; a window whose tab is not known is
    left out), the page opens a popup (a "Sign in with Google" window), the tab leaves the site for another (a single
    sign-on round trip).
  - When it measures again: when the tab has loaded a page of that site, when it leaves the site, 2 and 8 seconds after
    a popup or passkey window closes, 4 and 12 seconds after the panel's sign-in form is submitted. Within the three
    minutes it also catches the cookies set after two-step verification.
  - Whose sign-in: whoever used the tab last when it measures again. The person's when the person used the tab in the
    last three minutes and the agent has not used it since (`BrowserTab.isDrivenByAgent`), on a page the agent handed
    over (`browser_handoff`) too (the user's decision of 2026-10-27, "sign-ins should spread"). A popup that has closed
    goes by who used the tab that opened it when the sign-in began. A sign-in the agent made through a password or code
    field and a vault fill (`.vaultFilled`) are the task's own. When the agent's moment is not a password or code field
    (browsing), it is nothing, and so is a tab nobody drives that goes through another site on its own.
- **Passing it on:** For the person's sign-in it counts the site's sign-in number up by one and copies that task
  profile's cookies of the site to the default profile and to the tasks with tabs open now that follow the site. The
  target's cookies of the site go first (the same visitor as the import in section 10): when two sessions' cookies mix
  on one site, Google's accounts site blocks it with `/CookieMismatch` (sections 8 and 9). Insertion is the path of
  sections 8 and 9 (`set_copied_cookies`) as it is, so host-only pairs and deleting the other shape (writing it expired)
  hold. A task without an open tab takes the site's cookies from the default profile at about:blank when its tab next
  opens, then opens the address (`BrowserTaskProfiles.opening`, `follow` in the host's `open`). A sign-in imported from
  another browser (section 10) is the person's too, so it goes from the default profile to the same tasks.
- **A task's own sign-in:** That site of that task leaves following, and a sign-in the person makes again in that task
  is not passed to others (whether the task's account is the person's cannot be known, so the side that overwrites
  nothing). A child task inherits its parent's own sign-ins. When the feature turns on, it reads the agents' fills in the
  vault's usage log (`~/.yardlet/vault/usage.jsonl`, 90 days) once and takes each as that task's own sign-in on that
  site.
- **First run:** A task made before the feature, the first time its tab opens afterwards, fills in from the default
  profile only the sites it has no cookie of at all (`fill`). Sites that already have cookies stay as they are; what
  overwrites them starts with the person's sign-ins made after the feature turned on. The bridge has no public suffix
  list, so a fill's site is coarser than the registrable domain (an IP address whole, otherwise the host's last two
  labels). Coarser only fills less; it never overwrites.
- **Storage:** `following` in `Browser/TaskProfiles.json`: each site's sign-in number of the person (`signIns`), per
  profile key the numbers it took (`received`) and its own sign-ins (`own`), the keys that began following
  (`followers`), and whether the vault log was read. No cookie values. The records of archived and deleted tasks go with
  their folders.
- **Where:** `BrowserLoginFollow.swift` (new), `BrowserTaskProfiles.swift` (`opening`, `personSignedIn`,
  `signedInItself`), `BrowserHostClient.swift` (`cookieDigest`, `copyCookies(from:to:site:)`, the tab event hook),
  `BrowserHostProtocol.swift`, `BrowserHostPaneVault.swift` and `BrowserHostPaneLoginImport.swift` (moments and
  imports), `VaultCenter.swift` (`agentFills`), the host's `BrowserHost.swift` and `TaskProfiles.swift` (the list of
  copies, `cookieDigest`), and in the bridge `yardlet_cef_copy_cookies` (a list of sites; add, replace or fill) and
  `yardlet_cef_cookie_digest`.
- **QA:** `run-check.sh … --ui-fixture-browser-check-only=isolation` (only these with `--ui-fixture-isolation-follow`).
  The QA server's `/follow/signin` (localhost) has a password form and a "Sign in with QA" link that goes through an
  account picker on another site (127.0.0.1) and back; both plant `qa_follow`. The person clicks through the host's
  input (the panel's path); the agent acts through DevTools and reports its use. Seven checks: the agent's password
  sign-in is its task's own (the person's sign-in number unchanged, open task F does not get it); the person's password
  sign-in reaches open task F and the default profile, and the agent's task G keeps `AGENT`; cookies a site renews while
  the person browses are not passed on; a single sign-on round trip in a tab nobody drives is not passed on; the
  person's sign-in without a password (single sign-on) reaches F and a task made later, and G keeps its own; the person's password sign-in on a page the agent handed over
  reaches F and the default profile and does not become that task's own; a task from
  before the feature keeps its own cookie on 127.0.0.1 (`OLD`) and takes only the site it had no cookie of
  (`fill.qa-follow.test`). Following section 3's revision, "the person's sign-in reaches running tasks too" and section
  8's "running tasks get one of each" changed. 2026-10-27 results (ad-hoc debug bundle,
  `$TMPDIR/browser-host-qa/login-follow/`): 18 isolation checks passed in a new QA home and again in the same home. With
  the last bundle, which adds the check of a tab nobody drives and the code field moment, in a new QA home (`final/`):
  19 isolation, 37 vault and 13 import checks all passed, no processes or crash reports left. After the handoff decision and the window owners
  (merged with 0.11.1), in a new QA home (`decision/`): 20 isolation (the handoff check added), 37 vault and 13 import
  checks passed, no processes or crash reports left. The host log has command names only, no cookie values. The moments the QA goes through are the password field and the round trip through
  another site. The popup, passkey window and code field moments use the same comparison but were not run in QA (the
  passkey window could take the screen). The `compat` and `passkey` runs, which show Chromium's windows, were not run
  again for the shared window hook (they can raise system prompts on the screen); `ChromiumWindowPresentationTests` and
  `BrowserAgentTabToolsTests` passed.
- **Limits:**
  - A sign-in the person makes on a page the agent handed over is the person's even with an account for that task alone
    (someone else's account, for example), so it spreads to other tasks. Such an account stays in its task when the
    agent fills it from the vault.
  - A task-only sign-in from before the feature with no vault record has no mark, so when the person later signs in to
    the same site, that task follows too.
  - A sign-in without a moment (a sign-in link opened outside Yardlet, for example) is not passed on. A passkey request
    the agent started and the person answered with Touch ID is no one's sign-in (the agent's moment is not a password or
    code field).
  - If the site changes its cookies by itself within three minutes after a moment, that is passed on once too (the
    window kept to catch two-step verification).
  - When passing a sign-in on, the target's partitioned cookies of the site are deleted too and do not come back
    (section 5: partitioned cookies cannot be moved). localStorage and IndexedDB do not follow.
  - A sign-out that ends within the site is not passed on (no moment). A sign-out that goes through another site
    (single sign-on sign-out) is passed on like a sign-in, so the tasks that follow the site are signed out too. When
    the person then signs in with another account, that sign-in is passed on.
