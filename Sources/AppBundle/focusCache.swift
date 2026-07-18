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
    let pid: Int32
    let targetWindowId: UInt32
    var attemptsLeft: Int
}

/// Reset every process-global this file owns. Called from setUpWorkspacesForTests so test order can't leak
/// state (these globals persist across tests otherwise).
@MainActor func resetFocusCacheForTests() {
    lastKnownNativeFocusedWindowId = nil
    lastKnownFrontmostAppPid = nil
    pendingRedirect = nil
    summonAppsOverrideForTests = nil
    summonApps = nil
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
    // through to "follow macOS" while pending -- that would undo our own redirect one session later.
    if var pending = pendingRedirect, pending.pid == pid, pending.attemptsLeft > 0,
       let target = Window.get(byId: pending.targetWindowId), target.nodeWorkspace?.isVisible == true
    {
        pending.attemptsLeft -= 1
        pendingRedirect = pending
        return target
    }
    pendingRedirect = nil

    // App was already frontmost => user deliberately switched windows *within* the app (cmd-`, Window menu,
    // clicking a corner-parked window). Honor it.
    guard isAppActivation else { return nativeFocused }

    // Behavior 1: prefer an existing window of this app on a visible workspace. Redirect, move nothing.
    if let target = mostRecentWindowOnVisibleWorkspace(ofApp: pid) {
        pendingRedirect = PendingRedirect(pid: pid, targetWindowId: target.windowId, attemptsLeft: 3)
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
