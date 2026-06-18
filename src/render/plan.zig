const std = @import("std");

pub const ArtifactNode = struct {
    key: []const u8,
    cached: bool = false,
};

pub const PageNode = struct {
    index: usize,
    hash: u64,
    artifact_deps: []const usize = &.{},
    cached: bool = false,
};

pub const Plan = struct {
    artifacts: []const ArtifactNode = &.{},
    pages: []const PageNode = &.{},
};
