REG ?= quay.io/you
TAG ?= latest
NS  ?= rhoim
IMAGEDIR ?= image

.PHONY: build push build-cpu push-cpu build-cpu-local package-cpu build-appliance-cpu-local package-appliance-cpu helm-install helm-uninstall

build:
	# GPU builds commented out for CPU-only workflows
	# podman build -t $(REG)/rhoim-gateway:$(TAG) ./gateway
	# podman build -t $(REG)/rhoim-vllm:$(TAG)    ./runtimes/vllm
	# podman build -t $(REG)/rhoim-appliance:$(TAG) ./deploy/appliance
	# Use CPU builds instead:
	podman build -t $(REG)/rhoim-vllm-cpu:$(TAG) -f ./runtimes/vllm-cpu/Dockerfile .
	podman build -t $(REG)/rhoim-appliance-cpu:$(TAG) -f ./deploy/appliance-cpu/Dockerfile .

push:
	# GPU pushes commented out for CPU-only workflows
	# podman push $(REG)/rhoim-gateway:$(TAG)
	# podman push $(REG)/rhoim-vllm:$(TAG)
	# podman push $(REG)/rhoim-appliance:$(TAG)
	# Use CPU pushes instead:
	podman push $(REG)/rhoim-vllm-cpu:$(TAG)
	podman push $(REG)/rhoim-appliance-cpu:$(TAG)

# Build CPU images with local tags (no registry prefix)
build-cpu-local:
	podman build -t rhoim-vllm-cpu:$(TAG) -f ./runtimes/vllm-cpu/Dockerfile .
	podman build -t rhoim-appliance-cpu:$(TAG) -f ./deploy/appliance-cpu/Dockerfile .

# Save CPU images as tarballs under ./$(IMAGEDIR)
package-cpu:
	mkdir -p $(IMAGEDIR)
	# Save vLLM CPU image; try local tag first, fallback to REG-qualified
	(podman image exists rhoim-vllm-cpu:$(TAG) && podman save -o $(IMAGEDIR)/rhoim-vllm-cpu-$(TAG).tar rhoim-vllm-cpu:$(TAG)) || podman save -o $(IMAGEDIR)/rhoim-vllm-cpu-$(TAG).tar $(REG)/rhoim-vllm-cpu:$(TAG)
	# Save appliance CPU image; try local tag first, fallback to REG-qualified
	(podman image exists rhoim-appliance-cpu:$(TAG) && podman save -o $(IMAGEDIR)/rhoim-appliance-cpu-$(TAG).tar rhoim-appliance-cpu:$(TAG)) || podman save -o $(IMAGEDIR)/rhoim-appliance-cpu-$(TAG).tar $(REG)/rhoim-appliance-cpu:$(TAG)

# Build ONLY the single appliance image locally (no registry)
build-appliance-cpu-local:
	podman build -t rhoim:$(TAG) -f ./deploy/appliance-cpu/Dockerfile .

# Package ONLY the appliance image to ./image
package-appliance-cpu:
	mkdir -p $(IMAGEDIR)
	(podman image exists rhoim:$(TAG) && podman save -o $(IMAGEDIR)/rhoim-$(TAG).tar rhoim:$(TAG)) || podman save -o $(IMAGEDIR)/rhoim-$(TAG).tar $(REG)/rhoim-appliance-cpu:$(TAG)

build-cpu:
	podman build -t $(REG)/rhoim-vllm-cpu:$(TAG) -f ./runtimes/vllm-cpu/Dockerfile .
	podman build -t $(REG)/rhoim-appliance-cpu:$(TAG) -f ./deploy/appliance-cpu/Dockerfile .

push-cpu:
	podman push $(REG)/rhoim-vllm-cpu:$(TAG)
	podman push $(REG)/rhoim-appliance-cpu:$(TAG)

helm-install:
	helm upgrade --install rhoim deploy/helm/rhoim -n $(NS) \
	  --set image.gateway=$(REG)/rhoim-gateway:$(TAG) \
	  --set image.vllm=$(REG)/rhoim-vllm:$(TAG) \
	  --set image.appliance=$(REG)/rhoim-appliance:$(TAG)

helm-uninstall:
	helm uninstall rhoim -n $(NS) || true

# Bootc UBI-based builds (CPU-only)
build-bootc-ubi:
	podman build -t localhost/rhoim-bootc-ubi:$(TAG) -f deploy/bootc-ubi/Containerfile .

build-bootc-image-ubi: build-bootc-ubi
	mkdir -p $(IMAGEDIR)
	podman run --rm --privileged \
		-v /var/lib/containers/storage:/var/lib/containers/storage \
		-v "$(PWD)/$(IMAGEDIR)":/output \
		quay.io/centos-bootc/bootc-image-builder:latest \
		--type qcow2 \
		localhost/rhoim-bootc-ubi:$(TAG)
