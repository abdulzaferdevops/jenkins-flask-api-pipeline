#!/bin/bash
# release.sh - runs ON the app server as 'deploy', streamed over SSH by Jenkins.
#
#   deploy   <app_root> <release> <keep> <health_url>
#       build the release's virtualenv, switch 'current', restart the service,
#       health-check it; on failure restore the previous release automatically.
#   rollback <app_root> <health_url>
#       switch to the newest earlier release that was previously healthy.
#
# Only healthy releases get a '.healthy' marker, so rollback never lands on a
# release that failed its health check or never finished building.
set -euo pipefail

MODE="${1:?mode: deploy|rollback}"
APP_ROOT="${2:?app root}"
SERVICE=flask-api.service
# Overridable for local testing; on the server these match the sudo rule exactly.
SYSTEMCTL="${SYSTEMCTL:-sudo -n /usr/bin/systemctl}"
JOURNAL="${JOURNAL:-sudo -n /usr/bin/journalctl -u $SERVICE -n 50 --no-pager}"

# PYTHON_BIN comes from the server's shared/app.env
if [ -r "$APP_ROOT/shared/app.env" ]; then
  # shellcheck disable=SC1091
  . "$APP_ROOT/shared/app.env"
fi
PY="${PYTHON_BIN:-python3}"

cd "$APP_ROOT"

switch_to() {
  ln -sfn "$APP_ROOT/releases/$1" current.next
  mv -T current.next current
}

active_release() {
  if [ -L current ]; then basename "$(readlink current)"; fi
}

healthy() {  # healthy <expected release> <health_url>
  local attempt body
  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    # Empty or non-JSON responses are normal while gunicorn restarts: just retry.
    body=$(curl -fsS -m 3 "$2" 2>/dev/null || true)
    if [ -n "$body" ] && printf '%s' "$body" | "$PY" -c '
import json, sys
try:
    d = json.load(sys.stdin)
except ValueError:
    sys.exit(1)
sys.exit(0 if d.get("status") == "ok" and d.get("release") == sys.argv[1] else 1)
' "$1"; then
      echo "health check passed on attempt $attempt: $body"
      return 0
    fi
    sleep 2
  done
  echo "health check failed after $attempt attempts (last response: ${body:-none})"
  return 1
}

restart_and_check() {  # restart_and_check <release> <health_url>
  $SYSTEMCTL restart $SERVICE
  healthy "$1" "$2"
}

case "$MODE" in
  deploy)
    RELEASE="${3:?release}"
    KEEP="${4:-5}"
    HEALTH_URL="${5:?health url}"
    REL="releases/$RELEASE"

    [ -s "$REL/app.py" ] && [ -s "$REL/requirements.txt" ] && [ -s "$REL/RELEASE" ] \
      || { echo "release $RELEASE is incomplete"; rm -rf "$REL"; exit 1; }

    echo "building virtualenv for $RELEASE with $PY"
    if ! { "$PY" -m venv "$REL/venv" \
           && "$REL/venv/bin/pip" install -q --disable-pip-version-check -r "$REL/requirements.txt"; }; then
      echo "dependency install FAILED - release discarded, live service untouched"
      rm -rf "$REL"
      exit 1
    fi

    previous=$(active_release)
    switch_to "$RELEASE"
    echo "switched current: ${previous:-none} -> $RELEASE"

    if restart_and_check "$RELEASE" "$HEALTH_URL"; then
      touch "$REL/.healthy"
      echo "healthy: $RELEASE is live"
    else
      echo "UNHEALTHY: $RELEASE - last service log lines:"
      $JOURNAL || true
      if [ -n "$previous" ] && [ -d "releases/$previous" ]; then
        echo "automatic rollback to $previous"
        switch_to "$previous"
        if restart_and_check "$previous" "$HEALTH_URL"; then
          echo "rollback healthy: $previous is live again"
        else
          echo "WARNING: $previous is not healthy either - investigate"
        fi
        rm -rf "$REL"
      else
        echo "no previous release to roll back to"
      fi
      exit 1
    fi

    # Keep the newest $KEEP releases; never delete the active one.
    active=$(active_release)
    ls -1 releases | sort | head -n -"$KEEP" | while read -r old; do
      [ "$old" = "$active" ] && continue
      rm -rf "releases/$old"
      echo "pruned: $old"
    done
    ;;

  rollback)
    HEALTH_URL="${3:?health url}"
    active=$(active_release)
    target=""
    for r in $(ls -1 releases | sort); do
      [ "$r" = "$active" ] && break
      [ -f "releases/$r/.healthy" ] && target="$r"
    done
    if [ -z "$target" ]; then
      echo "no earlier healthy release than ${active:-none} - nothing to roll back to"
      exit 1
    fi
    switch_to "$target"
    if restart_and_check "$target" "$HEALTH_URL"; then
      echo "rolled back: $active -> $target (healthy)"
    else
      echo "UNHEALTHY after rollback to $target - restoring $active"
      $JOURNAL || true
      switch_to "$active"
      $SYSTEMCTL restart $SERVICE
      exit 1
    fi
    ;;

  *)
    echo "usage: release.sh deploy|rollback ..."
    exit 2
    ;;
esac
