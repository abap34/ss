pub const Atom = struct {
    width: f32,
    advance: f32,
    is_space: bool,
};

pub const Decision = enum {
    skip,
    draw,
    break_then_draw,
};

pub const Cursor = struct {
    offset: f32 = 0,
    pending_break_after_space: bool = false,
    preserve_leading_space: bool = false,

    pub fn next(self: *Cursor, atom: Atom, line_width: f32, enabled: bool) Decision {
        if (atom.is_space and self.offset == 0 and !self.preserve_leading_space) return .skip;

        if (self.pending_break_after_space) {
            if (atom.is_space and !self.preserve_leading_space) return .skip;
            self.pending_break_after_space = false;
            self.offset = 0;
            return .break_then_draw;
        }

        if (enabled and self.offset > 0 and self.offset + atom.width > @max(line_width, 1)) {
            if (atom.is_space and !self.preserve_leading_space) {
                self.pending_break_after_space = true;
                return .skip;
            }
            self.offset = 0;
            return .break_then_draw;
        }

        return .draw;
    }

    pub fn advance(self: *Cursor, amount: f32) void {
        self.offset += amount;
    }
};

pub fn visualLineCount(atoms: []const Atom, max_width: f32, preserve_leading_space: bool) usize {
    if (atoms.len == 0) return 1;
    var lines: usize = 1;
    var cursor = Cursor{ .preserve_leading_space = preserve_leading_space };
    for (atoms) |atom| {
        switch (cursor.next(atom, max_width, true)) {
            .skip => continue,
            .break_then_draw => lines += 1,
            .draw => {},
        }
        cursor.advance(atom.advance);
    }
    return lines;
}
