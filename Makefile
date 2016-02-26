.PHONY: test

run: bin/h2
	./bin/h2

bin/h2: h2.cr src/*.cr src/**/*.cr
	crystal build --link-flags="./libssl.a ./libcrypto.a" -o bin/h2 h2.cr

test:
	crystal run test/*_test.cr test/**/*_test.cr -- --verbose
