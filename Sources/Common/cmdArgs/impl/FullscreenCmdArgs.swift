import Foundation

public struct FullscreenCmdArgs: CmdArgs {
    public let rawArgsForStrRepr: EquatableNoop<StrArrSlice>
    fileprivate init(rawArgs: StrArrSlice) { self.rawArgsForStrRepr = .init(rawArgs) }
    public static let parser: CmdParser<Self> = cmdParser(
        kind: .fullscreen,
        allowInConfig: true,
        help: fullscreen_help_generated,
        flags: [
            "--no-outer-gaps": trueBoolFlag(\.noOuterGaps),
            "--frame": singleValueSubArgParser(\.frame, "<x,y,w,h>", FractionRect.parse),
            "--fail-if-noop": trueBoolFlag(\.failIfNoop),
            "--window-id": optionalWindowIdFlag(),
        ],
        posArgs: [ArgParser(\.toggle, parseToggleEnum)],
    )

    public var toggle: ToggleEnum = .toggle
    public var noOuterGaps: Bool = false
    public var frame: FractionRect? = nil
    public var failIfNoop: Bool = false
    /*conforms*/ public var windowId: UInt32?
    /*conforms*/ public var workspaceName: WorkspaceName?
}

/// FocusTile patch: a rectangle expressed as fractions (0-1) of the monitor's visible frame.
/// Used by `fullscreen --frame x,y,w,h` to hold the window at an arbitrary captured frame
/// while it stays in the tiling tree (neighbors never move).
public struct FractionRect: Sendable, Equatable {
    public let x: Double
    public let y: Double
    public let w: Double
    public let h: Double

    public static func parse(_ raw: String) -> FractionRect? {
        let parts = raw.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 4, let x = parts[0], let y = parts[1], let w = parts[2], let h = parts[3] else { return nil }
        guard (0.0 ... 1.0).contains(x), (0.0 ... 1.0).contains(y), w > 0, h > 0, x + w <= 1.001, y + h <= 1.001 else { return nil }
        return FractionRect(x: x, y: y, w: w, h: h)
    }
}

public func parseFullscreenCmdArgs(_ args: StrArrSlice) -> ParsedCmd<FullscreenCmdArgs> {
    parseSpecificCmdArgs(FullscreenCmdArgs(rawArgs: args), args)
        .filterNot("--no-outer-gaps is incompatible with 'off' argument") { $0.toggle == .off && $0.noOuterGaps }
        .filterNot("--frame is incompatible with 'off' argument") { $0.toggle == .off && $0.frame != nil }
        .filterNot("--frame is incompatible with --no-outer-gaps") { $0.noOuterGaps && $0.frame != nil }
        .filter("--fail-if-noop requires 'on' or 'off' argument") { $0.failIfNoop.implies($0.toggle == .on || $0.toggle == .off) }
}
