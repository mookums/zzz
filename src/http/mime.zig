const std = @import("std");
const assert = std.debug.assert;

/// HTTP MIME Types.
/// TODO: Extend this to add in all of the "common" MIME types.
/// https://developer.mozilla.org/en-US/docs/Web/HTTP/Basics_of_HTTP/MIME_types/Common_types
pub const Mime = struct {
    content_type: []const u8,
    extension: []const u8,
    description: []const u8,

    pub const AAC = Mime{
        .content_type = "audio/acc",
        .extension = ".acc",
        .description = "AAC Audio",
    };

    pub const APNG = Mime{
        .content_type = "image/apng",
        .extension = ".apng",
        .description = "Animated Portable Network Graphics (APNG) Image",
    };

    pub const AVI = Mime{
        .content_type = "video/x-msvideo",
        .extension = ".avi",
        .description = "AVI: Audio Video Interleave",
    };

    pub const AVIF = Mime{
        .content_type = "image/avif",
        .extension = ".avif",
        .description = "AVIF Image",
    };

    pub const BIN = Mime{
        .content_type = "application/octet-stream",
        .extension = ".bin",
        .description = "Any kind of binary data",
    };

    pub const CSS = Mime{
        .content_type = "text/css",
        .extension = ".css",
        .description = "Cascading Style Sheets (CSS)",
    };

    pub const HTML = Mime{
        .content_type = "text/html",
        .extension = ".html",
        .description = "HyperText Markup Language (HTML)",
    };

    pub const ICO = Mime{
        .content_type = "image/vnd.microsoft.icon",
        .extension = ".ico",
        .description = "Icon Format",
    };

    pub const JS = Mime{
        .content_type = "text/javascript",
        .extension = ".js",
        .description = "JavaScript",
    };

    pub const JSON = Mime{
        .content_type = "application/json",
        .extension = ".json",
        .description = "JSON Format",
    };

    pub const PDF = Mime{
        .content_type = "application/pdf",
        .extension = ".pdf",
        .description = "Adobe Portable Document Format",
    };

    /// This turn an extension into a unsigned 64 bit number
    /// to be used as a key for quickly matching extensions
    /// with their MIME type.
    ///
    /// We are making an assumption here that users will not
    /// use an extension that is longer than 8 characters.
    ///
    /// If we need one more character, it might be worth
    /// omitting the dot at the start since it is the same
    /// amongst all of them.
    fn extension_to_key(extension: []const u8) u64 {
        assert(extension.len > 0);
        assert(extension.len <= 8);

        // Here, we just pad the extension, ensuring
        // that it will be able to get cast into a u64.
        var buffer = [1]u8{0} ** 8;
        for (0..extension.len) |i| {
            buffer[i] = extension[i];
        }

        return std.mem.readPackedIntNative(u64, buffer[0..], 0);
    }

    fn content_type_to_key(content_type: []const u8) u64 {
        // Our p needs to be larger than the cardinality of our input set.
        // Our input set includes 26 lowercase letters, 10 digits and
        // 2 symbols ('.' and '-').
        const p = 43;
        // https://planetmath.org/goodhashtableprimes
        const m = 25165843;
        var hash: u64 = 0;

        // Polynomial Rolling Hash.
        var p_power: u64 = 1;
        for (content_type) |byte| {
            hash = @mod(hash + byte * p_power, m);
            p_power = @mod(p_power * p, m);
        }

        return hash;
    }

    pub fn from_extension(extension: []const u8) Mime {
        assert(extension.len > 0);
        assert(extension.len <= 8);

        return switch (extension_to_key(extension)) {
            extension_to_key(Mime.AAC.extension) => Mime.AAC,
            extension_to_key(Mime.APNG.extension) => Mime.APNG,
            extension_to_key(Mime.AVI.extension) => Mime.AVI,
            extension_to_key(Mime.AVIF.extension) => Mime.AVIF,
            extension_to_key(Mime.BIN.extension) => Mime.BIN,
            extension_to_key(Mime.CSS.extension) => Mime.CSS,
            extension_to_key(Mime.HTML.extension), extension_to_key(".htm") => Mime.HTML,
            extension_to_key(Mime.ICO.extension) => Mime.ICO,
            extension_to_key(Mime.JS.extension) => Mime.JS,
            extension_to_key(Mime.JSON.extension) => Mime.JSON,
            extension_to_key(Mime.PDF.extension) => Mime.PDF,

            // If it is not a supported MIME type, send it as an octet-stream.
            // https://developer.mozilla.org/en-US/docs/Web/HTTP/Basics_of_HTTP/MIME_types/Common_types
            else => Mime{
                .extension = extension,
                .content_type = "application/octet-stream",
                .description = "Unknown File Type",
            },
        };
    }

    pub fn from_content_type(content_type: []const u8) Mime {
        return switch (content_type_to_key(content_type)) {
            content_type_to_key(Mime.AAC.content_type) => Mime.AAC,
            content_type_to_key(Mime.APNG.content_type) => Mime.APNG,
            content_type_to_key(Mime.AVI.content_type) => Mime.AVI,
            content_type_to_key(Mime.AVIF.content_type) => Mime.AVIF,
            content_type_to_key(Mime.BIN.content_type) => Mime.BIN,
            content_type_to_key(Mime.CSS.content_type) => Mime.CSS,
            content_type_to_key(Mime.HTML.content_type) => Mime.HTML,
            content_type_to_key(Mime.ICO.content_type) => Mime.ICO,
            content_type_to_key(Mime.JS.content_type) => Mime.JS,
            content_type_to_key(Mime.JSON.content_type) => Mime.JSON,
            content_type_to_key(Mime.PDF.content_type) => Mime.PDF,

            // If it is not a supported MIME type, we use the bin extension.
            else => Mime{
                .extension = ".bin",
                .content_type = content_type,
                .description = "Unknown File Type",
            },
        };
    }
};

const testing = std.testing;

const all_mimes = [_]Mime{
    Mime.AAC,
    Mime.APNG,
    Mime.AVI,
    Mime.AVIF,
    Mime.BIN,
    Mime.CSS,
    Mime.HTML,
    Mime.ICO,
    Mime.JS,
    Mime.JSON,
    Mime.PDF,
};

test "MIME from extensions" {
    for (all_mimes) |mime| {
        //std.debug.print("Mime: {s}\n", .{mime.description});
        try testing.expectEqual(mime, Mime.from_extension(mime.extension));
    }
}

test "MIME from unknown extension" {
    const extension = ".whatami";
    const mime = Mime.from_extension(extension);
    try testing.expectEqualStrings(extension, mime.extension);
    try testing.expectEqualStrings("application/octet-stream", mime.content_type);
}

test "MIME from content types" {
    for (all_mimes) |mime| {
        try testing.expectEqual(mime, Mime.from_content_type(mime.content_type));
    }
}

test "MIME from unknown content type" {
    const content_type = "application/whatami";
    const mime = Mime.from_content_type(content_type);
    try testing.expectEqualStrings(".bin", mime.extension);
    try testing.expectEqualStrings(content_type, mime.content_type);
}
