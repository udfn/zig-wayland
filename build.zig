const std = @import("std");
const zbs = std.Build;
const fs = std.fs;
const mem = std.mem;

pub fn build(b: *zbs) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    if (b.option(bool, "no_build", "Do nothing. Useful when used as a dependency.") orelse false) {
        return;
    }
    const scanner = ScanProtocolsStep.create(b);

    scanner.generate("wl_compositor", 1);
    scanner.generate("wl_shm", 1);
    scanner.generate("wl_seat", 2);
    scanner.generate("wl_output", 1);

    inline for ([_][]const u8{ "globals", "list", "listener", "seats" }) |example| {
        const exe = b.addExecutable(.{ .name = example, .root_source_file = .{ .path = "example/" ++ example ++ ".zig" }, .target = target, .optimize = optimize });
        exe.root_module.addImport("wayland", scanner.module);
        exe.linkSystemLibrary("wayland-client");
        b.installArtifact(exe);
    }

    const exe = b.addExecutable(.{
        .name = "zig-wl-scanner",
        .root_source_file = .{ .path = "src/scanner.zig" },
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run.addArgs(args);
    }
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run.step);

    const test_step = b.step("test", "Run the tests");
    {
        const scanner_tests = b.addTest(.{ .root_source_file = .{ .path = "src/scanner.zig" }, .target = target, .optimize = optimize });

        scanner_tests.root_module.addImport("wayland", scanner.module);

        const run_test = b.addRunArtifact(scanner_tests);

        test_step.dependOn(&run_test.step);
    }
    {
        const ref_all = b.addTest(.{ .root_source_file = .{ .path = "src/ref_all.zig" }, .target = target, .optimize = optimize });

        ref_all.root_module.addImport("wayland", scanner.module);
        ref_all.linkLibC();
        ref_all.linkSystemLibrary("wayland-server");
        ref_all.linkSystemLibrary("wayland-egl");
        ref_all.linkSystemLibrary("wayland-cursor");
        const run_test = b.addRunArtifact(ref_all);

        test_step.dependOn(&run_test.step);
    }
}

pub const ScanProtocolsStep = struct {
    const Target = struct {
        name: []const u8,
        version: u32,
    };

    /// Absolute paths to protocol xml
    protocol_paths: std.ArrayListUnmanaged(zbs.LazyPath),
    run_scanner: *std.Build.Step.Run,

    wayland_dir: []const u8,
    wayland_protocols_dir: []const u8,

    module: *std.Build.Module,
    pub fn create(builder: *zbs) *ScanProtocolsStep {
        const ally = builder.allocator;
        const self = ally.create(ScanProtocolsStep) catch oom();
        const scanner_exe = builder.addExecutable(.{
            .name = "zig-wl-scanner",
            .root_source_file = builder.path("src/scanner.zig"),
            .optimize = .ReleaseSmall,
            .target = builder.host,
        });
        const run_scanner = builder.addRunArtifact(scanner_exe);
        self.* = .{
            .module = builder.createModule(.{
                .root_source_file = run_scanner.addPrefixedOutputFileArg("-O", "wayland.zig"),
                .link_libc = true,
            }),
            .protocol_paths = .{},
            .run_scanner = run_scanner,
            .wayland_dir = mem.trim(u8, builder.run(&[_][]const u8{ "pkg-config", "--variable=pkgdatadir", "wayland-scanner" }), &std.ascii.whitespace),
            .wayland_protocols_dir = mem.trim(u8, builder.run(&[_][]const u8{ "pkg-config", "--variable=pkgdatadir", "wayland-protocols" }), &std.ascii.whitespace),
        };
        run_scanner.addPrefixedFileArg("-P", .{ .cwd_relative = fs.path.join(ally, &[_][]const u8{ self.wayland_dir, "wayland.xml" }) catch @panic("OOM") });
        return self;
    }

    /// Scan the protocol xml at the given absolute or relative path
    pub fn addProtocolPath(self: *ScanProtocolsStep, path: zbs.LazyPath) void {
        self.protocol_paths.append(self.run_scanner.step.owner.allocator, path) catch @panic("OOM");
        self.run_scanner.addPrefixedFileArg("-P", path);
    }

    /// Scan the protocol xml provided by the wayland-protocols
    /// package given the relative path (e.g. "stable/xdg-shell/xdg-shell.xml")
    pub fn addSystemProtocol(self: *ScanProtocolsStep, relative_path: []const u8) void {
        const absolute_path = fs.path.join(self.run_scanner.step.owner.allocator, &[_][]const u8{ self.wayland_protocols_dir, relative_path }) catch @panic("OOM");
        self.protocol_paths.append(self.run_scanner.step.owner.allocator, .{ .cwd_relative = absolute_path }) catch @panic("OOM");
        self.run_scanner.addPrefixedFileArg("-P", .{ .cwd_relative = absolute_path });
    }

    /// Generate code for the given global interface at the given version,
    /// as well as all interfaces that can be created using it at that version.
    /// If the version found in the protocol xml is less than the requested version,
    /// an error will be printed and code generation will fail.
    /// Code is always generated for wl_display, wl_registry, wl_callback, and wl_buffer.
    pub fn generate(self: *ScanProtocolsStep, global_interface: []const u8, version: u32) void {
        self.run_scanner.addArg(std.fmt.allocPrint(self.run_scanner.step.owner.allocator, "-T{s}:{}", .{ global_interface, version }) catch @panic("OOM"));
    }
};

fn oom() noreturn {
    @panic("out of memory");
}
