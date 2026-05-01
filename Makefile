.PHONY: test test-system lint ci coverage run ui workers

# bin/* scripts use a Ruby shebang that Windows cmd/PowerShell can't
# honor, so route every invocation through bash. Override BASH on the
# command line if your install lives elsewhere: `make BASH=/path/to/bash run`.
ifeq ($(OS),Windows_NT)
  BASH ?= C:/Program Files/Git/bin/bash.exe
  OPEN ?= start ""
else
  BASH ?= bash
  OPEN ?= open
endif

run:
	"$(BASH)" bin/run $(filter-out $@,$(MAKECMDGOALS))

ui workers:
	@true

test:
	"$(BASH)" -c 'bin/rails test'

test-system:
	"$(BASH)" -c 'bin/rails test:system'

lint:
	"$(BASH)" -c 'bin/rubocop'

coverage:
	"$(BASH)" -c 'bin/rails test' && $(OPEN) coverage/index.html

ci: test test-system lint
