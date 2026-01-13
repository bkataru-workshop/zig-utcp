const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Main library module
    const utcp_mod = b.addModule("utcp", .{
        .root_source_file = b.path("src/utcp.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Unit tests
    const lib_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/utcp.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_lib_tests = b.addRunArtifact(lib_tests);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_lib_tests.step);

    // Example: HTTP client
    const http_example = b.addExecutable(.{
        .name = "http_client",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/http_client.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    http_example.root_module.addImport("utcp", utcp_mod);
    
    const install_http = b.addInstallArtifact(http_example, .{});
    const example_step = b.step("examples", "Build example programs");
    example_step.dependOn(&install_http.step);
    
    const run_http = b.addRunArtifact(http_example);
    run_http.step.dependOn(&install_http.step);
    const run_http_step = b.step("run-http", "Run HTTP client example");
    run_http_step.dependOn(&run_http.step);
}
