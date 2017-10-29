CRYSTAL ?= crystal
OPENSSL ?= /opt/openssl-1.1.0e

.PHONY: test

bin/h: h.cr src/*.cr src/**/*.cr
	PKG_CONFIG_PATH=$(OPENSSL)/lib/pkgconfig $(CRYSTAL) build -o bin/h h.cr

bin/h2: h2.cr src/*.cr src/**/*.cr
	PKG_CONFIG_PATH=$(OPENSSL)/lib/pkgconfig $(CRYSTAL) build -o bin/h2 h2.cr

bin/server: server.cr src/*.cr src/**/*.cr
	PKG_CONFIG_PATH=$(OPENSSL)/lib/pkgconfig $(CRYSTAL) build -o bin/server server.cr

bin/client: client.cr src/*.cr src/**/*.cr
	PKG_CONFIG_PATH=$(OPENSSL)/lib/pkgconfig $(CRYSTAL) build -o bin/client client.cr

run: bin/server
	LD_LIBRARY_PATH=$(OPENSSL)/lib ./bin/server

run_client: bin/client
	LD_LIBRARY_PATH=$(OPENSSL)/lib ./bin/client

test:
	$(CRYSTAL) run test/*_test.cr test/**/*_test.cr

#h2spec:
#	bin/h2spec -p 9292 -t -k -S
