.POSIX:
.PHONY:

CRYSTAL = crystal
CRFLAGS =

bin/server: server.cr src/*.cr src/**/*.cr
	$(CRYSTAL) build $(CRFLAGS) -o bin/server server.cr

bin/client: client.cr src/*.cr src/**/*.cr
	$(CRYSTAL) build $(CRFLAGS) -o bin/client client.cr

run: bin/server
	./bin/server

run_client: bin/client
	./bin/client

ssl: .PHONY
	@mkdir -p ssl
	openssl req -x509 -newkey rsa:4096 -keyout ssl/server.key -out ssl/server.crt \
		-sha256 -days 3650 -nodes -subj "/C=XX/ST=X/L=X/O=X/OU=X/CN=X"

test: .PHONY
	$(CRYSTAL) run $(CRFLAGS) test/*_test.cr test/**/*_test.cr
