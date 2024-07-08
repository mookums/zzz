const std = @import("std");
const assert = std.debug.assert;

/// TODO: Extend this to add in all of the "common" MIME types.
/// https://developer.mozilla.org/en-US/docs/Web/HTTP/Basics_of_HTTP/MIME_types/Common_types
const Mime = struct {
    content_type: []const u8,
    extension: []const u8,
    description: []const u8,

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

    pub fn from_extension(extension: []const u8) Mime {
        assert(extension.len > 0);
        assert(extension.len <= 8);

        return switch (extension_to_key(extension)) {
            extension_to_key(".aac") => AAC,
            extension_to_key(".apng") => APNG,
            extension_to_key(".avi") => AVI,
            extension_to_key(".avif") => AVIF,
            extension_to_key(".bin") => BIN,
            extension_to_key(".css") => CSS,
            extension_to_key(".htm"), extension_to_key(".html") => HTML,
            extension_to_key(".js") => JS,
            extension_to_key(".json") => JSON,

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
        // This is slightly more challenging to do quickly.
        //
        // Consider using polynominal rolling hash as the comparison method?
        // This could be effective as long as we calculate the hashes we are
        // matching against at compile time!
        //
        // hash(string) = ( s[0] * p^0 + s[1] * p^1 * s[2] * p^2 ... + s[n-1] * p^(n-1) ) mod p
        // where p is a prime number larger than our alphabet.
        _ = content_type;
        @panic("TODO!");
    }
};

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

const testing = std.testing;

test "MIME from extensions" {
    const extensions = [_][]const u8{ ".bin", ".html", ".js", ".json", ".htm" };
    const mimes = [_]Mime{ BIN, HTML, JS, JSON, HTML };

    for (extensions, mimes) |extension, mime| {
        try testing.expectEqual(mime, Mime.from_extension(extension));
    }
}

test "MIME from unknown extension" {
    const extension = ".whatami";
    const mime = Mime.from_extension(extension);
    try testing.expectEqualStrings(extension, mime.extension);
    try testing.expectEqualStrings("application/octet-stream", mime.content_type);
}
