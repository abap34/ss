const std = @import("std");
const manifest_hash_bytes = 12;

pub const TreeSitterManifest = struct {
    schema: u32,
    runtime: Runtime,
    languages: []const Language,

    const Runtime = struct {
        repo: []const u8,
        commit: []const u8,
    };

    pub const Language = struct {
        name: []const u8,
        display_name: []const u8,
        repo: []const u8,
        commit: []const u8,
        aliases: []const []const u8,
        files: []const File,
    };

    const File = struct {
        from: []const u8,
        to: []const u8,
    };
};

pub fn parse(allocator: std.mem.Allocator, text: []const u8) TreeSitterManifest {
    const manifest = std.json.parseFromSliceLeaky(TreeSitterManifest, allocator, text, .{ .ignore_unknown_fields = true }) catch |err|
        std.debug.panic("failed to parse tree-sitter bundle metadata: {}", .{err});
    validateTreeSitterManifest(manifest);
    return manifest;
}

fn validateTreeSitterManifest(manifest: TreeSitterManifest) void {
    if (manifest.schema != 1) @panic("unsupported tree-sitter language manifest schema.");
    if (!isCommitHash(manifest.runtime.commit)) @panic("tree-sitter runtime commit must be a 40-character hash.");
    if (manifest.languages.len == 0) @panic("tree-sitter language manifest must list at least one language.");
    for (manifest.languages) |language| {
        if (language.name.len == 0 or language.display_name.len == 0) {
            @panic("tree-sitter language manifest has an empty language name.");
        }
        if (language.repo.len == 0 or !isCommitHash(language.commit)) {
            std.debug.panic("tree-sitter language manifest has an invalid commit: {s}", .{language.name});
        }
        if (language.aliases.len == 0 or language.files.len == 0) {
            std.debug.panic("tree-sitter language manifest entry is incomplete: {s}", .{language.name});
        }
        for (language.files) |file| {
            rejectUnsafeManifestPath(file.from, "tree-sitter source path");
            rejectUnsafeManifestPath(file.to, "tree-sitter destination path");
        }
    }
}

fn isCommitHash(value: []const u8) bool {
    if (value.len != 40) return false;
    for (value) |byte| {
        if (!std.ascii.isHex(byte)) return false;
    }
    return true;
}

fn rejectUnsafeManifestPath(value: []const u8, label: []const u8) void {
    if (value.len == 0 or std.fs.path.isAbsolute(value)) {
        std.debug.panic("{s} must be relative and non-empty: {s}", .{ label, value });
    }
    var parts = std.mem.tokenizeAny(u8, value, "/\\");
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, "..")) {
            std.debug.panic("{s} must stay inside its root: {s}", .{ label, value });
        }
    }
}

pub fn hash(allocator: std.mem.Allocator, manifest_text: []const u8) []const u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(manifest_text, &digest, .{});
    var out = allocator.alloc(u8, manifest_hash_bytes * 2) catch @panic("OOM");
    for (digest[0..manifest_hash_bytes], 0..) |byte, index| {
        out[index * 2] = hexDigit(byte >> 4);
        out[index * 2 + 1] = hexDigit(byte & 0x0f);
    }
    return out;
}

fn hexDigit(value: u8) u8 {
    return if (value < 10) '0' + value else 'a' + (value - 10);
}
