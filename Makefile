.PHONY: help clean build run test \
	strictdoc-init strictdoc-generate strictdoc-validate strictdoc-export \
	strictdoc-serve strictdoc-tree strictdoc-help tla-check install-hooks

ROOT := $(abspath .)
export PATH := $(ROOT)/.tools/erlang/bin:$(ROOT)/.tools:$(PATH)
PYTHON := $(ROOT)/.venv/bin/python
STRICTDOC := $(ROOT)/.venv/bin/strictdoc
REBAR := $(ROOT)/.tools/rebar3
TLC := $(ROOT)/.tools/tla2tools.jar
VALIDATE_DIR := $(ROOT)/.tools/strictdoc-validate

help:
	@echo "AirTrafficControl targets:"
	@echo "  make build                 Compile the Erlang release"
	@echo "  make run                   Load the example airport and halt"
	@echo "  make test                  Run Common Test and PropEr"
	@echo "  make clean                 Remove build output"
	@echo "  make strictdoc-init        Create the StrictDoc virtualenv"
	@echo "  make strictdoc-generate    Write HTML into reqs/html"
	@echo "  make strictdoc-validate    Parse requirements and check links"
	@echo "  make strictdoc-export      Alias of strictdoc-generate"
	@echo "  make strictdoc-serve       Serve the requirements browser"
	@echo "  make strictdoc-tree        List requirement documents"
	@echo "  make strictdoc-help        Show StrictDoc help"
	@echo "  make tla-check             Model-check specs/tla/AtcTower.tla"
	@echo "  make install-hooks         Install the pre-commit HTML hook"

$(STRICTDOC): requirements.txt
	python3 -m venv $(ROOT)/.venv
	$(ROOT)/.venv/bin/pip install -r requirements.txt

strictdoc-init: $(STRICTDOC)
	@echo "StrictDoc is installed in .venv"

strictdoc-generate: $(STRICTDOC)
	mkdir -p reqs/html
	$(STRICTDOC) export reqs --output-dir reqs/html --formats html --config strictdoc.toml --included-documents --project-title AirTrafficControl

strictdoc-validate: $(STRICTDOC)
	mkdir -p $(VALIDATE_DIR)
	$(STRICTDOC) export reqs --output-dir $(VALIDATE_DIR) --formats html --config strictdoc.toml --included-documents --project-title AirTrafficControl

strictdoc-export: strictdoc-generate

strictdoc-serve: $(STRICTDOC)
	$(STRICTDOC) server reqs --config strictdoc.toml

strictdoc-tree:
	@find reqs -type f \( -name '*.sdoc' -o -name '*.sgra' \) | sort

strictdoc-help: $(STRICTDOC)
	$(STRICTDOC) --help

build:
	$(REBAR) compile

run: build
	$(REBAR) as prod release
	$(ROOT)/_build/prod/rel/atc_tower/bin/atc_tower start
	$(ROOT)/_build/prod/rel/atc_tower/bin/atc_tower eval 'atc_tower_cli:main(["config/example-airport.toml"]).'
	$(ROOT)/_build/prod/rel/atc_tower/bin/atc_tower stop

test: build
	$(REBAR) as test ct
	$(REBAR) as test eunit

tla-check:
	java -XX:+IgnoreUnrecognizedVMOptions -Dtlc2.tool.fp.FPSet.impl=tlc2.tool.fp.OffHeapDiskFPSet -jar $(TLC) -workers 2 -deadlock -config specs/tla/AtcTower.cfg specs/tla/AtcTower.tla

clean:
	$(REBAR) clean || true
	rm -rf _build erl_crash.dump $(VALIDATE_DIR) states

install-hooks:
	mkdir -p $(ROOT)/.git/hooks
	cp $(ROOT)/scripts/git-hooks/pre-commit $(ROOT)/.git/hooks/pre-commit
	chmod +x $(ROOT)/.git/hooks/pre-commit $(ROOT)/scripts/git-hooks/pre-commit
