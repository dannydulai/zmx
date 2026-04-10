const std = @import("std");
const posix = std.posix;

pub fn getSeshPrefix() []const u8 {
    return std.posix.getenv("ZMX_SESSION_PREFIX") orelse "";
}

pub fn getSeshNameFromEnv() []const u8 {
    return std.posix.getenv("ZMX_SESSION") orelse "";
}

pub fn getSeshName(alloc: std.mem.Allocator, sesh: []const u8) ![]const u8 {
    const prefix = getSeshPrefix();
    if (prefix.len == 0 and sesh.len == 0) {
        return error.SessionNameRequired;
    }
    const full = try std.fmt.allocPrint(alloc, "{s}{s}", .{ prefix, sesh });
    // Session names become filenames under socket_dir. Rejecting path
    // separators and dot-dot prevents socket creation and stale-socket
    // deletion from operating outside that directory.
    if (std.mem.indexOfScalar(u8, full, '/') != null or
        std.mem.indexOfScalar(u8, full, 0) != null or
        std.mem.eql(u8, full, ".") or std.mem.eql(u8, full, ".."))
    {
        alloc.free(full);
        return error.InvalidSessionName;
    }
    return full;
}

pub fn sessionConnect(sesh: []const u8) !i32 {
    var unix_addr = try std.net.Address.initUnix(sesh);
    const socket_fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0);
    errdefer posix.close(socket_fd);
    try posix.connect(socket_fd, &unix_addr.any, unix_addr.getOsSockLen());
    return socket_fd;
}

pub fn cleanupStaleSocket(dir: std.fs.Dir, session_name: []const u8) void {
    std.log.warn("stale socket found, cleaning up session={s}", .{session_name});
    dir.deleteFile(session_name) catch |err| {
        std.log.warn("failed to delete stale socket err={s}", .{@errorName(err)});
    };
    deleteVarsFile(dir, session_name);
}

/// Merge new vars into the existing vars file for a session.
/// Reads current vars, applies changes (empty value = delete), writes back.
/// Deletes the file if no vars remain.
pub fn mergeVarsFile(
    alloc: std.mem.Allocator,
    dir: std.fs.Dir,
    session_name: []const u8,
    new_vars: []const [2][]const u8,
) !void {
    var name_buf: [1024]u8 = undefined;
    const fname = varsFileName(&name_buf, session_name) orelse return error.NameTooLong;

    // Read existing vars
    var keys: std.ArrayList([]const u8) = .empty;
    var values: std.ArrayList([]const u8) = .empty;
    defer {
        for (keys.items) |k| alloc.free(k);
        keys.deinit(alloc);
        for (values.items) |v| alloc.free(v);
        values.deinit(alloc);
    }

    if (dir.openFile(fname, .{})) |file| {
        defer file.close();
        const content = try file.readToEndAlloc(alloc, 64 * 1024);
        defer alloc.free(content);

        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            if (std.mem.indexOfScalar(u8, line, '=')) |eq| {
                if (eq == 0) continue;
                try keys.append(alloc, try alloc.dupe(u8, line[0..eq]));
                try values.append(alloc, try alloc.dupe(u8, line[eq + 1 ..]));
            }
        }
    } else |_| {}

    // Apply new vars
    for (new_vars) |kv| {
        const key = kv[0];
        const value = kv[1];

        // Find existing key
        var found: ?usize = null;
        for (keys.items, 0..) |k, i| {
            if (std.mem.eql(u8, k, key)) {
                found = i;
                break;
            }
        }

        if (value.len == 0) {
            // Delete
            if (found) |i| {
                alloc.free(keys.items[i]);
                alloc.free(values.items[i]);
                _ = keys.orderedRemove(i);
                _ = values.orderedRemove(i);
            }
        } else if (found) |i| {
            // Update
            alloc.free(values.items[i]);
            values.items[i] = try alloc.dupe(u8, value);
        } else {
            // Add
            try keys.append(alloc, try alloc.dupe(u8, key));
            try values.append(alloc, try alloc.dupe(u8, value));
        }
    }

    if (keys.items.len == 0) {
        dir.deleteFile(fname) catch {};
        return;
    }

    const file = try dir.createFile(fname, .{});
    defer file.close();
    var write_buf: [4096]u8 = undefined;
    var w = file.writer(&write_buf);
    for (keys.items, values.items) |k, v| {
        try w.interface.print("{s}={s}\n", .{ k, v });
    }
    try w.interface.flush();
}

pub fn deleteVarsFile(dir: std.fs.Dir, session_name: []const u8) void {
    var buf: [1024]u8 = undefined;
    const name = varsFileName(&buf, session_name) orelse return;
    dir.deleteFile(name) catch {};
}

/// Read the vars file contents, returning null if it doesn't exist or on error.
pub fn readVarsFile(alloc: std.mem.Allocator, dir: std.fs.Dir, session_name: []const u8) ?[]const u8 {
    var buf: [1024]u8 = undefined;
    const name = varsFileName(&buf, session_name) orelse return null;
    const file = dir.openFile(name, .{}) catch return null;
    defer file.close();
    const content = file.readToEndAlloc(alloc, 64 * 1024) catch return null;
    // Trim trailing newline for display
    const trimmed = std.mem.trimRight(u8, content, "\n");
    if (trimmed.len == content.len) return content;
    // Shrink allocation
    const result = alloc.dupe(u8, trimmed) catch {
        alloc.free(content);
        return null;
    };
    alloc.free(content);
    return result;
}

fn varsFileName(buf: *[1024]u8, session_name: []const u8) ?[]const u8 {
    const suffix = ".vars";
    if (session_name.len + suffix.len > buf.len) return null;
    @memcpy(buf[0..session_name.len], session_name);
    @memcpy(buf[session_name.len .. session_name.len + suffix.len], suffix);
    return buf[0 .. session_name.len + suffix.len];
}

pub fn sessionExists(dir: std.fs.Dir, name: []const u8) !bool {
    const stat = dir.statFile(name) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    if (stat.kind != .unix_domain_socket) {
        return error.FileNotUnixSocket;
    }
    return true;
}

pub fn createSocket(fname: []const u8) !i32 {
    // AF.UNIX: Unix domain socket for local IPC with client processes
    // SOCK.STREAM: Reliable, bidirectional communication
    // SOCK.NONBLOCK: Set socket to non-blocking
    const fd = try posix.socket(
        posix.AF.UNIX,
        posix.SOCK.STREAM | posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC,
        0,
    );
    errdefer posix.close(fd);

    var unix_addr = try std.net.Address.initUnix(fname);
    try posix.bind(fd, &unix_addr.any, unix_addr.getOsSockLen());
    try posix.listen(fd, 128);
    return fd;
}

/// Maximum number of usable bytes in a Unix domain socket path.
/// Derived from the platform's sockaddr_un.path field, minus 1 for the
/// required null terminator.
pub const max_socket_path_len: usize = @typeInfo(
    @TypeOf(@as(posix.sockaddr.un, undefined).path),
).array.len - 1;

pub fn getSocketPath(
    alloc: std.mem.Allocator,
    socket_dir: []const u8,
    session_name: []const u8,
) error{ NameTooLong, OutOfMemory }![]const u8 {
    const dir = socket_dir;
    const path_len = dir.len + 1 + session_name.len;
    if (path_len > max_socket_path_len) return error.NameTooLong;
    const fname = try alloc.alloc(u8, path_len);
    @memcpy(fname[0..dir.len], dir);
    @memcpy(fname[dir.len .. dir.len + 1], "/");
    @memcpy(fname[dir.len + 1 ..], session_name);
    return fname;
}

pub fn printSessionNameTooLong(session_name: []const u8, socket_dir: []const u8) void {
    var buf: [4096]u8 = undefined;
    var w = std.fs.File.stderr().writer(&buf);
    if (maxSessionNameLen(socket_dir)) |max_len| {
        w.interface.print(
            "error: session name is too long ({d} bytes, max {d} for socket directory \"{s}\")\n",
            .{ session_name.len, max_len, socket_dir },
        ) catch {};
    } else {
        w.interface.print(
            "error: socket directory path is too long (\"{s}\")\n",
            .{socket_dir},
        ) catch {};
    }
    w.interface.flush() catch {};
}

/// Returns the maximum session name length for a given socket directory,
/// or null if the socket directory itself is already too long.
pub fn maxSessionNameLen(socket_dir: []const u8) ?usize {
    // path = socket_dir + "/" + session_name
    const overhead = socket_dir.len + 1;
    if (overhead >= max_socket_path_len) return null;
    return max_socket_path_len - overhead;
}

test "max_socket_path_len matches platform sockaddr_un" {
    const path_field_len = @typeInfo(
        @TypeOf(@as(posix.sockaddr.un, undefined).path),
    ).array.len;
    try std.testing.expectEqual(path_field_len - 1, max_socket_path_len);
    try std.testing.expect(max_socket_path_len > 0);
}

test "getSocketPath succeeds for paths within limit" {
    const alloc = std.testing.allocator;
    const result = try getSocketPath(alloc, "/tmp/zmx", "mysession");
    defer alloc.free(result);
    try std.testing.expectEqualStrings("/tmp/zmx/mysession", result);
}

test "getSocketPath returns NameTooLong when path exceeds limit" {
    const alloc = std.testing.allocator;
    const dir = [_]u8{'d'} ** (max_socket_path_len - 2);
    const dir_slice: []const u8 = &dir;

    const ok = try getSocketPath(alloc, dir_slice, "x");
    defer alloc.free(ok);
    try std.testing.expectEqual(max_socket_path_len, ok.len);

    const err = getSocketPath(alloc, dir_slice, "xx");
    try std.testing.expectError(error.NameTooLong, err);
}

test "getSocketPath returns NameTooLong for empty dir with oversized name" {
    const alloc = std.testing.allocator;
    const name = [_]u8{'n'} ** (max_socket_path_len);
    const name_slice: []const u8 = &name;
    const err = getSocketPath(alloc, "", name_slice);
    try std.testing.expectError(error.NameTooLong, err);
}

test "maxSessionNameLen computes correct dynamic limit" {
    const short_dir = "/tmp/zmx";
    const short_max = maxSessionNameLen(short_dir).?;
    try std.testing.expectEqual(max_socket_path_len - short_dir.len - 1, short_max);

    const full_dir = [_]u8{'f'} ** max_socket_path_len;
    const full_dir_slice: []const u8 = &full_dir;
    try std.testing.expectEqual(@as(?usize, null), maxSessionNameLen(full_dir_slice));

    const tight_dir = [_]u8{'t'} ** (max_socket_path_len - 2);
    const tight_dir_slice: []const u8 = &tight_dir;
    try std.testing.expectEqual(@as(?usize, 1), maxSessionNameLen(tight_dir_slice));
}

test "getSocketPath boundary: name fills exactly to limit" {
    const alloc = std.testing.allocator;
    const dir = "/tmp/zmx";
    const max_name_len = maxSessionNameLen(dir).?;

    const name_at_limit = try alloc.alloc(u8, max_name_len);
    defer alloc.free(name_at_limit);
    @memset(name_at_limit, 'a');

    const path = try getSocketPath(alloc, dir, name_at_limit);
    defer alloc.free(path);
    try std.testing.expectEqual(max_socket_path_len, path.len);

    const name_over_limit = try alloc.alloc(u8, max_name_len + 1);
    defer alloc.free(name_over_limit);
    @memset(name_over_limit, 'b');

    try std.testing.expectError(error.NameTooLong, getSocketPath(alloc, dir, name_over_limit));
}
