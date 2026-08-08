HOST := 127.0.0.1
PORT := 8080

.PHONY: run send

run:
	zig build run

send:
	printf 'Hello, from a makefile!' | nc -u -w 1 $(HOST) $(PORT)
