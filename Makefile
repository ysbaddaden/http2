CRYSTAL_BIN ?= crystal

.PHONY: test

bin/h: h.cr src/*.cr src/**/*.cr
	PKG_CONFIG_PATH=/usr/local/ssl/lib/pkgconfig $(CRYSTAL_BIN) build -o bin/h h.cr

bin/h2: h2.cr src/*.cr src/**/*.cr
	PKG_CONFIG_PATH=/usr/local/ssl/lib/pkgconfig $(CRYSTAL_BIN) build -o bin/h2 h2.cr

run: bin/h2
	./bin/h2

test:
	$(CRYSTAL_BIN) run test/*_test.cr test/**/*_test.cr -- --verbose

#h2spec:
#	bin/h2spec -p 9292 -t -k -S
