FROM --platform=linux/amd64 ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       ca-certificates wget curl qemu-system-x86 qemu-utils cloud-image-utils \
       coreutils grep sed procps util-linux e2fsprogs \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --shell /bin/bash app \
    && mkdir -p /state \
    && chown app:app /state

COPY qemu-sshx.sh /usr/local/bin/qemu-sshx.sh
RUN chmod 0755 /usr/local/bin/qemu-sshx.sh

USER app
WORKDIR /state
ENTRYPOINT ["/usr/local/bin/qemu-sshx.sh"]
