#!/usr/bin/env bash
# v0.2.55g git access to the PRIVATE repo's test-results branch, sourced by push_private.sh and the swarm scripts.
# Two ways in, nothing is ever echoed:
#   1. SEEDFALL_RESULTS_KEY (preferred, owner's choice 2026-11-24): an SSH deploy key with write access on Gizziboi/Seedfall. A repository
#      ruleset on Gizziboi/Seedfall blocks every branch except test-results for everyone but the owner, so this key can only write
#      test-results. Written to $RUNNER_TEMP for the step only and deleted by pg_done.
#   2. SEEDFALL_PRIVATE_TOKEN (old): a fine-grained token, Contents read/write on Seedfall. GitHub can't limit a token to one branch, so
#      this one can write any branch; kept only until the owner has set up 1 and deleted the token.
PG_URL=""
PG_H=""
pg_setup() {
  if [ -n "${SEEDFALL_RESULTS_KEY:-}" ]; then
    umask 077
    printf '%s\n' "$SEEDFALL_RESULTS_KEY" > "$RUNNER_TEMP/rk"
    export GIT_SSH_COMMAND="ssh -i $RUNNER_TEMP/rk -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR"
    PG_URL=git@github.com:Gizziboi/Seedfall.git
    PG_H=""
    return 0
  fi
  if [ -n "${SEEDFALL_PRIVATE_TOKEN:-}" ]; then
    PG_URL=https://github.com/Gizziboi/Seedfall
    PG_H="AUTHORIZATION: basic $(printf 'x-access-token:%s' "$SEEDFALL_PRIVATE_TOKEN" | base64 | tr -d '\n')"
    return 0
  fi
  return 1
}
pg_git() {
  if [ -n "$PG_H" ]; then git -c http.extraheader="$PG_H" "$@"; else git "$@"; fi
}
# pg_clone DIR: shallow clone of test-results into DIR (an empty branch is started when it doesn't exist yet)
pg_clone() {
  rm -rf "$1"
  if ! pg_git clone -q --depth 1 --branch test-results "$PG_URL" "$1" >/dev/null 2>&1; then
    mkdir -p "$1" && ( cd "$1" && git init -q && git checkout -q -b test-results && git remote add origin "$PG_URL" )
  fi
  git -C "$1" config user.name "seedfall-qa"; git -C "$1" config user.email "qa@users.noreply.github.com"
}
# pg_push DIR MESSAGE
pg_push() {
  ( cd "$1" && git add -A >/dev/null 2>&1 && git commit -qm "$2" >/dev/null 2>&1; pg_git push -q origin test-results >/dev/null 2>&1 )
}
pg_done() {
  rm -f "$RUNNER_TEMP/rk"
  unset GIT_SSH_COMMAND
}
