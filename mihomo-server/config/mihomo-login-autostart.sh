# Example Bash login hook. Prefer install.sh --shell-init for user installation.

case $- in
  *i*)
    if command -v mihomoctl >/dev/null 2>&1; then
      mihomoctl start >/dev/null 2>&1 || true
    fi
    ;;
esac
