# One environment for every agent on the polyglot benchmark.
#
# Built FROM Aider's own benchmark image, because that image is the environment the
# public leaderboard's numbers come from: Python 3.11 with pytest, Go 1.21, Java 21,
# Node 20 with jest, Rust, CMake and Boost. Nothing here changes a toolchain the tests
# run under; it only adds the agents.
#
#   - Almide at a pinned develop commit, to build golemide, comide and the companions
#   - gramide (from gramide-cli), hew and ctxgate, built from the sources
#     bench/container.sh copied in
#   - golemide and comide, built from the working trees bench/container.sh copied in
#   - ZCode at a pinned commit, built with its own pinned Node 24 and pnpm, kept in
#     /opt/node24 and off PATH so every test still runs under the image's Node 20
#   - the Cursor CLI (cursor-agent), from Cursor's installer, version recorded
FROM aider-benchmark

SHELL ["/bin/bash", "-o", "pipefail", "-c"]
ARG ALMIDE_SHA=ce7cd75538fa4eb793b6c532c7a41f908ae90dbd
ARG NODE_VERSION=24.14.0
ARG PNPM_VERSION=10.33.2
ARG ZCODE_SHA

# From source: the published Linux binaries need glibc 2.39, and this image is Ubuntu
# 22.04 (glibc 2.35). Everything almide builds links against the same libc, so building
# here is also what makes golemide and its tools run here. A develop commit and not a
# release: golemide 0.2.0 and comide need fixes that no tag has yet (almide#2536,
# #2537, #2539), and it is the commit golemide's CI is pinned to.
RUN git init -q /tmp/almide && cd /tmp/almide \
 && git remote add origin https://github.com/almide/almide \
 && git fetch -q --depth 1 origin "${ALMIDE_SHA}" && git checkout -q FETCH_HEAD \
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
      ( cd "/src/$t" && almide build -o "$t" > "/tmp/$t-build.log" 2>&1 && install -m 0755 "$t" "/usr/local/bin/$t" ) \
      || { tail -30 "/tmp/$t-build.log"; exit 1; }; \
    done \
 && hew --help > /dev/null && gramide languages > /dev/null

COPY golemide/ /opt/golemide/
RUN cd /opt/golemide && almide build > /tmp/golemide-build.log 2>&1 \
 && ln -s /opt/golemide/golemide /usr/local/bin/golemide && golemide --version \
 || { tail -30 /tmp/golemide-build.log; exit 1; }

COPY comide/ /opt/comide/
RUN cd /opt/comide && almide build src/main.almd -o comide > /tmp/comide-build.log 2>&1 \
 && ln -s /opt/comide/comide /usr/local/bin/comide && comide --help > /dev/null \
 || { tail -30 /tmp/comide-build.log; exit 1; }

# Last, because it is the layer that changes by itself: the installer serves whatever
# is current. The version it installed is what the results are recorded against.
RUN curl -fsS https://cursor.com/install | bash > /tmp/cursor-install.log 2>&1 \
 && for b in cursor-agent agent; do [ -x "/root/.local/bin/$b" ] && ln -sf "/root/.local/bin/$b" "/usr/local/bin/$b"; done; \
 cursor-agent --version > /opt/cursor-agent.version 2>&1 || { tail -30 /tmp/cursor-install.log; exit 1; }

WORKDIR /opt/golemide
