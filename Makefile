.PHONY: help clean build run test aircraft-test physics scenario-test \
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
	@echo "  make aircraft-test         Run the aircraft pytest suite"
	@echo "  make scenario-test         Fly the pinned busy-flow scenario at max scale"
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
	rm -rf $(ROOT)/.tools/strictdoc-html
	$(STRICTDOC) export reqs --output-dir $(ROOT)/.tools/strictdoc-html --formats html --config strictdoc.toml --included-documents --project-title AirTrafficControl
	rm -rf $(ROOT)/reqs/html
	mkdir -p $(ROOT)/reqs/html
	cp -a $(ROOT)/.tools/strictdoc-html/html/. $(ROOT)/reqs/html/

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
	$(ROOT)/.tools/erlang/bin/erl -noshell $$(find $(ROOT)/_build/prod/rel/atc_tower/lib -type d -name ebin -printf '-pa %p ') -eval 'ok = atc_tower_cli:main(["$(ROOT)/config/example-airport.toml"]), halt(0).'

test:
	$(REBAR) as test ct

apps/physics/libphysics.so: apps/physics/physics.c apps/physics/physics.h
	mkdir -p $(ROOT)/.tools/tmp
	TMPDIR=$(ROOT)/.tools/tmp gcc -std=c11 -Wall -Wextra -shared -fPIC -O2 -o $@ apps/physics/physics.c -lm

physics: apps/physics/libphysics.so

# @relation(AC-SIP001, AC-STP001, scope=file)
aircraft-test: $(STRICTDOC) apps/physics/libphysics.so
	cd $(ROOT)/apps/aircraft && $(PYTHON) -m pytest -q

scenario-test: build physics $(STRICTDOC)
	$(PYTHON) tools/navdata/import_navdata.py --download $(ROOT)/data/raw --out $(ROOT)/data/catalog
	$(PYTHON) -m pytest -q tools/navdata/test_import.py tools/traffic/test_compose.py
	$(PYTHON) tools/traffic/run_scenario.py --scenario $(ROOT)/data/catalog/scenario.json --scale max --log $(ROOT)/logs/scenario --root $(ROOT) --compose $(ROOT)/docker/scenario-compose.yml

tla-check:
	java -XX:+UseParallelGC -jar $(TLC) -workers 2 -config specs/tla/AtcTower.cfg specs/tla/AtcTower.tla

clean:
	$(REBAR) clean || true
	rm -rf _build erl_crash.dump $(VALIDATE_DIR) states

install-hooks:
	mkdir -p $(ROOT)/.git/hooks
	cp $(ROOT)/scripts/git-hooks/pre-commit $(ROOT)/.git/hooks/pre-commit
	chmod +x $(ROOT)/.git/hooks/pre-commit $(ROOT)/scripts/git-hooks/pre-commit
