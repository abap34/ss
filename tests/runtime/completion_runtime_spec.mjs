#!/usr/bin/env node
import { execFile, spawn } from "node:child_process";
import { mkdtemp, readFile, rm, stat, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { promisify } from "node:util";
import { assert, root, ssBin } from "./harness.mjs";

const execFileAsync = promisify(execFile);

await testCompletionPrintsScriptWithoutInstalling();
await testPackageCommandHelp();
await testBashCompletionInstallsWithYes();
await testFishCompletionAsksBeforeWriting();
await testDeniedCompletionInstallDoesNotWrite();
await testZshCompletionAddsInitBlockOnce();

async function testCompletionPrintsScriptWithoutInstalling() {
  const home = await mkdtempHome("ss-completion-print-");
  try {
    const xdgData = path.join(home, "data");
    const result = await runCompletion(["completion", "bash", "--print"], home, { XDG_DATA_HOME: xdgData });
    assert(result.code === 0, `completion --print failed:\n${combined(result)}`);
    assert(result.stdout.includes("# ss bash completion"), `bash script was not printed:\n${combined(result)}`);
    assertRenderFormatCompletion(result.stdout, "bash");
    await assertCacheForceCompletion(result.stdout, "bash", home);
    await assertPackageCompletion(result.stdout, "bash", home);
    await assertInitCompletion(result.stdout, "bash", home);
    for (const shell of ["zsh", "fish"]) {
      const printed = await runCompletion(["completion", shell, "--print"], home, { XDG_DATA_HOME: xdgData });
      assert(printed.code === 0, `${shell} completion --print failed:\n${combined(printed)}`);
      assertRenderFormatCompletion(printed.stdout, shell);
      await assertInitCompletion(printed.stdout, shell, home);
      await assertCacheForceCompletion(printed.stdout, shell, home);
      if (shell !== "zsh") await assertPackageCompletion(printed.stdout, shell, home);
    }
    assert(!(await exists(path.join(xdgData, "bash-completion", "completions", "ss"))), "--print should not install completion files");
  } finally {
    await rm(home, { recursive: true, force: true });
  }
}

function assertRenderFormatCompletion(script, shell) {
  assert(!/\bcheck\b/.test(script), `${shell} still offers the removed check command`);
  assert(script.includes("--format") || script.includes("-l format"), `${shell} completion omitted --format`);
  assert(script.includes("pdf html"), `${shell} completion omitted PDF and HTML format values`);
}

async function assertCacheForceCompletion(script, shell, home) {
  const scriptPath = path.join(home, `completion.${shell}`);
  await writeFile(scriptPath, script);
  const args = shell === "bash" ? ["-c", `
    source "$1" || exit 1
    COMP_WORDS=(ss cache project clear --f)
    COMP_CWORD=4
    _ss
    [[ "\${COMPREPLY[*]}" == "--force" ]] || exit 1
    COMP_WORDS=(ss cache project stats --f)
    _ss
    [[ \${#COMPREPLY[@]} -eq 0 ]] || exit 1
    COMP_WORDS=(ss cache tree-sitter clear --f)
    _ss
    [[ \${#COMPREPLY[@]} -eq 0 ]] || exit 1
  `, "--", scriptPath] : shell === "fish" ? ["--no-config", "-c", `
    source $argv[1]; or exit 1
    string match -q -- '--force*' (complete --do-complete 'ss cache project clear --f'); or exit 1
    for line in 'ss cache project stats --f' 'ss cache tree-sitter clear --f'
      if string match -q -- '--force*' (complete --do-complete $line)
        exit 1
      end
    end
  `, "--", scriptPath] : ["-n", scriptPath];
  await runShellCheck(shell, args, home, "cache force completion");
}

async function runShellCheck(shell, args, cwd, label) {
  try {
    const result = await execFileAsync(shell, args, { cwd, timeout: 10_000 });
    console.log(`${shell} ${label} passed`);
    return result.stdout;
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
    console.log(`${shell} completion execution skipped: shell unavailable`);
    return null;
  }
}

async function assertPackageCompletion(script, shell, home) {
  const scriptPath = path.join(home, `packages.${shell}`);
  await writeFile(scriptPath, script);
  await writeFile(path.join(home, "project manifest.toml"), "");
  await writeFile(path.join(home, "local repository"), "");
  const args = shell === "bash" ? ["-c", `
    source "$1" || exit 1
    complete_line() {
      COMP_WORDS=("$@")
      COMP_CWORD=$((\${#COMP_WORDS[@]} - 1))
      _ss
    }
    expect_candidate() { [[ " \${COMPREPLY[*]} " == *" $1 "* ]] || { printf 'missing completion: %s\\n' "$1" >&2; exit 1; }; }
    for prefix in '' help; do
      if [[ -z "$prefix" ]]; then complete_line ss ''; else complete_line ss "$prefix" ''; fi
      for command in add fetch update status; do expect_candidate "$command"; done
    done
    complete_line ss add --
    for option in --git --tag --branch --rev --project; do expect_candidate "$option"; done
    complete_line ss add --git 'repository --tag backup' --
    for option in --tag --branch --rev; do expect_candidate "$option"; done
    for command in fetch update status; do
      complete_line ss "$command" --
      expect_candidate --project
      [[ " \${COMPREPLY[*]} " != *' --git '* ]] || exit 1
      complete_line ss "$command" --project project
      [[ \${#COMPREPLY[@]} -eq 1 && "\${COMPREPLY[0]}" == 'project manifest.toml' ]] || exit 1
    done
    complete_line ss status --
    expect_candidate --color
    for option in --git --locked --asset-base-dir; do
      [[ " \${COMPREPLY[*]} " != *" $option "* ]] || exit 1
    done
    complete_line ss status --color ''
    for mode in auto always never; do expect_candidate "$mode"; done
    complete_line ss fetch --
    expect_candidate --locked
    complete_line ss update --
    [[ " \${COMPREPLY[*]} " != *' --locked '* ]] || exit 1
    complete_line ss add --git local
    [[ \${#COMPREPLY[@]} -eq 1 && "\${COMPREPLY[0]}" == 'local repository' ]] || exit 1
    for selector in --tag --branch --rev; do
      complete_line ss add "$selector" ''
      [[ \${#COMPREPLY[@]} -eq 0 ]] || exit 1
      complete_line ss add "$selector" v1 --
      expect_candidate --project
      for excluded in --tag --branch --rev; do
        [[ " \${COMPREPLY[*]} " != *" $excluded "* ]] || exit 1
      done
    done
  `, "--", scriptPath] : ["--no-config", "-c", `
    complete -c ss -e
    source $argv[1]; or exit 1
    function candidates
      complete --do-complete "$argv[1]" | string split -f1 \\t
    end
    for prefix in 'ss ' 'ss help '
      set -l results (candidates $prefix)
      for command in add fetch update status
        contains -- $command $results; or exit 1
      end
    end
    set -l results (candidates 'ss add --')
    for option in --git --tag --branch --rev --project
      contains -- $option $results; or exit 1
    end
    for command in fetch update status
      set results (candidates "ss $command --")
      contains -- --project $results; or exit 1
      contains -- --git $results; and exit 1
      string match -q '*project*manifest.toml*' (candidates "ss $command --project project"); or exit 1
    end
    contains -- --color (candidates "ss status --"); or exit 1
    for option in --git --locked --asset-base-dir
      contains -- $option (candidates "ss status --"); and exit 1
    end
    for mode in auto always never
      contains -- $mode (candidates "ss status --color "); or exit 1
    end
    contains -- --locked (candidates "ss fetch --"); or exit 1
    contains -- --locked (candidates "ss update --"); and exit 1
    string match -q '*local*repository*' (candidates 'ss add --git local'); or exit 1
    for selector in --tag --branch --rev
      test (count (candidates "ss add $selector ")) -eq 0; or exit 1
      set results (candidates "ss add $selector v1 --")
      contains -- --project $results; or exit 1
      for excluded in --tag --branch --rev
        contains -- $excluded $results; and exit 1
      end
    end
    exit 0
  `, "--", scriptPath];
  await runShellCheck(shell, args, home, "package completion behavior");
}

async function testPackageCommandHelp() {
  const home = await mkdtempHome("ss-packages-help-");
  try {
    const general = await runCompletion(["--help"], home);
    assert(general.code === 0, `general help failed:\n${combined(general)}`);
    for (const command of ["init", "add", "fetch", "update", "status"]) {
      assert(general.stdout.includes(`ss ${command}`), `general help omitted ${command}`);
      for (const args of [[command, "--help"], [command, "-h"], [command, "help"], ["help", command]]) {
        const result = await runCompletion(args, home);
        assert(result.code === 0, `ss ${args.join(" ")} failed:\n${combined(result)}`);
        assert(result.stdout.includes(`ss ${command}`), `command help omitted ${command}`);
        const options = command === "init"
          ? ["--package", "--entry", "--force", "--user", "--host", "--no-git"]
          : command === "add"
            ? ["--git", "--tag", "--branch", "--rev", "--project"]
            : command === "fetch" ? ["--locked", "--project"]
              : command === "status" ? ["--project", "--color"] : ["--project"];
        for (const option of options) {
          assert(result.stdout.includes(option), `command help omitted ${option}`);
        }
        if (command === "init") {
          assert(result.stdout.includes("With --package, initialize Git"), "Git setup must be described as package-only");
        }
        assert(!/ss (?:watch )?check\b/.test(result.stdout), "help advertises the removed check command");
      }
    }
  } finally {
    await rm(home, { recursive: true, force: true });
  }
}

async function testBashCompletionInstallsWithYes() {
  const home = await mkdtempHome("ss-completion-bash-");
  try {
    const xdgData = path.join(home, "data");
    const result = await runCompletion(["completion", "bash", "--yes"], home, { XDG_DATA_HOME: xdgData });
    assert(result.code === 0, `bash completion install failed:\n${combined(result)}`);
    const target = path.join(xdgData, "bash-completion", "completions", "ss");
    const script = await readFile(target, "utf8");
    assert(script.includes("complete -F _ss ss"), `bash completion was not written to ${target}`);
    assert(result.stderr.includes(`create ${target}`), `install plan did not mention bash target:\n${combined(result)}`);
  } finally {
    await rm(home, { recursive: true, force: true });
  }
}

async function testFishCompletionAsksBeforeWriting() {
  const home = await mkdtempHome("ss-completion-fish-");
  try {
    const xdgConfig = path.join(home, "config");
    const target = path.join(xdgConfig, "fish", "completions", "ss.fish");
    const result = await runCompletion(["completion", "fish"], home, { XDG_CONFIG_HOME: xdgConfig }, "y\n");
    assert(result.code === 0, `fish completion install failed:\n${combined(result)}`);
    assert(result.stderr.includes("Proceed? [y/N]"), `fish install did not prompt:\n${combined(result)}`);
    const script = await readFile(target, "utf8");
    assert(script.includes("complete -c ss"), `fish completion was not written to ${target}`);
  } finally {
    await rm(home, { recursive: true, force: true });
  }
}

async function testDeniedCompletionInstallDoesNotWrite() {
  const home = await mkdtempHome("ss-completion-deny-");
  try {
    const xdgConfig = path.join(home, "config");
    const target = path.join(xdgConfig, "fish", "completions", "ss.fish");
    const result = await runCompletion(["completion", "fish"], home, { XDG_CONFIG_HOME: xdgConfig }, "n\n");
    assert(result.code === 0, `denied fish completion command should succeed:\n${combined(result)}`);
    assert(result.stderr.includes("completion install cancelled"), `denied install did not report cancellation:\n${combined(result)}`);
    assert(!(await exists(target)), `denied install should not create ${target}`);
  } finally {
    await rm(home, { recursive: true, force: true });
  }
}

async function testZshCompletionAddsInitBlockOnce() {
  const home = await mkdtempHome("ss-completion-zsh-");
  try {
    const zshrc = path.join(home, ".zshrc");
    await writeFile(zshrc, "# user config\n", "utf8");
    const target = path.join(home, ".zsh", "completions", "_ss");

    const first = await runCompletion(["completion", "zsh", "--yes"], home);
    assert(first.code === 0, `zsh completion install failed:\n${combined(first)}`);
    const script = await readFile(target, "utf8");
    assert(script.includes("#compdef ss"), `zsh completion was not written to ${target}`);
    const firstZshrc = await readFile(zshrc, "utf8");
    assert(firstZshrc.includes("# >>> ss completion >>>"), `zsh init block was not added:\n${firstZshrc}`);

    const second = await runCompletion(["completion", "zsh", "--yes"], home);
    assert(second.code === 0, `second zsh completion install failed:\n${combined(second)}`);
    const secondZshrc = await readFile(zshrc, "utf8");
    assert(countOccurrences(secondZshrc, "# >>> ss completion >>>") === 1, `zsh init block was duplicated:\n${secondZshrc}`);
    assert(second.stderr.includes(`already current ${zshrc}`), `second install did not report current zshrc:\n${combined(second)}`);
  } finally {
    await rm(home, { recursive: true, force: true });
  }
}

async function runCompletion(args, home, extraEnv = {}, input = "") {
  return await new Promise((resolve, reject) => {
    const child = spawn(ssBin, args, {
      cwd: root,
      env: {
        ...process.env,
        HOME: home,
        ...extraEnv,
      },
      stdio: ["pipe", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    const timeout = setTimeout(() => {
      child.kill();
      reject(new Error(`completion command timed out: ss ${args.join(" ")}`));
    }, 10000);
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk) => {
      stdout += chunk;
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk;
    });
    child.on("error", (error) => {
      clearTimeout(timeout);
      reject(error);
    });
    child.on("close", (code) => {
      clearTimeout(timeout);
      resolve({ code: code ?? -1, stdout, stderr });
    });
    child.stdin.end(input);
  });
}

async function mkdtempHome(prefix) {
  return await mkdtemp(path.join(os.tmpdir(), prefix));
}

async function exists(filePath) {
  try {
    await stat(filePath);
    return true;
  } catch (error) {
    if (error?.code === "ENOENT") return false;
    throw error;
  }
}

function countOccurrences(text, needle) {
  return text.split(needle).length - 1;
}

function combined(result) {
  return `${result.stdout}\n${result.stderr}`;
}

async function assertInitCompletion(script, shell, home) {
  const scriptPath = path.join(home, `init.${shell}`);
  await writeFile(scriptPath, script);
  const args = shell === "bash" ? ["-c", `
    source "$1" || exit 1
    COMP_WORDS=(ss init --p)
    COMP_CWORD=2
    _ss
    [[ "\${COMPREPLY[*]}" == "--package" ]] || exit 1
    for option in --user --host --no-git; do
      COMP_WORDS=(ss init "$option")
      COMP_CWORD=2
      _ss
      [[ "\${COMPREPLY[*]}" == "$option" ]] || exit 1
    done
    COMP_WORDS=(ss init --user '')
    COMP_CWORD=3
    _ss
    [[ \${#COMPREPLY[@]} -eq 0 ]] || exit 1
    COMP_WORDS=(ss init --host '')
    _ss
    [[ \${#COMPREPLY[@]} -eq 0 ]] || exit 1
    COMP_WORDS=(ss init --package --e)
    COMP_CWORD=3
    _ss
    [[ "\${COMPREPLY[*]}" == "--entry" ]] || exit 1
  `, "--", scriptPath] : shell === "fish" ? ["--no-config", "-c", `
    source $argv[1]; or exit 1
    string match -q -- '--package*' (complete --do-complete 'ss init --p'); or exit 1
    for option in user host no-git
      string match -q -- --$option'*' (complete --do-complete "ss init --$option"); or exit 1
    end
    string match -q -- '--entry*' (complete --do-complete 'ss init --package --e'); or exit 1
  `, "--", scriptPath] : ["-n", scriptPath];
  assert(script.includes(shell === "fish" ? "-l package" : "--package"), `${shell} omitted --package`);
  await runShellCheck(shell, args, home, "init package completion");
}
