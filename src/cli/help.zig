const std = @import("std");
const utils = @import("utils");

const error_report = utils.err;

pub const Output = enum {
    stdout,
    stderr,
};

const Style = struct {
    heading: []const u8 = "",
    command: []const u8 = "",
    option: []const u8 = "",
    reset: []const u8 = "",
};

var color_mode: error_report.ColorMode = .auto;

pub fn setColorMode(mode: error_report.ColorMode) void {
    color_mode = mode;
}

pub fn general(output: Output) void {
    const s = style(output);
    outputPrint(output,
        \\{s}Usage:{s}
        \\  {s}ss <command>{s} [options]
        \\
        \\{s}Project:{s}
        \\  {s}ss init [dir]{s}           Create a project
        \\  {s}ss doctor{s}               Check local setup
        \\
    , .{
        s.heading, s.reset,
        s.command, s.reset,
        s.heading, s.reset,
        s.command, s.reset,
        s.command, s.reset,
    });
    writeAll(output, "\n");
    outputPrint(output,
        \\{s}Build:{s}
        \\  {s}ss check [input.ss]{s}     Check source
        \\  {s}ss render [input.ss]{s}    Write PDF or HTML
        \\  {s}ss dump [input.ss]{s}      Write IR JSON
        \\
        \\{s}Tools:{s}
        \\  {s}ss watch <mode>{s}         Re-run check or render on changes
        \\  {s}ss debug <topic>{s}        Write schedule or layout JSON
        \\  {s}ss cache <target>{s}       Manage caches
        \\  {s}ss lsp{s}                  Run language server
        \\  {s}ss version{s}              Show version details
        \\  {s}ss completion <shell>{s}   Install shell completion
        \\
    , .{
        s.heading, s.reset,
        s.command, s.reset,
        s.command, s.reset,
        s.command, s.reset,
        s.heading, s.reset,
        s.command, s.reset,
        s.command, s.reset,
        s.command, s.reset,
        s.command, s.reset,
        s.command, s.reset,
        s.command, s.reset,
    });
    writeAll(output, "\n");
    outputPrint(output,
        \\{s}Examples:{s}
        \\  {s}ss init .{s}
        \\  {s}ss render slide.ss{s}
        \\  {s}ss render help{s}
        \\
        \\Run '{s}ss <command> help{s}' for command details.
        \\
    , .{
        s.heading, s.reset,
        s.command, s.reset,
        s.command, s.reset,
        s.command, s.reset,
        s.command, s.reset,
    });
}

pub fn command(output: Output, name: []const u8) bool {
    if (std.mem.eql(u8, name, "help")) {
        help(output);
        return true;
    }
    if (std.mem.eql(u8, name, "init")) {
        init(output);
        return true;
    }
    if (std.mem.eql(u8, name, "doctor")) {
        doctor(output);
        return true;
    }
    if (std.mem.eql(u8, name, "check")) {
        check(output);
        return true;
    }
    if (std.mem.eql(u8, name, "render")) {
        render(output);
        return true;
    }
    if (std.mem.eql(u8, name, "dump")) {
        dump(output);
        return true;
    }
    if (std.mem.eql(u8, name, "watch")) {
        watch(output);
        return true;
    }
    if (std.mem.eql(u8, name, "debug")) {
        debug(output);
        return true;
    }
    if (std.mem.eql(u8, name, "cache")) {
        cache(output);
        return true;
    }
    if (std.mem.eql(u8, name, "lsp")) {
        lsp(output);
        return true;
    }
    if (std.mem.eql(u8, name, "version")) {
        version(output);
        return true;
    }
    if (std.mem.eql(u8, name, "completion")) {
        completionHelp(output);
        return true;
    }
    return false;
}

pub fn completionScript(shell: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, shell, "bash")) {
        return bash_completion;
    }
    if (std.mem.eql(u8, shell, "zsh")) {
        return zsh_completion;
    }
    if (std.mem.eql(u8, shell, "fish")) {
        return fish_completion;
    }
    return null;
}

pub fn completion(shell: []const u8) bool {
    const script = completionScript(shell) orelse return false;
    writeAll(.stdout, script);
    return true;
}

fn help(output: Output) void {
    const s = style(output);
    outputPrint(output,
        \\{s}Usage:{s}
        \\  {s}ss help{s}
        \\  {s}ss help <command>{s}
        \\  {s}ss <command> help{s}
        \\
        \\{s}Examples:{s}
        \\  {s}ss help render{s}
        \\  {s}ss render help{s}
        \\
    , .{
        s.heading, s.reset,
        s.command, s.reset,
        s.command, s.reset,
        s.command, s.reset,
        s.heading, s.reset,
        s.command, s.reset,
        s.command, s.reset,
    });
}

fn init(output: Output) void {
    const s = style(output);
    outputPrint(output,
        \\{s}Usage:{s}
        \\  {s}ss init [dir]{s}
        \\
        \\{s}Options:{s}
        \\  {s}--entry FILE{s}            Entry file to create
        \\  {s}--force{s}                 Overwrite generated files
        \\
        \\{s}Examples:{s}
        \\  {s}ss init .{s}
        \\  {s}ss init slides --entry talk.ss{s}
        \\
    , .{
        s.heading, s.reset,
        s.command, s.reset,
        s.heading, s.reset,
        s.option,  s.reset,
        s.option,  s.reset,
        s.heading, s.reset,
        s.command, s.reset,
        s.command, s.reset,
    });
}

fn doctor(output: Output) void {
    const s = style(output);
    outputPrint(output,
        \\{s}Usage:{s}
        \\  {s}ss doctor{s}
        \\  {s}ss doctor [input.ss]{s}
        \\
        \\{s}Options:{s}
        \\  {s}--project FILE_OR_DIR{s}   Load entry and asset base from ss.toml
        \\  {s}--asset-base-dir DIR{s}    Resolve relative assets from DIR
        \\  {s}--strict{s}                Exit non-zero when issues are found
        \\
        \\{s}Examples:{s}
        \\  {s}ss doctor{s}
        \\  {s}ss doctor --project slides --strict{s}
        \\
    , .{
        s.heading, s.reset,
        s.command, s.reset,
        s.command, s.reset,
        s.heading, s.reset,
        s.option,  s.reset,
        s.option,  s.reset,
        s.option,  s.reset,
        s.heading, s.reset,
        s.command, s.reset,
        s.command, s.reset,
    });
}

fn check(output: Output) void {
    const s = style(output);
    outputPrint(output,
        \\{s}Usage:{s}
        \\  {s}ss check [input.ss]{s}
        \\  {s}ss check --project FILE_OR_DIR{s}
        \\
        \\{s}Options:{s}
        \\  {s}--project FILE_OR_DIR{s}   Load entry and asset base from ss.toml
        \\  {s}--asset-base-dir DIR{s}    Resolve relative assets from DIR
        \\  {s}--color auto|always|never{s}
        \\  {s}--diagnostic-level LEVEL{s} note|warning|error|off
        \\  {s}--warnings off{s}          Hide warning diagnostics
        \\  {s}--quiet{s}                 Hide progress and warning diagnostics
        \\
        \\{s}Examples:{s}
        \\  {s}ss check slide.ss{s}
        \\  {s}ss check --project slides{s}
        \\
    , .{
        s.heading, s.reset,
        s.command, s.reset,
        s.command, s.reset,
        s.heading, s.reset,
        s.option,  s.reset,
        s.option,  s.reset,
        s.option,  s.reset,
        s.option,  s.reset,
        s.option,  s.reset,
        s.option,  s.reset,
        s.heading, s.reset,
        s.command, s.reset,
        s.command, s.reset,
    });
}

fn render(output: Output) void {
    const s = style(output);
    outputPrint(output,
        \\{s}Usage:{s}
        \\  {s}ss render [input.ss] [output.pdf]{s}
        \\  {s}ss render --format html --output slides.html input.ss{s}
        \\
        \\{s}Options:{s}
        \\  {s}--project FILE_OR_DIR{s}   Load entry and asset base from ss.toml
        \\  {s}--asset-base-dir DIR{s}    Resolve relative assets from DIR
        \\  {s}--output FILE{s}           PDF or self-contained HTML file
        \\  {s}--format pdf|html{s}        Output format
        \\  {s}--jobs N{s}                Parallel render jobs
        \\  {s}--diagnostics-json FILE{s} Write diagnostics JSON
        \\  {s}--color auto|always|never{s}
        \\  {s}--diagnostic-level LEVEL{s} note|warning|error|off
        \\  {s}--warnings off{s}          Hide warning diagnostics
        \\  {s}--quiet{s}                 Hide progress and warning diagnostics
        \\
    , .{
        s.heading, s.reset,
        s.command, s.reset,
        s.command, s.reset,
        s.heading, s.reset,
        s.option,  s.reset,
        s.option,  s.reset,
        s.option,  s.reset,
        s.option,  s.reset,
        s.option,  s.reset,
        s.option,  s.reset,
        s.option,  s.reset,
        s.option,  s.reset,
        s.option,  s.reset,
        s.option,  s.reset,
    });
    outputPrint(output,
        \\{s}Examples:{s}
        \\  {s}ss render slide.ss{s}
        \\  {s}ss render slide.ss deck.pdf{s}
        \\  {s}ss render --project slides --output deck.pdf{s}
        \\  {s}ss render --format html --output deck.html slide.ss{s}
        \\
    , .{
        s.heading, s.reset,
        s.command, s.reset,
        s.command, s.reset,
        s.command, s.reset,
        s.command, s.reset,
    });
}

fn dump(output: Output) void {
    const s = style(output);
    outputPrint(output,
        \\{s}Usage:{s}
        \\  {s}ss dump [input.ss] [output.json]{s}
        \\  {s}ss dump --project FILE_OR_DIR --output output.json{s}
        \\
        \\{s}Options:{s}
        \\  {s}--project FILE_OR_DIR{s}   Load entry and asset base from ss.toml
        \\  {s}--asset-base-dir DIR{s}    Resolve relative assets from DIR
        \\  {s}--output FILE{s}           JSON output path
        \\  {s}--color auto|always|never{s}
        \\  {s}--diagnostic-level LEVEL{s} note|warning|error|off
        \\  {s}--warnings off{s}          Hide warning diagnostics
        \\  {s}--quiet{s}                 Hide progress and warning diagnostics
        \\
        \\{s}Examples:{s}
        \\  {s}ss dump slide.ss{s}
        \\  {s}ss dump slide.ss state.json{s}
        \\  {s}ss dump --project slides --output state.json{s}
        \\
    , .{
        s.heading, s.reset,
        s.command, s.reset,
        s.command, s.reset,
        s.heading, s.reset,
        s.option,  s.reset,
        s.option,  s.reset,
        s.option,  s.reset,
        s.option,  s.reset,
        s.option,  s.reset,
        s.option,  s.reset,
        s.option,  s.reset,
        s.heading, s.reset,
        s.command, s.reset,
        s.command, s.reset,
        s.command, s.reset,
    });
}

fn watch(output: Output) void {
    const s = style(output);
    outputPrint(output,
        \\{s}Usage:{s}
        \\  {s}ss watch check [input.ss]{s}
        \\  {s}ss watch render [--format pdf|html] [input.ss] [output]{s}
        \\
        \\{s}Options:{s}
        \\  {s}--project FILE_OR_DIR{s}   Load entry and asset base from ss.toml
        \\  {s}--asset-base-dir DIR{s}    Resolve relative assets from DIR
        \\  {s}--output FILE{s}           PDF or self-contained HTML file
        \\  {s}--format pdf|html{s}       Output format for watch render
        \\  {s}--interval-ms N{s}         Poll interval
        \\  {s}--jobs N{s}                Parallel render jobs
        \\  {s}--color auto|always|never{s}
        \\  {s}--diagnostic-level LEVEL{s} note|warning|error|off
        \\  {s}--warnings off{s}          Hide warning diagnostics
        \\  {s}--quiet{s}                 Hide progress and warning diagnostics
        \\
    , .{
        s.heading, s.reset,
        s.command, s.reset,
        s.command, s.reset,
        s.heading, s.reset,
        s.option,  s.reset,
        s.option,  s.reset,
        s.option,  s.reset,
        s.option,  s.reset,
        s.option,  s.reset,
        s.option,  s.reset,
        s.option,  s.reset,
        s.option,  s.reset,
        s.option,  s.reset,
        s.option,  s.reset,
    });
    outputPrint(output,
        \\{s}Examples:{s}
        \\  {s}ss watch check slide.ss{s}
        \\  {s}ss watch render slide.ss deck.pdf{s}
        \\  {s}ss watch render --format html --output deck.html slide.ss{s}
        \\  {s}ss watch render --project slides --output deck.pdf{s}
        \\
    , .{
        s.heading, s.reset,
        s.command, s.reset,
        s.command, s.reset,
        s.command, s.reset,
        s.command, s.reset,
    });
}

fn debug(output: Output) void {
    const s = style(output);
    outputPrint(output,
        \\{s}Usage:{s}
        \\  {s}ss debug schedule [input.ss] --output FILE{s}
        \\  {s}ss debug layout conflicts [input.ss] --output FILE{s}
        \\  {s}ss debug layout trace [input.ss] --output FILE{s}
        \\
        \\{s}Options:{s}
        \\  {s}--project FILE_OR_DIR{s}   Load entry and asset base from ss.toml
        \\  {s}--asset-base-dir DIR{s}    Resolve relative assets from DIR
        \\  {s}--output FILE{s}           Required JSON output path
        \\  {s}--color auto|always|never{s}
        \\  {s}--diagnostic-level LEVEL{s} note|warning|error|off
        \\  {s}--warnings off{s}          Hide warning diagnostics
        \\  {s}--quiet{s}                 Hide progress and warning diagnostics
        \\
        \\{s}Examples:{s}
        \\  {s}ss debug schedule slide.ss --output execution.json{s}
        \\  {s}ss debug layout conflicts --project slides --output layout-conflicts.json{s}
        \\
    , .{
        s.heading, s.reset,
        s.command, s.reset,
        s.command, s.reset,
        s.command, s.reset,
        s.heading, s.reset,
        s.option,  s.reset,
        s.option,  s.reset,
        s.option,  s.reset,
        s.option,  s.reset,
        s.option,  s.reset,
        s.option,  s.reset,
        s.option,  s.reset,
        s.heading, s.reset,
        s.command, s.reset,
        s.command, s.reset,
    });
}

fn cache(output: Output) void {
    const s = style(output);
    outputPrint(output,
        \\{s}Usage:{s}
        \\  {s}ss cache project clear|stats{s}
        \\  {s}ss cache tree-sitter clear|prune|stats{s}
        \\
        \\{s}Examples:{s}
        \\  {s}ss cache project stats{s}
        \\  {s}ss cache project clear{s}
        \\  {s}ss cache tree-sitter prune{s}
        \\
    , .{
        s.heading, s.reset,
        s.command, s.reset,
        s.command, s.reset,
        s.heading, s.reset,
        s.command, s.reset,
        s.command, s.reset,
        s.command, s.reset,
    });
}

fn lsp(output: Output) void {
    const s = style(output);
    outputPrint(output,
        \\{s}Usage:{s}
        \\  {s}ss lsp{s}
        \\
        \\Run the language server over stdio.
        \\
    , .{
        s.heading, s.reset,
        s.command, s.reset,
    });
}

fn version(output: Output) void {
    const s = style(output);
    outputPrint(output,
        \\{s}Usage:{s}
        \\  {s}ss version{s}
        \\  {s}ss --version{s}
        \\  {s}ss -V{s}
        \\
        \\Show build, source, native PDF, and cache schema details.
        \\
    , .{
        s.heading, s.reset,
        s.command, s.reset,
        s.command, s.reset,
        s.command, s.reset,
    });
}

fn completionHelp(output: Output) void {
    const s = style(output);
    outputPrint(output,
        \\{s}Usage:{s}
        \\  {s}ss completion bash|zsh|fish{s}
        \\  {s}ss completion bash|zsh|fish --yes{s}
        \\  {s}ss completion bash|zsh|fish --print{s}
        \\
        \\{s}Examples:{s}
        \\  {s}ss completion zsh{s}
        \\  {s}ss completion fish --yes{s}
        \\  {s}ss completion bash --print{s}
        \\
    , .{
        s.heading, s.reset,
        s.command, s.reset,
        s.command, s.reset,
        s.command, s.reset,
        s.heading, s.reset,
        s.command, s.reset,
        s.command, s.reset,
        s.command, s.reset,
    });
}

fn style(output: Output) Style {
    if (!useColor(output)) return .{};
    return .{
        .heading = "\x1b[1m",
        .command = "\x1b[36m",
        .option = "\x1b[33m",
        .reset = "\x1b[0m",
    };
}

fn useColor(output: Output) bool {
    return switch (color_mode) {
        .auto => std.c.getenv("NO_COLOR") == null and !envEquals("CLICOLOR", "0") and outputIsTty(output),
        .always => true,
        .never => false,
    };
}

fn outputIsTty(output: Output) bool {
    const fd: c_int = switch (output) {
        .stdout => 1,
        .stderr => 2,
    };
    return std.c.isatty(fd) == 1;
}

fn envEquals(name: [:0]const u8, expected: []const u8) bool {
    const value = std.c.getenv(name) orelse return false;
    return std.mem.eql(u8, std.mem.span(value), expected);
}

fn outputPrint(output: Output, comptime fmt: []const u8, args: anytype) void {
    var buffer: [12 * 1024]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, fmt, args) catch return;
    writeAll(output, text);
}

fn writeAll(output: Output, bytes: []const u8) void {
    const fd: c_int = switch (output) {
        .stdout => 1,
        .stderr => 2,
    };
    var offset: usize = 0;
    while (offset < bytes.len) {
        const n = std.c.write(fd, bytes[offset..].ptr, bytes.len - offset);
        if (n <= 0) return;
        offset += @intCast(n);
    }
}

const bash_completion =
    \\# ss bash completion
    \\_ss()
    \\{
    \\  local cur prev command
    \\  COMPREPLY=()
    \\  cur="${COMP_WORDS[COMP_CWORD]}"
    \\  prev="${COMP_WORDS[COMP_CWORD-1]}"
    \\  command="${COMP_WORDS[1]}"
    \\
    \\  local commands="init doctor check render dump watch debug cache lsp version completion help"
    \\  local common_opts="help --help -h"
    \\  local diagnostic_opts="--diagnostic-level --warnings --quiet"
    \\  local project_opts="--project --asset-base-dir --color $diagnostic_opts"
    \\  local render_opts="--project --asset-base-dir --output --format --jobs --diagnostics-json --color $diagnostic_opts"
    \\
    \\  case "$prev" in
    \\    --project|--asset-base-dir|--output|--diagnostics-json|--entry)
    \\      COMPREPLY=( $(compgen -f -- "$cur") )
    \\      return 0
    \\      ;;
    \\    --jobs|--interval-ms)
    \\      COMPREPLY=( $(compgen -W "1 2 4 8" -- "$cur") )
    \\      return 0
    \\      ;;
    \\    --format)
    \\      COMPREPLY=( $(compgen -W "pdf html" -- "$cur") )
    \\      return 0
    \\      ;;
    \\    --color)
    \\      COMPREPLY=( $(compgen -W "auto always never" -- "$cur") )
    \\      return 0
    \\      ;;
    \\    --diagnostic-level)
    \\      COMPREPLY=( $(compgen -W "note warning error off" -- "$cur") )
    \\      return 0
    \\      ;;
    \\    --warnings)
    \\      COMPREPLY=( $(compgen -W "off" -- "$cur") )
    \\      return 0
    \\      ;;
    \\  esac
    \\
    \\  if [[ $COMP_CWORD -eq 1 ]]; then
    \\    COMPREPLY=( $(compgen -W "$commands --help -h --version -V" -- "$cur") )
    \\    return 0
    \\  fi
    \\
    \\  case "$command" in
    \\    init)
    \\      COMPREPLY=( $(compgen -W "$common_opts --entry --force" -- "$cur") )
    \\      ;;
    \\    doctor)
    \\      COMPREPLY=( $(compgen -W "$common_opts --project --asset-base-dir --strict" -- "$cur") )
    \\      ;;
    \\    check|dump)
    \\      COMPREPLY=( $(compgen -W "$common_opts $project_opts --output" -- "$cur") )
    \\      ;;
    \\    render)
    \\      COMPREPLY=( $(compgen -W "$common_opts $render_opts" -- "$cur") )
    \\      ;;
    \\    watch)
    \\      if [[ $COMP_CWORD -eq 2 ]]; then
    \\        COMPREPLY=( $(compgen -W "check render help --help -h" -- "$cur") )
    \\      else
    \\        COMPREPLY=( $(compgen -W "$common_opts $render_opts --interval-ms" -- "$cur") )
    \\      fi
    \\      ;;
    \\    debug)
    \\      if [[ $COMP_CWORD -eq 2 ]]; then
    \\        COMPREPLY=( $(compgen -W "schedule layout help --help -h" -- "$cur") )
    \\      elif [[ "${COMP_WORDS[2]}" == "layout" && $COMP_CWORD -eq 3 ]]; then
    \\        COMPREPLY=( $(compgen -W "conflicts trace help --help -h" -- "$cur") )
    \\      else
    \\        COMPREPLY=( $(compgen -W "$common_opts $project_opts --output" -- "$cur") )
    \\      fi
    \\      ;;
    \\    cache)
    \\      if [[ $COMP_CWORD -eq 2 ]]; then
    \\        COMPREPLY=( $(compgen -W "project tree-sitter help --help -h" -- "$cur") )
    \\      elif [[ "${COMP_WORDS[2]}" == "project" ]]; then
    \\        COMPREPLY=( $(compgen -W "clear stats help --help -h" -- "$cur") )
    \\      else
    \\        COMPREPLY=( $(compgen -W "clear prune stats help --help -h" -- "$cur") )
    \\      fi
    \\      ;;
    \\    completion)
    \\      COMPREPLY=( $(compgen -W "bash zsh fish help --yes --print --help -h" -- "$cur") )
    \\      ;;
    \\    help)
    \\      COMPREPLY=( $(compgen -W "$commands" -- "$cur") )
    \\      ;;
    \\  esac
    \\}
    \\complete -F _ss ss
    \\
;

const zsh_completion =
    \\#compdef ss
    \\
    \\_ss() {
    \\  local -a commands
    \\  commands=(
    \\    'init:Create a project'
    \\    'doctor:Check local setup'
    \\    'check:Check source'
    \\    'render:Write PDF or HTML'
    \\    'dump:Write IR JSON'
    \\    'watch:Re-run check or render on changes'
    \\    'debug:Write schedule or layout JSON'
    \\    'cache:Manage caches'
    \\    'lsp:Run language server'
    \\    'version:Show version details'
    \\    'completion:Install shell completion'
    \\    'help:Show help'
    \\  )
    \\
    \\  local -a common_opts project_opts render_opts
    \\  common_opts=('help[show command help]' '--help[show command help]' '-h[show command help]')
    \\  project_opts=('--project[load ss.toml]:file or dir:_files' '--asset-base-dir[resolve assets from dir]:dir:_files -/' '--color[color mode]:(auto always never)' '--diagnostic-level[diagnostic display level]:(note warning error off)' '--warnings[warning display]:(off)' '--quiet[hide progress and warning diagnostics]')
    \\  render_opts=($project_opts '--output[output path]:file:_files' '--format[output format]:(pdf html)' '--jobs[parallel render jobs]:jobs:' '--diagnostics-json[diagnostics JSON path]:file:_files')
    \\
    \\  if (( CURRENT == 2 )); then
    \\    _describe 'command' commands
    \\    return
    \\  fi
    \\
    \\  case $words[2] in
    \\    init)
    \\      _arguments '*::arg:->args' '--entry[entry file]:file:_files' '--force[overwrite generated files]' $common_opts
    \\      ;;
    \\    doctor)
    \\      _arguments '*::arg:->args' '--project[load ss.toml]:file or dir:_files' '--asset-base-dir[resolve assets from dir]:dir:_files -/' '--strict[fail on issues]' $common_opts
    \\      ;;
    \\    check|dump)
    \\      _arguments '*::arg:->args' $project_opts '--output[output path]:file:_files' $common_opts
    \\      ;;
    \\    render)
    \\      _arguments '*::arg:->args' $render_opts $common_opts
    \\      ;;
    \\    watch)
    \\      _arguments '2:mode:(check render help)' '*::arg:->args' $render_opts '--interval-ms[poll interval]:milliseconds:' $common_opts
    \\      ;;
    \\    debug)
    \\      _arguments '2:topic:(schedule layout help)' '3:layout topic:(conflicts trace help)' '*::arg:->args' $project_opts '--output[output path]:file:_files' $common_opts
    \\      ;;
    \\    cache)
    \\      _arguments '2:target:(project tree-sitter help)' '3:command:(clear prune stats help)' $common_opts
    \\      ;;
    \\    completion)
    \\      _arguments '2:shell:(bash zsh fish help)' '--yes[install without prompting]' '--print[write script to stdout]' $common_opts
    \\      ;;
    \\    help)
    \\      _describe 'command' commands
    \\      ;;
    \\  esac
    \\}
    \\
    \\_ss "$@"
    \\
;

const fish_completion =
    \\# ss fish completion
    \\complete -c ss -f
    \\complete -c ss -n '__fish_use_subcommand' -a init -d 'Create a project'
    \\complete -c ss -n '__fish_use_subcommand' -a doctor -d 'Check local setup'
    \\complete -c ss -n '__fish_use_subcommand' -a check -d 'Check source'
    \\complete -c ss -n '__fish_use_subcommand' -a render -d 'Write PDF or HTML'
    \\complete -c ss -n '__fish_use_subcommand' -a dump -d 'Write IR JSON'
    \\complete -c ss -n '__fish_use_subcommand' -a watch -d 'Re-run check or render on changes'
    \\complete -c ss -n '__fish_use_subcommand' -a debug -d 'Write schedule or layout JSON'
    \\complete -c ss -n '__fish_use_subcommand' -a cache -d 'Manage caches'
    \\complete -c ss -n '__fish_use_subcommand' -a lsp -d 'Run language server'
    \\complete -c ss -n '__fish_use_subcommand' -a version -d 'Show version details'
    \\complete -c ss -n '__fish_use_subcommand' -a completion -d 'Install shell completion'
    \\complete -c ss -n '__fish_use_subcommand' -a help -d 'Show help'
    \\
    \\complete -c ss -s h -l help -d 'Show help'
    \\complete -c ss -s V -l version -d 'Show version details'
    \\
    \\complete -c ss -n '__fish_seen_subcommand_from init' -l entry -r -d 'Entry file to create'
    \\complete -c ss -n '__fish_seen_subcommand_from init' -l force -d 'Overwrite generated files'
    \\
    \\complete -c ss -n '__fish_seen_subcommand_from check dump render doctor watch debug' -l project -r -d 'Load entry and asset base from ss.toml'
    \\complete -c ss -n '__fish_seen_subcommand_from check dump render doctor watch debug' -l asset-base-dir -r -d 'Resolve relative assets from DIR'
    \\complete -c ss -n '__fish_seen_subcommand_from check dump render doctor watch debug' -l color -r -a 'auto always never' -d 'Color mode'
    \\complete -c ss -n '__fish_seen_subcommand_from check dump render watch debug' -l diagnostic-level -r -a 'note warning error off' -d 'Diagnostic display level'
    \\complete -c ss -n '__fish_seen_subcommand_from check dump render watch debug' -l warnings -r -a 'off' -d 'Warning display'
    \\complete -c ss -n '__fish_seen_subcommand_from check dump render watch debug' -l quiet -d 'Hide progress and warning diagnostics'
    \\complete -c ss -n '__fish_seen_subcommand_from dump render watch debug' -l output -r -d 'Output path'
    \\complete -c ss -n '__fish_seen_subcommand_from render watch' -l format -r -a 'pdf html' -d 'Output format'
    \\complete -c ss -n '__fish_seen_subcommand_from render watch' -l jobs -r -d 'Parallel render jobs'
    \\complete -c ss -n '__fish_seen_subcommand_from render' -l diagnostics-json -r -d 'Diagnostics JSON path'
    \\complete -c ss -n '__fish_seen_subcommand_from watch' -l interval-ms -r -d 'Poll interval'
    \\complete -c ss -n '__fish_seen_subcommand_from doctor' -l strict -d 'Fail on issues'
    \\complete -c ss -n '__fish_seen_subcommand_from completion' -l yes -d 'Install without prompting'
    \\complete -c ss -n '__fish_seen_subcommand_from completion' -l print -d 'Write script to stdout'
    \\
    \\complete -c ss -n '__fish_seen_subcommand_from watch' -a 'check render help' -d 'Watch mode'
    \\complete -c ss -n '__fish_seen_subcommand_from debug' -a 'schedule layout help' -d 'Debug topic'
    \\complete -c ss -n '__fish_seen_subcommand_from cache' -a 'project tree-sitter help' -d 'Cache target'
    \\complete -c ss -n '__fish_seen_subcommand_from completion' -a 'bash zsh fish help' -d 'Shell'
    \\complete -c ss -n '__fish_seen_subcommand_from help' -a 'init doctor check render dump watch debug cache lsp version completion' -d 'Command'
    \\
;
