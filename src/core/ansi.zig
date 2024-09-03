const std = @import("std");

const ANSI_ESCAPE_FMT = "\x1B[{d}m";

// https://en.wikipedia.org/wiki/ANSI_escape_code#SGR_(Select_Graphic_Rendition)_parameters
pub const Effect = struct {
    const Off = std.fmt.comptimePrint(ANSI_ESCAPE_FMT, .{0});
    const Bold = std.fmt.comptimePrint(ANSI_ESCAPE_FMT, .{1});
    /// Not widely supported.
    const Faint = std.fmt.comptimePrint(ANSI_ESCAPE_FMT, .{2});
    /// Not widely supported. Treated as inverse sometimes.
    const Italic = std.fmt.comptimePrint(ANSI_ESCAPE_FMT, .{3});
    const Underline = std.fmt.comptimePrint(ANSI_ESCAPE_FMT, .{4});
    const SlowBlink = std.fmt.comptimePrint(ANSI_ESCAPE_FMT, .{5});
    /// Not widely supported.
    const RapidBlink = std.fmt.comptimePrint(ANSI_ESCAPE_FMT, .{6});
    const Invert = std.fmt.comptimePrint(ANSI_ESCAPE_FMT, .{7});
    /// Not widely supported.
    const Conceal = std.fmt.comptimePrint(ANSI_ESCAPE_FMT, .{8});
    /// Not widely supported.
    const Strike = std.fmt.comptimePrint(ANSI_ESCAPE_FMT, .{9});
    const BoldOff = std.fmt.comptimePrint(ANSI_ESCAPE_FMT, .{21});
    const BoldFaintOff = std.fmt.comptimePrint(ANSI_ESCAPE_FMT, .{22});
    const ItalicOff = std.fmt.comptimePrint(ANSI_ESCAPE_FMT, .{23});
    const UnderlineOff = std.fmt.comptimePrint(ANSI_ESCAPE_FMT, .{24});
    const BlinkOff = std.fmt.comptimePrint(ANSI_ESCAPE_FMT, .{25});
    const InvertOff = std.fmt.comptimePrint(ANSI_ESCAPE_FMT, .{27});
    const Reveal = std.fmt.comptimePrint(ANSI_ESCAPE_FMT, .{28});
    const StrikeOff = std.fmt.comptimePrint(ANSI_ESCAPE_FMT, .{29});
    const Framed = std.fmt.comptimePrint(ANSI_ESCAPE_FMT, .{51});
    const Encircled = std.fmt.comptimePrint(ANSI_ESCAPE_FMT, .{52});
    const Overlined = std.fmt.comptimePrint(ANSI_ESCAPE_FMT, .{53});
    const FramedEncircledOff = std.fmt.comptimePrint(ANSI_ESCAPE_FMT, .{54});
    const OverlinedOff = std.fmt.comptimePrint(ANSI_ESCAPE_FMT, .{55});
};

pub const Color = struct {
    const Off = std.fmt.comptimePrint(ANSI_ESCAPE_FMT, .{0});
    const Black = std.fmt.comptimePrint(ANSI_ESCAPE_FMT, .{30});
    const Red = std.fmt.comptimePrint(ANSI_ESCAPE_FMT, .{31});
    const Green = std.fmt.comptimePrint(ANSI_ESCAPE_FMT, .{32});
    const Yellow = std.fmt.comptimePrint(ANSI_ESCAPE_FMT, .{33});
    const Blue = std.fmt.comptimePrint(ANSI_ESCAPE_FMT, .{34});
    const Magenta = std.fmt.comptimePrint(ANSI_ESCAPE_FMT, .{35});
    const Cyan = std.fmt.comptimePrint(ANSI_ESCAPE_FMT, .{36});
    const Gray = std.fmt.comptimePrint(ANSI_ESCAPE_FMT, .{37});
};

pub const BrightColor = struct {
    const Off = std.fmt.comptimePrint(ANSI_ESCAPE_FMT, .{39});
    const Gray = std.fmt.comptimePrint(ANSI_ESCAPE_FMT, .{90});
    const Red = std.fmt.comptimePrint(ANSI_ESCAPE_FMT, .{91});
    const Green = std.fmt.comptimePrint(ANSI_ESCAPE_FMT, .{92});
    const Yellow = std.fmt.comptimePrint(ANSI_ESCAPE_FMT, .{93});
    const Blue = std.fmt.comptimePrint(ANSI_ESCAPE_FMT, .{94});
    const Magenta = std.fmt.comptimePrint(ANSI_ESCAPE_FMT, .{95});
    const Cyan = std.fmt.comptimePrint(ANSI_ESCAPE_FMT, .{96});
    const White = std.fmt.comptimePrint(ANSI_ESCAPE_FMT, .{97});
};

pub const Bg = struct {
    const Off = std.fmt.comptimePrint(ANSI_ESCAPE_FMT, .{0});
    const Black = std.fmt.comptimePrint(ANSI_ESCAPE_FMT, .{40});
    const Red = std.fmt.comptimePrint(ANSI_ESCAPE_FMT, .{41});
    const Green = std.fmt.comptimePrint(ANSI_ESCAPE_FMT, .{42});
    const Yellow = std.fmt.comptimePrint(ANSI_ESCAPE_FMT, .{43});
    const Blue = std.fmt.comptimePrint(ANSI_ESCAPE_FMT, .{44});
    const Magenta = std.fmt.comptimePrint(ANSI_ESCAPE_FMT, .{45});
    const Cyan = std.fmt.comptimePrint(ANSI_ESCAPE_FMT, .{46});
    const Gray = std.fmt.comptimePrint(ANSI_ESCAPE_FMT, .{47});
};

pub const BrightBg = struct {
    const Off = std.fmt.comptimePrint(ANSI_ESCAPE_FMT, .{0});
    const Gray = std.fmt.comptimePrint(ANSI_ESCAPE_FMT, .{100});
    const Red = std.fmt.comptimePrint(ANSI_ESCAPE_FMT, .{101});
    const Green = std.fmt.comptimePrint(ANSI_ESCAPE_FMT, .{102});
    const Yellow = std.fmt.comptimePrint(ANSI_ESCAPE_FMT, .{103});
    const Blue = std.fmt.comptimePrint(ANSI_ESCAPE_FMT, .{104});
    const Magenta = std.fmt.comptimePrint(ANSI_ESCAPE_FMT, .{105});
    const Cyan = std.fmt.comptimePrint(ANSI_ESCAPE_FMT, .{106});
    const White = std.fmt.comptimePrint(ANSI_ESCAPE_FMT, .{107});
};

const testing = std.testing;

test "Misc ANSI" {
    std.debug.print(
        "{s}{s}THIS SHOULD BE BLUE{s} {s}HI{s} RED AND {s}NOW WITH A CYAN BACKGROUND{s}\n",
        .{ Color.Blue, Effect.Strike, Effect.StrikeOff, BrightColor.Yellow, Color.Red, Bg.Cyan, Effect.Off },
    );
}
