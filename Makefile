TAG ?= v1.20.0
IMAGE ?= knot

.PHONY: help build

help: ## Show this help
	@grep -E '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-20s %s\n", $$1, $$2}'

build: ## Build the Debian-based image
	docker build -f Dockerfile --build-arg TAG=$(TAG) -t $(IMAGE):$(TAG) .

