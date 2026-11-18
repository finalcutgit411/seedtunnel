# SPDX-License-Identifier: GPL-3.0-or-later
# Development tools (not needed to use seedtunnel)
#   make lint        code analysis with shellcheck
#   make fmt         formats the code with shfmt
#   make fmt-check   checks the formatting without changing anything
#   make i18n        every message has its French translation
#   make unit        unit tests (no root, no server needed)
#   make check       all of the above, plus « bash -n »
#   make deps        lists the tools of the targets above that are missing
#
# Tools (Debian, Ubuntu):
#   apt install make shellcheck shfmt python3 jq git openssl openssh-client \
#       curl inotify-tools qrencode
# The screenshots of the README (tools/preview.sh) also need Playwright with
# Chromium and the font DejaVu Sans Mono (fonts-dejavu-core).

SCRIPTS := seedtunnel.sh $(wildcard lib/*.sh) $(wildcard lang/*.sh) $(wildcard tests/*.sh) $(wildcard tools/*.sh)
# what seedtunnel.sh loads, read together by the second analysis
MODULES := $(wildcard lib/*.sh) $(wildcard lang/*.sh) seedtunnel.sh
INTEGRATION := tests/integration.sh
# 4 spaces, indented « case », operators (| && ||) at the start of lines
SHFMT := shfmt -i 4 -ci -bn
# commands used by lint, fmt-check, i18n and unit
TOOLS := shellcheck shfmt python3 jq git openssl ssh-keygen curl gzip tar inotifywait qrencode

.PHONY: lint fmt fmt-check i18n unit check deps

# Exclusions: the script is split into files loaded by seedtunnel.sh (the
# variables of a file are used in the others: SC2034, SC2154) and it loads its
# state files /etc/seedtunnel/*.conf dynamically (SC1090, SC1091).
# The integration tests stand alone: there, a variable used but never set
# (SC2154), in capitals too, is a typo; it is looked for.
# The modules are then read once more, put end to end as seedtunnel.sh loads
# them: a variable used but set in none of them (SC2154) is a typo too. Each
# line found is given back in its own file.
lint:
	shellcheck -x -P SCRIPTDIR -S warning -e SC2034,SC2154,SC1090,SC1091 $(filter-out $(INTEGRATION),$(SCRIPTS))
	shellcheck -x -P SCRIPTDIR -S warning -e SC2034,SC1090,SC1091 --enable=check-unassigned-uppercase $(INTEGRATION)
	@tmp=$$(mktemp) && trap 'rm -f "$$tmp" "$$tmp.out"' EXIT \
		&& sed 's/^#!/#/' $(MODULES) >"$$tmp" \
		&& { shellcheck -S warning -i SC2154 --enable=check-unassigned-uppercase -f gcc "$$tmp" >"$$tmp.out"; status=$$?; } \
		&& awk -v out="$$tmp.out" 'FILENAME != out { line++; if (FNR == 1) { name[++n] = FILENAME; first[n] = line }; next } \
			{ split($$0, at, ":"); for (i = n; i > 1 && first[i] > at[2]; i--); \
			sub(/^[^:]*:[0-9]+:/, name[i] ":" at[2] - first[i] + 1 ":"); print }' $(MODULES) "$$tmp.out" \
		&& exit $$status

deps:
	@missing=""; for tool in $(TOOLS); do command -v "$$tool" >/dev/null || missing="$$missing $$tool"; done; \
		if [ -n "$$missing" ]; then echo "Missing:$$missing (inotifywait: inotify-tools)"; exit 1; fi; \
		echo "All the tools are there."

fmt:
	$(SHFMT) -w $(SCRIPTS)

fmt-check:
	$(SHFMT) -d $(SCRIPTS)

i18n:
	python3 tests/i18n_check.py

unit:
	tests/unit.sh

check: lint fmt-check i18n unit
	@for f in $(SCRIPTS); do bash -n "$$f" || exit 1; done
	@echo "All good."
