BASE_URL := http://127.0.0.1:8080

.PHONY: list create get update delete


list:
	curl -sS $(BASE_URL)/notes

create:
	curl -sS -X POST $(BASE_URL)/notes -d 'Learn Zig'

get:
	curl -sS $(BASE_URL)/notes/1

update:
	curl -sS -X PUT $(BASE_URL)/notes/1 -d 'Learn Zig and build APIs'

delete:
	curl -sS -X DELETE $(BASE_URL)/notes/1
