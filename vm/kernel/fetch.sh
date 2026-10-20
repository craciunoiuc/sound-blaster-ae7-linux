#!/usr/bin/env bash
# vm/kernel/fetch.sh — get linux-stable $KVER into $LINUX_SRC and put
# vm/patches/*.patch on branch $LINUX_BRANCH with git am. Idempotent.
set -euo pipefail

# shellcheck source=../config.sh
source "$(dirname "${BASH_SOURCE[0]}")/../config.sh"

PATCH_DIR="$VM_DIR/patches"
FORCE=0

usage() {
	cat <<-EOF
	Usage: ${0##*/} [--force]

	Clone $LINUX_URL at $KVER into $LINUX_SRC (shallow) if missing.
	Then set branch $LINUX_BRANCH to $KVER plus vm/patches/*.patch (git am).
	Does nothing if $LINUX_BRANCH already has exactly that content.

	  --force   discard local changes and commits that are not in vm/patches
	EOF
}

die() { echo "fetch.sh: error: $*" >&2; exit 1; }
log() { echo "fetch.sh: $*"; }

for arg in "$@"; do
	case "$arg" in
	--force) FORCE=1 ;;
	-h|--help) usage; exit 0 ;;
	*) usage >&2; exit 2 ;;
	esac
done

g() { git -C "$LINUX_SRC" "$@"; }

if [[ ! -d "$LINUX_SRC/.git" ]]; then
	[[ ! -e "$LINUX_SRC" ]] || die "$LINUX_SRC exists but is not a git repository"
	log "cloning $KVER from $LINUX_URL (shallow)"
	git -c advice.detachedHead=false clone --depth 1 --branch "$KVER" "$LINUX_URL" "$LINUX_SRC"
fi

if ! g rev-parse -q --verify "refs/tags/$KVER^{commit}" >/dev/null; then
	log "fetching tag $KVER"
	g fetch --depth 1 origin tag "$KVER"
fi
base="$(g rev-parse "$KVER^{commit}")"

# The clone gets the committer identity from the outer repo if it has none.
GIT_ID=()
if ! g config user.email >/dev/null; then
	GIT_ID=(-c "user.name=$(git -C "$REPO" config user.name)"
		-c "user.email=$(git -C "$REPO" config user.email)")
fi

if [[ -d "$(g rev-parse --absolute-git-dir)/rebase-apply" ]]; then
	if ((FORCE)); then
		g am --abort || true
	else
		die "a git am or rebase is in progress in $LINUX_SRC (finish it, or use --force)"
	fi
fi

shopt -s nullglob
patches=("$PATCH_DIR"/*.patch)
shopt -u nullglob

# Apply all patches to a temporary index to get the target tree.
# This makes sure that the patches apply before the work tree changes.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
want_tree="$(
	export GIT_INDEX_FILE="$tmp/index"
	g read-tree "$base"
	for p in "${patches[@]}"; do
		g apply --cached "$p" || die "${p##*/} does not apply on $KVER (or on the patches before it)"
	done
	g write-tree
)"

branch_ref="refs/heads/$LINUX_BRANCH"
have_branch=0
g rev-parse -q --verify "$branch_ref" >/dev/null && have_branch=1

print_applied() {
	local n
	n="$(g rev-list --count "$base..$LINUX_BRANCH")"
	log "$LINUX_BRANCH = $KVER + $n patch(es):"
	g log --reverse --format='  %h %s' "$base..$LINUX_BRANCH"
}

dirty="$(g status --porcelain)"

if ((have_branch)) &&
	g merge-base --is-ancestor "$base" "$LINUX_BRANCH" &&
	[[ "$(g rev-parse "$LINUX_BRANCH^{tree}")" == "$want_tree" ]]; then
	if [[ "$(g symbolic-ref -q HEAD || true)" != "$branch_ref" ]]; then
		g checkout -q "$LINUX_BRANCH"
	fi
	log "up to date, nothing to apply"
	[[ -z "$dirty" ]] || log "warning: $LINUX_SRC has local changes, the build uses them"
	print_applied
	exit 0
fi

# Find the commits on the branch that no patch file contains (by patch-id).
lost=()
if ((have_branch)) && g merge-base --is-ancestor "$base" "$LINUX_BRANCH"; then
	declare -A known=()
	for p in "${patches[@]}"; do
		while read -r id _; do
			known[$id]=1
		done < <(g patch-id --stable <"$p")
	done
	for c in $(g rev-list --reverse "$base..$LINUX_BRANCH"); do
		id="$(g show --no-color --format= "$c" | g patch-id --stable | awk '{print $1}')"
		[[ -n "$id" && -n "${known[$id]:-}" ]] || lost+=("$c")
	done
elif ((have_branch)); then
	mapfile -t lost < <(g rev-list --max-count=20 "$LINUX_BRANCH" --not "$base")
fi

if [[ -n "$dirty" || ${#lost[@]} -gt 0 ]]; then
	if ((FORCE)); then
		log "--force: discarding local changes and ${#lost[@]} unexported commit(s)"
	else
		[[ -z "$dirty" ]] || { echo "Local changes in $LINUX_SRC:" >&2; echo "$dirty" | head -20 >&2; }
		if ((${#lost[@]})); then
			echo "Commits on $LINUX_BRANCH that are not in vm/patches:" >&2
			for c in "${lost[@]}"; do g log -1 --format='  %h %s' "$c" >&2; done
			echo "Export them: git -C $LINUX_SRC format-patch -o $PATCH_DIR $KVER..$LINUX_BRANCH" >&2
		fi
		die "refusing to reset $LINUX_BRANCH (use --force to discard)"
	fi
fi

log "resetting $LINUX_BRANCH to $KVER"
if ((FORCE)); then
	g checkout -q -f -B "$LINUX_BRANCH" "$base"
	g clean -fdq
else
	g checkout -q -B "$LINUX_BRANCH" "$base"
fi

for p in "${patches[@]}"; do
	log "applying ${p##*/}"
	if ! g "${GIT_ID[@]}" am -q "$p"; then
		g am --abort || true
		die "git am failed on ${p##*/}; $LINUX_BRANCH is at $KVER"
	fi
done

[[ "$(g rev-parse HEAD^{tree})" == "$want_tree" ]] || die "result tree is not the expected tree"
print_applied
