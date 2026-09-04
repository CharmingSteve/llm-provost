ARG BASE_PYTHON_IMAGE=python:3.11-alpine@sha256:e60a76d54e289c65d676aa92009fa373b9bfe95c02805190105f8308324ebe02
#Base image needs  needs to be twice, here and in env.versions
# This Alpine is from https://hub.docker.com/layers/library/python/3.11-alpine3.23/images/sha256-d2f7cab9195aef6d63af382e070462cc8361b8d9478877a4eae7ff65ff8c7fb2 it is multiplatform 
# checkov:skip=CKV_DOCKER_7:base image is pinned to a digest via ARG default above
# hadolint ignore=DL3006
FROM ${BASE_PYTHON_IMAGE}

COPY hash-pip/requirements-runtime.txt /tmp/requirements-runtime.txt
RUN apk upgrade --no-cache \
	&& rm -rf /usr/local/lib/python3.11/site-packages/setuptools \
		/usr/local/lib/python3.11/site-packages/setuptools-*.dist-info \
		/usr/local/lib/python3.11/site-packages/wheel \
		/usr/local/lib/python3.11/site-packages/wheel-*.dist-info \
	&& pip install --no-cache-dir --upgrade --force-reinstall --require-hashes --no-deps -r /tmp/requirements-runtime.txt \
	&& rm -f /tmp/requirements-runtime.txt \
	&& rm -rf /usr/local/lib/python3.11/site-packages/pip \
		/usr/local/lib/python3.11/site-packages/pip-*.dist-info \
		/usr/local/lib/python3.11/site-packages/setuptools \
		/usr/local/lib/python3.11/site-packages/setuptools-*.dist-info \
		/usr/local/lib/python3.11/site-packages/wheel \
		/usr/local/lib/python3.11/site-packages/wheel-*.dist-info \
		/usr/local/bin/pip /usr/local/bin/pip3 \
		/usr/local/bin/uv /usr/local/bin/uvx \
	&& adduser -D -u 10001 -s /bin/sh appuser \
	&& chown -R appuser:appuser /usr/local/lib/python3.11/site-packages

COPY mcp_server/ /app/mcp_server/

USER appuser

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
	CMD python -c "import socket; s = socket.create_connection(('127.0.0.1', 8088), 3); s.close()" || exit 1

# remove comment to trigger rebuild, or just add

