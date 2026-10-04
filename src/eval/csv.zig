const std = @import("std");
const utils = @import("utils");

const cancellation_interval = 4096;

pub const Cell = struct {
    text: []const u8,
    row: usize,
    column: usize,
    end_row: bool,
};

pub const Table = struct {
    arena: std.heap.ArenaAllocator,
    cells: std.ArrayList(Cell) = .empty,

    pub fn deinit(self: *Table) void {
        self.arena.deinit();
    }
};

pub const Failure = struct {
    row: usize = 1,
    column: usize = 1,
    reason: []const u8 = "invalid CSV",
};

// Parse and validate before invoking any user callbacks.
pub fn parse(allocator: std.mem.Allocator, input: []const u8, failure: *Failure, cancellation: ?utils.Cancellation) !Table {
    var result = Table{ .arena = std.heap.ArenaAllocator.init(allocator) };
    errdefer result.deinit();
    const memory = result.arena.allocator();
    if (!std.unicode.utf8ValidateSlice(input)) {
        failure.reason = "input is not valid UTF-8";
        return error.InvalidCsv;
    }
    var pos: usize = if (std.mem.startsWith(u8, input, "\xef\xbb\xbf")) 3 else 0;
    if (pos == input.len) return result;
    var row: usize = 1;
    var column: usize = 1;
    var columns: ?usize = null;
    while (true) {
        if (cancellation) |token| try token.check();
        var last_cancel_check = pos;
        failure.row = row;
        failure.column = column;
        var value = std.ArrayList(u8).empty;
        if (pos < input.len and input[pos] == '"') {
            pos += 1;
            while (true) {
                if (pos == input.len) {
                    failure.reason = "unterminated quoted field";
                    return error.InvalidCsv;
                }
                if (pos - last_cancel_check >= cancellation_interval) {
                    if (cancellation) |token| try token.check();
                    last_cancel_check = pos;
                }
                const byte = input[pos];
                pos += 1;
                if (byte == '"') {
                    if (pos < input.len and input[pos] == '"') {
                        pos += 1;
                        try value.append(memory, '"');
                    } else break;
                } else if (byte == '\r') {
                    if (pos < input.len and input[pos] == '\n') pos += 1;
                    try value.append(memory, '\n');
                } else try value.append(memory, byte);
            }
            if (pos < input.len and input[pos] != ',' and input[pos] != '\r' and input[pos] != '\n') {
                failure.reason = "expected a comma or record ending after closing quote";
                return error.InvalidCsv;
            }
        } else {
            const start = pos;
            while (pos < input.len and input[pos] != ',' and input[pos] != '\r' and input[pos] != '\n') : (pos += 1) {
                if (pos - last_cancel_check >= cancellation_interval) {
                    if (cancellation) |token| try token.check();
                    last_cancel_check = pos;
                }
                if (input[pos] == '"') {
                    failure.reason = "quote inside an unquoted field";
                    return error.InvalidCsv;
                }
            }
            try value.appendSlice(memory, input[start..pos]);
        }
        const end_row = pos == input.len or input[pos] != ',';
        try result.cells.append(memory, .{ .text = try value.toOwnedSlice(memory), .row = row, .column = column, .end_row = end_row });
        if (end_row) {
            if (columns) |expected| {
                if (column != expected) {
                    failure.reason = "record has a different number of fields than the first record";
                    return error.InvalidCsv;
                }
            } else columns = column;
            if (pos == input.len) break;
            const ending = input[pos];
            pos += 1;
            if (ending == '\r' and pos < input.len and input[pos] == '\n') pos += 1;
            if (pos == input.len) break;
            row += 1;
            column = 1;
        } else {
            pos += 1;
            column += 1;
        }
    }
    return result;
}
