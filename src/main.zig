const std = @import("std");
const build_options = @import("build_options");

const Io = std.Io;
const net = Io.net;
const json = std.json;

const max_connections = 12_000;
const min_worker_count = 4;
const max_worker_count = 128;
const max_page_size = 100;

const Note = struct {
    id: u32,
    text: []u8,
};

const Page = struct {
    offset: usize = 0,
    limit: usize = 20,
};

const App = struct {
    allocator: std.mem.Allocator,
    notes: std.array_hash_map.Auto(u32, Note) = .empty,
    notes_lock: Io.RwLock = .init,
    next_id: u32 = 1,
    active_connections: std.atomic.Value(usize) = .init(0),

    fn deinit(app: *App, io: Io) void {
        app.notes_lock.lockUncancelable(io);
        defer app.notes_lock.unlock(io);

        for (app.notes.values()) |note| {
            app.allocator.free(note.text);
        }
        app.notes.deinit(app.allocator);
    }

    fn tryAcquireConnection(app: *App) bool {
        const previous = app.active_connections.fetchAdd(1, .acq_rel);
        if (previous < max_connections) return true;

        _ = app.active_connections.fetchSub(1, .acq_rel);
        return false;
    }

    fn releaseConnection(app: *App) void {
        _ = app.active_connections.fetchSub(1, .acq_rel);
    }

    fn createNote(app: *App, io: Io, text: []const u8) !u32 {
        const owned_text = try app.allocator.dupe(u8, text);
        errdefer app.allocator.free(owned_text);

        app.notes_lock.lockUncancelable(io);
        defer app.notes_lock.unlock(io);

        const id = app.next_id;
        app.next_id +%= 1;
        if (app.next_id == 0) return error.NoteIdExhausted;

        try app.notes.put(app.allocator, id, .{ .id = id, .text = owned_text });
        return id;
    }

    fn writeNoteJson(app: *App, io: Io, id: u32, body: *std.ArrayList(u8)) !bool {
        app.notes_lock.lockSharedUncancelable(io);
        defer app.notes_lock.unlockShared(io);

        const note = app.notes.get(id) orelse return false;
        try body.print(app.allocator, "{f}", .{json.fmt(note, .{})});
        return true;
    }

    fn writeNotesJson(app: *App, io: Io, page: Page, body: *std.ArrayList(u8)) !void {
        app.notes_lock.lockSharedUncancelable(io);
        defer app.notes_lock.unlockShared(io);

        const notes = app.notes.values();
        const start = @min(page.offset, notes.len);
        const end = @min(start + page.limit, notes.len);

        try body.append(app.allocator, '[');
        for (notes[start..end], 0..) |note, index| {
            if (index != 0) try body.append(app.allocator, ',');
            try body.print(app.allocator, "{f}", .{json.fmt(note, .{})});
        }
        try body.append(app.allocator, ']');
    }

    fn updateNote(app: *App, io: Io, id: u32, text: []const u8) !bool {
        const owned_text = try app.allocator.dupe(u8, text);
        errdefer app.allocator.free(owned_text);

        app.notes_lock.lockUncancelable(io);
        defer app.notes_lock.unlock(io);

        const note = app.notes.getPtr(id) orelse return false;
        app.allocator.free(note.text);
        note.text = owned_text;
        return true;
    }

    fn deleteNote(app: *App, io: Io, id: u32) bool {
        app.notes_lock.lockUncancelable(io);
        defer app.notes_lock.unlock(io);

        const note = app.notes.get(id) orelse return false;
        app.allocator.free(note.text);
        return app.notes.swapRemove(id);
    }

    fn count(app: *App, io: Io) usize {
        app.notes_lock.lockSharedUncancelable(io);
        defer app.notes_lock.unlockShared(io);
        return app.notes.count();
    }
};

const WorkerPool = struct {
    allocator: std.mem.Allocator,
    io: Io,
    app: *App,
    queue: std.ArrayList(net.Stream) = .empty,
    mutex: Io.Mutex = .init,
    condition: Io.Condition = .init,
    stopping: bool = false,
    threads: []std.Thread = &.{},
    started_threads: usize = 0,

    fn init(allocator: std.mem.Allocator, io: Io, app: *App, worker_count: usize) !*WorkerPool {
        const pool = try allocator.create(WorkerPool);
        pool.* = .{
            .allocator = allocator,
            .io = io,
            .app = app,
        };
        errdefer {
            pool.deinit();
            allocator.destroy(pool);
        }

        try pool.queue.ensureTotalCapacity(allocator, max_connections);
        pool.threads = try allocator.alloc(std.Thread, worker_count);

        for (pool.threads) |*thread| {
            thread.* = try std.Thread.spawn(.{}, workerMain, .{pool});
            pool.started_threads += 1;
        }
        return pool;
    }

    fn destroy(pool: *WorkerPool) void {
        const allocator = pool.allocator;
        pool.deinit();
        allocator.destroy(pool);
    }

    fn deinit(pool: *WorkerPool) void {
        pool.mutex.lockUncancelable(pool.io);
        pool.stopping = true;
        pool.condition.broadcast(pool.io);
        pool.mutex.unlock(pool.io);

        for (pool.threads[0..pool.started_threads]) |thread| {
            thread.join();
        }
        if (pool.threads.len != 0) pool.allocator.free(pool.threads);

        for (pool.queue.items) |stream| {
            stream.close(pool.io);
            pool.app.releaseConnection();
        }
        pool.queue.deinit(pool.allocator);
    }

    fn enqueue(pool: *WorkerPool, stream: net.Stream) bool {
        pool.mutex.lockUncancelable(pool.io);
        defer pool.mutex.unlock(pool.io);

        if (pool.stopping or pool.queue.items.len == max_connections) return false;
        pool.queue.appendAssumeCapacity(stream);
        pool.condition.signal(pool.io);
        return true;
    }

    fn take(pool: *WorkerPool) ?net.Stream {
        pool.mutex.lockUncancelable(pool.io);
        defer pool.mutex.unlock(pool.io);

        while (pool.queue.items.len == 0 and !pool.stopping) {
            pool.condition.waitUncancelable(pool.io, &pool.mutex);
        }
        if (pool.queue.items.len == 0) return null;
        return pool.queue.swapRemove(0);
    }

    fn workerMain(pool: *WorkerPool) void {
        while (pool.take()) |stream| {
            handleConnection(pool.io, stream, pool.app);
        }
    }
};

pub fn main(init: std.process.Init) !void {
    var app: App = .{ .allocator = init.gpa };
    defer app.deinit(init.io);

    const cpu_count = std.Thread.getCpuCount() catch 1;
    const worker_count = if (build_options.concurrent)
        @min(@max(cpu_count * 4, min_worker_count), max_worker_count)
    else
        1;
    const workers = try WorkerPool.init(init.gpa, init.io, &app, worker_count);
    defer workers.destroy();

    try runServer(init.io, &app, workers, worker_count);
}

fn runServer(io: Io, app: *App, workers: *WorkerPool, worker_count: usize) !void {
    const address = try net.IpAddress.parse("0.0.0.0", 8080);
    var server = try address.listen(io, .{
        .reuse_address = true,
        .kernel_backlog = 16_384,
    });
    defer server.deinit(io);

    std.debug.print("Listening on http://0.0.0.0:8080 with {d} workers\n", .{worker_count});

    while (true) {
        const stream = try server.accept(io);
        if (!app.tryAcquireConnection()) {
            stream.close(io);
            continue;
        }
        if (!workers.enqueue(stream)) {
            app.releaseConnection();
            stream.close(io);
        }
    }
}

fn handleConnection(io: Io, stream: net.Stream, app: *App) void {
    defer app.releaseConnection();
    defer stream.close(io);

    var read_buffer: [4096]u8 = undefined;
    var write_buffer: [4096]u8 = undefined;
    var connection_reader = stream.reader(io, &read_buffer);
    var connection_writer = stream.writer(io, &write_buffer);
    var server = std.http.Server.init(&connection_reader.interface, &connection_writer.interface);

    if (server.reader.state == .ready) {
        var request = server.receiveHead() catch |err| switch (err) {
            error.HttpConnectionClosing => return,
            else => {
                std.debug.print("failed to read request: {t}\n", .{err});
                return;
            },
        };

        route(&request, io, app) catch |err| {
            std.debug.print("failed to serve {s}: {t}\n", .{ request.head.target, err });
            return;
        };
    }
}

fn route(request: *std.http.Server.Request, io: Io, app: *App) !void {
    const target = request.head.target;
    const query_start = std.mem.indexOfScalar(u8, target, '?');
    const path = target[0..(query_start orelse target.len)];
    const query = if (query_start) |start| target[start + 1 ..] else "";
    const method = request.head.method;

    if (std.mem.eql(u8, path, "/notes")) {
        return switch (method) {
            .GET => listNotes(request, io, app, query),
            .POST => createNote(request, io, app),
            else => respondJson(request, .method_not_allowed, "{\"error\":\"method not allowed\"}"),
        };
    }

    if (std.mem.startsWith(u8, path, "/notes/")) {
        const id_text = path["/notes/".len..];
        const id = std.fmt.parseInt(u32, id_text, 10) catch {
            return respondJson(request, .bad_request, "{\"error\":\"invalid note id\"}");
        };

        return switch (method) {
            .GET => getNote(request, io, app, id),
            .PUT => updateNote(request, io, app, id),
            .DELETE => deleteNote(request, io, app, id),
            else => respondJson(request, .method_not_allowed, "{\"error\":\"method not allowed\"}"),
        };
    }

    return respondJson(request, .not_found, "{\"error\":\"not found\"}");
}

fn listNotes(request: *std.http.Server.Request, io: Io, app: *App, query: []const u8) !void {
    const page = parsePage(query) catch {
        return respondJson(request, .bad_request, "{\"error\":\"invalid pagination\"}");
    };

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(app.allocator);
    try app.writeNotesJson(io, page, &body);
    try respondJson(request, .ok, body.items);
}

fn getNote(request: *std.http.Server.Request, io: Io, app: *App, id: u32) !void {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(app.allocator);

    if (!try app.writeNoteJson(io, id, &body)) {
        return respondJson(request, .not_found, "{\"error\":\"note not found\"}");
    }

    try respondJson(request, .ok, body.items);
}

fn createNote(request: *std.http.Server.Request, io: Io, app: *App) !void {
    const text = readBody(request, app.allocator) catch |err| switch (err) {
        error.BodyTooLarge => return respondJson(request, .payload_too_large, "{\"error\":\"request body is too large\"}"),
        else => return err,
    };
    defer app.allocator.free(text);

    if (text.len == 0) {
        return respondJson(request, .bad_request, "{\"error\":\"request body is empty\"}");
    }

    const id = try app.createNote(io, text);
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(app.allocator);
    _ = try app.writeNoteJson(io, id, &body);
    try respondJson(request, .created, body.items);
}

fn updateNote(request: *std.http.Server.Request, io: Io, app: *App, id: u32) !void {
    const text = readBody(request, app.allocator) catch |err| switch (err) {
        error.BodyTooLarge => return respondJson(request, .payload_too_large, "{\"error\":\"request body is too large\"}"),
        else => return err,
    };
    defer app.allocator.free(text);

    if (text.len == 0) {
        return respondJson(request, .bad_request, "{\"error\":\"request body is empty\"}");
    }

    if (!try app.updateNote(io, id, text)) {
        return respondJson(request, .not_found, "{\"error\":\"note not found\"}");
    }

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(app.allocator);
    _ = try app.writeNoteJson(io, id, &body);
    try respondJson(request, .ok, body.items);
}

fn deleteNote(request: *std.http.Server.Request, io: Io, app: *App, id: u32) !void {
    if (!app.deleteNote(io, id)) {
        return respondJson(request, .not_found, "{\"error\":\"note not found\"}");
    }

    try respondJson(request, .ok, "{\"deleted\":true}");
}

fn parsePage(query: []const u8) !Page {
    if (query.len == 0) return .{};

    var page = Page{};
    var seen_offset = false;
    var seen_limit = false;
    var fields = std.mem.splitScalar(u8, query, '&');
    while (fields.next()) |field| {
        const separator = std.mem.indexOfScalar(u8, field, '=') orelse return error.InvalidPagination;
        const key = field[0..separator];
        const value = field[separator + 1 ..];

        if (std.mem.eql(u8, key, "offset") and !seen_offset) {
            page.offset = std.fmt.parseInt(usize, value, 10) catch return error.InvalidPagination;
            seen_offset = true;
        } else if (std.mem.eql(u8, key, "limit") and !seen_limit) {
            page.limit = std.fmt.parseInt(usize, value, 10) catch return error.InvalidPagination;
            if (page.limit == 0 or page.limit > max_page_size) return error.InvalidPagination;
            seen_limit = true;
        } else {
            return error.InvalidPagination;
        }
    }
    return page;
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
