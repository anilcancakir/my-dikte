#!/usr/bin/env bash
# deploy-remote.sh: ship the committed MyDikteRemote to the work Mac and restart it there.
#
# Builds HEAD (never the working tree) in a dedicated worktree, assembles and signs a release bundle with
# the same identity as dev-run.sh but without entitlements (the remote app never touches the microphone),
# copies it over SSH to a stable path on the work Mac, and relaunches it. The signature is what keeps the
# Accessibility grant there: an Apple Development build signed by the same certificate satisfies the same
# designated requirement, so macOS asks once, not on every update.
#
# Meant to run from the post-commit hook in the background, so it is quiet about the normal failures:
# an unreachable host or a deploy already in flight exits 0. It loops until the deployed commit matches
# HEAD, so a commit made during a deploy is picked up by the run that is already going.
#
# Usage: ./deploy-remote.sh            deploy HEAD unless the work Mac already runs it
#        ./deploy-remote.sh --force    deploy even when the commit matches
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HOST="home-mac"
SIGN_IDENTITY="Apple Development: Anilcan Cakir (936TDTZJN9)"
WORKTREE="$HERE/.build/deploy-worktree"
STAGE="$HERE/.build/deploy-stage/MyDikteRemote.app"
LOCK="$HERE/.build/deploy-remote.lock"
REMOTE_APP="Applications/MyDikteRemote.app"
REMOTE_MARKER="Library/Application Support/MyDikteRemote/deployed-commit"

FORCE=false
[[ "${1:-}" == "--force" ]] && FORCE=true

say() { printf '%s \033[1;34m==>\033[0m %s\n' "$(date '+%H:%M:%S')" "$*"; }

remote() { ssh -o BatchMode=yes -o ConnectTimeout=5 "$HOST" "$@"; }

# 1. One deploy at a time; the run holding the lock re-checks HEAD before it exits.
mkdir -p "$HERE/.build"
if ! mkdir "$LOCK" 2>/dev/null; then
    say "Another deploy is running; it will pick up $(git -C "$HERE" rev-parse --short HEAD)."
    exit 0
fi
trap 'rmdir "$LOCK"' EXIT

if ! remote true 2>/dev/null; then
    say "$HOST is not reachable; skipping. Run ./deploy-remote.sh once it is back."
    exit 0
fi

deployed="$(remote "cat \"\$HOME/$REMOTE_MARKER\" 2>/dev/null || true")"

while true; do
    commit="$(git -C "$HERE" rev-parse HEAD)"

    if [[ "$commit" == "$deployed" && "$FORCE" == false ]]; then
        say "$HOST already runs ${commit:0:7}."
        exit 0
    fi

    # 2. Build exactly the commit: a detached worktree under .build keeps incremental builds and never
    #    sees uncommitted edits in the main checkout.
    if [[ ! -d "$WORKTREE" ]]; then
        git -C "$HERE" worktree add --detach "$WORKTREE" "$commit" > /dev/null
    else
        git -C "$WORKTREE" checkout --quiet --detach "$commit"
    fi

    say "Building ${commit:0:7} (release)..."
    # The tail is the log's only copy of a failed background build, so it keeps enough to read the error.
    ( cd "$WORKTREE" && swift build -c release --product MyDikteRemote 2>&1 | tail -40 )

    # 3. Hardened Runtime but no entitlements file: the remote app needs neither microphone nor network.
    say "Assembling and signing..."
    rm -rf "$STAGE"
    mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
    cp "$WORKTREE/.build/release/MyDikteRemote" "$STAGE/Contents/MacOS/MyDikteRemote"
    cp "$WORKTREE/RemoteInfo.plist" "$STAGE/Contents/Info.plist"
    codesign --force \
        --sign "$SIGN_IDENTITY" \
        --options runtime \
        "$STAGE"
    codesign --verify --strict "$STAGE"

    # 4. Copy beside the live bundle, then swap and relaunch in one step, so a dropped connection never
    #    leaves a half-copied app at the path macOS keys its grants to.
    say "Copying to $HOST..."
    rsync -a --delete "$STAGE/" "$HOST:$REMOTE_APP.next/"

    # The script travels on stdin: SentinelOne on the work Mac SIGKILLs a process whose argv carries a
    # long script, and ssh re-splits argv on the remote shell, which breaks the space in "Application
    # Support". -x on pkill matches the whole command line, so a live `--relay` child is left alone.
    say "Restarting on $HOST..."
    remote bash -s <<REMOTE_SCRIPT
set -e
app="\$HOME/$REMOTE_APP"
marker="\$HOME/$REMOTE_MARKER"
pkill -xf "\$app/Contents/MacOS/MyDikteRemote" || true
# Wait for the old instance to exit: if it is still up, open activates it instead of the new build.
for _ in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -xf "\$app/Contents/MacOS/MyDikteRemote" > /dev/null || break
    sleep 0.5
done
rm -rf "\$app"
mv "\$app.next" "\$app"
mkdir -p "\$(dirname "\$marker")"
echo $commit > "\$marker"
open "\$app"
REMOTE_SCRIPT

    say "$HOST runs ${commit:0:7}."
    deployed="$commit"
    FORCE=false
done
