const std = @import("std");
const pg = @import("pg");

const auth = @import("auth.zig");
const jwt = @import("jwt.zig");

const Io = std.Io;
const net = Io.net;
const json = std.json;

const Note = struct {
    id: u32,
    text: []const u8,
};

const App = struct {
    allocator: std.mem.Allocator,
    pool: *pg.Pool,
    io: std.Io,
    jwt_secret: []const u8,
};

const User = struct {
    username: []const u8,
    password: []const u8,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    const jwt_secret = init.environ_map.get("JWT_SECRET") orelse {
        std.debug.print("JWT_SECRET env variable is required", .{});
        return error.MissingJWTSecret;
    };

    if (jwt_secret.len == 0) {
        std.debug.print("JWT_SECRET env variable must be not empty", .{});
        return error.MissingJWTSecret;
    }

    var pool = try pg.Pool.init(io, init.gpa, .{
        .size = 5,
        .connect = .{ .host = "127.0.0.1", .port = 5432 },
        .auth = .{
            .username = "postgres",
            .password = "postgres",
            .database = "notes",
        },
    });
    defer pool.deinit();

    var app: App = .{
        .allocator = init.gpa,
        .pool = pool,
        .io = io,
        .jwt_secret = jwt_secret,
    };

    const address = try net.IpAddress.parse("127.0.0.1", 8080);
    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);

    _ = try pool.exec(@embedFile("sql/create_notes_table.sql"), .{});
    _ = try pool.exec(@embedFile("sql/create_users_table.sql"), .{});

    std.debug.print("Listening on http://127.0.0.1:8080\n", .{});

    while (true) {
        const stream = try server.accept(io);
        handleConnection(io, stream, &app);
    }
}

fn handleConnection(io: Io, stream: net.Stream, app: *App) void {
    defer stream.close(io);

    var read_buffer: [4096]u8 = undefined;
    var write_buffer: [4096]u8 = undefined;
    var connection_reader = stream.reader(io, &read_buffer);
    var connection_writer = stream.writer(io, &write_buffer);
    var server = std.http.Server.init(&connection_reader.interface, &connection_writer.interface);

    while (server.reader.state == .ready) {
        var request = server.receiveHead() catch |err| switch (err) {
            error.HttpConnectionClosing => return,
            else => {
                std.debug.print("failed to read request: {t}\n", .{err});
                return;
            },
        };

        route(&request, app) catch |err| {
            std.debug.print("failed to serve {s}: {t}\n", .{ request.head.target, err });
            return;
        };
    }
}

fn route(request: *std.http.Server.Request, app: *App) !void {
    const method = request.head.method;
    const path = request.head.target;

    if (std.mem.eql(u8, path, "/user")) {
        return switch (method) {
            .POST => createUser(request, app),
            else => respondJson(
                request,
                .method_not_allowed,
                "{\"error\":\"method not allowed\"}",
            ),
        };
    }

    if (std.mem.eql(u8, path, "/login")) {
        return switch (method) {
            .POST => login(request, app),
            else => respondJson(
                request,
                .method_not_allowed,
                "{\"error\":\"method not allowed\"}",
            ),
        };
    }

    const token = bearerToken(request) orelse
        return respondUnauthorized(request);

    const now = Io.Clock.real.now(app.io).toSeconds();
    jwt.verifyToken(app.allocator, app.jwt_secret, token, now) catch
        return respondUnauthorized(request);

    if (std.mem.eql(u8, path, "/notes")) {
        return switch (method) {
            .GET => listNotes(request, app),
            .POST => createNote(request, app),
            else => respondJson(request, .method_not_allowed, "{\"error\":\"method not allowed\"}"),
        };
    }

    if (std.mem.startsWith(u8, path, "/notes/")) {
        const id_text = path["/notes/".len..];
        const id = std.fmt.parseInt(u32, id_text, 10) catch {
            return respondJson(request, .bad_request, "{\"error\":\"invalid note id\"}");
        };

        return switch (method) {
            .GET => getNote(request, app, id),
            .PUT => updateNote(request, app, id),
            .DELETE => deleteNote(request, app, id),
            else => respondJson(request, .method_not_allowed, "{\"error\":\"method not allowed\"}"),
        };
    }

    return respondJson(request, .not_found, "{\"error\":\"not found\"}");
}

fn createUser(request: *std.http.Server.Request, app: *App) !void {
    const body = readBody(request, app.allocator) catch |err| switch (err) {
        error.BodyTooLarge => return respondJson(
            request,
            .payload_too_large,
            "{\"error\":\"request body is too large\"}",
        ),
        else => return err,
    };
    defer app.allocator.free(body);

    const parsed = json.parseFromSlice(User, app.allocator, body, .{}) catch {
        return respondJson(
            request,
            .bad_request,
            "{\"error\":\"invalid credentials payload\"}",
        );
    };
    defer parsed.deinit();

    const credentials = parsed.value;
    if (credentials.username.len == 0 or credentials.password.len == 0) {
        return respondJson(
            request,
            .bad_request,
            "{\"error\":\"username and password are required\"}",
        );
    }

    var password_hash_buffer: [auth.password_hash_buffer_size]u8 = undefined;
    const password_hash = try auth.hashPassword(
        app.allocator,
        app.io,
        credentials.password,
        &password_hash_buffer,
    );

    var row = (try app.pool.row(
        @embedFile("sql/create_user.sql"),
        .{ credentials.username, password_hash },
    )) orelse {
        return respondJson(
            request,
            .conflict,
            "{\"error\":\"username already exists\"}",
        );
    };
    defer row.deinit() catch {};

    const username = try row.get([]const u8, 0);
    var response: std.ArrayList(u8) = .empty;
    defer response.deinit(app.allocator);
    try response.print(app.allocator, "{f}", .{json.fmt(.{ .username = username }, .{})});

    try respondJson(request, .created, response.items);
}

fn login(request: *std.http.Server.Request, app: *App) !void {
    const body = readBody(request, app.allocator) catch |err| switch (err) {
        error.BodyTooLarge => return respondJson(
            request,
            .payload_too_large,
            "{\"error\":\"request body is too large\"}",
        ),
        else => return err,
    };
    defer app.allocator.free(body);

    const parsed = json.parseFromSlice(User, app.allocator, body, .{}) catch {
        return respondJson(
            request,
            .bad_request,
            "{\"error\":\"invalid credentials payload\"}",
        );
    };
    defer parsed.deinit();

    const credentials = parsed.value;
    if (credentials.username.len == 0 or credentials.password.len == 0) {
        return respondJson(
            request,
            .bad_request,
            "{\"error\":\"username and password are required\"}",
        );
    }

    var row = (try app.pool.row(
        @embedFile("sql/get_user.sql"),
        .{credentials.username},
    )) orelse return respondInvalidUser(request);
    defer row.deinit() catch {};

    const password_hash = try row.get([]const u8, 0);
    if (!auth.verifyPassword(app.allocator, app.io, password_hash, credentials.password)) {
        return respondInvalidUser(request);
    }

    const now = Io.Clock.real.now(app.io).toSeconds();
    const token = try jwt.issueToken(
        app.allocator,
        app.jwt_secret,
        credentials.username,
        now,
    );
    defer app.allocator.free(token);

    var response: std.ArrayList(u8) = .empty;
    defer response.deinit(app.allocator);
    try response.print(app.allocator, "{f}", .{json.fmt(.{
        .token = token,
        .toke_type = "Bearer",
        .expires_in = jwt.token_lifetime_seconds,
    }, .{})});

    try respondJson(request, .ok, response.items);
}

fn bearerToken(request: *const std.http.Server.Request) ?[]const u8 {
    var token: ?[]const u8 = null;
    var headers = request.iterateHeaders();

    const bearer_len = "Bearer ".len;
    while (headers.next()) |header| {
        if (!std.ascii.eqlIgnoreCase(header.name, "authorization")) {
            continue;
        }

        if (token != null) {
            return null;
        }

        if (header.value.len <= bearer_len or
            !std.ascii.eqlIgnoreCase(header.value[0..bearer_len], "Bearer "))
        {
            return null;
        }
        token = header.value[bearer_len..];
    }
    return token;
}

fn respondInvalidUser(request: *std.http.Server.Request) !void {
    try respondJson(
        request,
        .unauthorized,
        "{\"error\":\"invalid username or password\"}",
    );
}

fn respondUnauthorized(request: *std.http.Server.Request) !void {
    try request.respond("{\"error\":\"authentication required\"}", .{
        .status = .unauthorized,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "www-authenticate", .value = "Bearer" },
        },
    });
}

fn listNotes(request: *std.http.Server.Request, app: *App) !void {
    var result = try app.pool.query(@embedFile("sql/list_notes.sql"), .{});
    defer result.deinit();

    var notes: std.ArrayList(Note) = .empty;
    defer notes.deinit(app.allocator);

    while (try result.next()) |row| {
        const id: u32 = @intCast(try row.get(i32, 0));
        try notes.append(app.allocator, .{ .id = id, .text = try row.get([]const u8, 1) });
    }

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(app.allocator);
    try body.print(app.allocator, "{f}", .{json.fmt(notes.items, .{})});
    try respondJson(request, .ok, body.items);
}

fn getNote(request: *std.http.Server.Request, app: *App, id: u32) !void {
    var row = (try app.pool.row(@embedFile("sql/get_note.sql"), .{id})) orelse {
        return respondJson(request, .not_found, "{\"error\":\"note not found\"}");
    };
    defer row.deinit() catch {};

    try respondNote(request, app, &row, .ok);
}

fn createNote(request: *std.http.Server.Request, app: *App) !void {
    const text = try readBody(request, app.allocator);
    defer app.allocator.free(text);
    if (text.len == 0) return respondJson(request, .bad_request, "{\"error\":\"request body is empty\"}");

    var row = (try app.pool.row(@embedFile("sql/create_note.sql"), .{text})) orelse return error.QueryFailed;
    defer row.deinit() catch {};

    try respondNote(request, app, &row, .created);
}

fn updateNote(request: *std.http.Server.Request, app: *App, id: u32) !void {
    const text = try readBody(request, app.allocator);
    defer app.allocator.free(text);
    if (text.len == 0) {
        return respondJson(request, .bad_request, "{\"error\":\"request body is empty\"}");
    }

    var row = (try app.pool.row(@embedFile("sql/update_note.sql"), .{ text, id })) orelse {
        return respondJson(request, .not_found, "{\"error\":\"note not found\"}");
    };
    defer row.deinit() catch {};

    try respondNote(request, app, &row, .ok);
}

fn deleteNote(request: *std.http.Server.Request, app: *App, id: u32) !void {
    const affected = try app.pool.exec(@embedFile("sql/delete_note.sql"), .{id});
    if ((affected orelse 0) == 0) {
        return respondJson(request, .not_found, "{\"error\":\"note not found\"}");
    }
    try respondJson(request, .ok, "{\"deleted\":true}");
}

fn readBody(request: *std.http.Server.Request, allocator: std.mem.Allocator) ![]u8 {
    const length = request.head.content_length orelse return allocator.dupe(u8, "");
    if (length > 1024) return error.BodyTooLarge;

    var body_buffer: [1024]u8 = undefined;
    var reader = try request.readerExpectContinue(&body_buffer);
    return reader.readAlloc(allocator, @intCast(length));
}

fn respondJson(
    request: *std.http.Server.Request,
    status: std.http.Status,
    body: []const u8,
) !void {
    try request.respond(body, .{
        .status = status,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
        },
    });
}

fn respondNote(
    request: *std.http.Server.Request,
    app: *App,
    row: *pg.QueryRow,
    status: std.http.Status,
) !void {
    const id: u32 = @intCast(try row.get(i32, 0));
    const note: Note = .{ .id = id, .text = try row.get([]const u8, 1) };

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(app.allocator);
    try body.print(app.allocator, "{f}", .{json.fmt(note, .{})});
    try respondJson(request, status, body.items);
}
