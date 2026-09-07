ifeq ($(OS),Windows_NT)
SHELL := bash.exe
PYTHON_BIN ?= python
else
SHELL := /usr/bin/env bash
PYTHON_BIN ?= python3
endif
.DEFAULT_GOAL := help

ROOT_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
BUILD_ROOT ?= $(ROOT_DIR)/build
NPM_BIN ?= npm
POWERSHELL_BIN ?= powershell.exe
XAI_DIR ?= $(ROOT_DIR)/trustme-xai

APP_NAME ?= trust-me
BUNDLE_ID ?= io.github.yumeansfish.trustme
RELEASE_VERSION ?= 0.0.0

export APP_NAME
export BUNDLE_ID
export RELEASE_VERSION
export XAI_DIR

.PHONY: \
	help scripts-test xai-test backend-test frontend-test test check contracts dev \
	frontend compose binary-server binary-app binary-macos-app binary-windows-app \
	binary build package package-macos package-windows release \
	update-app sync-app clean

help:
	@echo "Build stages:"
	@echo "  make frontend      Vue source -> static frontend artifact"
	@echo "  make compose       frontend + backend + XAI + config -> composed ActivityWatch tree"
	@echo "  make binary-app    composed tree -> native application"
	@echo "  make package       native application -> platform installer"
	@echo "  make package-macos explicitly build a macOS DMG"
	@echo "  make package-windows explicitly build a Windows setup EXE"
	@echo
	@echo "Other commands: make binary-server, make update-app, make check, make dev"

scripts-test:
	cd "$(ROOT_DIR)" && "$(PYTHON_BIN)" -m pytest -q scripts/tests

xai-test:
	cd "$(XAI_DIR)" && \
		PYTHONPATH="$(XAI_DIR)/src$${PYTHONPATH:+:$$PYTHONPATH}" \
		"$(PYTHON_BIN)" -m pytest -q
	cd "$(XAI_DIR)" && "$(PYTHON_BIN)" -m ruff check src tests

backend-test:
	cd "$(ROOT_DIR)/backend" && \
		PYTHONPATH="$(XAI_DIR)/src$${PYTHONPATH:+:$$PYTHONPATH}" \
		"$(PYTHON_BIN)" -m pytest -q

frontend-test:
	cd "$(ROOT_DIR)/frontend" && "$(NPM_BIN)" run typecheck && "$(NPM_BIN)" run test:node

test: scripts-test xai-test backend-test frontend-test

check:
	"$(ROOT_DIR)/scripts/check.sh"

contracts:
	"$(PYTHON_BIN)" "$(ROOT_DIR)/scripts/sync_frontend_contracts.py" --write

dev:
	$(MAKE) -C "$(ROOT_DIR)/frontend" dev \
		HOST="$${DEV_HOST:-127.0.0.1}" \
		PORT="$${DEV_PORT:-27180}" \
		AW_SERVER_URL="$${AW_SERVER_URL:-}"

frontend:
	"$(PYTHON_BIN)" "$(ROOT_DIR)/scripts/sync_frontend_contracts.py" --check
	"$(NPM_BIN)" --prefix "$(ROOT_DIR)/frontend" ci
	"$(NPM_BIN)" --prefix "$(ROOT_DIR)/frontend" run build

compose: frontend
	"$(PYTHON_BIN)" "$(ROOT_DIR)/scripts/compose_activitywatch.py" \
		--activitywatch-dir "$(ROOT_DIR)/activitywatch" \
		--backend-dir "$(ROOT_DIR)/backend" \
		--xai-dir "$(XAI_DIR)" \
		--config-dir "$(ROOT_DIR)/config" \
		--frontend-artifact-dir "$(ROOT_DIR)/frontend/dist" \
		--output-dir "$(BUILD_ROOT)/composed/activitywatch"

ifeq ($(OS),Windows_NT)
binary-server: compose
	BUILD_ROOT="$(BUILD_ROOT)" \
	APP_NAME="$(APP_NAME)" \
	RELEASE_VERSION="$(RELEASE_VERSION)" \
	XAI_DIR="$(XAI_DIR)" \
	"$(POWERSHELL_BIN)" -NoProfile -ExecutionPolicy Bypass \
		-File "$(ROOT_DIR)/scripts/build_windows.ps1" -Target server

binary-app: binary-windows-app

package: package-windows
else
binary-server: compose
	BUILD_ROOT="$(BUILD_ROOT)" "$(ROOT_DIR)/scripts/build_binaries.sh" server

binary-app: binary-macos-app

package: package-macos
endif

binary-macos-app: compose
	BUILD_ROOT="$(BUILD_ROOT)" "$(ROOT_DIR)/scripts/build_binaries.sh" app

binary-windows-app: compose
	BUILD_ROOT="$(BUILD_ROOT)" \
	APP_NAME="$(APP_NAME)" \
	RELEASE_VERSION="$(RELEASE_VERSION)" \
	XAI_DIR="$(XAI_DIR)" \
	"$(POWERSHELL_BIN)" -NoProfile -ExecutionPolicy Bypass \
		-File "$(ROOT_DIR)/scripts/build_windows.ps1" -Target app

binary: binary-app

build: binary

package-macos: binary-macos-app
	BUILD_ROOT="$(BUILD_ROOT)" "$(ROOT_DIR)/scripts/release_macos.sh"

package-windows: binary-windows-app
	BUILD_ROOT="$(BUILD_ROOT)" \
	APP_NAME="$(APP_NAME)" \
	RELEASE_VERSION="$(RELEASE_VERSION)" \
	"$(POWERSHELL_BIN)" -NoProfile -ExecutionPolicy Bypass \
		-File "$(ROOT_DIR)/scripts/release_windows.ps1"

release: package

update-app: binary-server
	BUILD_ROOT="$(BUILD_ROOT)" \
	SERVER_BUNDLE_DIR="$(BUILD_ROOT)/bin/server/aw-server" \
	"$(ROOT_DIR)/scripts/update_local_app.sh" --skip-build

sync-app: update-app

clean:
	rm -rf "$(BUILD_ROOT)"
