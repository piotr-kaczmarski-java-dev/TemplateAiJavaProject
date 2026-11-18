#!/usr/bin/env bash
# Creates a new, initialised project from this template. Template-only (not copied into projects).
#   1. Copies the template's files (tracked + untracked-but-not-ignored; no build output, node_modules, .git).
#   2. Runs tools/init-project.sh in the copy (package, artifact, placeholders, git, hooks).
#   3. Installs frontend dependencies + Playwright Chromium (skip with --no-install).
#   4. Adds a `template` remote (for pulling later tooling updates) and makes the initial commit,
#      recording the template commit it came from.
#   5. Optional: --github creates a GitHub repo with `gh` and pushes.
#
# Usage: tools/new-project.sh --name "My App" [--group com.acme] [--artifact my-app] [--package com.acme.myapp]
#                             [--folder my-app] [--parent DIR] [--no-install] [--github [--owner X] [--public]]
#   defaults: --folder = artifact, --parent = the folder that contains this template
set -euo pipefail
source "$(dirname "$0")/_lib.sh"
template="$ROOT"

name="" folder="" parent="" install=1 github=0 owner="" public=0 init_args=()
while (( $# )); do
    case "$1" in
        --name) name="$2"; init_args+=(--name "$2"); shift ;;
        --group|--package) init_args+=("$1" "$2"); shift ;;
        --artifact) init_args+=("$1" "$2"); folder="${folder:-$2}"; shift ;;
        --folder) folder="$2"; shift ;;
        --parent) parent="$2"; shift ;;
        --no-install) install=0 ;;
        --github) github=1 ;;
        --owner) owner="$2"; shift ;;
        --public) public=1 ;;
        -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1"; exit 3 ;;
    esac
    shift
done
step() { printf '==> %s\n' "$*"; }
die() { printf 'FAIL  %s\n' "$*"; exit 1; }

[[ -n "$name" ]] || die "--name is required"
[[ -n "$folder" ]] || folder="$(tr '[:upper:]' '[:lower:]' <<<"$name" | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g')"
[[ -n "$parent" ]] || parent="$(dirname "$template")"
dest="$(realpath -m "$parent/$folder")"
[[ -e "$dest" ]] && die "$dest already exists - pick another --name/--folder or remove it."
git -C "$template" rev-parse --git-dir >/dev/null 2>&1 || die "the template must be a git repository (git init && git commit first)."

template_url="$(git -C "$template" remote get-url origin 2>/dev/null || true)"
template_ref="$(git -C "$template" rev-parse --short HEAD 2>/dev/null || echo uncommitted)"
if (( github )); then
    have gh || die "gh (GitHub CLI) not found; install it or drop --github."
    [[ -z "$owner" && "$template_url" =~ github\.com[:/]([^/]+)/ ]] && owner="${BASH_REMATCH[1]}"
    [[ -n "$owner" ]] || owner="$(gh api user -q .login 2>/dev/null || true)"
    [[ -n "$owner" ]] || die "cannot infer the GitHub owner; pass --owner."
fi
dirty="$(git -C "$template" status --porcelain | wc -l)"
(( dirty )) && echo "NOTE  the template has $dirty uncommitted change(s); they are copied as they are on disk."

# ---------------------------------------------------------------- 1. copy
step "Copying template ($template_ref) to $dest"
n=0
while IFS= read -r -d '' f; do
    [[ "$f" == tools/new-project.sh ]] && continue          # template-only
    [[ -e "$template/$f" ]] || continue                     # deleted locally but still tracked
    mkdir -p "$dest/$(dirname "$f")"
    cp -p "$template/$f" "$dest/$f"
    n=$((n + 1))
done < <(git -C "$template" ls-files -z --cached --others --exclude-standard)
echo "    $n files"

# ---------------------------------------------------------------- 2. initialise
step "Initialising '$name'"
"$dest/tools/init-project.sh" "${init_args[@]}" | sed -n '/^Next steps:/q;p' | sed '/^$/d; s/^/    /'

# ---------------------------------------------------------------- 3. install
if (( install )); then
    step "Installing frontend dependencies + Playwright Chromium"
    (cd "$dest/frontend" && npm ci --no-audit --no-fund --loglevel=error && npx playwright install chromium >/dev/null) \
        || echo "    install failed - run it later: cd frontend && npm ci && npx playwright install chromium"
fi

# ---------------------------------------------------------------- 4. remote + initial commit
cd "$dest"
git remote add template "${template_url:-$template}"
step "Initial commit (runs the pre-commit repo lint)"
git add -A
git commit -q -m "Initial project '$name' from template $template_ref" -m "Template: ${template_url:-$template}" \
    || die "initial commit failed - see the lint output above."

if (( github )); then
    vis=--private
    (( public )) && vis=--public
    step "Creating GitHub repo $owner/$folder (${vis#--}) and pushing"
    gh repo create "$owner/$folder" "$vis" --source . --remote origin --push \
        || die "gh repo create failed (the local project is fine; create the remote by hand)."
fi

echo
echo "OK  '$name' created at $dest"
echo "Next:"
echo "  cd \"$dest\""
echo "  tools/check.sh && tools/test.sh      # Docker running for *IT tests"
echo "  claude                               # then run /kickoff"
(( github )) || echo "  Remote: gh repo create <owner>/$folder --private --source . --remote origin --push"
echo "Later template updates: git fetch template && git checkout template/main -- tools .claude .githooks .github AGENTS.md CLAUDE.md"
