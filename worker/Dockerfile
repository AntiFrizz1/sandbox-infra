FROM node:22.23.2-bookworm-slim@sha256:48e4b67d85f87bd551df43704e24d252f56cc5f8e9718841aace50f19948f0f9
RUN apt-get update && apt-get upgrade -y && apt-get install -y --no-install-recommends python3 make g++ \
    && rm -rf /var/lib/apt/lists/*
COPY run.sh /usr/local/lib/sandbox-worker.sh
ENTRYPOINT ["/bin/sh", "/usr/local/lib/sandbox-worker.sh"]
