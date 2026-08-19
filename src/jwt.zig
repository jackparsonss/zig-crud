const std = @import("std");

const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const Allocator = std.mem.Allocator;

pub const token_lifetime_seconds: i64 = 60 * 60;

const base64url = std.base64.url_safe_no_pad;
const jwt_header = "{\"alg\":\"HS256\",\"typ\":\"JWT\"}";

const Header = struct {
    alg: []const u8,
    typ: []const u8,
};

const Claims = struct {
    sub: []const u8,
    iat: i64,
    exp: i64,
};

pub fn issueToken(
    allocator: Allocator,
    secret: []const u8,
    username: []const u8,
    now: i64,
) ![]u8 {
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(allocator);

    try payload.print(allocator, "{f}", .{std.json.fmt(Claims{
        .sub = username,
        .iat = now,
        .exp = now + token_lifetime_seconds,
    }, .{})});

    return createToken(allocator, secret, jwt_header, payload.items);
}

pub fn verifyToken(
    allocator: Allocator,
    secret: []const u8,
    token: []const u8,
    now: i64,
) !void {
    const first_dot = std.mem.indexOfScalar(u8, token, '.') orelse return error.InvalidToken;
    const second_dot_relative = std.mem.indexOfScalar(u8, token[first_dot + 1 ..], '.') orelse
        return error.InvalidToken;

    const second_dot = first_dot + 1 + second_dot_relative;
    if (std.mem.indexOfScalar(u8, token[second_dot + 1 ..], '.') != null) {
        return error.InvalidToken;
    }

    const encoded_header = token[0..first_dot];
    const encoded_payload = token[first_dot + 1 .. second_dot];
    const encoded_signature = token[second_dot + 1 ..];
    if (encoded_header.len == 0 or encoded_payload.len == 0 or encoded_signature.len == 0) {
        return error.InvalidToken;
    }

    const signature_len = base64url.Decoder.calcSizeForSlice(encoded_signature) catch
        return error.InvalidToken;
    if (signature_len != HmacSha256.mac_length) {
        return error.InvalidToken;
    }

    var signature: [HmacSha256.mac_length]u8 = undefined;
    base64url.Decoder.decode(&signature, encoded_signature) catch return error.InvalidToken;

    var expected_signature: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&expected_signature, token[0..second_dot], secret);
    if (!std.crypto.timing_safe.eql(
        [HmacSha256.mac_length]u8,
        expected_signature,
        signature,
    )) return error.InvalidToken;

    const header_json = decodeAlloc(allocator, encoded_header) catch return error.InvalidToken;
    defer allocator.free(header_json);
    const payload_json = decodeAlloc(allocator, encoded_payload) catch return error.InvalidToken;
    defer allocator.free(payload_json);

    const parsed_header = std.json.parseFromSlice(Header, allocator, header_json, .{}) catch
        return error.InvalidToken;
    defer parsed_header.deinit();
    if (!std.mem.eql(u8, parsed_header.value.alg, "HS256") or
        !std.mem.eql(u8, parsed_header.value.typ, "JWT"))
    {
        return error.InvalidToken;
    }

    const parsed_claims = std.json.parseFromSlice(Claims, allocator, payload_json, .{}) catch
        return error.InvalidToken;
    defer parsed_claims.deinit();

    const claims = parsed_claims.value;
    if (claims.sub.len == 0 or claims.iat < 0 or claims.exp < claims.iat) {
        return error.InvalidToken;
    }

    if (claims.exp <= now) {
        return error.ExpiredToken;
    }
}

fn createToken(
    allocator: Allocator,
    secret: []const u8,
    header_json: []const u8,
    payload_json: []const u8,
) ![]u8 {
    const encoded_header = try encodeAlloc(allocator, header_json);
    defer allocator.free(encoded_header);

    const encoded_payload = try encodeAlloc(allocator, payload_json);
    defer allocator.free(encoded_payload);

    var signing_input: std.ArrayList(u8) = .empty;
    defer signing_input.deinit(allocator);
    try signing_input.appendSlice(allocator, encoded_header);
    try signing_input.append(allocator, '.');
    try signing_input.appendSlice(allocator, encoded_payload);

    var signature: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&signature, signing_input.items, secret);

    var encoded_signature: [base64url.Encoder.calcSize(HmacSha256.mac_length)]u8 = undefined;
    _ = base64url.Encoder.encode(&encoded_signature, &signature);

    try signing_input.append(allocator, '.');
    try signing_input.appendSlice(allocator, &encoded_signature);
    return signing_input.toOwnedSlice(allocator);
}

fn encodeAlloc(allocator: Allocator, input: []const u8) ![]u8 {
    const output = try allocator.alloc(u8, base64url.Encoder.calcSize(input.len));
    _ = base64url.Encoder.encode(output, input);
    return output;
}

fn decodeAlloc(allocator: Allocator, input: []const u8) ![]u8 {
    const decoded_len = try base64url.Decoder.calcSizeForSlice(input);
    const output = try allocator.alloc(u8, decoded_len);
    errdefer allocator.free(output);

    try base64url.Decoder.decode(output, input);
    return output;
}
