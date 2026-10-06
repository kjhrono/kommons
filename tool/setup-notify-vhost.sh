#!/bin/bash
# Runs ON the VM as ubuntu (in the docker group).
# Uses Docker volume mounts to perform root-level file operations
# on the host filesystem — no sudo needed.
set -e

VHOST_SRC="/home/ubuntu/notify-mediasart.conf"

echo "=== Step 1: Install nginx vhost ==="
docker run --rm -v /etc/nginx:/etc/nginx alpine sh -c \
  "cp /dev/stdin /etc/nginx/sites-available/notify-mediasart" < "$VHOST_SRC"
echo "  ✓ vhost installed to /etc/nginx/sites-available/notify-mediasart"

echo "=== Step 2: Enable vhost + add notify.mediasart.com to port-80 redirect ==="
docker run --rm -v /etc/nginx:/etc/nginx alpine sh -c '
  ln -sf /etc/nginx/sites-available/notify-mediasart /etc/nginx/sites-enabled/notify-mediasart
  # Add notify.mediasart.com to the port-80 redirect server_name in mediasart.conf
  sed -i "s/stats\.mediasart\.com;/stats.mediasart.com notify.mediasart.com;/" /etc/nginx/sites-available/mediasart.conf
'
echo "  ✓ symlink created, mediasart.conf updated"

echo "=== Step 3: Reload nginx (activate port-80 server_name for ACME challenge) ==="
docker run --rm --privileged --pid=host -v /var/run/nginx.pid:/var/run/nginx.pid:ro busybox sh -c \
  'kill -HUP $(cat /var/run/nginx.pid)'
echo "  ✓ nginx reloaded"

echo "=== Step 4: Expand certbot SAN for notify.mediasart.com ==="
docker run --rm \
  -v /etc/letsencrypt:/etc/letsencrypt \
  -v /var/www/letsencrypt:/var/www/letsencrypt \
  --network=host \
  certbot/certbot:latest \
  certonly --webroot -w /var/www/letsencrypt \
    -d mediasart.com \
    -d www.mediasart.com \
    -d stats.mediasart.com \
    -d auth.mediasart.com \
    -d kalcio.mediasart.com \
    -d kapaxinfiniti.mediasart.com \
    -d katalogus.mediasart.com \
    -d kognitio.mediasart.com \
    -d kollectio.mediasart.com \
    -d notify.mediasart.com \
    --cert-name mediasart.com \
    --expand \
    --non-interactive \
    --agree-tos
echo "  ✓ cert expanded"

echo "=== Step 5: Reload nginx (pick up new certificate) ==="
docker run --rm --privileged --pid=host -v /var/run/nginx.pid:/var/run/nginx.pid:ro busybox sh -c \
  'kill -HUP $(cat /var/run/nginx.pid)'
echo "  ✓ nginx reloaded"

echo ""
echo "=== ALL DONE ==="
