# Zig CRUD

A small in-memory CRUD API for learning Zig. The default build uses a bounded
worker pool, so clients queue behind a fixed number of workers rather than
creating an operating-system thread per connection.

## Run locally

```sh
zig build run
```

The server listens on `http://127.0.0.1:8080` and also accepts connections on
the container-friendly `0.0.0.0:8080` bind address. Notes are intentionally
in-memory and are discarded at restart.

`GET /notes` supports bounded pagination:

```sh
curl 'http://127.0.0.1:8080/notes?offset=0&limit=20'
```

`limit` must be between 1 and 100.

## Scaling benchmark

The Compose setup builds with Zig `0.17.0-dev.902`, starts the API with a
20,000-file-descriptor limit, and runs k6 on the same Docker host. The k6
workload gives every virtual user its own create/read/update/read/delete cycle.

```sh
make perf-baseline
make perf-scaled
```

Each command performs five runs by default and writes raw k6 summaries, API
logs, environment metadata, and an aggregate report to `perf/results/`.
`RUNS=1 ./perf/run.sh scaled` is useful for a quick check.

The scaled profile requires every run to have fewer than 1% failed requests and
p95 latency below 250 ms at 10,000 virtual users. Before running it, ensure the
host has `ulimit -n >= 20000` and `net.core.somaxconn >= 16384`.

Because k6 and the API run on the same Docker host, the result is combined
client/server capacity. Use separate hosts before treating the measurement as a
server-only capacity claim.
