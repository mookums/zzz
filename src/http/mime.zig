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

    pub const AVIF = Mime{
        .content_type = "image/avif",
        .extension = ".avif",
        .description = "AVIF Image",
    };

    pub const AVI = Mime{
        .content_type = "video/x-msvideo",
        .extension = ".avi",
        .description = "AVI: Audio Video Interleave",
    };

    pub const BIN = Mime{
        .content_type = "application/octet-stream",
        .extension = ".bin",
        .description = "Any kind of binary data",
    };

    pub const BMP = Mime{
        .content_type = "image/bmp",
        .extension = ".bmp",
        .description = "Windows OS/2 Bitmap Graphics",
    };

    pub const CSS = Mime{
        .content_type = "text/css",
        .extension = ".css",
        .description = "Cascading Style Sheets (CSS)",
    };

    pub const CSV = Mime{
        .content_type = "text/csv",
        .extension = ".csv",
        .description = "Comma-seperated values (CSV)",
    };

    pub const GZ = Mime{
        .content_type = "application/gzip",
        .extension = ".gz",
        .description = "GZip Compressed Archive",
    };

    pub const GIF = Mime{
        .content_type = "image/gif",
        .extension = ".gif",
        .description = "Graphics Interchange Format (GIF)",
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

    pub const JPEG = Mime{
        .content_type = "image/jpeg",
        .extension = ".jpg",
        .description = "JPEG Image",
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

    pub const MP3 = Mime{
        .content_type = "audio/mpeg",
        .extension = ".mp3",
        .description = "MP3 audio",
    };

    pub const MP4 = Mime{
        .content_type = "video/mp4",
        .extension = ".mp4",
        .description = "MP4 Video",
    };

    pub const PNG = Mime{
        .content_type = "image/png",
        .extension = ".png",
        .description = "Portable Network Graphics",
    };

    pub const PDF = Mime{
        .content_type = "application/pdf",
        .extension = ".pdf",
        .description = "Adobe Portable Document Format",
    };

    pub const SH = Mime{
        .content_type = "application/x-sh",
        .extension = ".sh",
        .description = "Bourne shell script",
    };

    pub const SVG = Mime{
        .content_type = "image/svg+xml",
        .extension = ".svg",
        .description = "Scalable Vector Graphics (SVG)",
    };

    pub const TAR = Mime{
        .content_type = "application/x-tar",
        .extension = ".tar",
        .description = "Tape Archive (TAR)",
    };

    pub const TTF = Mime{
        .content_type = "font/ttf",
        .extension = ".ttf",
        .description = "TrueType Font",
    };

    pub const TEXT = Mime{
        .content_type = "text/plain",
        .extension = ".txt",
        .description = "Text (generally ASCII or ISO-8859-n)",
    };

    pub const WAV = Mime{
        .content_type = "audio/wav",
        .extension = ".wav",
        .description = "Waveform Audio Format",
    };

    pub const WEBM = Mime{
        .content_type = "video/webm",
        .extension = ".webm",
        .description = "WEBM Video",
    };

    pub const WEBP = Mime{
        .content_type = "image/webp",
        .extension = ".webp",
        .description = "WEBP Image",
    };

    pub const WOFF = Mime{
        .content_type = "font/woff",
        .extension = ".woff",
        .description = "Web Open Font Format (WOFF)",
    };

    pub const XML = Mime{
        .content_type = "application/xml",
        .extension = ".xml",
        .description = "XML",
    };

    pub const ZIP = Mime{
        .content_type = "application/zip",
        .extension = ".zip",
        .description = "ZIP Archive",
    };

    pub const @"7Z" = Mime{
        .content_type = "application/x-7z-compressed",
        .extension = ".7z",
        .description = "7-zip archive",
    };

    fn extension_to_key(extension: []const u8) u64 {
        assert(extension.len > 0);
        const hash = std.hash.Wyhash.hash(0, extension);
        return hash;
    }

    fn content_type_to_key(content_type: []const u8) u64 {
        assert(content_type.len > 0);
        const hash = std.hash.Wyhash.hash(0, content_type);
        return hash;
    }

    pub fn from_extension(extension: []const u8) Mime {
        assert(extension.len > 0);

        const extension_key = extension_to_key(extension);
        inline for (all_mime_types) |mime| {
            const mime_extension_key = comptime extension_to_key(mime.extension);
            if (extension_key == mime_extension_key) return mime;
        }

        return Mime{
            .extension = extension,
            .content_type = "application/octet-stream",
            .description = "Unknown File Type",
        };
    }

    pub fn from_content_type(content_type: []const u8) Mime {
        assert(content_type.len > 0);

        const content_type_key = content_type_to_key(content_type);
        inline for (all_mime_types) |mime| {
            const mime_content_type_key = comptime content_type_to_key(mime.content_type);
            if (content_type_key == mime_content_type_key) return mime;
        }

        return Mime{
            .extension = ".bin",
            .content_type = content_type,
            .description = "Unknown File Type",
        };
    }
};

const all_mime_types = blk: {
    const decls = @typeInfo(Mime).Struct.decls;
    var mimes: [decls.len]Mime = undefined;
    var index: usize = 0;
    for (decls) |decl| {
        if (@TypeOf(@field(Mime, decl.name)) == Mime) {
            mimes[index] = @field(Mime, decl.name);
            index += 1;
        }
    }

    var return_mimes: [index]Mime = undefined;
    for (0..index) |i| {
        return_mimes[i] = mimes[i];
    }

    break :blk return_mimes;
};

const testing = std.testing;

test "MIME from extensions" {
    for (all_mime_types) |mime| {
        try testing.expectEqualStrings(mime.description, Mime.from_extension(mime.extension).description);
    }
}

test "MIME from unknown extension" {
    const extension = ".whatami";
    const mime = Mime.from_extension(extension);
    try testing.expectEqualStrings(extension, mime.extension);
    try testing.expectEqualStrings("application/octet-stream", mime.content_type);
}

test "MIME from content types" {
    for (all_mime_types) |mime| {
        try testing.expectEqualStrings(mime.description, Mime.from_content_type(mime.content_type).description);
    }
}

test "MIME from unknown content type" {
    const content_type = "application/whatami";
    const mime = Mime.from_content_type(content_type);
    try testing.expectEqualStrings(".bin", mime.extension);
    try testing.expectEqualStrings(content_type, mime.content_type);
}
