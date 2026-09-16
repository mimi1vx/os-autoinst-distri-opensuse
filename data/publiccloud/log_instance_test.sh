#!/bin/bash
# Self-contained regression test for log_instance.sh's GCE stop path.
#
# Runs the real log_instance.sh as a subprocess with a PATH-stubbed `flock`
# so no real gcloud API or unrelated process is touched. Covers the lock
# being acquired immediately and the lock timing out, crossed with no PID
# file, a stale PID file, and a live logger PID.
#
# Usage: ./log_instance_test.sh [path-to-log_instance.sh]
set -eu

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LOGSCRIPT=${1:-"$SCRIPT_DIR/log_instance.sh"}
STUBDIR=$(mktemp -d)
trap 'rm -rf "$STUBDIR" "$OUTDIR"' EXIT

# log_instance.sh hardcodes its state dir under /tmp/log_instance/<instance_id>.
INSTANCE_ID=testinst
OUTDIR=/tmp/log_instance/"$INSTANCE_ID"

# Stub `flock`: LOG_INSTANCE_TEST_FLOCK_MODE=ok succeeds immediately,
# =timeout fails, simulating `flock -w N` timing out.
cat >"$STUBDIR/flock" <<'EOF'
#!/bin/bash
[ "${LOG_INSTANCE_TEST_FLOCK_MODE:-ok}" = "ok" ]
EOF
chmod +x "$STUBDIR/flock"

PID_FILE="$OUTDIR/pid"
FAIL=0

run_case() {
	local label=$1 mode=$2 setup=$3
	rm -rf "$OUTDIR"
	mkdir -p "$OUTDIR"
	TEST_PID=""
	eval "$setup"

	local out rc=0
	out=$(PATH="$STUBDIR:$PATH" LOG_INSTANCE_TEST_FLOCK_MODE="$mode" \
		bash "$LOGSCRIPT" stop GCE "$INSTANCE_ID" host zone 2>&1) || rc=$?

	local ok=1
	[ "$rc" -eq 0 ] || ok=0
	[ -f "$PID_FILE" ] && ok=0
	if [ -n "$TEST_PID" ]; then
		if kill -0 "$TEST_PID" 2>/dev/null; then
			ok=0
			kill -9 "$TEST_PID" 2>/dev/null || true
		fi
		wait "$TEST_PID" 2>/dev/null || true
	fi

	if [ "$ok" -eq 1 ]; then
		echo "PASS: $label"
	else
		echo "FAIL: $label (exit=$rc, pidfile_exists=$([ -f "$PID_FILE" ] && echo yes || echo no))"
		echo "$out"
		FAIL=1
	fi
}

# shellcheck disable=SC2016 # single-quoted on purpose: expanded later by run_case's eval
run_case "no PID file, lock acquired" ok ":"
# shellcheck disable=SC2016
run_case "no PID file, lock timeout" timeout ":"
# shellcheck disable=SC2016
run_case "stale PID file, lock acquired" ok 'echo 999999 > "$PID_FILE"'
# shellcheck disable=SC2016
run_case "stale PID file, lock timeout" timeout 'echo 999999 > "$PID_FILE"'
# shellcheck disable=SC2016
run_case "live logger, lock acquired" ok 'sleep 100 & TEST_PID=$!; echo $TEST_PID > "$PID_FILE"'
# shellcheck disable=SC2016
run_case "live logger, lock timeout" timeout 'sleep 100 & TEST_PID=$!; echo $TEST_PID > "$PID_FILE"'

exit "$FAIL"
