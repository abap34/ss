const std = @import("std");
const core = @import("core");
const utils = @import("utils");
const scanner = @import("../../syntax/scanner.zig");
const type_resolution = @import("../../language/type_resolution.zig");
const snapshot_api = @import("../snapshot.zig");
const types = @import("types.zig");

// This analysis deliberately ignores expression evaluation, nested scopes, and
// transitive imports. Bound both its input and work, independently of the query
// deadline that selected it. Cancellation still stops it immediately.
pub const Limits = struct {
    pub const milliseconds = 2;
    pub const source_bytes = 8192;
    pub const tokens = 512;
    pub const facts = 2048;
    pub const modules = 64;
    pub const names = 64;
    pub const definitions = 8;
    pub const label_bytes = 256;
};

const Work = struct {
    budget: types.QueryBudget,
    remaining: usize = Limits.facts,

    fn init(opts: types.QueryOptions) Work {
        var options = opts;
        options.budget_ms = Limits.milliseconds;
        options.start_ns = null;
        return .{ .budget = types.QueryBudget.start(options) };
    }

    fn step(self: *Work) bool {
        if (self.remaining == 0 or self.budget.expired()) return false;
        self.remaining -= 1;
        return true;
    }
};

const Declaration = struct {
    name: []const u8,
    kind: types.CompletionKind,
    type_label: []const u8,
    span: utils.source.ByteSpan,
};

// Only the innermost delimiter can own a field name. A completed assignment is
// followed by another field after a comma, a newline, or an adjacent name.
const UpdatePosition = struct {
    const Slot = enum { expression, field, value_start, value };
    parents: [Limits.tokens]Slot = undefined,
    depth: usize = 0,
    slot: Slot = .expression,
    previous: []const u8 = "",
    line: usize = 0,
    can_end_value: bool = false,

    fn consume(self: *UpdatePosition, item: scanner.Token, word: []const u8, offset: usize) bool {
        if (self.slot == .value and self.can_end_value and
            (item.line != self.line or (item.kind == .identifier and !std.mem.eql(u8, word, "with"))))
            self.slot = .field;
        // At the start of a token the cursor is still before it.
        if (item.span.start >= offset) return true;
        const ch = if (word.len == 1) word[0] else 0;
        switch (ch) {
            '{', '(', '[' => {
                if (self.depth == self.parents.len) return false;
                self.parents[self.depth] = if (self.slot == .value_start) .value else self.slot;
                self.depth += 1;
                self.slot = if (ch == '{' and std.mem.eql(u8, self.previous, "with")) .field else .expression;
            },
            '}', ')', ']' => {
                self.slot = if (self.depth == 0) .expression else blk: {
                    self.depth -= 1;
                    break :blk self.parents[self.depth];
                };
            },
            '=' => if (self.slot == .field) {
                self.slot = .value_start;
            },
            ',' => if (self.slot != .expression) {
                self.slot = .field;
            },
            else => if (self.slot == .value_start) {
                self.slot = .value;
            },
        }
        self.can_end_value = switch (item.kind) {
            .identifier => !std.mem.eql(u8, word, "with"),
            .string, .color_string, .number => true,
            else => ch == ')' or ch == '}' or ch == ']' or ch == '?',
        };
        self.previous = word;
        self.line = item.line;
        return true;
    }

    fn atField(self: *const UpdatePosition, last: ?scanner.Token, next: ?scanner.Token, text: []const u8, offset: usize) bool {
        if (self.slot != .value or !self.can_end_value) return self.slot == .field;
        const token = last orelse return false;
        if (offset < token.span.end or (offset == token.span.end and token.kind == .identifier)) return false;
        // A following operator, call or member access still belongs to this
        // value. Only a field name, a delimiter, or EOF can follow a full value.
        const following = next orelse return true;
        const word = text[following.span.start..following.span.end];
        return if (following.kind == .identifier) !std.mem.eql(u8, word, "with") else std.mem.eql(u8, word, ",") or std.mem.eql(u8, word, "}");
    }
};

const Context = struct {
    req: types.SourceRequest,
    text: []const u8,
    start: usize,
    tokens: [Limits.tokens]scanner.Token = undefined,
    len: usize = 0,
    name: []const u8 = "",
    qualifier: ?[]const u8 = null,
    member: bool = false,
    update_field: bool = false,
    suppressed: bool = false,

    fn init(req: types.SourceRequest, work: *Work) Context {
        const offset = @min(req.offset, req.source.len);
        var start = offset -| (Limits.source_bytes / 2);
        // Start on a whole line; never scan a long prefix to find lexical state.
        while (start > 0 and start < offset and req.source[start - 1] != '\n') : (start += 1) {}
        const end = @min(req.source.len, @min(start +| Limits.source_bytes, offset +| 512));
        var self = Context{ .req = req, .text = req.source[start..end], .start = start };
        var tokens = scanner.tokens(self.text);
        var position = UpdatePosition{};
        const local_offset = offset - start;
        var last: ?scanner.Token = null;
        var next: ?scanner.Token = null;
        var reached_cursor = false;
        var scanned: usize = 0;
        while (true) : (scanned += 1) {
            if (scanned % 8 == 0 and !work.step()) {
                if (!reached_cursor) self.suppressed = true;
                break;
            }
            const token = tokens.nextWithPunctuation() orelse break;
            if (next == null and token.span.start >= local_offset) next = token;
            if (!reached_cursor) {
                if (token.span.start <= local_offset and !position.consume(token, self.word(token), local_offset)) {
                    self.suppressed = true;
                    break;
                }
                reached_cursor = token.span.end >= local_offset;
                if (token.span.start < local_offset) last = token;
            }
            if (token.kind == .punctuation) continue;
            if (self.len == self.tokens.len) {
                const retained = self.tokens.len / 2;
                std.mem.copyForwards(scanner.Token, self.tokens[0..retained], self.tokens[retained..]);
                self.len = retained;
            }
            self.tokens[self.len] = token;
            self.len += 1;
        }
        self.update_field = position.atField(last, next, self.text, local_offset);
        var name_start = local_offset;
        for (self.tokens[0..self.len]) |token| {
            if (!work.step()) break;
            if (token.span.start > local_offset) break;
            if (local_offset > token.span.end) continue;
            if (token.kind == .string or token.kind == .color_string) self.suppressed = true;
            if (token.kind == .identifier) {
                self.name = self.word(token);
                name_start = token.span.start;
            }
        }
        const line_start = if (std.mem.lastIndexOfScalar(u8, self.text[0..local_offset], '\n')) |newline| newline + 1 else 0;
        var probe = line_start;
        var token_index: usize = 0;
        while (probe < local_offset) {
            while (token_index < self.len and self.tokens[token_index].span.end <= probe) : (token_index += 1) {}
            if (token_index < self.len and self.tokens[token_index].span.start <= probe) {
                probe = self.tokens[token_index].span.end;
            } else {
                if (utils.source.lineCommentMarkerLength(self.text, probe) != null) {
                    self.suppressed = true;
                    break;
                }
                probe += 1;
            }
        }
        // A skipped comment or multiline string must not become an identifier.
        if (self.name.len == 0 and local_offset > 0 and isNameByte(self.text[local_offset - 1])) self.suppressed = true;
        var previous = name_start;
        while (previous > 0 and utils.source.isInlineSpace(self.text[previous - 1])) : (previous -= 1) {}
        if (previous > 0 and self.text[previous - 1] == '.') {
            self.member = true;
        } else if (previous >= 2 and std.mem.eql(u8, self.text[previous - 2 .. previous], "::")) {
            var begin = previous - 2;
            while (begin > 0 and isNameByte(self.text[begin - 1])) : (begin -= 1) {}
            if (begin < previous - 2) self.qualifier = self.text[begin .. previous - 2];
        }
        return self;
    }

    fn word(self: *const Context, token: scanner.Token) []const u8 {
        return self.text[token.span.start..token.span.end];
    }

    fn declaration(self: *const Context, index: usize) ?Declaration {
        if (index == 0) return null;
        const token = self.tokens[index];
        if (token.kind != .identifier) return null;
        const previous = self.word(self.tokens[index - 1]);
        const kind: types.CompletionKind = if (std.mem.eql(u8, previous, "let") or std.mem.eql(u8, previous, "const"))
            .variable
        else if (std.mem.eql(u8, previous, "fn"))
            .function
        else if (std.mem.eql(u8, previous, "type") or std.mem.eql(u8, previous, "enum"))
            .type_decl
        else
            return null;
        const name = self.word(token);
        if (name.len > Limits.label_bytes or scanner.isKeyword(name)) return null;
        if (std.mem.eql(u8, previous, "let") and self.start + token.span.start > self.req.offset) return null;
        var label: []const u8 = "Any";
        if (kind == .variable and index + 1 < self.len) {
            const next = self.tokens[index + 1];
            const gap = std.mem.trim(u8, self.text[token.span.end..next.span.start], " \t");
            if (std.mem.eql(u8, gap, ":") and next.kind == .identifier) {
                const tail = self.text[next.span.start..next.line_end];
                const annotation = std.mem.trim(u8, tail[0 .. std.mem.indexOfScalar(u8, tail, '=') orelse tail.len], " \t\r");
                if (annotation.len <= Limits.label_bytes) label = annotation;
            } else if (std.mem.eql(u8, gap, "=") and next.span.end <= next.line_end and
                std.mem.trim(u8, self.text[next.span.end..next.line_end], " \t\r").len == 0)
            {
                label = switch (next.kind) {
                    .number => "Number",
                    .string => "String",
                    .color_string => "Color",
                    .identifier => if (std.mem.eql(u8, self.word(next), "true") or std.mem.eql(u8, self.word(next), "false")) "Bool" else "Any",
                    else => "Any",
                };
            }
        }
        return .{ .name = name, .kind = kind, .type_label = label, .span = .{
            .start = self.start + token.span.start,
            .end = self.start + token.span.end,
        } };
    }
};

/// A surrounding parse error can erase the entire update from the syntax tree.
/// In that case there is no receiver type to supply field names.
pub fn isUpdateField(req: types.SourceRequest, budget: types.QueryBudget) bool {
    var work = Work{ .budget = budget };
    const context = Context.init(req, &work);
    return context.update_field;
}

const Candidates = struct {
    items: [Limits.names]types.CompletionCandidate = undefined,
    len: usize = 0,

    fn add(self: *Candidates, name: []const u8, kind: types.CompletionKind, detail: ?[]const u8) void {
        if (name.len == 0 or name.len > Limits.label_bytes or self.len == self.items.len) return;
        for (self.items[0..self.len]) |item| if (std.mem.eql(u8, item.label, name)) return;
        self.items[self.len] = .{ .label = name, .kind = kind, .detail = if (detail) |text| if (text.len <= Limits.label_bytes) text else null else null };
        self.len += 1;
    }
};

pub fn complete(allocator: std.mem.Allocator, snapshot: *const snapshot_api.AnalysisSnapshot, req: types.SourceRequest, opts: types.QueryOptions) !types.CompletionResult {
    var work = Work.init(opts);
    if (work.budget.canceled()) return .{ .items = try allocator.alloc(types.CompletionCandidate, 0) };
    var out = Candidates{};
    const context = Context.init(req, &work);
    // An update needs the receiver's fields. Leave the incomplete list empty
    // until the typed query can identify them.
    if (!context.suppressed and !context.update_field) {
        if (context.member) {
            // Unknown receivers admit fields from ordinary types.
            for (snapshot.record_fields) |field| {
                if (!work.step()) break;
                out.add(field.name, .property, null);
            }
            for (snapshot.enum_cases) |item| {
                if (!work.step()) break;
                out.add(item.name, .enum_case, null);
            }
        } else if (context.qualifier == null) {
            var i = context.len;
            while (i > 0 and work.step()) {
                i -= 1;
                if (context.declaration(i)) |decl| out.add(decl.name, decl.kind, decl.type_label);
            }
            for (scanner.keywordLabels()) |word| out.add(word, .keyword, null);
            for (type_resolution.builtinTypes()) |builtin| out.add(builtin.name, .type_decl, null);
        }
        if (!context.member) {
            const modules = visibleModules(snapshot, req.path, context.qualifier, &work);
            var i = snapshot.value_bindings.len;
            while (i > 0 and work.step()) {
                i -= 1;
                const binding = snapshot.value_bindings[i];
                if (binding.module_id) |id| {
                    if (!modules.contains(id)) continue;
                } else if (!binding.primitive or context.qualifier != null) continue;
                out.add(binding.name, if (binding.kind == .function) .function else .variable, null);
            }
            for (snapshot.type_definitions) |decl| {
                if (!work.step()) break;
                if (modules.contains(decl.module_id)) out.add(decl.name, .type_decl, null);
            }
        }
    }
    if (work.budget.canceled()) return .{ .items = try allocator.alloc(types.CompletionCandidate, 0) };
    return .{ .items = try allocator.dupe(types.CompletionCandidate, out.items[0..out.len]), .is_incomplete = true };
}

pub fn hover(allocator: std.mem.Allocator, snapshot: *const snapshot_api.AnalysisSnapshot, req: types.SourceRequest, opts: types.QueryOptions) !?types.HoverInfo {
    var work = Work.init(opts);
    if (work.budget.canceled()) return null;
    const context = Context.init(req, &work);
    if (context.suppressed or context.name.len == 0 or context.name.len > Limits.label_bytes or work.budget.canceled()) return null;
    var label: ?[]const u8 = null;
    if (!context.update_field and !context.member and context.qualifier == null) {
        for (0..context.len) |index| {
            if (!work.step()) {
                label = "Any";
                break;
            }
            const decl = context.declaration(index) orelse continue;
            if (!std.mem.eql(u8, decl.name, context.name)) continue;
            label = if (label) |previous| if (std.mem.eql(u8, previous, decl.type_label)) previous else "Any" else decl.type_label;
        }
    }
    if (label == null and !context.update_field and !context.member) {
        const modules = visibleModules(snapshot, req.path, context.qualifier, &work);
        var signature: ?[]const u8 = null;
        var matches: usize = 0;
        for (modules.items[0..modules.len]) |id| {
            if (!work.step()) {
                signature = null;
                break;
            }
            const binding = snapshot.valueBindingInModule(id, context.name) orelse continue;
            matches += 1;
            if (matches > 1) {
                signature = null;
                break;
            }
            if (binding.signature.len <= Limits.label_bytes) signature = binding.signature;
        }
        if (signature) |text| {
            if (work.budget.canceled()) return null;
            return .{ .markdown = try std.fmt.allocPrint(allocator, "```ss\n{s}\n```", .{text}) };
        }
    }
    if (work.budget.canceled()) return null;
    return .{ .markdown = try std.fmt.allocPrint(allocator, "```ss\n({s}: {s})\n```", .{ context.name, label orelse "Any" }) };
}

pub fn definition(allocator: std.mem.Allocator, snapshot: *const snapshot_api.AnalysisSnapshot, req: types.SourceRequest, opts: types.QueryOptions) ![]types.DefinitionTarget {
    var work = Work.init(opts);
    if (work.budget.canceled()) return allocator.alloc(types.DefinitionTarget, 0);
    const context = Context.init(req, &work);
    var targets: [Limits.definitions]types.DefinitionTarget = undefined;
    var len: usize = 0;
    if (!context.suppressed and context.name.len > 0 and !context.update_field and !context.member) {
        if (context.qualifier == null) {
            var i = context.len;
            while (i > 0 and len < targets.len and work.step()) {
                i -= 1;
                const decl = context.declaration(i) orelse continue;
                if (!std.mem.eql(u8, decl.name, context.name)) continue;
                const begin = sourcePosition(req, decl.span.start) orelse continue;
                const end = sourcePosition(req, decl.span.end) orelse continue;
                targets[len] = .{ .path = req.path, .line = begin.line, .character = begin.character, .end_line = end.line, .end_character = end.character };
                len += 1;
            }
        }
        if (len == 0) {
            const modules = visibleModules(snapshot, req.path, context.qualifier, &work);
            for (modules.items[0..modules.len]) |id| {
                if (len == targets.len or !work.step()) break;
                const decl = snapshot.valueDefinitionInModule(id, context.name) orelse continue;
                const module = findModule(snapshot, null, id, &work) orelse continue;
                const location = module.location(.{ .start = decl.span_start, .end = decl.span_end });
                const physical = if (module.source_files.len == 0) module else findModule(snapshot, location.path, null, &work) orelse continue;
                const begin = boundedPosition(physical.line_index, location.span.start) orelse continue;
                const end = boundedPosition(physical.line_index, location.span.end) orelse continue;
                targets[len] = .{ .path = physical.path, .module_spec = if (physical.path == null) physical.spec else null, .line = begin.line, .character = begin.character, .end_line = end.line, .end_character = end.character };
                len += 1;
            }
        }
    }
    if (work.budget.canceled()) len = 0;
    return allocator.dupe(types.DefinitionTarget, targets[0..len]);
}

const Modules = struct {
    items: [16]core.SourceModuleId = undefined,
    len: usize = 0,

    fn contains(self: Modules, id: core.SourceModuleId) bool {
        for (self.items[0..self.len]) |item| if (item == id) return true;
        return false;
    }

    fn add(self: *Modules, id: core.SourceModuleId) void {
        if (self.len == self.items.len or self.contains(id)) return;
        self.items[self.len] = id;
        self.len += 1;
    }
};

fn visibleModules(snapshot: *const snapshot_api.AnalysisSnapshot, path: []const u8, qualifier: ?[]const u8, work: *Work) Modules {
    var out = Modules{};
    const module = findModule(snapshot, path, null, work) orelse return out;
    if (qualifier == null) out.add(module.id);
    for (module.imports) |item| {
        if (!work.step()) return out;
        if (qualifier) |alias| {
            if (!std.mem.eql(u8, alias, item.alias orelse "")) continue;
        } else if (!item.unqualified) continue;
        if (item.module_id) |id| out.add(id);
    }
    if (qualifier == null) for (module.implicit_import_ids) |id| {
        if (!work.step()) break;
        out.add(id);
    };
    return out;
}

fn findModule(snapshot: *const snapshot_api.AnalysisSnapshot, path: ?[]const u8, id: ?core.SourceModuleId, work: *Work) ?snapshot_api.ModuleFact {
    for (snapshot.modules[0..@min(snapshot.modules.len, Limits.modules)]) |module| {
        if (!work.step()) return null;
        if (id) |value| {
            if (module.id == value) return module;
        } else if (path) |value| {
            if (std.mem.eql(u8, module.path orelse continue, value)) return module;
        }
    }
    return null;
}

fn sourcePosition(req: types.SourceRequest, offset: usize) ?utils.source.Utf16Position {
    if (req.line_index) |index| {
        if (index.text.ptr == req.source.ptr and index.text.len == req.source.len) return boundedPosition(index, offset);
    }
    if (req.source.len > Limits.source_bytes) return null;
    return utils.source.utf16PositionAt(req.source, offset);
}

fn boundedPosition(index: utils.source.LineIndex, offset: usize) ?utils.source.Utf16Position {
    if (offset > index.text.len) return null;
    if (offset - index.lineAt(offset).span.start > Limits.source_bytes) return null;
    return index.utf16PositionAt(offset);
}

fn isNameByte(byte: u8) bool {
    return scanner.isCallableIdentifierContinue(byte);
}
