SHELL := /bin/bash

ROOT_DIR:= $(patsubst %/,%,$(dir $(realpath $(lastword $(MAKEFILE_LIST)))))
include build/check_defined.mk

# Package
GO_PKG := github.com/operator-framework/operator-metering
REPORTING_OPERATOR_PKG := $(GO_PKG)/cmd/reporting-operator
# these are directories/files which get auto-generated or get reformated by
# gofmt
VERIFY_FILE_PATHS := cmd pkg test manifests Gopkg.lock

DOCKER_BUILD_CMD = docker build
OKD_BUILD = false
OCP_BUILD = false
REPO_DIR = $(ROOT_DIR)/hack/ocp-util/repos
SUB_MGR_FILE = $(ROOT_DIR)/hack/ocp-util/subscription-manager.conf

IMAGE_REPOSITORY = quay.io
IMAGE_ORG = openshift
DOCKER_BASE_URL = $(IMAGE_REPOSITORY)/$(IMAGE_ORG)

GIT_REVISION = $(shell git rev-list --count HEAD)
OLM_PACKAGE_MAJOR_MINOR_PATCH_VERSION = 4.3.0
OLM_PACKAGE_PRE_RELEASE_VERSION = $(GIT_REVISION)
OLM_PACKAGE_BUILD_META = $(shell hack/date.sh +%s)

OLM_PACKAGE_VERSION=$(OLM_PACKAGE_MAJOR_MINOR_PATCH_VERSION)-$(OLM_PACKAGE_PRE_RELEASE_VERSION)+$(OLM_PACKAGE_BUILD_META)
OLM_PACKAGE_ORG = coreos

METERING_SRC_IMAGE_REPO=$(DOCKER_BASE_URL)/metering-src
METERING_SRC_IMAGE_TAG=latest

REPORTING_OPERATOR_IMAGE_REPO=$(DOCKER_BASE_URL)/origin-metering-reporting-operator
REPORTING_OPERATOR_IMAGE_TAG=4.3
METERING_OPERATOR_IMAGE_REPO=$(DOCKER_BASE_URL)/origin-metering-ansible-operator
METERING_OPERATOR_IMAGE_TAG=4.3

REPORTING_OPERATOR_DOCKERFILE=Dockerfile.reporting-operator
METERING_ANSIBLE_OPERATOR_DOCKERFILE=Dockerfile.metering-ansible-operator

ifeq ($(OKD_BUILD), true)
	DOCKER_BUILD_CMD=imagebuilder -mount $(REPO_DIR):/etc/yum.repos.d/ -mount $(SUB_MGR_FILE):/etc/yum/pluginconf.d/subscription-manager.conf
	REPORTING_OPERATOR_DOCKERFILE=Dockerfile.reporting-operator.okd
endif

ifeq ($(OCP_BUILD), true)
	DOCKER_BUILD_CMD=imagebuilder -mount $(REPO_DIR):/etc/yum.repos.d/ -mount $(SUB_MGR_FILE):/etc/yum/pluginconf.d/subscription-manager.conf
	REPORTING_OPERATOR_DOCKERFILE=Dockerfile.reporting-operator.rhel
	METERING_ANSIBLE_OPERATOR_DOCKERFILE=Dockerfile.metering-ansible-operator.rhel
endif

GO_BUILD_ARGS := -ldflags '-extldflags "-static"'
GOOS = "linux"
CGO_ENABLED = 0

TEST2JSON_BIN_OUT = bin/test2json
DEPLOY_METERING_BIN_OUT = bin/deploy-metering
REPORTING_OPERATOR_BIN_OUT = bin/reporting-operator
REPORTING_OPERATOR_BIN_OUT_LOCAL = bin/reporting-operator-local
RUN_UPDATE_CODEGEN ?= true
CHECK_GO_FILES ?= true

REPORTING_OPERATOR_BIN_DEPENDENCIES =
CODEGEN_SOURCE_GO_FILES =
CODEGEN_OUTPUT_GO_FILES =
GOFILES =

# Adds all the Go files in the repo as a dependency to the build-reporting-operator target
ifeq ($(CHECK_GO_FILES), true)
	GOFILES := $(shell find $(ROOT_DIR) -name '*.go' | grep -v -E '(./vendor)')
endif

# Adds the update-codegen dependency to the build-reporting-operator target
ifeq ($(RUN_UPDATE_CODEGEN), true)
	REPORTING_OPERATOR_BIN_DEPENDENCIES += update-codegen
	CODEGEN_SOURCE_GO_FILES := $(shell $(ROOT_DIR)/hack/codegen_source_files.sh)
	CODEGEN_OUTPUT_GO_FILES := $(shell $(ROOT_DIR)/hack/codegen_output_files.sh)
endif

all: fmt unit verify docker-build-all

docker-build-all: reporting-operator-docker-build metering-ansible-operator-docker-build

reporting-operator-docker-build: $(REPORTING_OPERATOR_DOCKERFILE)
	$(DOCKER_BUILD_CMD) -f $< -t $(REPORTING_OPERATOR_IMAGE_REPO):$(REPORTING_OPERATOR_IMAGE_TAG) $(ROOT_DIR)

metering-src-docker-build: Dockerfile.src
	$(DOCKER_BUILD_CMD) -f $< -t $(METERING_SRC_IMAGE_REPO):$(METERING_SRC_IMAGE_TAG) $(ROOT_DIR)

metering-ansible-operator-docker-build: $(METERING_ANSIBLE_OPERATOR_DOCKERFILE)
	$(DOCKER_BUILD_CMD) -f $< -t $(METERING_OPERATOR_IMAGE_REPO):$(METERING_OPERATOR_IMAGE_TAG) $(ROOT_DIR)

# Runs gofmt on all files in project except vendored source
fmt:
	find . -name '*.go' -not -path "./vendor/*" | xargs gofmt -w

# Update dependencies
vendor: Gopkg.toml
	dep ensure -v

test: unit

unit:
	hack/unit.sh

unit-docker: metering-src-docker-build
	docker run \
		--rm \
		-t \
		-w /go/src/github.com/operator-framework/operator-metering \
		-v $(PWD):/go/src/github.com/operator-framework/operator-metering \
		$(METERING_SRC_IMAGE_REPO):$(METERING_SRC_IMAGE_TAG) \
		make unit

e2e: $(TEST2JSON_BIN_OUT) $(DEPLOY_METERING_BIN_OUT)
	hack/e2e.sh

e2e-local: reporting-operator-local metering-ansible-operator-docker-build
	$(MAKE) e2e METERING_RUN_TESTS_LOCALLY=true METERING_OPERATOR_IMAGE_REPO=$(METERING_OPERATOR_IMAGE_REPO) METERING_OPERATOR_IMAGE_TAG=$(METERING_OPERATOR_IMAGE_TAG)

e2e-docker: metering-src-docker-build
	docker run \
		--name metering-e2e-docker \
		-t \
		-e METERING_NAMESPACE \
		-e METERING_OPERATOR_IMAGE_REPO -e METERING_OPERATOR_IMAGE_TAG \
		-e REPORTING_OPERATOR_IMAGE_REPO -e REPORTING_OPERATOR_IMAGE_TAG \
		-e KUBECONFIG=/kubeconfig \
		-e TEST_OUTPUT_PATH=/out \
		-w /go/src/github.com/operator-framework/operator-metering \
		-v $(KUBECONFIG):/kubeconfig \
		-v $(PWD):/go/src/github.com/operator-framework/operator-metering \
		-v /out \
		$(METERING_SRC_IMAGE_REPO):$(METERING_SRC_IMAGE_TAG) \
		make e2e
	rm -rf bin/e2e-docker-test-output
	docker cp metering-e2e-docker:/out bin/e2e-docker-test-output
	docker rm metering-e2e-docker

vet:
	go vet $(GO_PKG)/cmd/... $(GO_PKG)/pkg/...

verify: verify-codegen verify-olm-manifests verify-helm-templates fmt vet
	@echo Checking for unstaged changes
	# validates no unstaged changes exist in $(VERIFY_FILE_PATHS)
	git diff --stat HEAD --ignore-submodules --exit-code -- $(VERIFY_FILE_PATHS)

verify-helm-templates:
	helm template ./charts/openshift-metering > /dev/null

verify-olm-manifests: metering-manifests
	operator-courier verify --ui_validate_io ./manifests/deploy/openshift/olm/bundle
	operator-courier verify --ui_validate_io ./manifests/deploy/upstream/olm/bundle

push-olm-manifests: verify-olm-manifests
	./hack/push-olm-manifests.sh $(OLM_PACKAGE_ORG) metering-ocp $(OLM_PACKAGE_VERSION)

verify-docker: metering-src-docker-build
	docker run \
		--rm \
		-t \
		-w /go/src/github.com/operator-framework/operator-metering \
		-v $(PWD):/go/src/github.com/operator-framework/operator-metering \
		$(METERING_SRC_IMAGE_REPO):$(METERING_SRC_IMAGE_TAG) \
		make verify

.PHONY: run-metering-operator-local
run-metering-operator-local: $(DEPLOY_METERING_BIN_OUT) metering-ansible-operator-docker-build
	export \
		METERING_OPERATOR_IMAGE_REPO=$(METERING_OPERATOR_IMAGE_REPO) \
		METERING_OPERATOR_IMAGE_TAG=$(METERING_OPERATOR_IMAGE_TAG); \
	./hack/run-metering-operator-local.sh

reporting-operator-bin: $(REPORTING_OPERATOR_BIN_OUT)

reporting-operator-local: $(GOFILES)
	$(MAKE) build-reporting-operator REPORTING_OPERATOR_BIN_OUT=$(REPORTING_OPERATOR_BIN_OUT_LOCAL) GOOS=$(shell go env GOOS)

.PHONY: run-reporting-operator-local
run-reporting-operator-local: reporting-operator-local
	./hack/run-reporting-operator-local.sh $(REPORTING_OPERATOR_ARGS)

$(REPORTING_OPERATOR_BIN_OUT): $(GOFILES)
	$(MAKE) build-reporting-operator

build-reporting-operator: $(REPORTING_OPERATOR_BIN_DEPENDENCIES) $(GOFILES)
	@:$(call check_defined, REPORTING_OPERATOR_BIN_OUT, Path to output binary location)
	mkdir -p $(dir $(REPORTING_OPERATOR_BIN_OUT))
	CGO_ENABLED=$(CGO_ENABLED) GOOS=$(GOOS) go build $(GO_BUILD_ARGS) -o $(REPORTING_OPERATOR_BIN_OUT) $(REPORTING_OPERATOR_PKG)

metering-manifests:
	export \
		METERING_OPERATOR_IMAGE_REPO=$(METERING_OPERATOR_IMAGE_REPO) \
		METERING_OPERATOR_IMAGE_TAG=$(METERING_OPERATOR_IMAGE_TAG); \
	./hack/generate-metering-manifests.sh

$(TEST2JSON_BIN_OUT): gotools/test2json/main.go
	go build -o $(TEST2JSON_BIN_OUT) gotools/test2json/main.go

$(DEPLOY_METERING_BIN_OUT): $(GOFILES)
	go build -o $(DEPLOY_METERING_BIN_OUT) $(GO_PKG)/cmd/deploy-metering

.PHONY: \
	test vendor fmt verify \
	update-codegen verify-codegen \
	docker-build docker-tag docker-push \
	docker-build-all docker-tag-all docker-push-all \
	metering-test-docker \
	metering-src-docker-build \
	build-reporting-operator reporting-operator-bin reporting-operator-local \
	metering-manifests \
	install-kube-prometheus-helm

update-codegen: $(CODEGEN_OUTPUT_GO_FILES)
	./hack/update-codegen.sh

$(CODEGEN_OUTPUT_GO_FILES): $(CODEGEN_SOURCE_GO_FILES)

verify-codegen:
	./hack/verify-codegen.sh
