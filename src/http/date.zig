const std = @import("std");
const assert = std.debug.assert;

const day_names: []const []const u8 = &.{
    "Mon",
    "Tue",
    "Wed",
    "Thu",
    "Fri",
    "Sat",
    "Sun",
};

const Month = struct {
    name: []const u8,
    days: u32,
};

const months: []const Month = &.{
    Month{ .name = "Jan", .days = 31 },
    Month{ .name = "Feb", .days = 28 },
    Month{ .name = "Mar", .days = 31 },
    Month{ .name = "Apr", .days = 30 },
    Month{ .name = "May", .days = 31 },
    Month{ .name = "Jun", .days = 30 },
    Month{ .name = "Jul", .days = 31 },
    Month{ .name = "Aug", .days = 31 },
    Month{ .name = "Sep", .days = 30 },
    Month{ .name = "Oct", .days = 31 },
    Month{ .name = "Nov", .days = 30 },
    Month{ .name = "Dec", .days = 31 },
};

pub const Date = struct {
    const HTTPDate = struct {
        const format = std.fmt.comptimePrint(
            "{s}, {s} {s} {s} {s}:{s}:{s} GMT",
            .{
                "{[day_name]s}",
                "{[day]d}",
                "{[month]s}",
                "{[year]d}",
                "{[hour]d:0>2}",
                "{[minute]d:0>2}",
                "{[second]d:0>2}",
            },
        );

        day_name: []const u8,
        day: u8,
        month: []const u8,
        year: u16,
        hour: u8,
        minute: u8,
        second: u8,

        pub fn into_buf(date: HTTPDate, buffer: []u8) ![]u8 {
            assert(buffer.len >= 29);
            return try std.fmt.bufPrint(buffer, format, date);
        }

        pub fn into_alloc(date: HTTPDate, allocator: std.mem.Allocator) ![]const u8 {
            return try std.fmt.allocPrint(allocator, format, date);
        }

        pub fn into_writer(date: HTTPDate, writer: anytype) !void {
            assert(std.meta.hasMethod(@TypeOf(writer), "print"));
            try writer.print(format, date);
        }
    };

    ts: i64,

    pub fn init(ts: i64) Date {
        return Date{ .ts = ts };
    }

    fn is_leap_year(year: i64) bool {
        return (@rem(year, 4) == 0 and @rem(year, 100) != 0) or (@rem(year, 400) == 0);
    }

    pub fn to_http_date(date: Date) HTTPDate {
        const secs = date.ts;
        const days = @divFloor(secs, 86400);
        const remsecs = @mod(secs, 86400);

        var year: i64 = 1970;
        var remaining_days = days;
        while (true) {
            const days_in_year: i64 = if (is_leap_year(year)) 366 else 365;
            if (remaining_days < days_in_year) break;
            remaining_days -= days_in_year;
            year += 1;
        }

        var month: usize = 0;
        for (months, 0..) |m, i| {
            const days_in_month = if (i == 1 and is_leap_year(year)) 29 else m.days;
            if (remaining_days < days_in_month) break;
            remaining_days -= days_in_month;
            month += 1;
        }

        const day = remaining_days + 1;
        const week_day = @mod((days + 3), 7);

        const hour: u8 = @intCast(@divFloor(remsecs, 3600));
        const minute: u8 = @intCast(@mod(@divFloor(remsecs, 60), 60));
        const second: u8 = @intCast(@mod(remsecs, 60));

        return HTTPDate{
            .day_name = day_names[@intCast(week_day)],
            .day = @intCast(day),
            .month = months[month].name,
            .year = @intCast(year),
            .hour = hour,
            .minute = minute,
            .second = second,
        };
    }
};

const testing = std.testing;

test "Parse Basic Date (Buffer)" {
    const ts = 1727411110;
    var date: Date = Date.init(ts);
    var buffer = [_]u8{0} ** 29;
    const http_date = date.to_http_date();
    try testing.expectEqualStrings("Fri, 27 Sep 2024 04:25:10 GMT", try http_date.into_buf(buffer[0..]));
}

test "Parse Basic Date (Alloc)" {
    const ts = 1727464105;
    var date: Date = Date.init(ts);
    const http_date = date.to_http_date();
    const http_string = try http_date.into_alloc(testing.allocator);
    defer testing.allocator.free(http_string);
    try testing.expectEqualStrings("Fri, 27 Sep 2024 19:08:25 GMT", http_string);
}

test "Parse Basic Date (Writer)" {
    const ts = 672452112;
    var date: Date = Date.init(ts);
    const http_date = date.to_http_date();
    var buffer = [_]u8{0} ** 29;
    var stream = std.io.fixedBufferStream(buffer[0..]);
    try http_date.into_writer(stream.writer());
    const http_string = stream.getWritten();
    try testing.expectEqualStrings("Wed, 24 Apr 1991 00:15:12 GMT", http_string);
}
