pub const Cancellation = struct {
    context: *const anyopaque,
    is_canceled: *const fn (context: *const anyopaque) bool,

    pub fn canceled(self: Cancellation) bool {
        return self.is_canceled(self.context);
    }

    pub fn check(self: Cancellation) !void {
        if (self.canceled()) return error.Canceled;
    }
};
