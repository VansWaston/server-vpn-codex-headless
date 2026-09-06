#!/usr/bin/env bash

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  printf '请用 source %q 将代理变量仅加载到当前 shell。\n' "$0" >&2
  exit 1
fi

export HTTP_PROXY='http://127.0.0.1:7890'
export HTTPS_PROXY='http://127.0.0.1:7890'
export ALL_PROXY='socks5h://127.0.0.1:7890'
export http_proxy="$HTTP_PROXY"
export https_proxy="$HTTPS_PROXY"
export all_proxy="$ALL_PROXY"
export NO_PROXY='127.0.0.1,localhost,::1'
export no_proxy="$NO_PROXY"
