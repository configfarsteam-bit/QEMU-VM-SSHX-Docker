FROM ubuntu:latest
ENV DEBIAN_FRONTEND=noninteractive VM_DIR=/var/lib/ubuntu-vm
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates wget qemu-system-x86 qemu-utils cloud-image-utils \
    && rm -rf /var/lib/apt/lists/*
COPY qemu.sh /usr/local/bin/qemu.sh
RUN chmod +x /usr/local/bin/qemu.sh
VOLUME ["/var/lib/ubuntu-vm"]
STOPSIGNAL SIGTERM
ENTRYPOINT ["/usr/local/bin/qemu.sh"]
