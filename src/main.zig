const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    const address = try std.Io.net.IpAddress.parse(
        "127.0.0.1",
        8080,
    );
    const socket = try address.bind(io, .{
        .mode = .dgram,
    });
    defer socket.close(io);

    std.debug.print("UDP Server listening on 127.0.0.1:8080\n", .{});

    while (true) {
        var buffer: [1024]u8 = undefined;
        const message = try socket.receive(
            io,
            &buffer,
        );

        std.debug.print("Received: {s}\n", .{message.data});
        try socket.send(io, &message.from, message.data);
    }
}
