FROM openresty/openresty:jammy

# hadolint ignore=DL3008
RUN apt-get update \
    && apt-get install --no-install-recommends -y \
        ca-certificates \
        curl \
        git \
        luarocks \
        python3 \
        python3-pip \
    && luarocks install lua-resty-http \
    && luarocks install lua-resty-jwt \
    && luarocks install lua-cjson \
    && groupadd --gid 65532 provost \
    && useradd --uid 65532 --gid 65532 --no-create-home --shell /usr/sbin/nologin provost \
    && mkdir -p /etc/nginx/conf.d /etc/nginx/lua /etc/nginx/mcp_routes /var/log/nginx /var/run/nginx \
    && rm -rf /var/lib/apt/lists/*

COPY default.conf /etc/nginx/conf.d/default.conf
COPY lua/ /etc/nginx/lua/
COPY bootstrap.sh /usr/local/bin/bootstrap.sh
COPY mcp_routes.json /etc/nginx/mcp_routes/mcp_routes.json
COPY rules.json /etc/nginx/rules.json

RUN chmod 0755 /usr/local/bin/bootstrap.sh \
    && chown -R provost:provost /etc/nginx /var/log/nginx /var/run/nginx

USER provost
EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD curl --fail --silent --show-error http://localhost:8000/health || exit 1

ENTRYPOINT ["/usr/local/bin/bootstrap.sh"]