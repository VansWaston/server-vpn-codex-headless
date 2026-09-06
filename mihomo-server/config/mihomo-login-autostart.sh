# Start the local-only Mihomo proxy on the first interactive root login.
# This file is installed as /etc/profile.d/mihomo-login-autostart.sh.

case $- in
  *i*)
    if [ "$(id -u)" -eq 0 ] && [ -x /workspace/mihomo-server/scripts/ensure-running.sh ]; then
      /workspace/mihomo-server/scripts/ensure-running.sh || true
    fi
    ;;
esac
