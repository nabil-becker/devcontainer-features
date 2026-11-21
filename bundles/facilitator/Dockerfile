# The facilitator node image (proposal facilitator-node, section 6.2): a node with no developer, an intranet hub,
# built from the same node bundle the devcontainer Feature installs. The build context holds the bundle tarball
# and its SHA256SUMS (task bundle:image locally; the release-node-image workflow from the released asset, whose
# digest the workflow checks against src/facilitator/digests.txt before the build).
#
#   docker build --build-arg BUNDLE_VERSION=0.3.0 -f bundles/facilitator/Dockerfile <folder with the bundle>
#
# Role standalone in slice N2: every port on loopback inside the container, nothing exposed. Secrets reach it as
# files or the environment (an OpenBao AppRole, slice N3), never baked in.

# debian:trixie-slim, by digest (the multi-arch index, read from Docker Hub on 2026-11-20).
ARG BASE=debian:trixie-slim@sha256:a72b4433de1cf7d6bae0c4cee74d0547f58601a643b3375f070c51600d63b6b2

FROM ${BASE} AS verify
ARG BUNDLE_VERSION
ARG TARGETARCH
# Optional: the digest pinned in digests.txt, checked too when given (the release workflow gives it).
ARG BUNDLE_SHA256=""
COPY facilitator-${BUNDLE_VERSION}-linux-${TARGETARCH}.tar.gz SHA256SUMS /bundle/
RUN set -eu; cd /bundle; asset="facilitator-${BUNDLE_VERSION}-linux-${TARGETARCH}.tar.gz"; \
    grep "  ${asset}\$" SHA256SUMS | sha256sum -c -; \
    if [ -n "${BUNDLE_SHA256}" ]; then echo "${BUNDLE_SHA256}  ${asset}" | sha256sum -c -; fi; \
    mkdir /out; tar -xzf "${asset}" -C /out --no-same-owner; test -f /out/facilitator/MANIFEST.json

FROM ${BASE}
ARG BUNDLE_VERSION
LABEL org.opencontainers.image.title="facilitator-node" \
      org.opencontainers.image.description="A facilitator node (the AGNTCY Directory, a SLIM node and the facilitator) with no developer: an intranet hub" \
      org.opencontainers.image.source="https://github.com/nabil-becker/devcontainer-features" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="${BUNDLE_VERSION}"
# openssh-client: the facilitator's ssh-agent and ssh-keygen sign every packet; tini: PID 1, reaps and passes signals.
RUN set -eu; apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates openssh-client tini; \
    rm -rf /var/lib/apt/lists/*; \
    useradd --system --uid 10001 --user-group --home-dir /var/lib/devcontainer-features/facilitator \
      --no-create-home --shell /usr/sbin/nologin facilitator; \
    mkdir -p /var/lib/devcontainer-features/facilitator /etc/facilitator; \
    chown facilitator:facilitator /var/lib/devcontainer-features/facilitator; \
    chmod 0700 /var/lib/devcontainer-features/facilitator
COPY --from=verify /out/facilitator /opt/facilitator
ENV PATH=/opt/facilitator/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    FACILITATOR_HOME=/var/lib/devcontainer-features/facilitator \
    FACILITATOR_FILE=/etc/facilitator/facilitator.yml \
    PARTICIPANTS_FILE=/etc/facilitator/participants.yml \
    FACILITATOR_MODE=node
# NFR-1: state only in the volume, at the same path as the Feature's.
VOLUME ["/var/lib/devcontainer-features/facilitator"]
WORKDIR /var/lib/devcontainer-features/facilitator
USER facilitator:facilitator
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 CMD ["facilitator", "infra", "status"]
ENTRYPOINT ["/usr/bin/tini", "--", "facilitator", "node", "run"]
