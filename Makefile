SHELL := /bin/zsh
.DEFAULT_GOAL := help

SIMULATOR ?= iPhone 17
SCHEME    ?= kPhotos
TUIST     ?= mise exec -- tuist

.PHONY: help setup install generate open build run-sim test dead-code clean
.PHONY: check-secrets check-headers check-realm lint lint-ci format format-check

help: ## Affiche l'aide
	@grep -E '^[a-zA-Z_-]+:.*?## ' Makefile | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

setup: ## Installe les outils déclarés dans .mise.toml
	mise install

install: ## Résout les dépendances SPM via Tuist
	$(TUIST) install
	python3 scripts/prepare_realm.py

generate: install ## Génère le projet Xcode (kPhotos.xcworkspace)
	$(TUIST) generate --no-open

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
	@if [ -d "$$(xcode-select -p)/../Applications/DeviceHub.app" ]; then \
		open -a "$$(xcode-select -p)/../Applications/DeviceHub.app"; \
	else open -a Simulator; fi
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

dead-code: ## Analyse le code inutilisé dans le workspace
	mise exec -- periphery scan -- \
		-destination 'platform=iOS Simulator,name=$(SIMULATOR)' \
		CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-

check-secrets: ## Vérifie les secrets dans les fichiers publiables et l’historique
	python3 scripts/check_secrets.py

check-headers: ## Vérifie les en-têtes et l'attribution de tous les sources
	python3 scripts/check_headers.py

check-realm: ## Vérifie le script de compatibilité Realm
	python3 -m unittest discover -s scripts/tests -p 'test_*.py'

lint: check-headers check-realm ## Lint SwiftLint
	mise exec -- swiftlint lint --strict --no-cache

lint-ci: check-headers check-realm ## Lint avec les règles strictes de CI
	mise exec -- swiftlint lint --strict --no-cache --config .swiftlint-ci.yml

format: ## Format SwiftFormat
	mise exec -- swiftformat . --cache ignore

format-check: ## Vérifie le format sans modifier les sources
	mise exec -- swiftformat . --lint --cache ignore

clean: ## Supprime DerivedData et fichiers générés Tuist
	rm -rf build Derived kPhotos.xcworkspace kPhotos.xcodeproj
	$(TUIST) clean 2>/dev/null || true
