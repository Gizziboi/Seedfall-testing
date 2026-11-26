#!/usr/bin/env bash
# Copy the (unencrypted) results to the private repo, branch test-results, folder <base>/<run>-<tag>/ (newest 20 folders kept per base).
# base = runs (the normal cloud QA) or swarm/runs (v0.2.55g bot swarm). The key / token is only ever used through ci/private_git.sh;
# nothing it touches is echoed.
TAG=$1; RUN=$2; BASE=${3:-runs}
. "$(dirname "$0")/private_git.sh"
pg_setup || { echo "no private repo access: skipped"; exit 0; }
[ -d out ] || { echo "no results"; pg_done; exit 0; }
D="$BASE/$(printf '%05d' "$RUN")-$TAG"
for i in 1 2 3 4 5; do
  pg_clone "$RUNNER_TEMP/res"
  (
    cd "$RUNNER_TEMP/res" || exit 1
    N=$(ls -d "$BASE"/* 2>/dev/null | wc -l); ls -d "$BASE"/* 2>/dev/null | sort | awk -v n="$N" 'NR <= n - 19' | while read -r o; do git rm -rq "$o" >/dev/null 2>&1; done
    mkdir -p "$D" && cp -R "$GITHUB_WORKSPACE/out/." "$D/"
    [ "$BASE" = "runs" ] && ls -d runs/* | sort -r > INDEX.txt
    exit 0
  ) && pg_push "$RUNNER_TEMP/res" "results $D" && { echo "copied to the private repo"; pg_done; exit 0; }
  sleep $((i * 6))
done
pg_done
echo "copy to the private repo failed"
