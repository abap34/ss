const std = @import("std");
const core = @import("core");
const render = @import("render");
const resources_compile = @import("render_resources");

const Allocator = std.mem.Allocator;

const MathSpec = struct {
    old_id: render.MathTreeId,
    input_kind: render.MathInputKind,
    source: []u8,

    fn deinit(self: *MathSpec, allocator: Allocator) void {
        allocator.free(self.source);
    }
};

const MathMapping = struct {
    old: render.MathTreeId,
    new: render.MathTreeId,
};

const Entry = struct {
    page_id: core.NodeId,
    index: usize,
    width: f64,
    height: f64,
    content: *render.PageContent,
    dependencies: []resources_compile.SourceDependency,
    resources: []render.ResourceId,
    fonts: []render.FontInstanceId,
    math: []MathSpec,
    last_used: u64,
    document_epoch: u64,
    byte_size: usize,

    fn deinit(self: *Entry, allocator: Allocator) void {
        self.content.release();
        resources_compile.deinitSourceDependencies(allocator, self.dependencies);
        allocator.free(self.resources);
        allocator.free(self.fonts);
        for (self.math) |*spec| spec.deinit(allocator);
        allocator.free(self.math);
    }
};

const CachedResource = struct {
    value: render.Resource,
    references: usize,
    byte_size: usize,
};

const CachedFont = struct {
    value: render.FontInstance,
    references: usize,
    byte_size: usize,
};

pub const Cache = struct {
    allocator: Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    entries: std.AutoHashMap(u64, Entry),
    resources: std.AutoHashMap(render.ResourceId, CachedResource),
    fonts: std.AutoHashMap(render.FontInstanceId, CachedFont),
    access_clock: u64 = 0,
    entry_limit: usize = min_entries,
    page_bytes: usize = 0,
    resource_bytes: usize = 0,
    font_bytes: usize = 0,
    document_epoch: u64 = 0,

    const min_entries = 256;
    const max_page_bytes = 256 * 1024 * 1024;
    const max_resource_bytes = 512 * 1024 * 1024;
    const max_font_bytes = 32 * 1024 * 1024;

    pub fn init(allocator: Allocator, io: std.Io) Cache {
        return .{
            .allocator = allocator,
            .io = io,
            .entries = std.AutoHashMap(u64, Entry).init(allocator),
            .resources = std.AutoHashMap(render.ResourceId, CachedResource).init(allocator),
            .fonts = std.AutoHashMap(render.FontInstanceId, CachedFont).init(allocator),
        };
    }

    pub fn beginDocument(self: *Cache, page_count: usize) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.document_epoch +%= 1;
        if (self.document_epoch == 0) self.document_epoch = 1;
        self.entry_limit = @max(min_entries, page_count);
        while (self.entries.count() > self.entry_limit) _ = self.evictLeastRecentlyUsed(false);
    }

    pub fn deinit(self: *Cache) void {
        self.clear();
        self.entries.deinit();
        self.resources.deinit();
        self.fonts.deinit();
        self.* = undefined;
    }

    pub fn put(
        self: *Cache,
        key: u64,
        page_allocator: Allocator,
        page: *render.Page,
        resource_graph: *const render.ResourceGraph,
        source_dependencies: []const resources_compile.SourceDependency,
        font_catalog: *const render.FontCatalog,
        math_catalog: *const render.MathCatalog,
    ) !bool {
        if (page_allocator.ptr != self.allocator.ptr or page_allocator.vtable != self.allocator.vtable) {
            return error.RenderPageCacheAllocatorMismatch;
        }
        const entry_byte_size = pageCacheEntryByteSize(page, source_dependencies, resource_graph, font_catalog, math_catalog);
        const standalone_resource_bytes = resourceGraphByteSize(resource_graph);
        const standalone_font_bytes = fontCatalogByteSize(font_catalog);
        if (entry_byte_size > max_page_bytes or standalone_resource_bytes > max_resource_bytes or
            standalone_font_bytes > max_font_bytes)
        {
            return false;
        }

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.entries.contains(key)) return true;
        while (self.entries.count() >= self.entry_limit or
            self.page_bytes > max_page_bytes - entry_byte_size or
            self.resource_bytes > max_resource_bytes - self.additionalResourceBytes(resource_graph) or
            self.font_bytes > max_font_bytes - self.additionalFontBytes(font_catalog))
        {
            if (self.entries.count() == 0) return false;
            if (!self.evictLeastRecentlyUsed(self.document_epoch != 0)) return false;
        }

        const dependencies = try self.allocator.alloc(resources_compile.SourceDependency, source_dependencies.len);
        var initialized_dependencies: usize = 0;
        errdefer {
            for (dependencies[0..initialized_dependencies]) |*dependency| dependency.deinit(self.allocator);
            self.allocator.free(dependencies);
        }
        for (source_dependencies, 0..) |dependency, index| {
            dependencies[index] = try dependency.clone(self.allocator);
            initialized_dependencies += 1;
        }

        const resource_ids = try self.allocator.alloc(render.ResourceId, resource_graph.entries.len);
        errdefer self.allocator.free(resource_ids);
        for (resource_graph.entries, 0..) |*resource, index| resource_ids[index] = resource.id;
        const font_ids = try self.allocator.alloc(render.FontInstanceId, font_catalog.instances.len);
        errdefer self.allocator.free(font_ids);
        for (font_catalog.instances, 0..) |*font, index| font_ids[index] = font.id;
        const math_specs = try self.allocator.alloc(MathSpec, math_catalog.trees.len);
        var initialized_math: usize = 0;
        errdefer {
            for (math_specs[0..initialized_math]) |*spec| spec.deinit(self.allocator);
            self.allocator.free(math_specs);
        }
        for (math_catalog.trees, 0..) |tree, index| {
            math_specs[index] = .{
                .old_id = tree.id,
                .input_kind = tree.input_kind,
                .source = try self.allocator.dupe(u8, tree.source),
            };
            initialized_math += 1;
        }

        var retained_resources: usize = 0;
        errdefer for (resource_ids[0..retained_resources]) |id| self.releaseResource(id);
        for (resource_graph.entries) |*resource| {
            try self.retainResource(resource);
            retained_resources += 1;
        }
        var retained_fonts: usize = 0;
        errdefer for (font_ids[0..retained_fonts]) |id| self.releaseFont(id);
        for (font_catalog.instances) |*font| {
            try self.retainFont(font);
            retained_fonts += 1;
        }

        try self.entries.ensureUnusedCapacity(1);
        const page_id = page.page_id;
        const page_index = page.index;
        const page_width = page.width;
        const page_height = page.height;
        const content = try page.takeContent(self.allocator, page_allocator);
        self.entries.putAssumeCapacityNoClobber(key, .{
            .page_id = page_id,
            .index = page_index,
            .width = page_width,
            .height = page_height,
            .content = content,
            .dependencies = dependencies,
            .resources = resource_ids,
            .fonts = font_ids,
            .math = math_specs,
            .last_used = self.nextAccess(),
            .document_epoch = self.document_epoch,
            .byte_size = entry_byte_size,
        });
        self.page_bytes += entry_byte_size;
        page.* = .{
            .page_id = page_id,
            .index = page_index,
            .width = page_width,
            .height = page_height,
        };
        return true;
    }

    pub fn materialize(
        self: *Cache,
        key: u64,
        allocator: Allocator,
        io: std.Io,
        resources: *resources_compile.Builder,
        fonts: *render.FontBuilder,
        math: *render.MathBuilder,
    ) !?render.Page {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const entry = self.entries.getPtr(key) orelse return null;
        for (entry.dependencies) |dependency| {
            if (try dependency.isCurrent(io)) continue;
            self.removeEntry(key);
            return null;
        }
        entry.last_used = self.nextAccess();
        entry.document_epoch = self.document_epoch;
        for (entry.resources) |id| {
            const resource = self.resources.getPtr(id) orelse return error.InvalidRenderPageCache;
            const added = try resources.addResource(allocator, io, &resource.value);
            if (!std.mem.eql(u8, &added, &id)) return error.InvalidRenderPageCache;
        }
        for (entry.fonts) |id| {
            const font = self.fonts.getPtr(id) orelse return error.InvalidRenderPageCache;
            const added = try fonts.add(allocator, io, font.value.spec());
            if (!std.mem.eql(u8, &added, &id)) return error.InvalidRenderPageCache;
        }

        const mappings = try allocator.alloc(MathMapping, entry.math.len);
        defer allocator.free(mappings);
        for (entry.math, 0..) |spec, index| mappings[index] = .{
            .old = spec.old_id,
            .new = try math.add(allocator, spec.source, spec.input_kind),
        };
        var page = try entry.content.materialize(
            allocator,
            entry.page_id,
            entry.index,
            entry.width,
            entry.height,
        );
        errdefer page.deinit(allocator);
        for (page.items.items) |*item| switch (item.*) {
            .math => |*value| value.tree = mappedMathTree(mappings, value.tree) orelse return error.InvalidRenderPageCache,
            else => {},
        };
        return page;
    }

    fn clearEntries(self: *Cache) void {
        var values = self.entries.valueIterator();
        while (values.next()) |entry| entry.deinit(self.allocator);
        self.entries.clearRetainingCapacity();
        self.page_bytes = 0;
    }

    fn clear(self: *Cache) void {
        self.clearEntries();
        var resource_values = self.resources.valueIterator();
        while (resource_values.next()) |resource| resource.value.deinit(self.allocator);
        self.resources.clearRetainingCapacity();
        self.resource_bytes = 0;
        var font_values = self.fonts.valueIterator();
        while (font_values.next()) |font| font.value.deinit(self.allocator);
        self.fonts.clearRetainingCapacity();
        self.font_bytes = 0;
    }

    fn nextAccess(self: *Cache) u64 {
        self.access_clock +%= 1;
        if (self.access_clock == 0) self.access_clock = 1;
        return self.access_clock;
    }

    fn retainResource(self: *Cache, resource: *const render.Resource) !void {
        if (self.resources.getPtr(resource.id)) |cached| {
            cached.references += 1;
            return;
        }
        var owned = try resource.clone(self.allocator);
        errdefer owned.deinit(self.allocator);
        const byte_size = @sizeOf(CachedResource) +| resource.retainedByteSize();
        try self.resources.putNoClobber(resource.id, .{ .value = owned, .references = 1, .byte_size = byte_size });
        self.resource_bytes += byte_size;
    }

    fn releaseResource(self: *Cache, id: render.ResourceId) void {
        const cached = self.resources.getPtr(id) orelse return;
        std.debug.assert(cached.references > 0);
        cached.references -= 1;
        if (cached.references != 0) return;
        const removed = self.resources.fetchRemove(id) orelse return;
        self.resource_bytes -= removed.value.byte_size;
        var value = removed.value.value;
        value.deinit(self.allocator);
    }

    fn retainFont(self: *Cache, font: *const render.FontInstance) !void {
        if (self.fonts.getPtr(font.id)) |cached| {
            cached.references += 1;
            return;
        }
        var owned = try font.clone(self.allocator);
        errdefer owned.deinit(self.allocator);
        const byte_size = font.ownedByteSize();
        try self.fonts.putNoClobber(font.id, .{ .value = owned, .references = 1, .byte_size = byte_size });
        self.font_bytes += byte_size;
    }

    fn releaseFont(self: *Cache, id: render.FontInstanceId) void {
        const cached = self.fonts.getPtr(id) orelse return;
        std.debug.assert(cached.references > 0);
        cached.references -= 1;
        if (cached.references != 0) return;
        const removed = self.fonts.fetchRemove(id) orelse return;
        self.font_bytes -= removed.value.byte_size;
        var value = removed.value.value;
        value.deinit(self.allocator);
    }

    fn evictLeastRecentlyUsed(self: *Cache, preserve_current_document: bool) bool {
        var oldest_key: ?u64 = null;
        var oldest_access: u64 = std.math.maxInt(u64);
        var iterator = self.entries.iterator();
        while (iterator.next()) |entry| {
            if (preserve_current_document and entry.value_ptr.document_epoch == self.document_epoch) continue;
            if (entry.value_ptr.last_used >= oldest_access) continue;
            oldest_key = entry.key_ptr.*;
            oldest_access = entry.value_ptr.last_used;
        }
        const key = oldest_key orelse return false;
        self.removeEntry(key);
        return true;
    }

    fn removeEntry(self: *Cache, key: u64) void {
        const removed = self.entries.fetchRemove(key) orelse return;
        self.page_bytes -= removed.value.byte_size;
        for (removed.value.resources) |id| self.releaseResource(id);
        for (removed.value.fonts) |id| self.releaseFont(id);
        var entry = removed.value;
        entry.deinit(self.allocator);
    }

    fn additionalResourceBytes(self: *const Cache, graph: *const render.ResourceGraph) usize {
        var total: usize = 0;
        for (graph.entries) |*resource| {
            if (!self.resources.contains(resource.id)) total +|= @sizeOf(CachedResource) +| resource.retainedByteSize();
        }
        return total;
    }

    fn additionalFontBytes(self: *const Cache, catalog: *const render.FontCatalog) usize {
        var total: usize = 0;
        for (catalog.instances) |*font| {
            if (!self.fonts.contains(font.id)) total +|= font.ownedByteSize();
        }
        return total;
    }
};

fn pageCacheEntryByteSize(
    page: *const render.Page,
    source_dependencies: []const resources_compile.SourceDependency,
    resource_graph: *const render.ResourceGraph,
    font_catalog: *const render.FontCatalog,
    math_catalog: *const render.MathCatalog,
) usize {
    var total = @sizeOf(Entry) +| page.ownedContentByteSize();
    total +|= source_dependencies.len *| @sizeOf(resources_compile.SourceDependency);
    for (source_dependencies) |dependency| total +|= dependency.path.len;
    total +|= resource_graph.entries.len *| @sizeOf(render.ResourceId);
    total +|= font_catalog.instances.len *| @sizeOf(render.FontInstanceId);
    total +|= math_catalog.trees.len *| @sizeOf(MathSpec);
    for (math_catalog.trees) |tree| total +|= tree.source.len;
    return total;
}

fn resourceGraphByteSize(graph: *const render.ResourceGraph) usize {
    var total: usize = 0;
    for (graph.entries) |*resource| total +|= @sizeOf(CachedResource) +| resource.retainedByteSize();
    return total;
}

fn fontCatalogByteSize(catalog: *const render.FontCatalog) usize {
    var total: usize = 0;
    for (catalog.instances) |*font| total +|= font.ownedByteSize();
    return total;
}

fn mappedMathTree(mappings: []const MathMapping, old: render.MathTreeId) ?render.MathTreeId {
    for (mappings) |mapping| if (mapping.old == old) return mapping.new;
    return null;
}
