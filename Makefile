# SPDX-License-Identifier: GPL-3.0-or-later
# Development tools (not needed to use seedtunnel)
#   make lint        code analysis with shellcheck
#   make fmt         formats the code with shfmt
#   make fmt-check   checks the formatting without changing anything
#   make i18n        every message has its French translation
#   make unit        unit tests (no root, no server needed)
#   make check       all of the above, plus « bash -n »

SCRIPTS := seedtunnel.sh $(wildcard lib/*.sh) $(wildcard lang/*.sh) $(wildcard tests/*.sh) $(wildcard tools/*.sh)
INTEGRATION := tests/integration.sh
# 4 spaces, indented « case », operators (| && ||) at the start of lines
SHFMT := shfmt -i 4 -ci -bn

.PHONY: lint fmt fmt-check i18n unit check

# Exclusions: the script is split into files loaded by seedtunnel.sh (the
# variables of a file are used in the others: SC2034, SC2154) and it loads its
# state files /etc/seedtunnel/*.conf dynamically (SC1090, SC1091).
# The integration tests stand alone: there, a variable used but never set
# (SC2154), in capitals too, is a typo; it is looked for.
lint:
	shellcheck -x -P SCRIPTDIR -S warning -e SC2034,SC2154,SC1090,SC1091 $(filter-out $(INTEGRATION),$(SCRIPTS))
	shellcheck -x -P SCRIPTDIR -S warning -e SC2034,SC1090,SC1091 --enable=check-unassigned-uppercase $(INTEGRATION)

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
