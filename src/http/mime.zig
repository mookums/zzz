const std = @import("std");
const assert = std.debug.assert;

const Pair = @import("../core/lib.zig").Pair;

const MimeOption = union(enum) {
    single: []const u8,
    /// The first one should be the priority one.
    /// The rest should just be there for compatibility reasons.
    multiple: []const []const u8,
};

fn generate_mime_helper(any: anytype) MimeOption {
    assert(@typeInfo(@TypeOf(any)) == .pointer);
    const ptr_info = @typeInfo(@TypeOf(any)).pointer;
    assert(ptr_info.is_const);

    switch (ptr_info.size) {
        else => unreachable,
        .one => {
            switch (@typeInfo(ptr_info.child)) {
                else => unreachable,
                .array => |arr_info| {
                    assert(arr_info.child == u8);
                    return MimeOption{ .single = any };
                },
                .@"struct" => |struct_info| {
                    for (struct_info.fields) |field| {
                        assert(@typeInfo(field.type) == .pointer);
                        const p_info = @typeInfo(field.type).pointer;
                        assert(@typeInfo(p_info.child) == .array);
                        const a_info = @typeInfo(p_info.child).array;
                        assert(a_info.child == u8);
                    }

                    return MimeOption{ .multiple = any };
                },
            }
        },
    }
}

/// MIME Types.
pub const Mime = struct {
    /// This is the actual MIME type.
    content_type: MimeOption,
    extension: MimeOption,
    description: []const u8,

    pub const AAC = generate("audio/acc", "acc", "AAC Audio");
    pub const APNG = generate("image/apng", "apng", "Animated Portable Network Graphics (APNG) Image");
    pub const AVIF = generate("image/avif", "avif", "AVIF Image");
    pub const AVI = generate("video/x-msvideo", "avi", "AVI: Audio Video Interleave");
    pub const AZW = generate("application/vnd.amazon.ebook", "azw", "AZW: Amazon Kindle eBook format");
    pub const BIN = generate("application/octet-stream", "bin", "Any kind of binary data");
    pub const BMP = generate("image/bmp", "bmp", "Windows OS/2 Bitmap Graphics");
    pub const BZ = generate("application/x-bzip", "bz", "BZip archive");
    pub const BZ2 = generate("application/x-bzip2", "bz2", "BZip2 archive");
    pub const CDA = generate("application/x-cdf", "cda", "CD audio");
    pub const CSS = generate("text/css", "css", "Cascading Style Sheets (CSS)");
    pub const CSV = generate("text/csv", "csv", "Comma-separated values (CSV)");
    pub const DOC = generate("application/msword", "doc", "Microsoft Word");
    pub const DOCX = generate(
        "application/vnd.openxlformats-officedocument.wordprocessingml.document",
        "docx",
        "Microsoft Word (OpenXML)",
    );
    pub const EPUB = generate("application/epub+zip", "epub", "Electronic Publication");
    pub const GIF = generate("image/gif", "gif", "Graphics Interchange Format (GIF)");
    pub const GZ = generate(&.{ "application/gzip", "application/x-gzip" }, "gz", "GZip Compressed Archive");
    pub const HTML = generate("text/html", &.{ "html", "htm" }, "HyperText Markup Language (HTML)");
    pub const ICO = generate(&.{ "image/x-icon", "image/vnd.microsoft.icon" }, "ico", "Icon Format");
    pub const ICS = generate("text/calander", "ics", "iCalendar format");
    pub const JAR = generate("application/java-archive", "jar", "Java Archive");
    pub const JPEG = generate("image/jpeg", &.{ "jpeg", "jpg" }, "JPEG Image");
    pub const JS = generate(&.{ "text/javascript", "application/javascript" }, "js", "JavaScript");
    pub const JSON = generate("application/json", "json", "JSON Format");
    pub const MP3 = generate("audio/mpeg", "mp3", "MP3 audio");
    pub const MP4 = generate("video/mp4", "mp4", "MP4 Video");
    pub const OGA = generate("audio/ogg", "ogg", "Ogg audio");
    pub const OGV = generate("video/ogg", "ogv", "Ogg video");
    pub const OGX = generate("application/ogg", "ogx", "Ogg multiplexed audo and video");
    pub const OTF = generate("font/otf", "otf", "OpenType font");
    pub const PDF = generate("application/pdf", "pdf", "Adobe Portable Document Format");
    pub const PHP = generate("application/x-httpd-php", "php", "Hypertext Preprocessor (Personal Home Page)");
    pub const PNG = generate("image/png", "png", "Portable Network Graphics");
    pub const RAR = generate("application/vnd.rar", "rar", "RAR archive");
    pub const RTF = generate("application/rtf", "rtf", "Rich Text Format (RTF)");
    pub const SH = generate("application/x-sh", "sh", "Bourne shell script");
    pub const SVG = generate("image/svg+xml", "svg", "Scalable Vector Graphics (SVG)");
    pub const TAR = generate("application/x-tar", "tar", "Tape Archive (TAR)");
    pub const TEXT = generate("text/plain", "txt", "Text (generally ASCII or ISO-8859-n)");
    pub const TSV = generate("text/tab-seperated-values", "tsv", "Tab-seperated values (TSV)");
    pub const TTF = generate("font/ttf", "ttf", "TrueType Font");
    pub const WAV = generate("audio/wav", "wav", "Waveform Audio Format");
    pub const WEBA = generate("audio/webm", "weba", "WEBM Audio");
    pub const WEBM = generate("video/webm", "webm", "WEBM Video");
    pub const WEBP = generate("image/webp", "webp", "WEBP Image");
    pub const WOFF = generate("font/woff", "woff", "Web Open Font Format (WOFF)");
    pub const WOFF2 = generate("font/woff2", "woff2", "Web Open Font Format (WOFF)");
    pub const XML = generate("application/xml", "xml", "XML");
    pub const ZIP = generate("application/zip", "zip", "ZIP Archive");
    pub const @"7Z" = generate("application/x-7z-compressed", "7z", "7-zip archive");

    pub fn generate(
        comptime content_type: anytype,
        comptime extension: anytype,
        description: []const u8,
    ) Mime {
        return Mime{
            .content_type = generate_mime_helper(content_type),
            .extension = generate_mime_helper(extension),
            .description = description,
        };
    }

    pub fn from_extension(extension: []const u8) Mime {
        assert(extension.len > 0);
        return mime_extension_map.get(extension) orelse Mime.BIN;
    }

    pub fn from_content_type(content_type: []const u8) Mime {
        assert(content_type.len > 0);
        return mime_content_map.get(content_type) orelse Mime.BIN;
    }
};

const all_mime_types = blk: {
    const decls = @typeInfo(Mime).@"struct".decls;
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

const mime_extension_map = blk: {
    const num_pairs = num: {
        var count: usize = 0;
        for (all_mime_types) |mime| {
            var value: usize = 0;
            value += switch (mime.extension) {
                .single => 1,
                .multiple => |items| items.len,
            };
            count += value;
        }

        break :num count;
    };

    var pairs: [num_pairs]Pair([]const u8, Mime) = undefined;

    var index: usize = 0;
    for (all_mime_types[0..]) |mime| {
        switch (mime.extension) {
            .single => |inner| {
                defer index += 1;
                pairs[index] = .{ inner, mime };
            },
            .multiple => |extensions| {
                for (extensions) |ext| {
                    defer index += 1;
                    pairs[index] = .{ ext, mime };
                }
            },
        }
    }

    break :blk std.StaticStringMap(Mime).initComptime(pairs);
};

const mime_content_map = blk: {
    const num_pairs = num: {
        var count: usize = 0;
        for (all_mime_types) |mime| {
            var value: usize = 0;
            value += switch (mime.content_type) {
                .single => 1,
                .multiple => |items| items.len,
            };
            count += value;
        }

        break :num count;
    };

    var pairs: [num_pairs]Pair([]const u8, Mime) = undefined;

    var index: usize = 0;
    for (all_mime_types[0..]) |mime| {
        switch (mime.content_type) {
            .single => |inner| {
                defer index += 1;
                pairs[index] = .{ inner, mime };
            },
            .multiple => |content_types| {
                for (content_types) |ext| {
                    defer index += 1;
                    pairs[index] = .{ ext, mime };
                }
            },
        }
    }

    break :blk std.StaticStringMap(Mime).initComptime(pairs);
};

const testing = std.testing;

test "MIME from extensions" {
    for (all_mime_types) |mime| {
        switch (mime.extension) {
            .single => |inner| {
                try testing.expectEqualStrings(
                    mime.description,
                    Mime.from_extension(inner).description,
                );
            },
            .multiple => |extensions| {
                for (extensions) |ext| {
                    try testing.expectEqualStrings(
                        mime.description,
                        Mime.from_extension(ext).description,
                    );
                }
            },
        }
    }
}

test "MIME from unknown extension" {
    const extension = ".whatami";
    const mime = Mime.from_extension(extension);
    try testing.expectEqual(Mime.BIN, mime);
}

test "MIME from content types" {
    for (all_mime_types) |mime| {
        switch (mime.content_type) {
            .single => |inner| {
                try testing.expectEqualStrings(
                    mime.description,
                    Mime.from_content_type(inner).description,
                );
            },
            .multiple => |content_types| {
                for (content_types) |ext| {
                    try testing.expectEqualStrings(
                        mime.description,
                        Mime.from_content_type(ext).description,
                    );
                }
            },
        }
    }
}

test "MIME from unknown content type" {
    const content_type = "application/whatami";
    const mime = Mime.from_content_type(content_type);
    try testing.expectEqual(Mime.BIN, mime);
}
