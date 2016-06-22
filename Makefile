CRYSTAL_BIN ?= crystal

.PHONY: test

run: bin/h2
	./bin/h2

bin/h2: h2.cr src/*.cr src/**/*.cr
	PKG_CONFIG_PATH=/usr/local/ssl/lib/pkgconfig $(CRYSTAL_BIN) compile -o bin/h2 h2.cr

test:
	$(CRYSTAL_BIN) run test/*_test.cr test/**/*_test.cr -- --verbose
