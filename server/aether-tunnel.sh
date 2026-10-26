#!/bin/bash
# Publishes the session server. A Tailscale Funnel hostname can replace the
# address by writing it to /etc/aether/public.url before this starts.
# The session server re-reads these files on every request, so a new tunnel
# address is picked up without restarting it.
set -u
mkdir -p /etc/aether
log=/var/log/aether-tunnel.log
: > "$log"
# A quick tunnel gets a new address every start; drop the dead one.
if grep -q 'trycloudflare\.com' /etc/aether/public.url 2>/dev/null; then
  rm -f /etc/aether/public.url /etc/aether/public.env
fi
/usr/local/bin/cloudflared tunnel --no-autoupdate --logfile "$log" --url http://127.0.0.1:7392 &
pid=$!
while kill -0 "$pid" 2>/dev/null; do
  url=$(grep -oE 'https://[A-Za-z0-9.-]+\.trycloudflare\.com' "$log" | head -1 || true)
  if [ -n "${url:-}" ] && [ "$(cat /etc/aether/public.url 2>/dev/null)" != "$url" ]; then
    printf '%s\n' "$url" > /etc/aether/public.url.tmp && mv /etc/aether/public.url.tmp /etc/aether/public.url
    printf 'AETHER_PUBLIC_URL=%s\n' "$url" > /etc/aether/public.env.tmp && mv /etc/aether/public.env.tmp /etc/aether/public.env
  fi
  sleep 2
done
wait "$pid"
