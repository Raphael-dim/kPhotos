SHELL := /bin/zsh
.DEFAULT_GOAL := help

SIMULATOR ?= iPhone 17
SCHEME    ?= kPhotos

.PHONY: help setup install generate open build run-sim test lint format clean

help: ## Affiche l'aide
	@grep -E '^[a-zA-Z_-]+:.*?## ' Makefile | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

setup: ## Installe les outils déclarés dans .mise.toml
	mise install

install: ## Résout les dépendances SPM via Tuist
	tuist install

generate: install ## Génère le projet Xcode (kPhotos.xcworkspace)
	tuist generate --no-open

open: ## Ouvre kPhotos.xcworkspace dans Xcode
	open kPhotos.xcworkspace

build: ## Build pour simulateur sans lancer Xcode
	xcodebuild -workspace kPhotos.xcworkspace \
		-scheme $(SCHEME) \
		-destination 'platform=iOS Simulator,name=$(SIMULATOR)' \
		-configuration Debug \
		build

run-sim: ## Build + boot du simulateur + install + launch
	@xcrun simctl boot "$(SIMULATOR)" 2>/dev/null || true
	@open -a Simulator
	xcodebuild -workspace kPhotos.xcworkspace \
		-scheme $(SCHEME) \
		-destination 'platform=iOS Simulator,name=$(SIMULATOR)' \
		-configuration Debug \
		-derivedDataPath build/DerivedData \
		build
	@APP_PATH=$$(find build/DerivedData -name 'kPhotos.app' -path '*Debug-iphonesimulator*' | head -1); \
		echo "Installing $$APP_PATH"; \
		xcrun simctl install booted "$$APP_PATH"; \
		xcrun simctl launch booted app.kphotos

test: ## Lance les tests unitaires sur simulateur
	xcodebuild test \
		-workspace kPhotos.xcworkspace \
		-scheme $(SCHEME) \
		-destination 'platform=iOS Simulator,name=$(SIMULATOR)'

lint: ## Lint SwiftLint
	swiftlint --strict

format: ## Format SwiftFormat
	swiftformat .

clean: ## Supprime DerivedData et fichiers générés Tuist
	rm -rf build Derived kPhotos.xcworkspace kPhotos.xcodeproj
	tuist clean 2>/dev/null || true
