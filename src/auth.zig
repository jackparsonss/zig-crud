const std = @import("std");

const pwhash = std.crypto.pwhash;

pub const password_hash_buffer_size = 256;

pub fn hashPassword(
    allocator: std.mem.Allocator,
    io: std.Io,
    password: []const u8,
    out: *[password_hash_buffer_size]u8,
) ![]const u8 {
    return pwhash.argon2.strHash(password, .{
        .allocator = allocator,
        .params = .owasp_2id,
    }, out, io);
}

pub fn verifyPassword(
    allocator: std.mem.Allocator,
    io: std.Io,
    password_hash: []const u8,
    password: []const u8,
) bool {
    pwhash.argon2.strVerify(
        password_hash,
        password,
        .{ .allocator = allocator },
        io,
    ) catch {
        return false;
    };

    return true;
}
