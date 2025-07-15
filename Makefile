.POSIX:
.PHONY:

CRYSTAL = crystal
CRFLAGS =

bin/h: h.cr src/*.cr src/**/*.cr
	$(CRYSTAL) build $(CRFLAGS) -o bin/h h.cr

bin/h2: h2.cr src/*.cr src/**/*.cr
	$(CRYSTAL) build $(CRFLAGS) -o bin/h2 h2.cr

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

#h2spec:
#	bin/h2spec -p 9292 -t -k -S
