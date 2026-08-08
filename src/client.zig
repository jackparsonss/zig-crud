const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const server_address = try std.Io.net.IpAddress.parse(
        "127.0.0.1",
        8080,
    );
    const client_address = try std.Io.net.IpAddress.parse(
        "0.0.0.0",
        0,
    );

    const socket = try client_address.bind(
        io,
        .{ .mode = .dgram },
    );
    defer socket.close(io);

    var stdin_buffer: [1024]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(
        io,
        &stdin_buffer,
    );

    std.debug.print("Type a message or quit\n", .{});

    while (true) {
        std.debug.print("> ", .{});
        const line = try stdin_reader.interface.takeDelimiter('\n') orelse break;

        var request_buffer: [1024]u8 = undefined;
        const request = if (std.mem.eql(u8, line, "PING"))
            line
        else
            try std.fmt.bufPrint(&request_buffer, "ECHO {s}", .{line});

        try socket.send(io, &server_address, request);

        var response_buffer: [1024]u8 = undefined;
        const response = try socket.receive(io, &response_buffer);
        std.debug.print("Server: {s}\n", .{response.data});
    }
}
