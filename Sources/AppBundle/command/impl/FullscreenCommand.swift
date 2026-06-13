import AppKit
import Common

struct FullscreenCommand: Command {
    let args: FullscreenCmdArgs
    /*conforms*/ var shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) -> Bool {
        guard let target = args.resolveTargetOrReportError(env, io) else { return false }
        guard let window = target.windowOrNil else {
            return io.err(noWindowIsFocused)
        }
        let newState: Bool = switch args.toggle {
            case .on: true
            case .off: false
            case .toggle: !window.isFullscreen
        }
        if newState == window.isFullscreen {
            // FocusTile patch: already in the target state — but if we're (still) fullscreen and a
            // NEW --frame was given, update the frame instead of no-op'ing. The unconditional
            // layoutWorkspaces() after every command then re-applies it. Without this, nudging the
            // zoom frame (re-issuing `fullscreen on --frame`) would silently do nothing.
            if newState, let f = args.frame, window.fullscreenFrame != f {
                window.fullscreenFrame = f
                window.markAsMostRecentChild()
                return true
            }
            io.err((newState ? "Already fullscreen. " : "Already not fullscreen. ") +
                "Tip: use --fail-if-noop to exit with non-zero code")
            return !args.failIfNoop
        }
        window.isFullscreen = newState
        window.noOuterGapsInFullscreen = args.noOuterGaps
        window.fullscreenFrame = args.frame // FocusTile patch: nil unless --frame given

        // Focus on its own workspace
        window.markAsMostRecentChild()
        return true
    }
}

let noWindowIsFocused = "No window is focused"
