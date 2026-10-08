FROM ubuntu:latest

ENV DEBIAN_FRONTEND=noninteractive
ENV VM_DIR=/var/lib/ubuntu-vm

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    ca-certificates \
    cloud-image-utils \
    openssh-client \
    qemu-system-x86 \
    qemu-utils \
    sshpass \
    wget \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/sshx-vm

COPY qemu.sh /usr/local/bin/qemu.sh
RUN chmod +x /usr/local/bin/qemu.sh

VOLUME ["/var/lib/ubuntu-vm"]

ENTRYPOINT ["/usr/local/bin/qemu.sh"]
