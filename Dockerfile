FROM --platform=linux/amd64 ubuntu:latest

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       ca-certificates wget curl qemu-system-x86 qemu-utils cloud-image-utils \
       openssh-client coreutils grep sed procps util-linux e2fsprogs python3 \
    && rm -rf /var/lib/apt/lists/*

# ttyd (checked against SHA256SUMS) + cloudflared, from the official GitHub releases
RUN set -eux; \
    base=https://github.com/tsl0922/ttyd/releases/latest/download; \
    wget -q -O /usr/local/bin/ttyd "$base/ttyd.x86_64"; \
    sum=$(wget -qO- "$base/SHA256SUMS" | awk '{n=$NF; sub(/^\*/,"",n); if (n=="ttyd.x86_64") {print $1; exit}}'); \
    echo "$sum  /usr/local/bin/ttyd" | sha256sum -c -; \
    wget -q -O /usr/local/bin/cloudflared \
      https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64; \
    chmod 0755 /usr/local/bin/ttyd /usr/local/bin/cloudflared; \
    ttyd --version; cloudflared --version

RUN useradd --create-home --shell /bin/bash app \
    && mkdir -p /state \
    && chown app:app /state

COPY qemu.sh /usr/local/bin/qemu.sh
RUN chmod 0755 /usr/local/bin/qemu.sh

USER app
WORKDIR /state
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/qemu.sh"]
