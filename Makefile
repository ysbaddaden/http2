.PHONY: test

test:
	crystal run test/*_test.cr test/**/*_test.cr -- --verbose
