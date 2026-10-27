const std = @import("std");
const project = @import("modules.zig");
const compat = @import("compat.zig");

pub fn configure(ctx: project.Context, utils: *std.Build.Module) void {
    const enabled = ctx.b.option(bool, "profiling", "Enable the optional Perfetto recording SDK") orelse false;
    const manifest_text = compat.readFile(ctx.b, "third_party/perfetto/manifest.json", .limited(64 * 1024)) catch
        @panic("cannot read third_party/perfetto/manifest.json");
    const manifest = std.json.parseFromSlice(std.json.Value, ctx.b.allocator, manifest_text, .{}) catch
        @panic("invalid Perfetto SDK manifest");
    const version = manifest.value.object.get("version").?.string;
    const options = ctx.b.addOptions();
    options.addOption(bool, "enabled", enabled);
    options.addOption([]const u8, "sdk", ctx.b.fmt("Perfetto v{s}", .{version}));
    utils.addOptions("profiling_options", options);
    if (!enabled) return;
    const source_root = "third_party/perfetto/sdk";
    var files = manifest.value.object.get("files").?.object.iterator();
    while (files.next()) |file| {
        const path = ctx.b.fmt("{s}/{s}", .{ source_root, file.key_ptr.* });
        const bytes = compat.readFile(ctx.b, path, .limited(16 * 1024 * 1024)) catch
            @panic("Perfetto SDK is missing. Run: python3 third_party/perfetto/tools/fetch.py");
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
        if (!std.mem.eql(u8, &std.fmt.bytesToHex(hash, .lower), file.value_ptr.string))
            @panic("Perfetto SDK differs from its manifest. Run: python3 third_party/perfetto/tools/fetch.py --check");
    }
    const native = ctx.b.createModule(.{
        .target = ctx.target,
        .optimize = .ReleaseFast,
        .link_libc = true,
        .link_libcpp = true,
    });
    native.addIncludePath(ctx.b.path(source_root));
    native.addCSourceFile(.{ .file = ctx.b.path(source_root ++ "/perfetto.cc"), .flags = &.{ "-std=c++17", "-DPERFETTO_SDK_WITH_SYSTEM_CONSUMER=0" } });
    native.addCSourceFile(.{ .file = ctx.b.path("src/utils/profiling/backend.cpp"), .flags = &.{"-std=c++17"} });
    const library = ctx.b.addLibrary(.{ .name = "ss-profiling", .root_module = native, .linkage = .static });
    utils.linkLibrary(library);
}
