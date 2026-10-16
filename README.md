# Zig Crud
A simple CRUD API for learning Zig. It uses PostgreSQL for storage, Argon2id
for password hashing, and a dependency-free HS256 JWT implementation built
with Zig's standard library.

Requires Zig 0.17. Start PostgreSQL and the API:

```sh
docker compose up -d
JWT_SECRET=super-secret zig build run
```

Register and log in:

```sh
curl -sS -X POST http://127.0.0.1:8080/user \
  -H 'content-type: application/json' \
  -d '{"username":"alice","password":"secret"}'

curl -sS -X POST http://127.0.0.1:8080/login \
  -H 'content-type: application/json' \
  -d '{"username":"alice","password":"secret"}'
```

Every `/notes` route requires the token returned by `/login`:

```sh
curl -sS http://127.0.0.1:8080/notes \
  -H "authorization: Bearer $TOKEN"
```

`GET /whoami` returns the token's claims without touching the database:

```sh
curl -sS http://127.0.0.1:8080/whoami \
  -H "authorization: Bearer $TOKEN"
```

Tokens expire after one hour. `JWT_SECRET` is required when the application
starts. The Dockerfile supplies `super-secret` as a development default; it
must be overridden with a strong secret in production.

## Load testing

`loadtest/` is a small Go load generator. It only sends requests that every
version of this API handles the same way, so the numbers compare directly
across builds. Start a server built with `-Doptimize=ReleaseFast`, then:

```sh
go -C loadtest run .                           # 64 connections, 10s per scenario
go -C loadtest run . -c 256 -scenarios whoami  # see -h for all flags
```

The `create` scenario inserts a row per request. The load generator competes
with the server for CPU when run on the same machine, so for numbers near the
top end run it from another host with `-url`.
