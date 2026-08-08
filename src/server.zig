const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const address = try std.Io.net.IpAddress.parse(
        "127.0.0.1",
        8080,
    );
    const socket = try address.bind(
        io,
        .{ .mode = .dgram },
    );
    defer socket.close(io);

    std.debug.print("UDP server listening on 127.0.0.1:8080\n", .{});

    while (true) {
        var buffer: [1024]u8 = undefined;
        const message = try socket.receive(io, &buffer);

        std.debug.print("Received {d} bytes from {f}: {s}\n", .{
            message.data.len,
            message.from,
            message.data,
        });

        try socket.send(io, &message.from, reply(message.data));
    }
}

fn reply(message: []const u8) []const u8 {
    if (std.mem.eql(u8, message, "PING")) {
        return "PONG";
    }

    if (std.mem.startsWith(u8, message, "ECHO ")) {
        return message[5..];
    }

    return "Try: PING or ECHO <message>";
}
