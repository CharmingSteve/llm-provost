#!/bin/sh
set -eu

# PROVOST_LOG_DEBUG is read once at start; recreate the container to change it.
config=/fluent-bit/etc/fluent-bit.conf
case "${PROVOST_LOG_DEBUG:-false}" in
  true|TRUE|True|1|yes|on)
    config=/fluent-bit/etc/fluent-bit-debug.conf
    echo "[fluent-bit] PROVOST_LOG_DEBUG on: audit records are teed to stdout"
    ;;
esac

exec /fluent-bit/bin/fluent-bit -c "$config"
