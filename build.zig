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

    // Documentation generation
    const docs = b.addObject(.{
        .name = "utcp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/utcp.zig"),
            .target = target,
            .optimize = .Debug,
        }),
    });
    const install_docs = b.addInstallDirectory(.{
        .source_dir = docs.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    const docs_step = b.step("docs", "Generate API documentation");
    docs_step.dependOn(&install_docs.step);

    // Benchmarks
    const bench_exe = b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/bench.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });
    bench_exe.root_module.addImport("utcp", utcp_mod);
    const run_bench = b.addRunArtifact(bench_exe);
    const bench_step = b.step("bench", "Run performance benchmarks");
    bench_step.dependOn(&run_bench.step);

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

    // Example: CLI client
    const cli_example = b.addExecutable(.{
        .name = "cli_client",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/cli_client.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    cli_example.root_module.addImport("utcp", utcp_mod);
    
    const install_cli = b.addInstallArtifact(cli_example, .{});
    example_step.dependOn(&install_cli.step);
    
    const run_cli = b.addRunArtifact(cli_example);
    run_cli.step.dependOn(&install_cli.step);
    const run_cli_step = b.step("run-cli", "Run CLI client example");
    run_cli_step.dependOn(&run_cli.step);

    // Example: MCP client
    const mcp_example = b.addExecutable(.{
        .name = "mcp_client",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/mcp_client.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    mcp_example.root_module.addImport("utcp", utcp_mod);
    
    const install_mcp = b.addInstallArtifact(mcp_example, .{});
    example_step.dependOn(&install_mcp.step);
    
    const run_mcp = b.addRunArtifact(mcp_example);
    run_mcp.step.dependOn(&install_mcp.step);
    if (b.args) |args| {
        run_mcp.addArgs(args);
    }
    const run_mcp_step = b.step("run-mcp", "Run MCP client example");
    run_mcp_step.dependOn(&run_mcp.step);

    // Example: Streaming
    const streaming_example = b.addExecutable(.{
        .name = "streaming_example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/streaming_example.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    streaming_example.root_module.addImport("utcp", utcp_mod);

    const install_streaming = b.addInstallArtifact(streaming_example, .{});
    example_step.dependOn(&install_streaming.step);

    const run_streaming = b.addRunArtifact(streaming_example);
    run_streaming.step.dependOn(&install_streaming.step);
    const run_streaming_step = b.step("run-streaming", "Run streaming example");
    run_streaming_step.dependOn(&run_streaming.step);

    // Example: Post-processors
    const postproc_example = b.addExecutable(.{
        .name = "postprocessor_example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/postprocessor_example.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    postproc_example.root_module.addImport("utcp", utcp_mod);

    const install_postproc = b.addInstallArtifact(postproc_example, .{});
    example_step.dependOn(&install_postproc.step);

    const run_postproc = b.addRunArtifact(postproc_example);
    run_postproc.step.dependOn(&install_postproc.step);
    const run_postproc_step = b.step("run-postproc", "Run post-processor example");
    run_postproc_step.dependOn(&run_postproc.step);

    // Example: OAuth2
    const oauth2_example = b.addExecutable(.{
        .name = "oauth2_example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/oauth2_example.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    oauth2_example.root_module.addImport("utcp", utcp_mod);

    const install_oauth2 = b.addInstallArtifact(oauth2_example, .{});
    example_step.dependOn(&install_oauth2.step);

    const run_oauth2 = b.addRunArtifact(oauth2_example);
    run_oauth2.step.dependOn(&install_oauth2.step);
    const run_oauth2_step = b.step("run-oauth2", "Run OAuth2 example");
    run_oauth2_step.dependOn(&run_oauth2.step);

    // CLI Tool
    const cli_exe = b.addExecutable(.{
        .name = "utcp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    cli_exe.root_module.addImport("utcp", utcp_mod);

    const install_cli_tool = b.addInstallArtifact(cli_exe, .{});
    const cli_step = b.step("cli", "Build UTCP CLI tool");
    cli_step.dependOn(&install_cli_tool.step);

    const run_utcp_cli = b.addRunArtifact(cli_exe);
    run_utcp_cli.step.dependOn(&install_cli_tool.step);
    if (b.args) |args| {
        run_utcp_cli.addArgs(args);
    }
    const run_utcp_step = b.step("run-utcp", "Run UTCP CLI tool");
    run_utcp_step.dependOn(&run_utcp_cli.step);
}
