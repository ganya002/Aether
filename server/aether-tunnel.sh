#!/bin/bash
# Publishes the session server. A Tailscale Funnel hostname can replace the
# address by writing it to /etc/aether/public.url before this starts.
set -u
mkdir -p /etc/aether
log=/var/log/aether-tunnel.log
: > "$log"
/usr/local/bin/cloudflared tunnel --no-autoupdate --logfile "$log" --url http://127.0.0.1:7392 &
pid=$!
while kill -0 "$pid" 2>/dev/null; do
  url=$(grep -oE 'https://[A-Za-z0-9.-]+\.trycloudflare\.com' "$log" | head -1 || true)
  if [ -n "${url:-}" ]; then
    printf '%s\n' "$url" > /etc/aether/public.url
    printf 'AETHER_PUBLIC_URL=%s\n' "$url" > /etc/aether/public.env
  fi
  sleep 2
done
wait "$pid"
