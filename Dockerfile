FROM debian:bookworm-slim AS build

ARG ZIG_VERSION=0.17.0-dev.902+7255f3e72

RUN apt-get update \
    && apt-get install --yes --no-install-recommends ca-certificates curl xz-utils \
    && curl --fail --location --silent --show-error \
        "https://ziglang.org/builds/zig-x86_64-linux-${ZIG_VERSION}.tar.xz" \
        --output /tmp/zig.tar.xz \
    && tar --extract --file /tmp/zig.tar.xz --directory /opt \
    && mv "/opt/zig-x86_64-linux-${ZIG_VERSION}" /opt/zig \
    && rm /tmp/zig.tar.xz \
    && rm -rf /var/lib/apt/lists/*

ENV PATH=/opt/zig:${PATH}

WORKDIR /src
COPY build.zig build.zig.zon ./
COPY src ./src

ARG CONCURRENT=true
RUN zig build -Doptimize=ReleaseFast -Dconcurrent=${CONCURRENT}

FROM debian:bookworm-slim

COPY --from=build /src/zig-out/bin/zig_rest /usr/local/bin/zig_rest

EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/zig_rest"]
