SHELL := /bin/bash

FORMULA_REPO := $(HOME)/Documents/late/homebrew-formulae
FORMULA_FILE := $(FORMULA_REPO)/Formula/elmterm.rb
FORMULA_RELATIVE := Formula/elmterm.rb

.PHONY: release
release:
	@set -euo pipefail; \
	printf "Release version (e.g. 0.9.2): "; \
	read -r VERSION; \
	if [[ -z "$$VERSION" ]]; then \
		echo "Version cannot be empty."; \
		exit 1; \
	fi; \
	if [[ "$$VERSION" =~ [^0-9.] || "$$VERSION" == .* || "$$VERSION" == *. || "$$VERSION" == *..* ]]; then \
		echo "Version must contain only digits and dots (example: 0.9.2)."; \
		exit 1; \
	fi; \
	if [[ ! -d "$(FORMULA_REPO)/.git" ]]; then \
		echo "Missing formula repository: $(FORMULA_REPO)"; \
		exit 1; \
	fi; \
	if [[ ! -f "$(FORMULA_FILE)" ]]; then \
		echo "Missing formula file: $(FORMULA_FILE)"; \
		exit 1; \
	fi; \
	if [[ -n "$$(git status --porcelain)" ]]; then \
		echo "ELMterm repository has uncommitted changes. Commit or stash first."; \
		exit 1; \
	fi; \
	if git rev-parse -q --verify "refs/tags/$$VERSION" >/dev/null; then \
		echo "Tag $$VERSION already exists."; \
		exit 1; \
	fi; \
	CURRENT_BRANCH=$$(git rev-parse --abbrev-ref HEAD); \
	echo "Creating release commit and tag $$VERSION on $$CURRENT_BRANCH"; \
	git add -A; \
	git commit --allow-empty -m "Release $$VERSION"; \
	git tag -a "$$VERSION" -m "Release $$VERSION"; \
	git push origin "$$CURRENT_BRANCH"; \
	git push origin "$$VERSION"; \
	TARBALL_URL="https://github.com/Automotive-Swift/ELMterm/archive/refs/tags/$$VERSION.tar.gz"; \
	echo "Downloading $$TARBALL_URL"; \
	SHA256=$$(curl -fsSL "$$TARBALL_URL" | shasum -a 256 | awk '{print $$1}'); \
	echo "Computed SHA256: $$SHA256"; \
	if [[ -n "$$(git -C "$(FORMULA_REPO)" status --porcelain)" ]]; then \
		echo "homebrew-formulae repository has uncommitted changes. Commit or stash first."; \
		exit 1; \
	fi; \
	FORMULA_BRANCH=$$(git -C "$(FORMULA_REPO)" rev-parse --abbrev-ref HEAD); \
	git -C "$(FORMULA_REPO)" pull --ff-only origin "$$FORMULA_BRANCH"; \
	VERSION="$$VERSION" SHA256="$$SHA256" ruby -i -pe 'sub(/^  url ".*"$$/, "  url \"https://github.com/Automotive-Swift/ELMterm/archive/refs/tags/#{ENV.fetch(\"VERSION\")}.tar.gz\""); sub(/^  version ".*"$$/, "  version \"#{ENV.fetch(\"VERSION\")}\""); sub(/^  sha256 ".*"$$/, "  sha256 \"#{ENV.fetch(\"SHA256\")}\"")' "$(FORMULA_FILE)"; \
	/opt/homebrew/bin/brew style "$(FORMULA_FILE)"; \
	git -C "$(FORMULA_REPO)" add "$(FORMULA_RELATIVE)"; \
	git -C "$(FORMULA_REPO)" commit -m "elmterm $$VERSION"; \
	git -C "$(FORMULA_REPO)" push origin "$$FORMULA_BRANCH"; \
	echo "Release $$VERSION complete."
