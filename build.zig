const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const server = b.addExecutable(.{
        .name = "udp_server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/server.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{},
        }),
    });

    const client = b.addExecutable(.{
        .name = "udp_client",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/client.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{},
        }),
    });

    b.installArtifact(server);
    b.installArtifact(client);

    const server_step = b.step("server", "Run the UDP server");
    const server_cmd = b.addRunArtifact(server);
    server_step.dependOn(&server_cmd.step);

    const client_step = b.step("client", "Run the UDP client");
    const client_cmd = b.addRunArtifact(client);
    client_step.dependOn(&client_cmd.step);
}
