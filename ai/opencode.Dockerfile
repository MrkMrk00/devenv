FROM debian:trixie

ARG TARGETARCH

ARG OPENCODE_VERSION=1.14.49
ARG OPENCODE_SHA256_AMD64="0b373d64650073df36616af189c18cecaa3d5cd19ae2121300cafed1efa54b11"
ARG OPENCODE_SHA256_ARM64="b7e6cbdf27c030c72846319c5213f8e6af94efa831ecd9edd2f3223b87adeae7"

ARG FNM_VERSION=1.39.0
ARG FNM_SHA256_AMD64="7807664f39d39fc518da1c35ba0181e4b3267603c4b1dedeb4b5fc6ae440a224"
ARG FNM_SHA256_ARM64="4eaff58b2c5bf30d0934027572dd0b5bbb60d2a1af309230b53662d4b1d45599"

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update
RUN apt-get upgrade -y --no-install-recommends
RUN apt-get install -y --no-install-recommends           \
    git curl jq gzip unzip ca-certificates opendoas less \
    build-essential iputils-ping tree                    \
    python3 python3-pip python3-venv                     \
    ripgrep dnsutils net-tools

RUN <<EOF
#!/usr/bin/bash
set -euxo pipefail

function install_opencode() {
    local version="$1"
    local sha_amd="$2"
    local sha_arm="$3"

    dir=$(mktemp -d)
    (
        cd "$dir"
        if [ "$TARGETARCH" = 'amd64' ]; then
            curl -# -SfL "https://github.com/anomalyco/opencode/releases/download/v$version/opencode-linux-x64.tar.gz" \
                -o opencode.tar.gz

            echo "$sha_amd  opencode.tar.gz" | sha256sum -c
        elif [ "$TARGETARCH" = 'arm64' ]; then
            curl -# -SfL "https://github.com/anomalyco/opencode/releases/download/v$version/opencode-linux-arm64.tar.gz" \
                -o opencode.tar.gz

            echo "$sha_arm  opencode.tar.gz" | sha256sum -c
        else
            echo "unsupported architecture $TARGETARCH" >&2
            exit 1
        fi

        tar xzOf opencode.tar.gz opencode \
            | install -m 755 /dev/stdin /usr/local/bin/opencode
    )
    rm -rf "$dir"
}

function install_fnm() {
    local version="$1"
    local sha_amd="$2"
    local sha_arm="$3"

    dir=$(mktemp -d)
    (
        cd "$dir"
        if [ "$TARGETARCH" = 'amd64' ]; then
            curl -# -SfL "https://github.com/Schniz/fnm/releases/download/v$version/fnm-linux.zip" -o fnm.zip
            echo "$sha_amd  fnm.zip" | sha256sum -c
        elif [ "$TARGETARCH" = 'arm64' ]; then
            curl -# -SfL "https://github.com/Schniz/fnm/releases/download/v$version/fnm-arm64.zip" -o fnm.zip
            echo "$sha_arm  fnm.zip" | sha256sum -c
        else
            echo "unsupported architecture $TARGETARCH" >&2
            exit 1
        fi

        unzip -p fnm fnm | install -m 0755 /dev/stdin /usr/local/bin/fnm
    )
    rm -rf "$dir"
}

pids=()

install_opencode "$OPENCODE_VERSION" "$OPENCODE_SHA256_AMD64" "$OPENCODE_SHA256_ARM64" &
pids+=($!)
install_fnm      "$FNM_VERSION"      "$FNM_SHA256_AMD64"      "$FNM_SHA256_ARM64"      &
pids+=($!)

for pid in "${pids[@]}"; do wait "$pid"; done
EOF

RUN groupadd -g 1000 agent && useradd -u 1000 -g agent -m -s /bin/bash agent

RUN touch /etc/doas.conf && chmod 600 /etc/doas.conf
RUN ln -sf /usr/bin/doas /usr/local/bin/sudo

RUN cat <<EOF > /etc/doas.conf
permit nopass agent as root cmd apt
EOF

RUN mkdir -p /home/agent/.config/opencode
RUN mkdir -p /home/agent/.local/share/opencode
RUN mkdir -p /home/agent/.local/state/opencode

RUN chown -R agent:agent /home/agent

WORKDIR /home/agent/app
USER agent

RUN echo 'eval $(fnm env --shell bash)' >> /home/agent/.profile
RUN fnm install 24

ENTRYPOINT ["/bin/bash", "-l", "-c"]

CMD ["exec /usr/local/bin/opencode"]
