VENV ?= .venv
PYTHON ?= $(VENV)/bin/python
OUTDIR ?= .local/www
HTTPDIR ?= $(OUTDIR)

.PHONY: init gen serve clean

init:
	git submodule update --init --recursive
	python3 -m venv $(VENV)
	$(PYTHON) -m pip install -r requirements.txt

gen:
	mkdir -p $(OUTDIR)
	DEBUG_WITH_REPOLIST=1 PYTHON_BIN=$(PYTHON) MIRROR_HTTPDIR=$(HTTPDIR) MIRROR_OUTDIR=$(OUTDIR) MIRROR_WEB_ROOT=$(OUTDIR) \
		./scripts/generate-index.sh

serve: gen
	$(PYTHON) -m http.server 8000 --directory $(OUTDIR)

clean:
	rm -rf .local
