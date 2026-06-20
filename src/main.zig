const std = @import("std");
const build_options = @import("build_options");

const Io = std.Io;
const net = Io.net;
const json = std.json;

const Note = struct {
    id: u32,
    text: []u8,
};

const App = struct {
    allocator: std.mem.Allocator,
    notes: std.array_hash_map.Auto(u32, Note) = .empty,
    notes_lock: Io.RwLock = .init,
    next_id: u32 = 1,

    fn deinit(app: *App, io: Io) void {
        app.notes_lock.lockUncancelable(io);
        defer app.notes_lock.unlock(io);

        for (app.notes.values()) |note| {
            app.allocator.free(note.text);
        }
        app.notes.deinit(app.allocator);
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

    fn writeNotesJson(app: *App, io: Io, body: *std.ArrayList(u8)) !void {
        app.notes_lock.lockSharedUncancelable(io);
        defer app.notes_lock.unlockShared(io);

        try body.print(app.allocator, "{f}", .{json.fmt(app.notes.values(), .{})});
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
        }
        pool.queue.deinit(pool.allocator);
    }

    fn enqueue(pool: *WorkerPool, stream: net.Stream) !void {
        pool.mutex.lockUncancelable(pool.io);
        defer pool.mutex.unlock(pool.io);

        if (pool.stopping) return error.WorkerPoolStopping;
        try pool.queue.append(pool.allocator, stream);
        pool.condition.signal(pool.io);
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
    const worker_count = if (build_options.concurrent) cpu_count else 1;
    const workers = try WorkerPool.init(init.gpa, init.io, &app, worker_count);
    defer workers.destroy();

    try runServer(init.io, workers, worker_count);
}

fn runServer(io: Io, workers: *WorkerPool, worker_count: usize) !void {
    const address = try net.IpAddress.parse("0.0.0.0", 8080);
    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);

    std.debug.print("Listening on http://0.0.0.0:8080 with {d} workers\n", .{worker_count});

    while (true) {
        const stream = try server.accept(io);
        workers.enqueue(stream) catch {
            stream.close(io);
        };
    }
}

fn handleConnection(io: Io, stream: net.Stream, app: *App) void {
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
    const method = request.head.method;
    const path = request.head.target;

    if (std.mem.eql(u8, path, "/notes")) {
        return switch (method) {
            .GET => listNotes(request, io, app),
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

fn listNotes(request: *std.http.Server.Request, io: Io, app: *App) !void {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(app.allocator);
    try app.writeNotesJson(io, &body);
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
    const text = try readBody(request, app.allocator);
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
    const text = try readBody(request, app.allocator);
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

fn readBody(request: *std.http.Server.Request, allocator: std.mem.Allocator) ![]u8 {
    const length = request.head.content_length orelse return allocator.dupe(u8, "");

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
