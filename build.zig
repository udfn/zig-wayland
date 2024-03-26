const std = @import("std");
const zbs = std.Build;
const fs = std.fs;
const mem = std.mem;

pub fn build(b: *zbs) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const scanner = ScanProtocolsStep.create(b);

    scanner.generate("wl_compositor", 1);
    scanner.generate("wl_shm", 1);
    scanner.generate("wl_seat", 2);
    scanner.generate("wl_output", 1);
    // HACKHACK! For some reason building this requires this hack.
    // But.. why?
    const incdir = mem.trim(u8, b.run(
        &[_][]const u8{ "pkg-config", "--cflags-only-I", "wayland-client" }),
        &std.ascii.whitespace);
    scanner.module.addIncludePath(.{ .cwd_relative = incdir[2..]});


    inline for ([_][]const u8{ "globals", "list", "listener", "seats" }) |example| {
        const exe = b.addExecutable(.{
            .name = example,
            .root_source_file = .{.path = "example/" ++ example ++ ".zig"},
            .target = target,
            .optimize = optimize
        });
        exe.root_module.addImport("wayland", scanner.module);
        exe.linkSystemLibrary("wayland-client");
        b.installArtifact(exe);
    }

    const test_step = b.step("test", "Run the tests");
    {
        const scanner_tests = b.addTest(.{
            .root_source_file = .{ .path = "src/scanner.zig"},
            .target = target,
            .optimize = optimize
        });

        scanner_tests.root_module.addImport("wayland", scanner.module);

        const run_test = b.addRunArtifact(scanner_tests);

        test_step.dependOn(&run_test.step);
    }
    {
        const ref_all = b.addTest(.{
            .root_source_file = .{ .path = "src/ref_all.zig"},
            .target = target,
            .optimize = optimize
        });

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
    const scanner = @import("src/scanner.zig");

    step: zbs.Step,
    result: zbs.GeneratedFile,

    /// Absolute paths to protocol xml
    protocol_paths: std.ArrayList([]const u8),
    /// Paths relative to the system wayland-protocol directory
    system_protocols: std.ArrayList([]const u8),
    targets: std.ArrayList(scanner.Target),
    wayland_dir:[]const u8,
    wayland_protocols_dir:[]const u8,

    module: *std.Build.Module,
    pub fn create(builder: *zbs) *ScanProtocolsStep {
        const ally = builder.allocator;
        const self = ally.create(ScanProtocolsStep) catch oom();
        self.* = .{
            .step = zbs.Step.init(.{
                .id = .custom,
                .name = "Scan Protocols",
                .owner = builder,
                .makeFn = make
            }),
            .module = builder.createModule(.{
                .link_libc = true,
                .root_source_file = .{ .generated = &self.result},
            }),
            .result = .{ .step = &self.step, .path = null },
            .protocol_paths = std.ArrayList([]const u8).init(ally),
            .system_protocols = std.ArrayList([]const u8).init(ally),
            .targets = std.ArrayList(scanner.Target).init(ally),
            .wayland_dir = mem.trim(u8, builder.run(
                &[_][]const u8{ "pkg-config", "--variable=pkgdatadir", "wayland-scanner" }),
                &std.ascii.whitespace),
            .wayland_protocols_dir = mem.trim(u8, builder.run(
                &[_][]const u8{ "pkg-config", "--variable=pkgdatadir", "wayland-protocols" }),
                &std.ascii.whitespace),
        };
        return self;
    }

    /// Scan the protocol xml at the given absolute or relative path
    pub fn addProtocolPath(self: *ScanProtocolsStep, path: []const u8) void {
        self.protocol_paths.append(path) catch oom();
    }

    /// Scan the protocol xml provided by the wayland-protocols
    /// package given the relative path (e.g. "stable/xdg-shell/xdg-shell.xml")
    pub fn addSystemProtocol(self: *ScanProtocolsStep, relative_path: []const u8) void {
        self.system_protocols.append(relative_path) catch oom();
    }

    /// Generate code for the given global interface at the given version,
    /// as well as all interfaces that can be created using it at that version.
    /// If the version found in the protocol xml is less than the requested version,
    /// an error will be printed and code generation will fail.
    /// Code is always generated for wl_display, wl_registry, wl_callback, and wl_buffer.
    pub fn generate(self: *ScanProtocolsStep, global_interface: []const u8, version: u32) void {
        self.targets.append(.{ .name = global_interface, .version = version }) catch oom();
    }

    fn make(step: *zbs.Step, progress:*std.Progress.Node) !void {
        _ = progress;
        const self = @fieldParentPtr(ScanProtocolsStep, "step", step);
        const ally = step.owner.allocator;

        var man = step.owner.graph.cache.obtain();
        defer man.deinit();
        man.hash.addBytes("134995asdfbbc");

        const wayland_xml = try fs.path.join(ally, &[_][]const u8{ self.wayland_dir, "wayland.xml" });
        try self.protocol_paths.append(wayland_xml);

        for (self.system_protocols.items) |relative_path| {
            const absolute_path = try fs.path.join(ally, &[_][]const u8{ self.wayland_protocols_dir, relative_path });
            try self.protocol_paths.append(absolute_path);
        }
        for (self.protocol_paths.items) |protocol_path| {
            _ = try man.addFile(protocol_path, null);
        }
        for (self.targets.items) |target| {
            man.hash.addBytes(target.name);
            man.hash.add(target.version);
        }
        const cache_hit = try step.cacheHit(&man);
        const digest = man.final();
        const out_path = try step.owner.cache_root.join(step.owner.allocator, &.{"zig-wayland", &digest });
        if (!cache_hit) {
            var root_dir = try fs.cwd().openDir(step.owner.build_root.path.?, .{});
            defer root_dir.close();
            var out_dir = try root_dir.makeOpenPath(out_path, .{});
            defer out_dir.close();
            try scanner.scan(root_dir, out_dir, self.protocol_paths.items, self.targets.items);
        }

        // Once https://github.com/ziglang/zig/issues/131 is implemented
        // we can stop generating/linking C code.
        for (self.protocol_paths.items) |protocol_path| {
            const code_path = self.getCodePath(protocol_path, &digest);
            if (!cache_hit) {
                _ = step.owner.run(
                    &[_][]const u8{ "wayland-scanner", "private-code", protocol_path, code_path },
                );
            }
            self.module.addCSourceFile(.{.file = .{.path = code_path}, .flags = &.{"-std=c99"}});
        }
        if (!cache_hit) {
            try man.writeManifest();
        }

        self.result.path = try fs.path.join(ally, &[_][]const u8{ out_path, "wayland.zig" });
    }

    fn getCodePath(self: *ScanProtocolsStep, xml_in_path: []const u8, digest: []const u8) []const u8 {
        const ally = self.step.owner.allocator;
        // Extension is .xml, so slice off the last 4 characters
        const basename = fs.path.basename(xml_in_path);
        const basename_no_ext = basename[0..(basename.len - 4)];
        const code_filename = std.fmt.allocPrint(ally, "{s}-protocol.c", .{basename_no_ext}) catch oom();
        return fs.path.join(ally, &[_][]const u8{
            self.step.owner.cache_root.path.?,
            "zig-wayland",
            digest,
            code_filename,
        }) catch oom();
    }
};

fn oom() noreturn {
    @panic("out of memory");
}
