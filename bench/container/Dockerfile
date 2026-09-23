# One environment for every agent on the polyglot benchmark.
#
# Built FROM Aider's own benchmark image, because that image is the environment the
# public leaderboard's numbers come from: Python 3.11 with pytest, Go 1.21, Java 21,
# Node 20 with jest, Rust, CMake and Boost. Nothing here changes a toolchain the tests
# run under; it only adds the agents.
#
#   - Almide, from its release, to build golemide and its companion tools
#   - gramide, hew and ctxgate, built from the sources bench/container.sh copied in
#   - golemide, built from the working tree bench/container.sh copied in
#   - ZCode at a pinned commit, built with its own pinned Node 24 and pnpm, kept in
#     /opt/node24 and off PATH so every test still runs under the image's Node 20
FROM aider-benchmark

SHELL ["/bin/bash", "-o", "pipefail", "-c"]
ARG ALMIDE_VERSION=v0.63.0-rc3
ARG NODE_VERSION=24.14.0
ARG PNPM_VERSION=10.33.2
ARG ZCODE_SHA

# From source at a release tag: the published Linux binaries need glibc 2.39, and this
# image is Ubuntu 22.04 (glibc 2.35). Everything almide builds links against the same
# libc, so building here is also what makes golemide and its tools run here.
# v0.63.0-rc3 and not v0.62.0: the host's compiler says 0.62.0 but was built after it,
# and hew already uses string.byte_slice, which the v0.62.0 tag does not have.
RUN git clone -q --depth 1 --branch "${ALMIDE_VERSION}" https://github.com/almide/almide /tmp/almide \
 && cd /tmp/almide \
 && cargo build --release --locked --bin almide > /tmp/almide-build.log 2>&1 \
 || { tail -30 /tmp/almide-build.log; exit 1; }
RUN install -m 0755 /tmp/almide/target/release/almide /usr/local/bin/almide \
 && rm -rf /tmp/almide \
 && almide --version

RUN case "$(uname -m)" in aarch64) n=arm64 ;; x86_64) n=x64 ;; *) exit 1 ;; esac \
 && curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${n}.tar.xz" | tar -xJ -C /opt \
 && mv "/opt/node-v${NODE_VERSION}-linux-${n}" /opt/node24 \
 && PATH=/opt/node24/bin:$PATH npm install -g --silent "pnpm@${PNPM_VERSION}" \
 && /opt/node24/bin/node --version

# ZCode first: it is the slow layer and changes least.
RUN test -n "$ZCODE_SHA" \
 && git init -q /opt/ZCode && cd /opt/ZCode \
 && git remote add origin https://github.com/zai-org/ZCode \
 && git fetch -q --depth 1 origin "$ZCODE_SHA" && git checkout -q FETCH_HEAD \
 && export PATH=/opt/node24/bin:$PATH COREPACK_ENABLE_PROJECT_SPEC=0 HUSKY=0 \
 && pnpm install --filter '@zcode/cli...' > /tmp/zcode-install.log 2>&1 \
 && pnpm --filter '@zcode/cli...' build > /tmp/zcode-build.log 2>&1 \
 && test -f apps/zcode-cli/packages/cli/dist/zcode.cjs \
 || { tail -40 /tmp/zcode-install.log /tmp/zcode-build.log; exit 1; }

COPY companions/ /src/
RUN for t in gramide hew ctxgate; do \
      ( cd "/src/$t" && almide build > "/tmp/$t-build.log" 2>&1 && install -m 0755 "$t" "/usr/local/bin/$t" ) \
      || { tail -30 "/tmp/$t-build.log"; exit 1; }; \
    done \
 && hew --help > /dev/null && gramide languages > /dev/null

COPY golemide/ /opt/golemide/
RUN cd /opt/golemide && almide build > /tmp/golemide-build.log 2>&1 \
 || { tail -30 /tmp/golemide-build.log; exit 1; }

WORKDIR /opt/golemide
