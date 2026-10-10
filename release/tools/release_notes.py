#!/usr/bin/env python3
"""Collect merged PRs and credit their authors in locally written release notes."""

import argparse
import json
import pathlib
import re
import subprocess


def command(root, args):
    try:
        result = subprocess.run(args, cwd=root, text=True, capture_output=True, timeout=60)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise ValueError(f"Could not read release information: {error}") from error
    if result.returncode:
        raise ValueError(result.stderr.strip() or f"Command failed: {' '.join(args)}")
    return result.stdout


def release_commits(root, previous, base):
    revision = f"{previous}..{base}" if previous else base
    output = command(root, ["git", "log", "--reverse", "--format=%H\t%s", revision])
    return [tuple(line.split("\t", 1)) for line in output.splitlines() if line]


def collect_pull_requests(root, commits, snapshot=None):
    if not commits:
        return []
    if snapshot is None:
        output = command(root, [
            "gh", "api", "--method", "GET", "--paginate", "--slurp",
            "repos/{owner}/{repo}/pulls?state=closed&per_page=100",
        ])
    else:
        output = pathlib.Path(snapshot).read_text(encoding="utf-8")
    data = json.loads(output)
    # gh --paginate --slurp returns pages; saved snapshots may be flat arrays.
    if not isinstance(data, list):
        raise ValueError("Pull request data must be a JSON array.")
    if data and isinstance(data[0], list):
        data = [pr for page in data for pr in page]
    hashes = {commit for commit, _ in commits}
    selected = {}
    for pr in data:
        if pr.get("merged_at") and pr.get("merge_commit_sha") in hashes:
            if not pr.get("user", {}).get("login"):
                raise ValueError(f"Missing author for pull request #{pr['number']}.")
            selected[pr["number"]] = pr
    return [selected[number] for number in sorted(selected)]


def human_author(pr):
    user = pr["user"]
    return user.get("type") != "Bot" and not user["login"].endswith("[bot]")


def visible_markdown(body):
    """Mask code without changing offsets used to locate prose references."""
    lines = []
    fence = None
    for line in body.splitlines(keepends=True):
        marker = re.match(r"^\s*(`{3,}|~{3,})", line)
        if fence:
            if marker and marker[1][0] == fence[0] and len(marker[1]) >= len(fence):
                fence = None
            lines.append(re.sub(r"[^\n]", " ", line))
        elif marker:
            fence = marker[1]
            lines.append(re.sub(r"[^\n]", " ", line))
        else:
            lines.append(re.sub(r"(`+).*?\1", lambda m: " " * len(m[0]), line))
    return "".join(lines)


def credit_notes(body, pull_requests):
    """Use explicit PR references; require human contributions to be described."""
    by_number = {pr["number"]: pr for pr in pull_requests}
    credited = set()
    visible = visible_markdown(body)
    edits = []
    for match in re.finditer(r"(?m)^- [^\n]*(?:\n[ \t]+[^\n]*)*", body):
        prose = visible[match.start():match.end()]
        if not prose.startswith("- "):
            continue
        numbers = set()
        references = prose
        for link in re.finditer(r"\[[^\]]*\]\(([^)]+)\)", prose):
            numbers.update(pr["number"] for pr in pull_requests if pr["html_url"] == link[1])
            references = references[:link.start()] + " " * len(link[0]) + references[link.end():]
        numbers.update(int(m[1]) for m in re.finditer(r"(?<![\w/])#([1-9]\d*)\b", references))
        numbers.update(pr["number"] for pr in pull_requests if re.search(re.escape(pr["html_url"]) + r"(?![\w/])", references))
        prs = [by_number[number] for number in sorted(numbers & by_number.keys())]
        if not prs:
            continue
        credited.update(pr["number"] for pr in prs)
        text = match[0]
        # Link bare #123 references while preserving existing Markdown links.
        for ref in reversed(list(re.finditer(r"(?<![\w/])#([1-9]\d*)\b", references))):
            pr = by_number.get(int(ref[1]))
            if pr:
                text = text[:ref.start()] + f"[#{pr['number']}]({pr['html_url']})" + text[ref.end():]
        authors = sorted({pr["user"]["login"] for pr in prs if human_author(pr)})
        missing = [author for author in authors if not re.search(rf"(?<![\w@])@{re.escape(author)}(?![\w-])", prose)]
        if missing:
            text = text.rstrip()
            if not text.endswith((".", "!", "?")):
                text += "."
            text += " Contributed by " + ", ".join(f"@{author}" for author in missing) + "."
        edits.append((match.start(), match.end(), text))

    missing_prs = [pr for pr in pull_requests if human_author(pr) and pr["number"] not in credited]
    if missing_prs:
        details = "\n".join(f"  #{pr['number']} by @{pr['user']['login']}: {pr['title']}" for pr in missing_prs)
        raise ValueError("Add these PR references to their matching change descriptions before preparing the release:\n" + details)

    for start, end, text in reversed(edits):
        body = body[:start] + text + body[end:]
    authors = sorted({pr["user"]["login"] for pr in pull_requests if human_author(pr)})
    thanks = re.search(r"(?m)^### Thanks\s*\n(?P<body>.*?)(?=^#{1,3} |\Z)", body, re.DOTALL)
    existing = thanks["body"] if thanks else ""
    missing = [author for author in authors if not re.search(rf"(?<![\w@])@{re.escape(author)}(?![\w-])", existing)]
    if missing:
        sentence = "Thanks to " + ", ".join(f"@{author}" for author in missing) + " for contributing to this release!"
        if thanks:
            end = thanks.end()
            body = body[:end].rstrip() + "\n\n" + sentence + "\n\n" + body[end:]
        else:
            body = body.rstrip() + "\n\n### Thanks\n\n" + sentence
    return body.strip()


def draft_notes(commits, pull_requests):
    by_commit = {pr["merge_commit_sha"]: pr for pr in pull_requests}
    bullets = []
    for commit, subject in commits:
        pr = by_commit.get(commit)
        if pr:
            subject = pr["title"]
            subject = f"{subject.rstrip('.')} (#{pr['number']})"
        if not subject.endswith((".", "!", "?")):
            subject += "."
        bullets.append(f"- {subject}")
    body = "### Changed\n\n" + ("\n".join(bullets) or "- Prepared release metadata.")
    return credit_notes(body, pull_requests)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", default="HEAD", help="Last implementation commit in the release.")
    parser.add_argument("--previous-tag", required=True, help="Exclusive starting tag for the release.")
    parser.add_argument("--pull-requests", type=pathlib.Path, help="Saved PR JSON; avoids GitHub access.")
    parser.add_argument("--body", type=pathlib.Path, help="Written Markdown body with explicit #PR references.")
    parser.add_argument("--collect", action="store_true", help="Print selected PR JSON for local review and reuse.")
    args = parser.parse_args()
    root = pathlib.Path(command(pathlib.Path.cwd(), ["git", "rev-parse", "--show-toplevel"]).strip())
    commits = release_commits(root, args.previous_tag, args.base)
    prs = collect_pull_requests(root, commits, args.pull_requests)
    if args.collect:
        print(json.dumps(prs, indent=2, ensure_ascii=False))
    elif args.body:
        print(credit_notes(args.body.read_text(encoding="utf-8"), prs))
    else:
        print(draft_notes(commits, prs))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError) as error:
        raise SystemExit(str(error))
