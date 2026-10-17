#!/usr/bin/env python3
"""Validate local listener policy without printing subscription credentials."""
import sys
from pathlib import Path

import yaml


def validate(path, port):
    config = yaml.safe_load(Path(path).read_text(encoding="utf-8"))
    if not isinstance(config, dict):
        raise ValueError
    if config.get("mixed-port") != int(port):
        raise ValueError
    if config.get("allow-lan", False) is not False:
        raise ValueError
    if config.get("bind-address") != "127.0.0.1":
        raise ValueError
    if any(config.get(key) for key in (
        "port", "socks-port", "redir-port", "tproxy-port", "listeners",
        "external-controller", "external-controller-tls", "external-controller-unix",
        "external-controller-pipe",
    )):
        raise ValueError
    if config.get("tun", {}).get("enable", False) is not False:
        raise ValueError
    if config.get("dns", {}).get("enable", False) is not False:
        raise ValueError


if __name__ == "__main__":
    try:
        validate(sys.argv[1], sys.argv[2])
    except (OSError, ValueError, TypeError, AttributeError, yaml.YAMLError):
        print("配置检查失败：需要匹配端口、127.0.0.1 监听，禁用额外监听、控制器、TUN 和 DNS 服务。", file=sys.stderr)
        sys.exit(1)
