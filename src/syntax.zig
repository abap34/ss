const ast = @import("ast");

pub const Program = ast.Program;
pub const PageDecl = ast.PageDecl;
pub const FunctionDecl = ast.FunctionDecl;
pub const ParamDecl = ast.ParamDecl;
pub const CallExpr = ast.CallExpr;
pub const Expr = ast.Expr;
pub const AnchorRef = ast.AnchorRef;
pub const ConstraintDecl = ast.ConstraintDecl;
pub const Statement = ast.Statement;
const syntax = @import("syntax/parse.zig");
pub const ParseDiagnostic = syntax.ParseDiagnostic;
pub const parse = syntax.parse;
pub const lastParseDiagnostic = syntax.lastDiagnostic;
