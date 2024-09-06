// These purposefully do not fit the general snake_case enum style.
// This is so that we can just use @tagName for the Status.
pub const Status = enum(u16) {
    /// 100 Continue
    /// https://developer.mozilla.org/en-US/docs/Web/HTTP/Status/100
    Continue = 100,
    /// 101 Switching Protocols
    /// https://developer.mozilla.org/en-US/docs/Web/HTTP/Status/101
    @"Switching Protocols" = 101,
    /// 102 Processing
    /// This is deprecrated and should generally not be used.
    /// https://developer.mozilla.org/en-US/docs/Web/HTTP/Status/102
    Processing = 102,
    /// 103 Early Hints
    /// https://developer.mozilla.org/en-US/docs/Web/HTTP/Status/103
    @"Early Hints" = 103,
    /// 200 OK
    /// https://developer.mozilla.org/en-US/docs/Web/HTTP/Status/200
    OK = 200,
    /// 201 Created
    /// https://developer.mozilla.org/en-US/docs/Web/HTTP/Status/201
    Created = 201,
    /// 202 Accepted
    /// https://developer.mozilla.org/en-US/docs/Web/HTTP/Status/202
    Accepted = 202,
    /// 203 Non-Authoritative Information
    /// https://developer.mozilla.org/en-US/docs/Web/HTTP/Status/203
    @"Non-Authoritative Informaton" = 203,
    /// 204 No Content
    /// https://developer.mozilla.org/en-US/docs/Web/HTTP/Status/204
    @"No Content" = 204,
    /// 205 Reset Content
    /// https://developer.mozilla.org/en-US/docs/Web/HTTP/Status/205
    @"Reset Content" = 205,
    /// 206 Partial Content
    /// https://developer.mozilla.org/en-US/docs/Web/HTTP/Status/206
    @"Partial Content" = 206,
    /// 207 Multi-Status
    /// Used exclusively with WebDAV
    /// https://developer.mozilla.org/en-US/docs/Web/HTTP/Status/207
    @"Multi-Status" = 207,
    /// 208 Already Reported
    /// Used exclusively with WebDAV
    /// https://developer.mozilla.org/en-US/docs/Web/HTTP/Status/208
    @"Already Reported" = 208,
    /// 226 IM Used
    /// https://developer.mozilla.org/en-US/docs/Web/HTTP/Status/226
    @"IM Used" = 226,
    /// 300 Multiple Choices
    /// https://developer.mozilla.org/en-US/docs/Web/HTTP/Status/300
    @"Multiple Choices" = 300,
    /// 301 Moved Permanently
    /// https://developer.mozilla.org/en-US/docs/Web/HTTP/Status/301
    @"Moved Permanently" = 301,
    /// 302 Found
    /// https://developer.mozilla.org/en-US/docs/Web/HTTP/Status/302
    Found = 302,
    /// 303 See Other
    /// https://developer.mozilla.org/en-US/docs/Web/HTTP/Status/303
    @"See Other" = 303,
    /// 304 Not Modified
    /// https://developer.mozilla.org/en-US/docs/Web/HTTP/Status/304
    @"Not Modified" = 304,
    /// 307 Temporary Redirect
    /// https://developer.mozilla.org/en-US/docs/Web/HTTP/Status/307
    @"Temporary Redirect" = 307,
    /// 308 Permanent Redirect
    /// https://developer.mozilla.org/en-US/docs/Web/HTTP/Status/308
    @"Permanent Redirect" = 308,
    /// 400 Bad Request
    /// https://developer.mozilla.org/en-US/docs/Web/HTTP/Status/400
    @"Bad Request" = 400,
    /// 401 Unauthorized
    /// https://developer.mozilla.org/en-US/docs/Web/HTTP/Status/401
    Unauthorized = 401,
    /// 402 Payment Required
    /// Nonstandard
    /// https://developer.mozilla.org/en-US/docs/Web/HTTP/Status/402
    @"Payment Required" = 402,
    /// 403 Forbidden
    /// https://developer.mozilla.org/en-US/docs/Web/HTTP/Status/403
    Forbidden = 403,
    /// 404 Not Found
    /// https://developer.mozilla.org/en-US/docs/Web/HTTP/Status/404
    @"Not Found" = 404,
    /// 405 Method Not Allowed
    /// https://developer.mozilla.org/en-US/docs/Web/HTTP/Status/405
    @"Method Not Allowed" = 405,
    /// Not Acceptable
    /// https://developer.mozilla.org/en-US/docs/Web/HTTP/Status/406
    @"Not Acceptable" = 406,
    /// 407 Proxy Authentication Required
    /// https://developer.mozilla.org/en-US/docs/Web/HTTP/Status/407
    @"Proxy Authentication Required" = 407,
    /// 408 Request Timeout
    /// https://developer.mozilla.org/en-US/docs/Web/HTTP/Status/408
    @"Request Timeout" = 408,
    /// 409 Conflict
    /// https://developer.mozilla.org/en-US/docs/Web/HTTP/Status/409
    Conflict = 409,
    /// 410 Gone
    /// https://developer.mozilla.org/en-US/docs/Web/HTTP/Status/410
    Gone = 410,
    /// 411 Length Required
    /// https://developer.mozilla.org/en-US/docs/Web/HTTP/Status/411
    @"Length Required" = 411,
    /// 412 Precondition Failed
    /// https://developer.mozilla.org/en-US/docs/Web/HTTP/Status/412
    @"Precondition Failed" = 412,
    /// 413 Content Too Large
    /// https://developer.mozilla.org/en-US/docs/Web/HTTP/Status/413
    @"Content Too Large" = 413,
    /// 414 URI Too Long
    /// https://developer.mozilla.org/en-US/docs/Web/HTTP/Status/414
    @"URI Too Long" = 414,
    /// 415 Unsupported Media Type
    /// https://developer.mozilla.org/en-US/docs/Web/HTTP/Status/415
    @"Unsupported Media Type" = 415,
    /// 416 Range Not Satisfiable
    /// https://developer.mozilla.org/en-US/docs/Web/HTTP/Status/416
    @"Range Not Satisfiable" = 416,
    /// 417 Expectation Failed
    /// https://developer.mozilla.org/en-US/docs/Web/HTTP/Status/417
    @"Expectation Failed" = 417,
    /// 418 I'm a Teapot
    /// https://developer.mozilla.org/en-US/docs/Web/HTTP/Status/418
    @"I'm a Teapot" = 418,
    /// 421 Misdirected Request
    /// https://developer.mozilla.org/en-US/docs/Web/HTTP/Status/421
    @"Misdirected Request" = 421,
    /// 422 Unprocessable Content
    /// https://developer.mozilla.org/en-US/docs/Web/HTTP/Status/422
    @"Unprocessable Content" = 422,
    /// 423 Locked
    /// Used exclusively with WebDAV
    /// https://developer.mozilla.org/en-US/docs/Web/HTTP/Status/423
    Locked = 423,
    /// 424 Failed Dependency
    /// Used (almost) exclusively with WebDAV
    /// https://developer.mozilla.org/en-US/docs/Web/HTTP/Status/424
    @"Failed Dependency" = 424,
    /// 425 Too Early
    /// https://developer.mozilla.org/en-US/docs/Web/HTTP/Status/425
    @"Too Early" = 425,
    /// 426 Upgrade Required
    /// https://developer.mozilla.org/en-US/docs/Web/HTTP/Status/426
    @"Upgrade Required" = 426,
    /// 428 Precondition Required
    /// https://developer.mozilla.org/en-US/docs/Web/HTTP/Status/428
    @"Precondition Required" = 428,
    /// 429 Too Many Requests
    /// https://developer.mozilla.org/en-US/docs/Web/HTTP/Status/429
    @"Too Many Requests" = 429,
    /// 431 Request Header Fields Too Large
    /// https://developer.mozilla.org/en-US/docs/Web/HTTP/Status/431
    @"Request Header Fields Too Large" = 431,
    /// 451 Unavailable for Legal Reasons
    /// https://developer.mozilla.org/en-US/docs/Web/HTTP/Status/451
    @"Unavailable for Legal Reasons" = 451,
    /// 500 Internal Server Error
    /// https://developer.mozilla.org/en-US/docs/Web/HTTP/Status/500
    @"Internal Server Error" = 500,
    /// 501 Not Implemented
    /// https://developer.mozilla.org/en-US/docs/Web/HTTP/Status/501
    @"Not Implemented" = 501,
    /// 502 Bad Gateway
    /// https://developer.mozilla.org/en-US/docs/Web/HTTP/Status/502
    @"Bad Gateway" = 502,
    /// 503 Service Unavailable
    /// https://developer.mozilla.org/en-US/docs/Web/HTTP/Status/503
    @"Service Unavailable" = 503,
    /// 504 Gateway Timeout
    /// https://developer.mozilla.org/en-US/docs/Web/HTTP/Status/504
    @"Gateway Timeout" = 504,
    /// 505 HTTP Version Not Supported
    /// https://developer.mozilla.org/en-US/docs/Web/HTTP/Status/505
    @"HTTP Version Not Supported" = 505,
    /// 506 Variant Also Negotiates
    /// https://developer.mozilla.org/en-US/docs/Web/HTTP/Status/506
    @"Variant Also Negotiates" = 506,
    /// 507 Insufficient Storage
    /// Used exclusively with WebDAV
    /// https://developer.mozilla.org/en-US/docs/Web/HTTP/Status/507
    @"Insufficient Storage" = 507,
    /// 508 Loop Detected
    /// Used exclusively with WebDAV
    /// https://developer.mozilla.org/en-US/docs/Web/HTTP/Status/508
    @"Loop Detected" = 508,
    /// 510 Not Extended
    /// https://developer.mozilla.org/en-US/docs/Web/HTTP/Status/510
    @"Not Extended" = 510,
    /// 511 Network Authentication Required
    /// https://developer.mozilla.org/en-US/docs/Web/HTTP/Status/511
    @"Network Authentication Required" = 511,
    /// Interally used, will cause the thread that accepts it
    /// to gracefully shutdown.
    Kill = 999,
};
