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

RUN printf '{"inbounds":[{"type":"snell","listen_port":1,"version":5,"psk":"build-check-psk"}],"outbounds":[{"type":"direct"}]}' > /tmp/snell-check.json \
 && /tmp/sing-box check -c /tmp/snell-check.json

FROM alpine:latest
ENV WARP=false
WORKDIR /app
RUN apk add --no-cache ca-certificates openssl wireguard-tools iproute2 iptables bash
COPY --chmod=755 --from=builder /tmp/sing-box /usr/local/bin/sing-box
COPY --chmod=755 --from=builder /tmp/wgcf /usr/local/bin/wgcf
COPY --chmod=755 start.sh .
VOLUME ["/data"]
CMD ["/app/start.sh"]
