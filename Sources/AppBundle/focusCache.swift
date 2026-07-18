import AppKit
import Foundation

@MainActor private var lastKnownNativeFocusedWindowId: UInt32? = nil

// Workspace-aware app activation (see resolveFocusPreferringVisibleWorkspace). `internal`, not `private`,
// so tests can reset them in setUpWorkspacesForTests -- they're process-global.
@MainActor var lastKnownFrontmostAppPid: Int32? = nil
@MainActor var pendingRedirect: PendingRedirect? = nil
/// Tests set this to bypass the on-disk summon list. Reset to nil in setUpWorkspacesForTests.
@MainActor var summonAppsOverrideForTests: Set<String>? = nil

struct PendingRedirect {
    let sourcePid: Int32   // app macOS focused (what we're redirecting *away* from)
    let targetPid: Int32   // app of the window we're redirecting *to* (== sourcePid for same-app redirects)
    let targetWindowId: UInt32
    var attemptsLeft: Int
}

// ---- Behavior 5, Phase A: instrumentation only (no redirect yet) ----
// A minimize/close bumps macOS focus to another same-app window that may live on a hidden workspace,
// dragging you there. Phase A records the minimize as a BumpEvent and LOGS, at the moment of the
// resulting focus follow, whether the record was already present -- answering the open question of
// whether the AX miniaturize event lands before or after the focus refresh. No behavior change yet.
struct BumpEvent {
    let windowId: UInt32
    let workspaceName: String
    var ttlRefreshes: Int
}
@MainActor var recentBumps: [BumpEvent] = []
private let bumpTtlRefreshes = 2

// Unbuffered so lines land in aerospace.err.log immediately (stdout under launchd is block-buffered).
func b5trace(_ msg: @autoclosure () -> String) {
    fputs("B5PHASEA " + msg() + "\n", stderr)
}

/// AX handler for `kAXWindowMiniaturizedNotification` (split out of refreshObs for Phase A). The element
/// is still alive on a minimize, so `containingWindowId()` recovers the id; the window's `nodeWorkspace`
/// is captured before normalizeLayoutReason re-parents it. Then refresh as usual, exactly like refreshObs.
func bumpObs(_ obs: AXObserver, ax: AXUIElement, notif: CFString, data: UnsafeMutableRawPointer?) {
    let windowId = ax.containingWindowId()
    let notif = notif as String
    Task { @MainActor in
        if !TrayMenuModel.shared.isEnabled { return }
        if let windowId {
            let ws = Window.get(byId: windowId)?.nodeWorkspace?.name
            recentBumps.append(BumpEvent(windowId: windowId, workspaceName: ws ?? "", ttlRefreshes: bumpTtlRefreshes))
            b5trace("BUMP-EVENT miniaturize win=\(windowId) ws=\(ws ?? "nil") queued=\(recentBumps.count)")
        }
        scheduleRefreshSession(.ax(notif))
    }
}

@MainActor private func ageBumpRecords() {
    guard !recentBumps.isEmpty else { return }
    for i in recentBumps.indices { recentBumps[i].ttlRefreshes -= 1 }
    recentBumps.removeAll { $0.ttlRefreshes <= 0 }
}

/// Behavior 5: a non-activation focus change landed on a hidden workspace. If a minimize/close just
/// bumped us here, keep focus on the workspace we were on (the bump's recorded workspace) instead of
/// following. Returns the window to redirect to, or nil to let the caller follow as before.
///
/// - No bump record => a deliberate ⌘`/click => follow (return nil).
/// - Bump present => `here` = the bumped window's workspace. Prefer a same-app window on `here` (clean),
///   else any window on `here` (cross-app -- keeps you put even if the app has nothing left here). If
///   `here` is now empty, follow (return nil; the empty-workspace case is deferred).
/// The bump is consumed on use. `here` may no longer be visible (delayed AX ordering: we already
/// followed away) -- redirecting re-activates it, a one-frame flash; still better than staying dragged.
@MainActor private func resolveBump(_ nativeFocused: Window, _ pid: Int32) -> Window? {
    let toWs = nativeFocused.nodeWorkspace?.name ?? "nil"
    guard let bump = recentBumps.last, !bump.workspaceName.isEmpty else {
        b5trace("BUMP none: non-activation follow->ws=\(toWs) (deliberate switch or not-yet-arrived) => follow")
        return nil
    }
    recentBumps.removeLast() // consume-on-use
    let here = Workspace.get(byName: bump.workspaceName)
    guard let target = here.mostRecentWindowRecursive(where: { $0.app.pid == pid })   // same app on `here`
        ?? here.mostRecentWindowRecursive(where: { _ in true })                       // else anything on `here`
    else {
        b5trace("BUMP win=\(bump.windowId) here=\(bump.workspaceName) now empty => allow follow->ws=\(toWs)")
        return nil
    }
    pendingRedirect = PendingRedirect(sourcePid: pid, targetPid: target.app.pid, targetWindowId: target.windowId, attemptsLeft: 3)
    b5trace("BUMP-REDIRECT win=\(bump.windowId) keep ws=\(bump.workspaceName) target=\(target.windowId)"
        + " (macOS was following to ws=\(toWs); hereVisible=\(here.isVisible))")
    return target
}

/// Reset every process-global this file owns. Called from setUpWorkspacesForTests so test order can't leak
/// state (these globals persist across tests otherwise).
@MainActor func resetFocusCacheForTests() {
    lastKnownNativeFocusedWindowId = nil
    lastKnownFrontmostAppPid = nil
    pendingRedirect = nil
    summonAppsOverrideForTests = nil
    summonApps = nil
    recentBumps = []
}

/// The data should flow (from nativeFocused to focused) and
///                      (from nativeFocused to lastKnownNativeFocusedWindowId)
/// Alternative names: takeFocusFromMacOs, syncFocusFromMacOs
@MainActor func updateFocusCache(_ nativeFocused: Window?) {
    if nativeFocused?.parent is MacosPopupWindowsContainer {
        return
    }

    // MUST precede any nativeFocus() below, and MUST be what macOS actually reports (not the redirect
    // target): MacApp.nativeFocus skips AX and merely activate()s when lastNativeFocusedWindowId matches,
    // which would leave the app focused on its own pick. See MacApp.swift nativeFocus fast-path.
    (nativeFocused?.app as? MacApp)?.lastNativeFocusedWindowId = nativeFocused?.windowId

    // Behavior 4: activation landed on an app with no focusable (non-minimized) window -- its only window(s)
    // are minimized, so macOS handed us nil. Un-minimize the most-recent one; the native restore path lands
    // it on focus.workspace (parity with clicking the Dock icon). If the app has *any* non-minimized window,
    // macOS focuses it instead (nativeFocused != nil) and this branch is never reached -- so an app with a
    // window open elsewhere still snaps to that window. Falls through so the tail clears the cache as before.
    if nativeFocused == nil {
        restoreMinimizedWindowOnActivation()
    }

    let effective = resolveFocusPreferringVisibleWorkspace(nativeFocused)

    if effective?.windowId != lastKnownNativeFocusedWindowId {
        _ = effective?.focusWindow()
        lastKnownNativeFocusedWindowId = effective?.windowId
    }
    if let effective, effective !== nativeFocused {
        effective.nativeFocus() // syncFocusToMacOs: macOS still believes nativeFocused has the focus
    }

    ageBumpRecords() // Behavior 5, Phase A: TTL so the bump queue can't grow unbounded
}

/// macOS activates *applications*; the app then picks which window to focus from its own MRU, which knows
/// nothing about AeroSpace workspaces (MacApp.getFocusedWindow reads Ax.focusedWindowAttr). So cmd-tab-ing
/// to Finder can land on a hidden-workspace window and drag the user there. When that happens *as part of
/// activating the app*, prefer a window of that app on a visible workspace; or, for opted-in apps, bring
/// the window to the user instead of following it away.
@MainActor
private func resolveFocusPreferringVisibleWorkspace(_ nativeFocused: Window?) -> Window? {
    // A transient nil must not spuriously arm the gate
    guard let nativeFocused else { return nil }
    let pid = nativeFocused.app.pid
    let isAppActivation = pid != lastKnownFrontmostAppPid
    lastKnownFrontmostAppPid = pid

    // Minimized/popup/unparented windows bind to NilTreeNode => not our business
    guard let nativeWorkspace = nativeFocused.nodeWorkspace else { pendingRedirect = nil; return nativeFocused }
    if nativeWorkspace.isVisible { pendingRedirect = nil; return nativeFocused }

    // ---- macOS focused a window on a hidden workspace ----

    // A redirect we already issued hasn't been honored yet. Keep insisting (bounded). Crucially do NOT fall
    // through to "follow macOS" while pending -- that would undo our own redirect one session later. Match
    // on source OR target pid: a cross-app behavior-5 redirect (source != target) must keep retrying while
    // macOS still reports the source app frontmost, until it catches up to the target.
    if var pending = pendingRedirect, pending.sourcePid == pid || pending.targetPid == pid, pending.attemptsLeft > 0,
       let target = Window.get(byId: pending.targetWindowId), target.nodeWorkspace?.isVisible == true
    {
        pending.attemptsLeft -= 1
        pendingRedirect = pending
        return target
    }
    pendingRedirect = nil

    // App was already frontmost. Either a deliberate within-app switch (cmd-`, Window menu) -> follow, or a
    // minimize/close bumped focus here -> keep the workspace you were on (behavior 5).
    guard isAppActivation else { return resolveBump(nativeFocused, pid) ?? nativeFocused }

    // Behavior 1: prefer an existing window of this app on a visible workspace. Redirect, move nothing.
    if let target = mostRecentWindowOnVisibleWorkspace(ofApp: pid) {
        pendingRedirect = PendingRedirect(sourcePid: pid, targetPid: pid, targetWindowId: target.windowId, attemptsLeft: 3)
        return target
    }

    // Behavior 3: no visible window, but this app is opted in to "come to me". Bind its window into the
    // focused workspace and let the tail focusWindow() it. Same window macOS already focused => no fight,
    // no pendingRedirect needed. Runs before layoutWorkspaces() (refresh.swift) => no flash.
    if isSummonApp(nativeFocused.app.rawAppBundleId) {
        let here = focus.workspace
        // Mirrors moveWindowToWorkspace (MoveNodeToWorkspaceCommand.swift): floating binds straight to the
        // workspace (layout untouched); tiled binds to the root tiling container (re-tiles -- hence opt-in).
        let container: NonLeafTreeNodeObject = nativeFocused.isFloating ? here : here.rootTilingContainer
        nativeFocused.bind(to: container, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
        return nativeFocused
    }

    // Behavior 2: no visible window, not opted in => following is correct and desirable.
    return nativeFocused
}

@MainActor
private func mostRecentWindowOnVisibleWorkspace(ofApp pid: Int32) -> Window? {
    let focused = focus.workspace
    // focus.workspace is not *guaranteed* visible: setFocus propagates setActiveWorkspace's Bool, which can
    // be false. So check rather than assume.
    var candidates: [Workspace] = focused.isVisible ? [focused] : []
    candidates += Workspace.all.filter { $0.isVisible && $0 != focused } // Workspace.all is sorted => stable
    for workspace in candidates {
        if let window = workspace.mostRecentWindowRecursive(where: { $0.app.pid == pid }) { return window }
    }
    return nil
}

/// Behavior 4 wrapper. The focused window was nil, so the pid must come from the frontmost app rather than
/// from a window. Gated on app activation (same pid semantics as resolveFocusPreferringVisibleWorkspace) so
/// unrelated nil-focus refreshes don't spuriously un-minimize. Keeps lastKnownFrontmostAppPid coherent.
@MainActor
private func restoreMinimizedWindowOnActivation() {
    guard let frontmost = NSWorkspace.shared.frontmostApplication else { return }
    let pid = frontmost.processIdentifier
    let isAppActivation = pid != lastKnownFrontmostAppPid
    lastKnownFrontmostAppPid = pid
    guard isAppActivation else { return }
    restoreMostRecentMinimizedWindow(ofApp: pid)
}

/// Un-minimize the app's most-recently-minimized window. macOS then restores it, and the native
/// normalizeLayoutReason path binds it to focus.workspace. `internal` so behavior 4 is unit-testable
/// without going through NSWorkspace (which reports the test runner, not TestApp).
@MainActor
func restoreMostRecentMinimizedWindow(ofApp pid: Int32) {
    macosMinimizedWindowsContainer.mruChildren
        .compactMap { $0 as? Window }
        .first { $0.app.pid == pid }?
        .setNativeMinimized(false)
}

@MainActor private var summonApps: (mtime: Date, ids: Set<String>)? = nil

/// Apps that should be summoned to the focused workspace on activation instead of followed to their own
/// workspace. Read from $XDG_CONFIG_HOME/aerospace/summon-apps.txt (one bundle id per line, `#` comments),
/// lazily, refreshed only when the file's mtime changes.
@MainActor private func isSummonApp(_ bundleId: String?) -> Bool {
    guard let bundleId else { return false }
    if let override = summonAppsOverrideForTests { return override.contains(bundleId) }
    let dir = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].map(URL.init(fileURLWithPath:))
        ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config")
    let url = dir.appending(path: "aerospace/summon-apps.txt")
    let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
    if summonApps?.mtime != mtime { // file changed (or vanished) since last read
        let ids = (try? String(contentsOf: url, encoding: .utf8)).map { text in
            Set(text.split(whereSeparator: \.isNewline)
                .map { (line: Substring) in line.prefix { $0 != "#" }.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty })
        } ?? []
        summonApps = (mtime ?? .distantPast, ids)
    }
    return summonApps?.ids.contains(bundleId) ?? false
}
