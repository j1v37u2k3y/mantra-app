# Mantra App — local task runner
# Wraps the npm scripts so `make <target>` works without remembering them.
#
# Usage:
#   make            # show help
#   make ci         # the same pipeline GitHub Actions runs
#   make test       # just the unit + API tests
#   make dev        # Express + Vite together

SHELL := /bin/bash

# Repo name used as the GitHub Pages base path.
REPO_NAME ?= mantra-app
PAGES_BASE ?= /$(REPO_NAME)/

.DEFAULT_GOAL := help

.PHONY: help install dev build build-pages preview typecheck test test-watch \
        ci smoke release-dry clean clean-dist clean-all

help: ## Show this help
	@echo "Mantra App — make targets"
	@echo
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "Override the Pages base path with: make build-pages REPO_NAME=other-repo"

install: ## Install npm dependencies (uses npm ci if package-lock matches)
	npm install

dev: ## Run Express (3174) + Vite (5174) together
	npm run dev

build: ## Production build → dist/ (local base path)
	npm run build

build-pages: ## Production build with VITE_BASE=$(PAGES_BASE) (what GH Pages uses)
	VITE_BASE=$(PAGES_BASE) npm run build

preview: build ## Build + serve dist/ via Express on 3174
	npm run preview

typecheck: ## tsc --noEmit
	npm run typecheck

test: ## Run vitest once (parser + server tests)
	npm test

test-watch: ## Run vitest in watch mode
	npm run test:watch

ci: ## Full pipeline: typecheck + test + build (what GitHub CI runs)
	npm run ci

smoke: ## Boot server.js and curl the API endpoints
	@echo "Starting server..."
	@node server.js & echo $$! > .smoke.pid; \
	sleep 1.5; \
	echo "→ /api/mantra";          curl -sSf http://localhost:3174/api/mantra && echo; \
	echo "→ /api/mantra/0";        curl -sSf http://localhost:3174/api/mantra/0 && echo; \
	echo "→ /api/mantra/99999";    curl -s -o /dev/null -w "  HTTP %{http_code}\n" http://localhost:3174/api/mantra/99999; \
	kill $$(cat .smoke.pid) 2>/dev/null; rm -f .smoke.pid; \
	echo "Server stopped."

release-dry: ## semantic-release dry run (no tags, no commits)
	npx semantic-release --dry-run --no-ci

clean-dist: ## Remove the Vite build output
	rm -rf dist

clean: clean-dist ## Alias for clean-dist

clean-all: clean-dist ## Remove dist/ AND node_modules/
	rm -rf node_modules