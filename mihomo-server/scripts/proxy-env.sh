#!/usr/bin/env bash

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  printf '请用 source %q 将代理变量仅加载到当前 shell。\n' "$0" >&2
  exit 1
fi

source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)/lib/toolkit.sh" || return 1
toolkit_set_proxy
