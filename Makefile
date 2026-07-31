.PHONY: build run dev test fmt clean

build:
	zig build -Doptimize=ReleaseSafe

run: build
	./zig-out/bin/nzbunny

dev:
	zig build run

test:
	zig build test

fmt:
	zig fmt build.zig src

clean:
	rm -rf .zig-cache zig-out
