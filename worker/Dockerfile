FROM node:22.23.3-bookworm-slim@sha256:43ac6c60b8f89723f746e8a92ce91abd5017e627ce1ddfe4238355d3a30b772c
RUN apt-get update && apt-get upgrade -y && apt-get install -y --no-install-recommends python3 make g++ \
    && rm -rf /var/lib/apt/lists/*
# The npm bundled with Node 22 carries vulnerable dependencies (pacote,
# sigstore, brace-expansion, ...); npm 11 ships fixed ones. Exact version.
RUN npm install -g npm@11.20.0 && npm cache clean --force && rm -rf /root/.npm
COPY run.sh /usr/local/lib/sandbox-worker.sh
ENTRYPOINT ["/bin/sh", "/usr/local/lib/sandbox-worker.sh"]
