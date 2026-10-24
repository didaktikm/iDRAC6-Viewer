# idrac6-viewer - Dell iDRAC6 Virtual Console (Avocent KVM client) in a container.
# Java 7 + Xvfb + openbox + x11vnc + noVNC. Open http://localhost:6080/vnc.html
#
# NOTE: linux/amd64 only (the iDRAC native libraries are x86_64). On Apple Silicon, Docker Desktop
# runs it through Rosetta/QEMU.
#
# Two-stage build: Zulu 7 is downloaded and unpacked in a separate stage (no apt, no Debian mirror),
# and only the JRE (the `jre` folder) ends up in the final image - no compiler, sources, demos or man
# pages. Changing the Debian mirror does not re-download Java.
# Mirror: deb.debian.org (Fastly) is cut off by some ISPs ("unexpected EOF"); pick another with
#   docker build --build-arg DEB_MIRROR=mirror.yandex.ru .

# ---------- stage 1: Zulu 7 -> JRE only ----------
FROM --platform=linux/amd64 debian:bookworm-slim AS java

ARG ZULU7_URL=https://cdn.azul.com/zulu/bin/zulu7.56.0.11-ca-jdk7.0.352-linux_x64.tar.gz
ADD ${ZULU7_URL} /tmp/zulu7.tar.gz

RUN mkdir /zulu \
    && tar -xzf /tmp/zulu7.tar.gz --strip-components=1 -C /zulu \
    && test -x /zulu/jre/bin/java \
    && test -d /zulu/jre/lib/amd64

# ---------- stage 2: final image ----------
FROM --platform=linux/amd64 debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive \
    DISPLAY=:1 \
    JAVA_HOME=/opt/zulu7

# Debian mirror for apt. The default works from Russia; CI overrides it with deb.debian.org.
# scripts/local.sh benchmarks several mirrors and picks the fastest one.
ARG DEB_MIRROR=mirror.yandex.ru

# Attempts 1-2 use the chosen mirror, the rest fall back to mirror.yandex.ru (has debian and debian-security).
RUN printf 'Acquire::Retries "8";\nAcquire::http::Timeout "30";\n' > /etc/apt/apt.conf.d/80retries \
    && cp /etc/apt/sources.list.d/debian.sources /tmp/debian.sources.orig \
    && ok=0 \
    && for i in 1 2 3 4 5; do \
         m="${DEB_MIRROR}"; [ "$i" -ge 3 ] && m="mirror.yandex.ru"; \
         echo "apt: attempt $i, mirror $m"; \
         sed "s#deb.debian.org#$m#g" /tmp/debian.sources.orig > /etc/apt/sources.list.d/debian.sources; \
         if apt-get update && apt-get install -y --no-install-recommends \
              ca-certificates curl unzip \
              xvfb openbox x11vnc novnc websockify \
              libx11-6 libxext6 libxrender1 libxtst6 libxi6 libxt6 \
              fontconfig fonts-dejavu-core; then ok=1; break; fi; \
         sleep 5; \
       done \
    && [ "$ok" = 1 ] \
    && rm -rf /var/lib/apt/lists/* /usr/share/doc /usr/share/man /tmp/debian.sources.orig

# JRE only, from Zulu 7 (layout /opt/zulu7/jre/{bin,lib} preserved - entrypoint does not change)
COPY --from=java /zulu/jre ${JAVA_HOME}/jre
ENV PATH=${JAVA_HOME}/jre/bin:${PATH}

# The version is set late so that changing it does not invalidate the apt and Java layers
ARG VERSION=dev
ENV IDRAC6_KVM_VERSION=${VERSION}

COPY idrac.java.security /opt/idrac/idrac.java.security
COPY entrypoint.sh /opt/idrac/entrypoint.sh
RUN chmod +x /opt/idrac/entrypoint.sh \
    && mkdir -p /work /iso

WORKDIR /work
EXPOSE 6080
ENTRYPOINT ["/opt/idrac/entrypoint.sh"]
