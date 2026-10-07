FROM mcr.microsoft.com/devcontainers/base:ubuntu-24.04

COPY src/node /tmp/local-features/node
COPY src/python /tmp/local-features/python
RUN bash /tmp/local-features/node/install.sh \
    && bash /tmp/local-features/python/install.sh \
    && rm -rf /tmp/local-features

ENV PATH="/usr/local/share/devcontainer-node/current/bin:${PATH}"
