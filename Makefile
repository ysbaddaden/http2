CRYSTAL_BIN ?= crystal

.PHONY: test

run: bin/h2
	./bin/h2

bin/h2: h2.cr src/*.cr src/**/*.cr
	$(CRYSTAL_BIN) build --link-flags="$(PWD)/libssl.a $(PWD)/libcrypto.a" -o bin/h2 h2.cr

test:
	$(CRYSTAL_BIN) run test/*_test.cr test/**/*_test.cr -- --verbose
