.POSIX:
.PHONY:

CRYSTAL = crystal
CRFLAGS =
TESTS = test/*_test.cr test/**/*_test.cr
OPTS = --chaos --parallel 4

-include local.mk

bin/%: samples/%.cr src/*.cr src/**/*.cr
	@mkdir -p bin
	$(CRYSTAL) build $(CRFLAGS) -o $@ $<

ssl: .PHONY
	@mkdir -p ssl
	openssl req -x509 -newkey rsa:4096 -keyout ssl/server.key -out ssl/server.crt \
		-sha256 -days 3650 -nodes -subj "/C=XX/ST=X/L=X/O=X/OU=X/CN=X"

test: .PHONY
	$(CRYSTAL) run $(CRFLAGS) $(TESTS) -- $(OPTS)
