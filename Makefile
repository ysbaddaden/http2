.POSIX:
.PHONY:

CRYSTAL = crystal
CRFLAGS =

bin/%: samples/%.cr src/*.cr src/**/*.cr
	@mkdir -p bin
	$(CRYSTAL) build $(CRFLAGS) -o $@ $<

ssl: .PHONY
	@mkdir -p ssl
	openssl req -x509 -newkey rsa:4096 -keyout ssl/server.key -out ssl/server.crt \
		-sha256 -days 3650 -nodes -subj "/C=XX/ST=X/L=X/O=X/OU=X/CN=X"

test: .PHONY
	$(CRYSTAL) run $(CRFLAGS) test/*_test.cr test/**/*_test.cr
