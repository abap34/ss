pub const names = @import("language/names.zig");
pub const registry = @import("language/registry.zig");
pub const declarations = @import("language/declarations.zig");
pub const types = @import("language_type");

pub const Type = types.Type;
pub const PrimitiveCall = registry.PrimitiveCall;
pub const PrimitiveDescriptor = registry.PrimitiveDescriptor;
pub const QueryDescriptor = registry.QueryDescriptor;
pub const DeclarationIndex = declarations.DeclarationIndex;
