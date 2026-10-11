FROM --platform=linux/amd64 ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV PORT=8080
ENV WEB_ROOT=/opt/web

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       ca-certificates wget curl python3 qemu-system-x86 qemu-utils cloud-image-utils \
       coreutils grep sed procps util-linux e2fsprogs \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --shell /bin/bash app \
    && mkdir -p /state /opt/web \
    && chown -R app:app /state /opt/web

COPY --chown=app:app index.html /opt/web/index.html
COPY --chown=app:app qemu-sshx.sh /usr/local/bin/qemu-sshx.sh
RUN chmod 0755 /usr/local/bin/qemu-sshx.sh

USER app
WORKDIR /state
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/qemu-sshx.sh"]
