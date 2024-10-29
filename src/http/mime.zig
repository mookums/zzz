const std = @import("std");
const assert = std.debug.assert;

/// HTTP MIME Types.
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

    pub const AZW = Mime{
        .content_type = "applicatgion/vnd.amazon.ebook",
        .extension = ".azw",
        .description = "AZW: Amazon Kindle eBook format",
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

    pub const BZ = Mime{
        .content_type = "application/x-bzip",
        .extension = ".bz",
        .description = "BZip archive",
    };

    pub const BZ2 = Mime{
        .content_type = "application/x-bzip2",
        .extension = ".bz2",
        .description = "BZip2 archive",
    };

    pub const CDA = Mime{
        .content_type = "application/x-cdf",
        .extension = ".cda",
        .description = "CD Audio",
    };

    pub const CSH = Mime{
        .content_type = "application/x-csh",
        .extension = ".csh",
        .description = "C-Shell script",
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

    pub const DOC = Mime{
        .content_type = "application/msword",
        .extension = ".doc",
        .description = "Microsoft Word",
    };

    pub const DOCX = Mime{
        .content_type = "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        .extension = ".docx",
        .description = "Microsoft Word (OpenXML)",
    };

    pub const EOT = Mime{
        .content_type = "application/vnd.ms-fontobject",
        .extension = ".eot",
        .description = "MS Embedded OpenType fonts",
    };

    pub const EPUB = Mime{
        .content_type = "application/epub+zip",
        .extension = ".epub",
        .description = "Electronic Publication",
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

    pub const HTM = Mime{
        .content_type = "text/html",
        .extension = ".htm",
        .description = "HyperText Markup Language (HTML)",
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

    pub const ICS = Mime{
        .content_type = "text/calendar",
        .extension = ".ics",
        .description = "iCalendar Format",
    };

    pub const JAR = Mime{
        .content_type = "application/java-archive",
        .extension = ".jar",
        .description = "Java Archive",
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

    pub const JSONLD = Mime{
        .content_type = "application/ld+json",
        .extension = ".jsonld",
        .description = "JSON-LD Format",
    };

    pub const MID = Mime{
        .content_type = "audio/midi",
        .extension = ".mid",
        .description = "Musical Instrument Digial Interface (MIDI)",
    };

    pub const MIDI = Mime{
        .content_type = "audio/x-midi",
        .extension = ".midi",
        .description = "Musical Instrument Digial Interface (MIDI)",
    };

    pub const MJS = Mime{
        .content_type = "text/javascript",
        .extension = ".mjs",
        .description = "Javascript module",
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

    pub const MPEG = Mime{
        .content_type = "video/mpeg",
        .extension = ".mpeg",
        .description = "MPEG Video",
    };

    pub const MPKG = Mime{
        .content_type = "application/vnd.apple.installer+xml",
        .extension = ".mpkg",
        .description = "Apple Installer Package",
    };

    pub const ODP = Mime{
        .content_type = "application/vnd.oasis.opendocument.presentation",
        .extension = ".odp",
        .description = "OpenDocument Presentation Document",
    };

    pub const ODS = Mime{
        .content_type = "application/vnd.oasis.opendocument.spreadsheet",
        .extension = ".ods",
        .description = "OpenDocument Spreadsheet Document",
    };

    pub const ODT = Mime{
        .content_type = "application/vnd.oasis.opendocument.text",
        .extension = ".odt",
        .description = "OpenDocument Text Document",
    };

    pub const OGA = Mime{
        .content_type = "audio/ogg",
        .extension = ".oga",
        .description = "Ogg audio",
    };

    pub const OGV = Mime{
        .content_type = "audio/ogv",
        .extension = ".ogv",
        .description = "Ogg video",
    };

    pub const OGX = Mime{
        .content_type = "audio/ogx",
        .extension = ".ogx",
        .description = "Ogg",
    };

    pub const OPUS = Mime{
        .content_type = "audio/ogg",
        .extension = ".opus",
        .description = "Opus audio in Ogg container",
    };

    pub const OTF = Mime{
        .content_type = "font/otf",
        .extension = ".otf",
        .description = "OpenType font",
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

    pub const PHP = Mime{
        .content_type = "application/x-httpd-php",
        .extension = ".php",
        .description = "Hypertext Preprocessor (Personal Home Page)",
    };

    pub const PPT = Mime{
        .content_type = "application/vnd.ms-powerpoint",
        .extension = ".ppt",
        .description = "Microsoft Powerpoint",
    };

    pub const PPTX = Mime{
        .content_type = "application/vnd.openxmlformats-officedocument.presentationml.presentation",
        .extension = ".pptx",
        .description = "Microsoft Powerpoint (OpenXML)",
    };

    pub const RAR = Mime{
        .content_type = "application/vnd.rar",
        .extension = ".rar",
        .description = "RAR archive",
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

    pub const TIFF = Mime{
        .content_type = "image/tiff",
        .extension = ".tiff",
        .description = "Tagged Image File Format (Tiff)",
    };

    pub const TS = Mime{
        .content_type = "video/mp2t",
        .extension = ".ts",
        .description = "MPEG transport stream",
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

    pub const VSD = Mime{
        .content_type = "application/vnd.visio",
        .extension = ".vsd",
        .description = "Microsoft Visio",
    };

    pub const WAV = Mime{
        .content_type = "audio/wav",
        .extension = ".wav",
        .description = "Waveform Audio Format",
    };

    pub const WEBA = Mime{
        .content_type = "audio/webm",
        .extension = ".weba",
        .description = "WEBM Audio",
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

    pub const WOFF2 = Mime{
        .content_type = "font/woff2",
        .extension = ".woff2",
        .description = "Web Open Font Format (WOFF)",
    };

    pub const XHTML = Mime{
        .content_type = "application/xhtml+xml",
        .extension = ".xhtml",
        .description = "XHTML",
    };

    pub const XLS = Mime{
        .content_type = "application/vnd.ms-excel",
        .extension = ".xls",
        .description = "Microsoft Excel",
    };

    pub const XLSX = Mime{
        .content_type = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        .extension = ".xlsx",
        .description = "Microsoft Excel (OpenXML)",
    };

    pub const XML = Mime{
        .content_type = "application/xml",
        .extension = ".xml",
        .description = "XML",
    };

    pub const XUL = Mime{
        .content_type = "application/vnd.mozilla.xul+xml",
        .extension = ".xul",
        .description = "XUL",
    };

    pub const ZIP = Mime{
        .content_type = "application/zip",
        .extension = ".zip",
        .description = "ZIP Archive",
    };

    pub const @"3GPA" = Mime{
        .content_type = "audio/3gpp",
        .extension = ".3gp",
        .description = "3GPP audio/vido container",
    };

    pub const @"3GPV" = Mime{
        .content_type = "video/3gpp",
        .extension = ".3gp",
        .description = "3GPP audio/vido container",
    };

    pub const @"3G2A" = Mime{
        .content_type = "audio/3gpp2",
        .extension = ".3g2",
        .description = "3GPP2 audio/vido container",
    };

    pub const @"3G2V" = Mime{
        .content_type = "video/3gpp2",
        .extension = ".3g2",
        .description = "3GPP2 audio/vido container",
    };

    pub const @"7Z" = Mime{
        .content_type = "application/x-7z-compressed",
        .extension = ".7z",
        .description = "7-zip archive",
    };

    fn extension_to_key(extension: []const u8) u64 {
        assert(extension.len > 0);
        return std.hash.Wyhash.hash(0, extension);
    }

    fn content_type_to_key(content_type: []const u8) u64 {
        assert(content_type.len > 0);
        return std.hash.Wyhash.hash(0, content_type);
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
