BASE_URL := http://127.0.0.1:8080

.PHONY: list post get update delete test perf-smoke perf-baseline perf-scaled


list:
	curl -sS $(BASE_URL)/notes

post:
	curl -sS -X POST $(BASE_URL)/notes -d 'Learn Zig'

get:
	curl -sS $(BASE_URL)/notes/1

update:
	curl -sS -X PUT $(BASE_URL)/notes/1 -d 'Learn Zig and build APIs'

delete:
	curl -sS -X DELETE $(BASE_URL)/notes/1

test:
	zig build test

perf-smoke:
	docker compose up --build --detach api
	@status=0; docker compose --profile perf run --rm --no-deps k6 run /scripts/smoke.js || status=$$?; docker compose down --remove-orphans; exit $$status

perf-baseline:
	./perf/run.sh baseline

perf-scaled:
	./perf/run.sh scaled
