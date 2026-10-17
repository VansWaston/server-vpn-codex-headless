#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
cd -- "$ROOT"
while IFS= read -r file; do
  case $file in
    *.sh|*/codexctl|*/codex-job-runner|*/mihomoctl) bash -n "$file" ;;
  esac
done < packaging-files.txt
python3 -m unittest discover -s mihomo-server/tests -v
python3 -m unittest discover -s tests -v
