CRYSTAL ?= crystal
CRFLAGS ?=

.PHONY: test

bin/h: h.cr src/*.cr src/**/*.cr
	$(CRYSTAL) build $(CRFLAGS) -o bin/h h.cr

bin/h2: h2.cr src/*.cr src/**/*.cr
	$(CRYSTAL) build $(CRFLAGS) -o bin/h2 h2.cr

bin/server: server.cr src/*.cr src/**/*.cr
	$(CRYSTAL) build -o $(CRFLAGS) bin/server server.cr

bin/client: client.cr src/*.cr src/**/*.cr
	$(CRYSTAL) build -o $(CRFLAGS) bin/client client.cr

run: bin/server
	./bin/server

run_client: bin/client
	./bin/client

test:
	$(CRYSTAL) run $(CRFLAGS) test/*_test.cr test/**/*_test.cr

#h2spec:
#	bin/h2spec -p 9292 -t -k -S
