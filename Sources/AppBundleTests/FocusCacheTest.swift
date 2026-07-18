@testable import AppBundle
import Common
import XCTest

@MainActor
final class FocusCacheTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    // Behavior 1: macOS activates the app onto a hidden-workspace window, but the app also has a window on a
    // visible workspace => redirect to the visible one, don't get yanked to the hidden workspace.
    func testPrefersVisibleWorkspaceWindowOnAppActivation() {
        let visible = focus.workspace
        let hidden = Workspace.get(byName: "hidden-\(name)")
        TestWindow.new(id: 1, parent: hidden.rootTilingContainer)
        TestWindow.new(id: 2, parent: visible.rootTilingContainer)
        assertEquals(visible.isVisible, true)
        assertEquals(hidden.isVisible, false)
        lastKnownFrontmostAppPid = nil // arm "app activation"

        updateFocusCache(Window.get(byId: 1)) // macOS: "the app focused its hidden-ws window"

        assertEquals(focus.windowOrNil?.windowId, 2) // did NOT follow
        assertEquals(focus.workspace, visible)
        assertEquals(hidden.isVisible, false) // no yank
        assertEquals(TestApp.shared.focusedWindow?.windowId, 2) // redirect was pushed to "macOS"
    }

    // Behavior 2: the app has no window on any visible workspace => following to the hidden one is correct.
    func testFollowsWhenAppHasNoWindowOnAnyVisibleWorkspace() {
        let hidden = Workspace.get(byName: "hidden-\(name)")
        let w1 = TestWindow.new(id: 1, parent: hidden.rootTilingContainer)
        lastKnownFrontmostAppPid = nil

        updateFocusCache(w1)

        assertEquals(focus.windowOrNil?.windowId, 1) // fallback: follow, as today
        assertEquals(focus.workspace, hidden)
    }

    // Behavior 3: an opted-in app with no visible window => bring its window to the focused workspace.
    func testSummonsListedAppWindowToFocusedWorkspace() {
        let visible = focus.workspace
        let hidden = Workspace.get(byName: "hidden-\(name)")
        let w1 = TestWindow.new(id: 1, parent: hidden.rootTilingContainer)
        summonAppsOverrideForTests = [TestApp.shared.rawAppBundleId!]
        lastKnownFrontmostAppPid = nil

        updateFocusCache(w1)

        assertEquals(w1.nodeWorkspace, visible) // window came to us
        assertEquals(hidden.allLeafWindowsRecursive.count, 0) // and left the hidden workspace
        assertEquals(focus.workspace, visible) // we did not travel
        assertEquals(focus.windowOrNil?.windowId, 1)
    }

    // The pid gate: when the app was already frontmost (in-app window switch, e.g. cmd-`), honor macOS and
    // follow even into a hidden workspace. Guards against fighting a deliberate within-app switch.
    func testDoesNotRedirectWhenAppWasAlreadyFrontmost() {
        let visible = focus.workspace
        let hidden = Workspace.get(byName: "hidden-\(name)")
        let w2 = TestWindow.new(id: 2, parent: visible.rootTilingContainer)
        let w1 = TestWindow.new(id: 1, parent: hidden.rootTilingContainer)
        lastKnownFrontmostAppPid = nil

        updateFocusCache(w2)                 // activation lands on the visible window; arms the gate (pid 0)
        assertEquals(focus.workspace, visible)

        updateFocusCache(w1)                 // same app, now points at a hidden window => in-app switch

        assertEquals(focus.windowOrNil?.windowId, 1) // followed
        assertEquals(focus.workspace, hidden)
    }

    // Behavior 1 refinement: among several of the app's windows on the visible workspace, pick the MRU one.
    func testPicksMruWindowAmongSeveralOnTheVisibleWorkspace() {
        let visible = focus.workspace
        let hidden = Workspace.get(byName: "hidden-\(name)")
        var w2: Window!
        var w3: Window!
        visible.rootTilingContainer.apply {
            w2 = TestWindow.new(id: 2, parent: $0)
            w3 = TestWindow.new(id: 3, parent: $0)
        }
        TestWindow.new(id: 1, parent: hidden.rootTilingContainer)
        _ = w3 // silence unused; w3 is the latest-bound, so w2 must be explicitly promoted
        w2.markAsMostRecentChild()
        lastKnownFrontmostAppPid = nil

        updateFocusCache(Window.get(byId: 1))

        assertEquals(focus.windowOrNil?.windowId, 2) // the MRU window, not merely the last-bound (3)
    }

    // Pure-tree: the filtered, backtracking recursive accessor added in TreeNodeEx.
    func testMostRecentWindowRecursiveWherePredicate() {
        let ws = focus.workspace
        var target: Window!
        var other: Window!
        ws.rootTilingContainer.apply {
            other = TestWindow.new(id: 7, parent: $0)
            target = TestWindow.new(id: 8, parent: $0)
        }
        assertEquals(ws.mostRecentWindowRecursive(where: { $0.windowId == 7 })?.windowId, 7) // backtracks off MRU (8)
        assertEquals(ws.mostRecentWindowRecursive(where: { $0.windowId == 999 }), nil)
        _ = (target, other)
    }

    // Behavior 4: app's only window is minimized => un-minimize it (the native restore path then lands it on
    // the focused workspace). Driven directly, since NSWorkspace.frontmostApplication reports the test runner.
    func testRestoreMostRecentMinimizedWindowUnminimizesIt() {
        let w = TestWindow.new(id: 1, parent: macosMinimizedWindowsContainer)
        assertEquals(w.lastSetNativeMinimized, nil)

        restoreMostRecentMinimizedWindow(ofApp: TestApp.shared.pid)

        assertEquals(w.lastSetNativeMinimized, false) // un-minimize requested
    }

    // Behavior 4 picks the most-recently-minimized window when several are minimized.
    func testRestorePicksMostRecentMinimized() {
        let w1 = TestWindow.new(id: 1, parent: macosMinimizedWindowsContainer)
        let w2 = TestWindow.new(id: 2, parent: macosMinimizedWindowsContainer) // bound later => MRU

        restoreMostRecentMinimizedWindow(ofApp: TestApp.shared.pid)

        assertEquals(w2.lastSetNativeMinimized, false)
        assertEquals(w1.lastSetNativeMinimized, nil)
    }

    // No minimized windows for the app => no-op (app with zero windows).
    func testRestoreNoMinimizedWindowsIsNoop() {
        restoreMostRecentMinimizedWindow(ofApp: TestApp.shared.pid) // container empty; must not crash
    }

    // Behavior 4 must NOT fire when the app has a non-minimized focused window (the Chrome case): macOS hands
    // updateFocusCache a real window, so the nil branch is never taken and the minimized one is left alone.
    func testDoesNotRestoreWhenAppHasNonMinimizedFocusedWindow() {
        let visible = focus.workspace
        let minimized = TestWindow.new(id: 1, parent: macosMinimizedWindowsContainer)
        let w2 = TestWindow.new(id: 2, parent: visible.rootTilingContainer)
        lastKnownFrontmostAppPid = nil

        updateFocusCache(w2) // non-nil focused window => nil branch not taken

        assertEquals(minimized.lastSetNativeMinimized, nil) // behavior 4 did not fire
        assertEquals(focus.windowOrNil?.windowId, 2)
    }

    // Behavior 5 (Phase B): a minimize bump keeps focus on the workspace you were on instead of
    // following macOS to the hidden-workspace window it picked. (Same-app-vs-cross-app *preference*
    // needs a second test app -- validated live; here every TestWindow shares TestApp, so this
    // exercises the "window on `here`" redirect via the same-app branch.)
    func testBumpKeepsFocusOnBumpWorkspace() {
        let visible = focus.workspace
        let hidden = Workspace.get(byName: "hidden-\(name)")
        let willMinimize = TestWindow.new(id: 2, parent: visible.rootTilingContainer)
        _ = TestWindow.new(id: 5, parent: visible.rootTilingContainer) // survivor on `here`
        let bumpedTo = TestWindow.new(id: 1, parent: hidden.rootTilingContainer)

        updateFocusCache(willMinimize)
        assertEquals(focus.windowOrNil?.windowId, 2)

        // simulate the minimize: id 2 leaves the workspace tree; a bump is recorded for `visible`
        willMinimize.bind(to: macosMinimizedWindowsContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        recentBumps = [BumpEvent(windowId: 2, workspaceName: visible.name, ttlRefreshes: 2)]

        updateFocusCache(bumpedTo) // macOS moved focus to hidden id 1

        assertEquals(focus.windowOrNil?.windowId, 5) // redirected to the survivor on `here`, not id 1
        assertEquals(focus.workspace, visible)       // stayed put
        assertEquals(recentBumps.count, 0)           // consumed
    }

    // A non-activation switch with NO bump (a deliberate cmd-`/click) still travels, unchanged.
    func testNoBumpNonActivationStillTravels() {
        let visible = focus.workspace
        let hidden = Workspace.get(byName: "hidden-\(name)")
        _ = TestWindow.new(id: 2, parent: visible.rootTilingContainer)
        let w1 = TestWindow.new(id: 1, parent: hidden.rootTilingContainer)

        updateFocusCache(TestWindow.new(id: 3, parent: visible.rootTilingContainer)) // activation
        updateFocusCache(w1) // non-activation, no bump => deliberate switch => follow

        assertEquals(focus.windowOrNil?.windowId, 1)
        assertEquals(focus.workspace, hidden)
    }

    // Empty bump workspace => nothing to keep focus on => allow the follow (deferred case). Bump still consumed.
    func testEmptyBumpWorkspaceAllowsFollow() {
        let visible = focus.workspace
        let hidden = Workspace.get(byName: "hidden-\(name)")
        let empty = Workspace.get(byName: "empty-\(name)")
        _ = TestWindow.new(id: 2, parent: visible.rootTilingContainer)
        let w1 = TestWindow.new(id: 1, parent: hidden.rootTilingContainer)

        updateFocusCache(TestWindow.new(id: 3, parent: visible.rootTilingContainer))
        recentBumps = [BumpEvent(windowId: 9, workspaceName: empty.name, ttlRefreshes: 2)]
        updateFocusCache(w1) // here (empty) has no window => follow

        assertEquals(focus.windowOrNil?.windowId, 1)
        assertEquals(focus.workspace, hidden)
        assertEquals(recentBumps.count, 0) // consumed even though we followed
    }

    // Behavior 5: bump records age out by TTL when never consumed (e.g. focus went to a visible window).
    func testBumpRecordsAgeOutByTtl() {
        let w = TestWindow.new(id: 1, parent: focus.workspace.rootTilingContainer)
        recentBumps = [BumpEvent(windowId: 9, workspaceName: focus.workspace.name, ttlRefreshes: 2)]

        updateFocusCache(w) // 2 -> 1
        assertEquals(recentBumps.count, 1)
        updateFocusCache(w) // 1 -> 0, dropped
        assertEquals(recentBumps.count, 0)
    }
}
