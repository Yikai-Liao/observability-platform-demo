FROM python:3.12-slim

ARG HTTP_PROXY
ARG HTTPS_PROXY
ARG ALL_PROXY
ARG NO_PROXY

ENV DEBIAN_FRONTEND=noninteractive

WORKDIR /app

RUN HTTP_PROXY="${HTTP_PROXY}" \
    HTTPS_PROXY="${HTTPS_PROXY}" \
    ALL_PROXY="${ALL_PROXY}" \
    NO_PROXY="${NO_PROXY}" \
    http_proxy="${HTTP_PROXY}" \
    https_proxy="${HTTPS_PROXY}" \
    all_proxy="${ALL_PROXY}" \
    no_proxy="${NO_PROXY}" \
    rm -f /etc/apt/sources.list.d/debian.sources \
    && printf '%s\n' \
        'deb http://mirrors.tuna.tsinghua.edu.cn/debian/ trixie main contrib non-free non-free-firmware' \
        'deb http://mirrors.tuna.tsinghua.edu.cn/debian/ trixie-updates main contrib non-free non-free-firmware' \
        'deb http://mirrors.tuna.tsinghua.edu.cn/debian/ trixie-backports main contrib non-free non-free-firmware' \
        'deb http://mirrors.tuna.tsinghua.edu.cn/debian-security trixie-security main contrib non-free non-free-firmware' \
        > /etc/apt/sources.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl netbase nodejs npm \
    && rm -rf /var/lib/apt/lists/*

COPY ts-app/package.json /app/package.json
COPY ts-app/tsconfig.json /app/tsconfig.json

RUN HTTP_PROXY="${HTTP_PROXY}" \
    HTTPS_PROXY="${HTTPS_PROXY}" \
    ALL_PROXY="${ALL_PROXY}" \
    NO_PROXY="${NO_PROXY}" \
    http_proxy="${HTTP_PROXY}" \
    https_proxy="${HTTPS_PROXY}" \
    all_proxy="${ALL_PROXY}" \
    no_proxy="${NO_PROXY}" \
    npm config set registry https://registry.npmmirror.com \
    && npm install

COPY ts-app/src /app/src

RUN npm run build \
    && npm prune --omit=dev

CMD ["node", "/app/dist/main.js"]
