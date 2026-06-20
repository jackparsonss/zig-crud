#!/usr/bin/env bash
set -euo pipefail

profile=${1:-scaled}
runs=${RUNS:-5}

case "$profile" in
  baseline) concurrent=false ;;
  scaled) concurrent=true ;;
  *)
    echo "usage: $0 [baseline|scaled]" >&2
    exit 2
    ;;
esac

require() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command: $1" >&2
    exit 1
  }
}

require curl
require docker
require python3

if (( $(ulimit -n) < 20000 )); then
  echo "open-file limit must be at least 20000; current limit: $(ulimit -n)" >&2
  exit 1
fi

somaxconn=$(sysctl -n net.core.somaxconn 2>/dev/null || true)
if [[ "$somaxconn" =~ ^[0-9]+$ ]] && (( somaxconn < 16384 )); then
  echo "net.core.somaxconn must be at least 16384; current value: $somaxconn" >&2
  exit 1
fi

timestamp=$(date -u +%Y%m%dT%H%M%SZ)
result_dir="perf/results/${profile}-${timestamp}"
mkdir -p "$result_dir"

{
  uname -a
  printf 'cpus: '
  getconf _NPROCESSORS_ONLN
  printf 'open_files: '
  ulimit -n
  printf 'somaxconn: %s\n' "${somaxconn:-unavailable}"
  docker version --format '{{.Server.Version}}'
} >"$result_dir/environment.txt"

wait_for_api() {
  for _ in $(seq 1 30); do
    if curl --fail --silent --output /dev/null "http://127.0.0.1:8080/notes"; then
      return 0
    fi
    sleep 1
  done
  echo "API did not become ready" >&2
  return 1
}

failed=0
for run in $(seq 1 "$runs"); do
  CONCURRENT="$concurrent" docker compose up --build --force-recreate --detach api
  wait_for_api

  set +e
  docker compose --profile perf run --rm --no-deps \
    --env PROFILE="$profile" \
    k6 run --summary-export="/results/run-${run}-summary.json" /scripts/mixed-crud.js
  status=$?
  set -e

  docker compose logs --no-color api >"$result_dir/server-${run}.log" || true
  docker compose down --remove-orphans

  if (( status != 0 )); then
    failed=1
    echo "run ${run} exited with status ${status}" >&2
  fi
done

python3 perf/aggregate.py "$result_dir"

if [[ "$profile" == "scaled" && "$failed" -ne 0 ]]; then
  exit 1
fi
