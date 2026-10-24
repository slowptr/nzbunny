const std = @import("std");
const Job = @import("database.zig").Job;
const ProgressSnapshot = @import("progress.zig").ProgressSnapshot;

pub const index_html =
    \\<!DOCTYPE html>
    \\<html lang="en">
    \\<head>
    \\    <meta charset="UTF-8">
    \\    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    \\    <link rel="stylesheet" href="/public/styles.css">
    \\    <title>nzbunny</title>
    \\</head>
    \\<body>
    \\    <main>
    \\      <div class="module-container">
    \\          <form method="post" action="/" enctype="multipart/form-data">
    \\              <div class="drop-zone" id="dropZone">
    \\                <input type="file" id="nzbfile" name="nzbfile" accept=".nzb" required>
    \\                <h2>Drop a file here</h2>
    \\                <p>or click to browse</p>
    \\                <div class="file-list" id="fileList"></div>
    \\              </div>
    \\              <button type="submit">Upload</button>
    \\          </form>
    \\      </div>
    \\    </main>
    \\    <img src="/public/nzbunny.png" alt="nzbunny logo" class="logo">
    \\    <script src="/public/upload.js"></script>
    \\</body>
    \\</html>
;

pub fn render(allocator: std.mem.Allocator, job: Job, snapshot: ?ProgressSnapshot, now: i64) ![]u8 {
    var page = std.Io.Writer.Allocating.init(allocator);
    defer page.deinit();
    const w = &page.writer;
    try w.writeAll(
        \\<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8">
        \\<meta name="viewport" content="width=device-width, initial-scale=1.0">
        \\<link rel="stylesheet" href="/public/styles.css">
    );
    const details = describe(job);
    if (details.refresh) try w.writeAll("<meta http-equiv=\"refresh\" content=\"2\">");
    try w.writeAll("<title>nzbunny - job ");
    try htmlEscape(w, job.id);
    try w.writeAll("</title></head><body><main><div class=\"module-container\"><h2>");
    try w.writeAll(details.title);
    try w.writeAll("</h2><p>");
    try w.writeAll(details.detail);
    try w.writeAll("</p><div class=\"job-card\"><p><strong>job id:</strong> ");
    try htmlEscape(w, job.id);
    try w.writeAll("</p><p><strong>file:</strong> ");
    try htmlEscape(w, job.filename);
    try w.writeAll("</p><p><strong>status:</strong> <span class=\"status-");
    try w.writeAll(job.status.publicName());
    try w.writeAll("\">");
    try w.writeAll(job.status.publicName());
    try w.writeAll("</span></p>");
    if (job.status == .processing) {
        if (snapshot) |progress| {
            const percent = if (progress.total == 0) 0 else @min(100, progress.completed * 100 / progress.total);
            try w.writeAll("<p><strong>phase:</strong> ");
            try w.writeAll(progressPhaseName(progress.phase));
            try w.writeAll("</p><div class=\"progress-track\" role=\"progressbar\" aria-label=\"Download progress\" aria-valuemin=\"0\" aria-valuemax=\"100\" aria-valuenow=\"");
            try w.print("{d}\"><span style=\"width:{d}%\"></span></div>", .{ percent, percent });
            try w.print("<p class=\"progress-detail\">{d} of {d} segments ({d}%)</p>", .{ progress.completed, progress.total, percent });
            try activityStatus(w, now, progress.last_activity, 30);
        } else {
            try w.writeAll("<p><strong>phase:</strong> starting downloader</p>");
            try activityStatus(w, now, job.updated_at, 30);
        }
    } else if (job.status == .finalizing) {
        try activityStatus(w, now, job.updated_at, 90);
    } else if (job.status == .pending) {
        try w.writeAll("<p><strong>queued for:</strong> ");
        try formatDuration(w, @max(0, now - job.created_at));
        try w.writeAll("</p>");
    }
    if (job.fail_reason.len != 0) {
        try w.writeAll("<p><strong>reason:</strong> ");
        try htmlEscape(w, job.fail_reason);
        try w.writeAll("</p>");
    }
    if (job.status == .complete and job.download_token.len != 0) {
        try w.writeAll("<p><strong>download:</strong> <a href=\"/d/");
        try htmlEscape(w, job.download_token);
        try w.writeAll("\">download artifact</a></p>");
    }
    if (job.artifact_size > 0) try w.print("<p><strong>size:</strong> {d} bytes</p>", .{job.artifact_size});
    if (job.expires_at) |expiry| {
        try w.writeAll("<p><strong>expires:</strong> ");
        try formatTimestamp(w, expiry);
        try w.writeAll("</p>");
    }
    try w.writeAll("<p><strong>created:</strong> ");
    try formatTimestamp(w, job.created_at);
    try w.writeAll("</p>");
    try w.writeAll(
        \\</div></div><div class="module-container"><a href="/">upload another file</a></div>
        \\<img src="/public/nzbunny.png" alt="nzbunny logo" class="logo"></main></body></html>
    );
    return allocator.dupe(u8, page.writer.buffered());
}

fn progressPhaseName(phase: @import("download.zig").Phase) []const u8 {
    return switch (phase) {
        .idle => "starting downloader",
        .parsing => "reading NZB metadata",
        .preparing => "preparing workspace",
        .preflight => "checking files",
        .downloading => "downloading segments",
        .assembling => "assembling files",
        .repairing => "repairing files",
    };
}

fn activityStatus(writer: *std.Io.Writer, now: i64, last_activity: i64, stall_seconds: i64) !void {
    const age = @max(0, now - last_activity);
    try writer.writeAll("<p><strong>last activity:</strong> ");
    try formatDuration(writer, age);
    try writer.writeAll(" ago</p>");
    if (age >= stall_seconds) {
        try writer.writeAll("<p class=\"stall-warning\"><strong>possible stall:</strong> no progress was recorded recently. The downloader timeout is still active.</p>");
    } else {
        try writer.writeAll("<p class=\"activity-ok\">activity is current</p>");
    }
}

fn formatDuration(writer: *std.Io.Writer, seconds: i64) !void {
    if (seconds < 60) return writer.print("{d}s", .{seconds});
    const minutes = @divFloor(seconds, 60);
    const remaining = @mod(seconds, 60);
    return writer.print("{d}m {d}s", .{ minutes, remaining });
}

pub fn htmlEscape(writer: *std.Io.Writer, value: []const u8) !void {
    for (value) |byte| switch (byte) {
        '&' => try writer.writeAll("&amp;"),
        '<' => try writer.writeAll("&lt;"),
        '>' => try writer.writeAll("&gt;"),
        '"' => try writer.writeAll("&quot;"),
        '\'' => try writer.writeAll("&#39;"),
        else => try writer.writeByte(byte),
    };
}

fn describe(job: Job) struct { title: []const u8, detail: []const u8, refresh: bool } {
    return switch (job.status) {
        .pending => .{ .title = "Queued", .detail = "Your NZB is in the queue.", .refresh = true },
        .processing => .{ .title = "Downloading", .detail = "The embedded downloader processes the job. This page refreshes automatically.", .refresh = true },
        .finalizing => .{ .title = "Finalizing", .detail = "The file is almost ready. Wait a few seconds.", .refresh = true },
        .complete => .{ .title = "Ready", .detail = "Your temporary download link is active until it expires.", .refresh = false },
        .expired => .{ .title = "Expired", .detail = "This temporary download expired and was removed.", .refresh = false },
        .failed => .{ .title = "Failed", .detail = "The job did not complete.", .refresh = false },
    };
}

fn formatTimestamp(writer: *std.Io.Writer, timestamp: i64) !void {
    if (timestamp < 0) return writer.print("{d} UTC", .{timestamp});
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(timestamp) };
    const epoch_day = epoch_seconds.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch_seconds.getDaySeconds();
    const weekdays = [_][]const u8{ "Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed" };
    const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    try writer.print("{s}, {d:0>2} {s} {d} {d:0>2}:{d:0>2}:{d:0>2} UTC", .{
        weekdays[epoch_day.day % 7],
        month_day.day_index + 1,
        months[month_day.month.numeric() - 1],
        year_day.year,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
    });
}

test "HTML escaping covers active characters" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    try htmlEscape(&output.writer, "<a x='\"'>&");
    try std.testing.expectEqualStrings("&lt;a x=&#39;&quot;&#39;&gt;&amp;", output.writer.buffered());
}
