FROM alpine:latest AS builder
ARG SINGBOX_VERSION
ARG WGCF_VERSION
RUN apk add --no-cache ca-certificates tar wget \
 && wget -qO /tmp/sing-box.tar.gz \
      "https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VERSION}/sing-box-${SINGBOX_VERSION}-linux-amd64-musl.tar.gz" \
 && tar -xzf /tmp/sing-box.tar.gz -C /tmp \
 && mv /tmp/sing-box-${SINGBOX_VERSION}-linux-amd64-musl/sing-box /tmp/sing-box \
 && wget -qO /tmp/wgcf \
      "https://github.com/ViRb3/wgcf/releases/download/v${WGCF_VERSION}/wgcf_${WGCF_VERSION}_linux_amd64" \
 && chmod +x /tmp/wgcf

# snell-server is a packed, statically-linked glibc binary that dlopen()s its
# shared libs lazily (libstdc++ only loads once it handles a connection), so the
# exact set can't be read statically or from an idle run. Determine it by tracing
# on this glibc host: start snell, drive held-open connections to force the lazy
# loads, then read /proc/<pid>/maps across all snell processes and copy exactly
# the .so files it mapped — no more, no less. The build log prints the captured
# set. (gcompat's musl loader can't run it: "Not a valid dynamic program".)
FROM debian:trixie-slim AS glibc
COPY snell-server /tmp/snell-server
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends libstdc++6 libgcc-s1 netcat-openbsd; \
    rm -rf /var/lib/apt/lists/*; \
    chmod +x /tmp/snell-server; \
    printf '[snell-server]\nlisten = 127.0.0.1:9999\npsk = trace-probe-psk-0123456789abcdef\n' > /tmp/snell.conf; \
    /tmp/snell-server -c /tmp/snell.conf >/tmp/snell.log 2>&1 & pid=$!; \
    sleep 1; \
    test -r /proc/$pid/maps || { echo "snell-server failed to start:"; cat /tmp/snell.log; exit 1; }; \
    for i in 1 2 3; do ( head -c 256 /dev/urandom; sleep 4 ) | nc 127.0.0.1 9999 & done; \
    sleep 2; \
    libs="$(for p in /proc/[0-9]*; do \
              [ "$(readlink "$p/exe" 2>/dev/null)" = /tmp/snell-server ] && cat "$p/maps"; \
            done | grep -oE '/(usr/)?lib[^ ]*\.so[0-9.]*' | sort -u)"; \
    kill $pid 2>/dev/null || true; \
    echo "=== snell-server log ==="; cat /tmp/snell.log || true; \
    echo "=== snell-server runtime libs ==="; printf '%s\n' "$libs"; \
    test -n "$libs"; \
    mkdir -p /glibc/lib64 /glibc/lib; \
    printf '%s\n' "$libs" | while read -r so; do \
      [ -n "$so" ] || continue; \
      dir=$(dirname "$so"); base=$(basename "$so"); \
      cp -aL "$so" "/glibc/lib/$base"; \
      case "$base" in ld-linux-*) cp -aL "$so" "/glibc/lib64/$base" ;; esac; \
      # /proc/maps reports the real file (e.g. libstdc++.so.6.0.33) but the loader
      # looks it up by SONAME, so recreate the sibling SONAME symlink(s).
      for l in "$dir"/*; do \
        if [ -L "$l" ] && [ "$(readlink "$l")" = "$base" ]; then \
          ln -sf "$base" "/glibc/lib/$(basename "$l")"; \
        fi; \
      done; \
    done

FROM alpine:latest
ENV WARP=false
WORKDIR /app
RUN apk add --no-cache ca-certificates openssl wireguard-tools iproute2 iptables bash
# Real glibc runtime for snell-server (no gcompat). Debian's loader searches
# /usr/lib/x86_64-linux-gnu by default, so its libs are found there without an
# ld.so cache; the differently-named musl files in /usr/lib don't collide.
COPY --from=glibc /glibc/lib64/ /lib64/
COPY --from=glibc /glibc/lib/ /usr/lib/x86_64-linux-gnu/
COPY --chmod=755 --from=builder /tmp/sing-box /usr/local/bin/sing-box
COPY --chmod=755 --from=builder /tmp/wgcf /usr/local/bin/wgcf
COPY --chmod=755 snell-server /usr/local/bin/snell-server
COPY --chmod=755 start.sh .
VOLUME ["/data"]
CMD ["/app/start.sh"]
