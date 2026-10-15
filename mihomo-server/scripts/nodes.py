#!/usr/bin/env python3
"""Read provider node names and prepare a local PROXY selection."""
import argparse
import base64
import json
import re
import sys
from pathlib import Path
from urllib.parse import unquote, urlsplit

import yaml


def node_names(text):
    data = yaml.safe_load(text)
    if isinstance(data, dict):
        names = [node['name'] for node in data.get('proxies', [])]
    else:
        raw = str(data or '').strip()
        if '://' not in raw:
            encoded = ''.join(raw.split())
            encoded += '=' * (-len(encoded) % 4)
            raw = base64.b64decode(encoded, validate=True).decode('utf-8')
        names = []
        for line in raw.splitlines():
            if not line.strip():
                continue
            uri = urlsplit(line.strip())
            if uri.scheme == 'ssr':
                raise ValueError('SSR 节点列表暂不支持；请使用 Clash YAML 订阅')
            if uri.scheme == 'vmess':
                payload = uri.netloc + uri.path
                payload += '=' * (-len(payload) % 4)
                name = json.loads(base64.b64decode(payload).decode('utf-8')).get('ps')
            else:
                name = unquote(uri.fragment)
            if not name:
                raise ValueError('订阅包含没有名称的节点；请使用 Clash YAML 订阅')
            names.append(name)
    if not names or any(not isinstance(name, str) or not name for name in names):
        raise ValueError('订阅没有有效的节点名称')
    if len(names) != len(set(names)):
        raise ValueError('订阅包含重复节点名称，无法精确选择')
    return names


def prepare_config(config, names, selection):
    groups = [group for group in config.get('proxy-groups', []) if group.get('name') == 'PROXY']
    if len(groups) != 1 or groups[0].get('use') != ['subscription'] or groups[0].get('type') != 'url-test':
        raise ValueError('需要唯一的 url-test PROXY 组，且仅引用 subscription provider')
    group = groups[0]
    if selection == '--auto':
        group.pop('filter', None)
        group.pop('exclude-filter', None)
        group.pop('exclude-type', None)
    else:
        if selection not in names:
            raise ValueError('找不到该节点；请先运行 mihomoctl nodes 并复制完整名称')
        group['filter'] = '^' + re.escape(selection) + '$'
        group.pop('exclude-filter', None)
        group.pop('exclude-type', None)
    return config


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('provider', type=Path)
    parser.add_argument('--config', type=Path)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--selection')
    args = parser.parse_args()
    names = node_names(args.provider.read_text())
    if args.config is None:
        for name in names:
            print(name)
        return
    config = prepare_config(yaml.safe_load(args.config.read_text()), names, args.selection)
    args.output.write_text(yaml.safe_dump(config, allow_unicode=True, sort_keys=False))


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError, TypeError, OSError, yaml.YAMLError) as exc:
        message = str(exc) if type(exc) is ValueError else f'无法解析订阅或配置（{type(exc).__name__}）'
        print(f'节点操作失败：{message}', file=sys.stderr)
        sys.exit(1)
