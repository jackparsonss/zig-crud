# Zig Crud
A simple CRUD API for learning Zig. It uses PostgreSQL for storage, Argon2id
for password hashing, and a dependency-free HS256 JWT implementation built
with Zig's standard library.

Start PostgreSQL and the API:

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

Tokens expire after one hour. `JWT_SECRET` is required when the application
starts. The Dockerfile supplies `super-secret` as a development default; it
must be overridden with a strong secret in production.
