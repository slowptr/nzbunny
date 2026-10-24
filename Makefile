.PHONY: build run dev test check test-container smoke fmt clean

build:
	zig build -Doptimize=ReleaseSafe

run: build
	./zig-out/bin/nzbunny

dev:
	zig build run

test:
	zig build test

check:
	zig fmt --check build.zig build.zig.zon src
	zig build test
	zig build test -Doptimize=ReleaseSafe

test-container:
	docker build --target test --progress=plain .

smoke:
	docker build -t nzbunny:test .
	python3 tests/smoke.py

fmt:
	zig fmt build.zig build.zig.zon src

clean:
	rm -rf .zig-cache zig-out
