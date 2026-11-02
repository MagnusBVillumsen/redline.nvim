NVIM ?= nvim

.PHONY: test fmt lint

test:
	$(NVIM) --headless --noplugin -u tests/minimal_init.lua -c 'lua require("tests.run").run()'

fmt:
	stylua lua plugin tests

lint:
	stylua --check lua plugin tests
