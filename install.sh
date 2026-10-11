#!/usr/bin/env bash
# v5.2: Caddy + Reality + Hysteria2; H2/gRPC optional; uninstall supported.
# Requires Debian 12/13 or Ubuntu 22.04/24.04, systemd, amd64/arm64.
# bash install.sh --help
set -Eeuo pipefail
if [[ ${1:-} == --help || ${1:-} == -h ]]; then
    cat <<'HELP'
用法：sudo bash install.sh [install|upgrade|health|sync-cert|links|rollback|uninstall] [选项]
install          首次安装 / 从原 v5.1 迁移 / 交互重新配置（保留凭证）
upgrade          只升级 Sing-Box，需 --version 1.14.x，保留配置
health           检查服务、配置、监听端口、HTTPS 和证书有效期
sync-cert        同步 Caddy 正式证书；内容改变才重启 Sing-Box
links            显示分享链接（含敏感凭证）
uninstall        备份后卸载本脚本管理的部署；保留系统包、账户与备份
--yes            卸载时跳过输入 UNINSTALL 的确认
rollback         恢复指定备份，需 --backup /var/backups/sb-v52/时间戳
--version X      明确选择稳定 1.14.x；默认固定 1.14.3
--adopt-caddy     允许备份并接管现有 Caddyfile；会替换其中原有站点
说明：不修改 SSH / 防火墙 / BBR，不自动升级软件，不宣称官方 LTS。
安装会通过现有 APT 源安装 Caddy 与基础依赖。APT 包安装不在文件回滚范围。
安装前：域名 A/AAAA 直指 VPS；放行 TCP 80/443、Reality TCP、HY2 UDP。
IPv6 的 AAAA 若配置错误会影响证书申请，请先修正或删除错误记录。
不自动修改 DNS、防火墙、SSH、BBR，也不自动安装安全补丁。
现有独立网站不会合并；--adopt-caddy 会接管整个 Caddyfile，请谨慎使用。
首次无 Python3 时先安装：apt-get update && apt-get install -y python3
节点信息：/etc/sing-box/node_info.txt（root-only，切勿公开）
配置备份：/var/backups/sb-v52/（含私钥，不自动清理）
同步周期：30 分钟；证书改变会短暂重启 Sing-Box，连接可能中断。
health 是本机配置/服务/监听/HTTPS/证书检查，仍须客户端测试每个协议。
排错：journalctl -u sing-box -u caddy -u sb-v52-cert-sync.service -n 80
迁移会短暂重启服务；保留原脚本四种协议的凭证，但 H2/gRPC 默认关闭。
这里的 v5.2 是脚本版本，不是 Sing-Box 版本；不是上游官方 LTS。

HELP
    exit 0
fi
[[ $EUID == 0 ]] || { echo '请使用 sudo / root 运行。' >&2; exit 1; }
command -v python3 >/dev/null || {
    echo '需要 Python 3。请先运行：sudo apt-get update && sudo apt-get install -y python3' >&2
    exit 1
}
# Runtime source is passed separately, keeping /dev/tty available for prompts.
TASK_FILE=$(mktemp)
trap 'rm -f "$TASK_FILE"' EXIT
cat > "$TASK_FILE" <<'PYTHON'
import argparse
import contextlib
import copy
import fcntl
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import platform
import pwd
import re
import secrets
import shutil
import socket
import ssl
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.parse
import uuid

VERSION = '5.2'
DEFAULT_SB = '1.14.3'
PINNED = {
    'amd64': 'e2bdf179c15a3652955dc44867e33ca0965c9c9b91b34267dcc5a5d639a5feee',
    'arm64': '29dae24d76bea3bc62d07dd3e60cfc12003de7debbd6b768df9be9c68360174e',
}
BASE = Path('/etc/sing-box')
STATE = BASE / 'state-v52.json'
BIN = Path('/usr/local/bin/sing-box')
ENGINE = Path('/usr/local/lib/sb-v52/manager.py')
BACKUPS = Path('/var/backups/sb-v52')
CADDY = Path('/etc/caddy/Caddyfile')
SERVICE = Path('/etc/systemd/system/sing-box.service')
SYNC_UNIT = Path('/etc/systemd/system/sb-v52-cert-sync.service')
TIMER = Path('/etc/systemd/system/sb-v52-cert-sync.timer')
WEB = Path('/var/www/sb-v52')
MANAGED = [BASE, BIN, ENGINE.parent, CADDY, SERVICE, SYNC_UNIT, TIMER, WEB,
           Path('/usr/local/bin/sb-v52'), Path('/usr/local/bin/sb-sync-cert')]
SERVICES = ['caddy', 'sing-box', 'sb-v52-cert-sync.timer']


def log(message):
    print('[v5.2] ' + message, flush=True)


def run(*args, check=True, capture=False, timeout=60, **kwargs):
    return subprocess.run([str(a) for a in args], check=check, timeout=timeout,
                          text=True, capture_output=capture, **kwargs)


def atomic(path, data, mode=0o600, group=None):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix='.' + path.name + '.', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as out:
            out.write(data.encode() if isinstance(data, str) else data)
            out.flush()
            os.fsync(out.fileno())
        os.chmod(temporary, mode)
        if group is not None:
            os.chown(temporary, 0, group)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def jwrite(path, value, **kwargs):
    atomic(path, json.dumps(value, indent=2, ensure_ascii=False) + '\n', **kwargs)


def load(path):
    return json.loads(Path(path).read_text())


def status(unit, kind='is-active'):
    return run('systemctl', kind, unit, check=False, capture=True).returncode == 0


def preflight():
    if os.geteuid() != 0:
        raise ValueError('需要 root 权限')
    release = {}
    for line in Path('/etc/os-release').read_text().splitlines():
        if '=' in line:
            key, value = line.split('=', 1)
            release[key] = value.strip('"')
    if (release.get('ID'), release.get('VERSION_ID')) not in {
            ('debian', '12'), ('debian', '13'), ('ubuntu', '22.04'), ('ubuntu', '24.04')}:
        raise ValueError('仅支持 Debian 12/13、Ubuntu 22.04/24.04')
    if not Path('/run/systemd/system').exists():
        raise ValueError('需要运行中的 systemd；不支持普通容器/非 systemd 环境')
    if platform.machine() not in ('x86_64', 'aarch64'):
        raise ValueError('仅支持 amd64 / arm64')
    for path in MANAGED:
        if path.is_symlink():
            raise ValueError(f'拒绝覆盖符号链接：{path}')
    for unit in ('caddy.service', 'sing-box.service'):
        fragment = run('systemctl', 'show', unit, '-p', 'FragmentPath', '--value',
                       capture=True).stdout.strip()
        if fragment and fragment not in (f'/etc/systemd/system/{unit}',
                f'/lib/systemd/system/{unit}', f'/usr/lib/systemd/system/{unit}'):
            raise ValueError(f'检测到非标准服务路径 {fragment}，请先人工检查')
        drops = run('systemctl', 'show', unit, '-p', 'DropInPaths', '--value',
                    capture=True).stdout.strip()
        if drops:
            raise ValueError(f'{unit} 存在自定义 override，请人工合并后再安装：{drops}')


def prompt(label, default='', secret=False):
    # No shell evaluation of any answer.
    with open('/dev/tty', 'r+') as tty:
        tty.write(f'{label} [{default}]: ')
        tty.flush()
        value = tty.readline()
    if not value:
        raise ValueError('交互输入中断')
    return value.strip() or default


def yes(label, default=False):
    value = prompt(label + ' (y/n)', 'y' if default else 'n').lower()
    if value not in ('y', 'n'):
        raise ValueError('请输入 y 或 n')
    return value == 'y'


def domain(value):
    value = value.lower().rstrip('.')
    if len(value) > 253 or '.' not in value:
        raise ValueError('需要完整域名')
    for part in value.split('.'):
        if not re.fullmatch(r'[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?', part):
            raise ValueError(f'非法域名：{value}')
    return value


def port(value):
    value = int(value)
    if not 1024 <= value <= 65535:
        raise ValueError('代理端口必须在 1024—65535 之间')
    return value


def migrate():
    if STATE.exists():
        return load(STATE)
    if not (BASE / 'config.json').exists():
        return None
    cfg = load(BASE / 'config.json')
    bytag = {i.get('tag'): i for i in cfg.get('inbounds', [])}
    required = {'vless-reality-in', 'hy2-in', 'vless-h2-in', 'vless-grpc-in'}
    if not required <= bytag.keys() or not (BASE / 'domain.txt').exists():
        raise ValueError('检测到未知 Sing-Box 配置。请人工迁移，避免覆盖其他部署')
    r, h, h2, g = (bytag[t] for t in
                    ('vless-reality-in', 'hy2-in', 'vless-h2-in', 'vless-grpc-in'))
    info = (BASE / 'node_info.txt').read_text() if (BASE / 'node_info.txt').exists() else ''
    public = re.search(r'(?:Reality 公钥:\s*|[?&]pbk=)([A-Za-z0-9_-]+)', info)
    if public is None:
        raise ValueError('旧配置缺少 Reality 公钥，不能安全保留密钥；请恢复旧 node_info.txt')
    endpoint = next((urllib.parse.urlsplit(line.strip()).hostname
        for line in info.splitlines() if line.strip().startswith('vless://')
        and 'security=reality' in line), None)
    return dict(domain=(BASE / 'domain.txt').read_text().strip(),
                address=endpoint or BASE.joinpath('domain.txt').read_text().strip(),
                reality_port=r['listen_port'], hy2_port=h['listen_port'],
                reality_sni=r['tls']['reality']['handshake']['server'],
                reality_uuid=r['users'][0]['uuid'],
                reality_private=r['tls']['reality']['private_key'],
                reality_public=public.group(1),
                short_id=r['tls']['reality']['short_id'][0],
                hy2_password=h['users'][0]['password'],
                h2_uuid=h2['users'][0]['uuid'], grpc_uuid=g['users'][0]['uuid'],
                h2_path=h2['transport']['path'], grpc_service=g['transport']['service_name'],
                h2_port=h2['listen_port'], grpc_port=g['listen_port'],
                h2=False, grpc=False, hy2=True, sb_version=DEFAULT_SB)


def validate_state(s):
    for key in ('domain', 'reality_sni'):
        s[key] = domain(s[key])
    try:
        ipaddress.ip_address(s['address'])
    except ValueError:
        s['address'] = domain(s['address'])
    for key in ('reality_port', 'hy2_port', 'h2_port', 'grpc_port'):
        s[key] = port(s[key])
    # Separate TCP/UDP may technically share a number, but this deployment keeps them separate.
    active = [s['reality_port']]
    if s['hy2']:
        active.append(s['hy2_port'])
    if s['h2']:
        active.append(s['h2_port'])
    if s['grpc']:
        active.append(s['grpc_port'])
    if len(active) != len(set(active)):
        raise ValueError('启用的代理端口不能重复')
    for key in ('reality_uuid', 'h2_uuid', 'grpc_uuid'):
        uuid.UUID(s[key])
    for key in ('reality_private', 'reality_public'):
        if not re.fullmatch(r'[A-Za-z0-9_-]{43}', s[key]):
            raise ValueError('Reality 密钥格式不正确')
    if not re.fullmatch(r'(?:[0-9a-fA-F]{2}){1,8}', s['short_id']):
        raise ValueError('Reality short ID 格式不正确')
    if not s['hy2_password'] or len(s['hy2_password']) > 256:
        raise ValueError('HY2 密码为空或过长')
    if not re.fullmatch(r'/[A-Za-z0-9/_-]+', s['h2_path']):
        raise ValueError('H2 路径只接受字母、数字、/、_、-')
    if not re.fullmatch(r'[A-Za-z0-9_-]+', s['grpc_service']):
        raise ValueError('gRPC 服务名只接受字母、数字、_、-')
    if s['h2_path'] == '/' + s['grpc_service'] or s['h2_path'].startswith('/' + s['grpc_service'] + '/'):
        raise ValueError('H2 路径与 gRPC 服务名冲突')


def download(version, dest):
    if not re.fullmatch(r'1\.14\.[0-9]+', version):
        raise ValueError('此版本脚本只接受稳定 1.14.x；跨版本升级需重新审核配置')
    arch = {'x86_64': 'amd64', 'aarch64': 'arm64'}[platform.machine()]
    name = f'sing-box-{version}-linux-{arch}.tar.gz'
    digest = PINNED[arch] if version == DEFAULT_SB else None
    if digest is None:
        metadata = run('curl', '--proto', '=https', '--tlsv1.2', '-fsSL',
            '--retry', '2', '--connect-timeout', '15', '--max-time', '45',
            f'https://api.github.com/repos/SagerNet/sing-box/releases/tags/v{version}',
            capture=True, timeout=150)
        release = json.loads(metadata.stdout)
        if release.get('prerelease') or release.get('draft'):
            raise ValueError('拒绝预发布版本')
        asset = next((a for a in release['assets'] if a['name'] == name), {})
        value = asset.get('digest', '') or ''
        if not re.fullmatch(r'sha256:[0-9a-f]{64}', value):
            raise ValueError('官方资产没有 SHA256 digest，拒绝下载')
        digest = value.split(':')[1]
    archive = dest.parent / name
    log(f'下载并验证固定版本 Sing-Box {version} ({arch})')
    run('curl', '--proto', '=https', '--tlsv1.2', '-fL', '--retry', '2',
        '--connect-timeout', '15', '--max-time', '180', '-o', archive,
        f'https://github.com/SagerNet/sing-box/releases/download/v{version}/{name}', timeout=600)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != digest:
        raise ValueError('SHA256 不匹配，拒绝执行下载文件')
    # Extract only the expected regular executable, never extract archive paths.
    with tarfile.open(archive, 'r:gz') as tar:
        member = tar.getmember(f'sing-box-{version}-linux-{arch}/sing-box')
        if not member.isfile() or not 0 < member.size < 200_000_000:
            raise ValueError('归档中的程序不是有效普通文件')
        with tar.extractfile(member) as src, dest.open('wb') as out:
            shutil.copyfileobj(src, out)
    dest.chmod(0o755)
    result = run(dest, 'version', capture=True).stdout
    if f'sing-box version {version}\n' not in result:
        raise ValueError('程序版本与下载版本不一致')


def configs(s):
    reality = dict(type='vless', tag='vless-reality-in', listen='::',
        listen_port=s['reality_port'], users=[dict(uuid=s['reality_uuid'], flow='xtls-rprx-vision')],
        tls=dict(enabled=True, server_name=s['reality_sni'], reality=dict(enabled=True,
            handshake=dict(server=s['reality_sni'], server_port=443),
            private_key=s['reality_private'], short_id=[s['short_id']])))
    inbounds = [reality]
    if s['hy2']:
        inbounds.append(dict(type='hysteria2', tag='hy2-in', listen='::',
            listen_port=s['hy2_port'], users=[dict(password=s['hy2_password'])],
            tls=dict(enabled=True, server_name=s['domain'],
                certificate_path=str(BASE / 'cert/current/server.crt'),
                key_path=str(BASE / 'cert/current/server.key'))))
    caddy = f"{s['domain']} {{\n    root * {WEB}\n    file_server\n"
    if s['h2']:
        inbounds.append(dict(type='vless', tag='vless-h2-in', listen='127.0.0.1',
            listen_port=s['h2_port'], users=[dict(uuid=s['h2_uuid'])],
            transport=dict(type='http', host=[s['domain']], path=s['h2_path'])))
        caddy += f"    reverse_proxy {s['h2_path']} http://127.0.0.1:{s['h2_port']} {{\n        flush_interval -1\n    }}\n"
    if s['grpc']:
        inbounds.append(dict(type='vless', tag='vless-grpc-in', listen='127.0.0.1',
            listen_port=s['grpc_port'], users=[dict(uuid=s['grpc_uuid'])],
            transport=dict(type='grpc', service_name=s['grpc_service'])))
        caddy += f"    @grpc {{\n        path /{s['grpc_service']}/*\n        header Content-Type application/grpc*\n    }}\n    reverse_proxy @grpc h2c://127.0.0.1:{s['grpc_port']}\n"
    caddy += '}\n'
    cfg = dict(log=dict(level='warn', timestamp=True), inbounds=inbounds,
               outbounds=[dict(type='direct', tag='direct')])
    return cfg, '# Managed by sb-v52\n' + caddy


def cert_valid(crt, key, hostname, seconds=86400):
    try:
        context = ssl.create_default_context()
        context.load_cert_chain(str(crt), str(key))  # verify pair and PEM parsing
        run('openssl', 'x509', '-in', crt, '-noout', '-checkhost', hostname, capture=True)
        run('openssl', 'x509', '-in', crt, '-noout', '-checkend', str(seconds), capture=True)
        # Use system trust store; no self-signed fallback.
        run('openssl', 'verify', '-purpose', 'sslserver', '-verify_hostname', hostname,
            '-CApath', '/etc/ssl/certs', '-untrusted', crt, crt, capture=True)
        return True
    except (ValueError, OSError, ssl.SSLError, subprocess.SubprocessError):
        return False


def find_cert(hostname):
    root = Path('/var/lib/caddy/.local/share/caddy/certificates')
    candidates = sorted(root.glob(f'*/{hostname}/{hostname}.crt'),
                        key=lambda p: p.stat().st_mtime, reverse=True)
    for crt in candidates:
        key = crt.with_suffix('.key')
        if key.exists() and cert_valid(crt, key, hostname):
            return crt, key
    raise ValueError('未找到有效的受信任 Caddy 证书；检查 DNS、80/443、防火墙和 Caddy 日志')


def publish_cert(s):
    crt, key = find_cert(s['domain'])
    # Stage and revalidate a stable pair in case Caddy renewed during the copy.
    root = BASE / 'cert'
    root.mkdir(parents=True, exist_ok=True)
    gid = pwd.getpwnam('sing-box').pw_gid
    os.chown(root, 0, gid)
    root.chmod(0o750)
    with tempfile.TemporaryDirectory(prefix='.cert-', dir=root) as tmp:
        tmp = Path(tmp)
        a, b = tmp / 'server.crt', tmp / 'server.key'
        shutil.copyfile(crt, a)
        shutil.copyfile(key, b)
        if not cert_valid(a, b, s['domain']):
            raise ValueError('证书复制期间发生变化，等待下次重试')
        current = root / 'current'
        old = os.readlink(current) if current.is_symlink() else None
        if current.exists() and not current.is_symlink():
            raise ValueError('cert/current 不是受管理的符号链接')
        if old and a.read_bytes() == (current / 'server.crt').read_bytes() and b.read_bytes() == (current / 'server.key').read_bytes():
            return False, old
        ident = 'pair-' + secrets.token_hex(8)
        target = root / ident
        target.mkdir(mode=0o750)
        os.chown(target, 0, gid)
        atomic(target / 'server.crt', a.read_bytes(), 0o640, gid)
        atomic(target / 'server.key', b.read_bytes(), 0o640, gid)
        link = root / ('.link-' + secrets.token_hex(8))
        link.symlink_to(ident)
        os.replace(link, current)
        return True, old


def revert_cert(old):
    current = BASE / 'cert/current'
    link = current.parent / ('.rollback-' + secrets.token_hex(8))
    if old:
        link.symlink_to(old)
        os.replace(link, current)
    elif current.is_symlink():
        current.unlink()


def snapshot():
    BACKUPS.mkdir(parents=True, exist_ok=True, mode=0o700)
    BACKUPS.chmod(0o700)
    target = BACKUPS / (time.strftime('%Y%m%d-%H%M%S') + '-' + secrets.token_hex(3))
    target.mkdir(mode=0o700)
    manifest = {'format': 1, 'paths': [], 'services': {}}
    for index, path in enumerate(MANAGED):
        exists = path.exists() or path.is_symlink()
        entry = dict(path=str(path), exists=exists, item=str(index))
        if exists:
            if path.is_dir():
                run('cp', '-a', '--', path, target / str(index))
            else:
                run('cp', '-a', '--', path, target / str(index))
        manifest['paths'].append(entry)
    for unit in SERVICES:
        manifest['services'][unit] = dict(active=status(unit), enabled=status(unit, 'is-enabled'))
    jwrite(target / 'manifest.json', manifest)
    log(f'已备份：{target}')
    return target


def remove(path):
    if path.is_dir() and not path.is_symlink():
        shutil.rmtree(path)
    elif path.exists() or path.is_symlink():
        path.unlink()


def restore(target):
    target = Path(target).resolve()
    if target.parent != BACKUPS.resolve() or not (target / 'manifest.json').is_file():
        raise ValueError('只能恢复 /var/backups/sb-v52/ 下的完整备份目录')
    manifest = load(target / 'manifest.json')
    if manifest.get('format') != 1 or [e['path'] for e in manifest['paths']] != [str(p) for p in MANAGED]:
        raise ValueError('备份清单格式不匹配')
    run('systemctl', 'stop', 'sb-v52-cert-sync.timer', 'sb-v52-cert-sync.service',
        'sing-box', 'caddy', check=False)
    for entry in manifest['paths']:
        path = Path(entry['path'])
        remove(path)
        if entry['exists']:
            path.parent.mkdir(parents=True, exist_ok=True)
            src = target / entry['item']
            if src.is_dir():
                run('cp', '-a', '--', src, path)
            else:
                run('cp', '-a', '--', src, path)
    run('systemctl', 'daemon-reload')
    for unit, original in manifest['services'].items():
        # Files are restored; disabled or missing pre-install services stay disabled.
        run('systemctl', 'enable' if original['enabled'] else 'disable', unit, check=False)
        if original['active']:
            run('systemctl', 'start', unit)
    log('已恢复文件和原服务启用/运行状态。APT 安装的包及新建服务账户不会卸载')


def ensure_user():
    try:
        account = pwd.getpwnam('sing-box')
        if account.pw_uid == 0 or account.pw_shell not in ('/usr/sbin/nologin', '/sbin/nologin', '/bin/false'):
            raise ValueError('已有 sing-box 账户不适合运行服务，请人工检查')
    except KeyError:
        run('useradd', '--system', '--user-group', '--no-create-home',
            '--home-dir', '/nonexistent', '--shell', '/usr/sbin/nologin', 'sing-box')
    return pwd.getpwnam('sing-box').pw_gid


def write_units():
    atomic(SERVICE, '''[Unit]
Description=sing-box (sb-v52)
After=network-online.target nss-lookup.target
Wants=network-online.target
StartLimitIntervalSec=120
StartLimitBurst=5

[Service]
User=sing-box
Group=sing-box
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=on-failure
RestartSec=5s
LimitNOFILE=65536
UMask=0027
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK
CapabilityBoundingSet=
AmbientCapabilities=

[Install]
WantedBy=multi-user.target
''', 0o644)
    atomic(SYNC_UNIT, '''[Unit]
Description=Validate and sync Caddy certificate for Sing-Box
After=caddy.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/sb-v52 sync-cert
UMask=0077
''', 0o644)
    atomic(TIMER, '''[Unit]
Description=Periodic Sing-Box certificate synchronization

[Timer]
OnBootSec=5min
OnUnitActiveSec=30min
RandomizedDelaySec=60
Persistent=true

[Install]
WantedBy=timers.target
''', 0o644)


def write_runtime():
    atomic(ENGINE, Path(__file__).read_bytes(), 0o700)
    for path, suffix in [(Path('/usr/local/bin/sb-v52'), '"$@"'),
                         (Path('/usr/local/bin/sb-sync-cert'), 'sync-cert')]:
        atomic(path, '#!/bin/sh\nexec /usr/bin/python3 /usr/local/lib/sb-v52/manager.py ' + suffix + '\n', 0o700)


def links(s):
    def url(scheme, credential, host, p, query, label):
        if ':' in host:
            host = '[' + host + ']'
        return (f'{scheme}://{urllib.parse.quote(credential, safe="")}@{host}:{p}?' +
                urllib.parse.urlencode(query) + '#' + urllib.parse.quote(label, safe=''))
    result = [url('vless', s['reality_uuid'], s['address'], s['reality_port'],
        dict(encryption='none', flow='xtls-rprx-vision', security='reality',
             sni=s['reality_sni'], fp='chrome', pbk=s['reality_public'],
             sid=s['short_id'], type='tcp'), 'Reality-' + s['domain'])]
    if s['hy2']:
        result.append(url('hysteria2', s['hy2_password'], s['domain'], s['hy2_port'],
                          dict(sni=s['domain']), 'HY2-' + s['domain']))
    if s['h2']:
        result.append(url('vless', s['h2_uuid'], s['domain'], 443,
            dict(encryption='none', security='tls', sni=s['domain'], type='http',
                 path=s['h2_path'], host=s['domain']), 'H2-' + s['domain']))
    if s['grpc']:
        result.append(url('vless', s['grpc_uuid'], s['domain'], 443,
            dict(encryption='none', security='tls', sni=s['domain'], type='grpc',
                 serviceName=s['grpc_service']), 'gRPC-' + s['domain']))
    return '\n\n'.join(result) + '\n'


def listeners():
    found = set()
    for proto, flags in [('tcp', '-Hltpn'), ('udp', '-Hlupn')]:
        for line in run('ss', flags, capture=True).stdout.splitlines():
            parts = line.split()
            if len(parts) >= 5:
                address, _, value = parts[3].rpartition(':')
                if value.isdigit():
                    found.add((proto, int(value), address, line))
    return found


def health(s, quiet=False):
    errors = []
    for unit in ('caddy', 'sing-box'):
        if not status(unit):
            errors.append(unit + ' 服务未运行')
    if not status('sb-v52-cert-sync.timer'):
        errors.append('证书同步 timer 未运行')
    for args in [(BIN, 'check', '-c', BASE / 'config.json'),
                 ('caddy', 'validate', '--config', CADDY, '--adapter', 'caddyfile')]:
        if run(*args, check=False, capture=True).returncode:
            errors.append('配置检查失败：' + str(args[0]))
    expected = [('tcp', 80, 'caddy'), ('tcp', 443, 'caddy'),
                ('tcp', s['reality_port'], 'sing-box')]
    if s['hy2']:
        expected.append(('udp', s['hy2_port'], 'sing-box'))
    if s['h2']:
        expected.append(('tcp', s['h2_port'], 'sing-box'))
    if s['grpc']:
        expected.append(('tcp', s['grpc_port'], 'sing-box'))
    actual = listeners()
    for proto, p, process in expected:
        if not any(a == proto and b == p and f'"{process}"' in line for a, b, _, line in actual):
            errors.append(f'{proto}/{p} 未由 {process} 监听')
    if s['hy2'] and not cert_valid(BASE / 'cert/current/server.crt', BASE / 'cert/current/server.key', s['domain'], 7 * 86400):
        errors.append('HY2 证书无效或将在 7 天内到期')
    https = run('curl', '--noproxy', '*', '--fail', '--silent', '--show-error',
        '--max-time', '15', '--resolve', f'{s["domain"]}:443:127.0.0.1',
        f'https://{s["domain"]}/', check=False, capture=True, timeout=20)
    if https.returncode:
        errors.append('本机 HTTPS 检查失败（未跳过证书验证）')
    if errors:
        raise ValueError('; '.join(errors))
    if not quiet:
        log('服务、配置、进程监听、HTTPS 和证书检查通过。仍需客户端测试 Reality/HY2 实际连接')


def install(args):
    preflight()
    old = migrate()
    s = copy.deepcopy(old) if old else dict(domain='', address='', reality_port=8443,
        hy2_port=8444, reality_sni='addons.mozilla.org', h2_port=10001, grpc_port=10002,
        h2_path='/rayh2', grpc_service='vless-grpc', h2=False, grpc=False, hy2=True,
        sb_version=DEFAULT_SB)
    log('已有凭证会保留；H2/gRPC 首次和旧版迁移默认关闭。不会修改防火墙或 SSH')
    s['domain'] = domain(prompt('网站/HY2 域名（DNS 必须直指此 VPS，不能经 CDN）', s['domain']))
    s['address'] = prompt('Reality 连接地址：公网 IP 或直连域名', s['address'] or s['domain'])
    s['reality_port'] = port(prompt('Reality TCP 端口', str(s['reality_port'])))
    s['reality_sni'] = domain(prompt('Reality TLS 握手目标/SNI（需可访问并支持 TLS1.3）', s['reality_sni']))
    s['hy2'] = yes('启用 Hysteria 2', s['hy2'])
    if s['hy2']:
        s['hy2_port'] = port(prompt('HY2 UDP 端口', str(s['hy2_port'])))
    s['h2'] = yes('启用可选 H2', s['h2'])
    if s['h2']:
        s['h2_path'] = prompt('H2 路径', s['h2_path'])
    s['grpc'] = yes('启用可选 gRPC', s['grpc'])
    if s['grpc']:
        s['grpc_service'] = prompt('gRPC 服务名', s['grpc_service'])
    # Only new installs default to a pinned version. Reconfigure reuses existing executable.
    s['sb_version'] = args.version or s['sb_version']
    if CADDY.exists() and '# Managed by sb-v52' not in CADDY.read_text():
        if old is None and not args.adopt_caddy:
            raise ValueError('已有 Caddyfile。确认接管其全部站点后用 --adopt-caddy；本次未覆盖')
        if old is not None and '127.0.0.1:10001' not in CADDY.read_text() and not args.adopt_caddy:
            raise ValueError('旧 Caddyfile 不符合原脚本模板，请检查后用 --adopt-caddy')
    log('需放行 TCP 80/443、Reality 端口以及启用的 HY2 UDP 端口；脚本不自动改规则')
    # Do not steal ports from unrelated processes.
    used = listeners() if shutil.which('ss') else set()
    wanted = {('tcp', 80): 'caddy', ('tcp', 443): 'caddy', ('tcp', s['reality_port']): 'sing-box'}
    if s['hy2']:
        wanted[('udp', s['hy2_port'])] = 'sing-box'
    for proto, p, _, line in used:
        process = wanted.get((proto, p))
        if process and f'"{process}"' not in line:
            raise ValueError(f'{proto}/{p} 已被其他进程占用')
    backup = snapshot()
    try:
        run('apt-get', 'update', timeout=600)
        run('apt-get', 'install', '-y', 'ca-certificates', 'curl', 'openssl',
            'iproute2', 'util-linux', 'passwd', 'caddy', timeout=900)
        gid = ensure_user()
        with tempfile.TemporaryDirectory(prefix='sb-v52-') as tmp:
            tmp = Path(tmp)
            tmp.chmod(0o755)
            candidate = tmp / 'sing-box'
            if old and BIN.exists() and not args.version:
                shutil.copy2(BIN, candidate)
                version_output = run(candidate, 'version', capture=True).stdout
                match = re.search(r'^sing-box version (1\.14\.[0-9]+)\s*$', version_output, re.M)
                if not match:
                    raise ValueError('现有程序不是稳定 1.14.x。请显式 --version 1.14.3 验证并升级')
                s['sb_version'] = match.group(1)
            else:
                download(s['sb_version'], candidate)
            if old is None:
                keys = run(candidate, 'generate', 'reality-keypair', capture=True).stdout
                private = re.search(r'PrivateKey:\s*(\S+)', keys)
                public = re.search(r'PublicKey:\s*(\S+)', keys)
                if not private or not public:
                    raise ValueError('Reality 密钥生成失败')
                s.update(reality_private=private.group(1), reality_public=public.group(1),
                    reality_uuid=str(uuid.uuid4()), h2_uuid=str(uuid.uuid4()),
                    grpc_uuid=str(uuid.uuid4()), short_id=secrets.token_hex(8),
                    hy2_password=secrets.token_urlsafe(32))
            validate_state(s)
            config, caddy = configs(s)
            proposed_caddy = tmp / 'Caddyfile'
            atomic(proposed_caddy, caddy, 0o644)
            run('caddy', 'validate', '--config', proposed_caddy, '--adapter', 'caddyfile', capture=True)
            WEB.mkdir(parents=True, exist_ok=True)
            WEB.chmod(0o755)
            atomic(WEB / 'index.html', '<!doctype html><html lang="en"><meta charset="utf-8">'
                '<meta name="viewport" content="width=device-width,initial-scale=1">'
                '<title>Personal site</title><body><main><h1>Welcome</h1>'
                '<p>This is a personal website.</p></main></body></html>\n', 0o644)
            atomic(CADDY, caddy, 0o644)
            run('systemctl', 'enable', 'caddy')
            run('systemctl', 'restart', 'caddy')
            # Real trusted website certificate is required even if HY2 is disabled.
            for attempt in range(60):
                try:
                    find_cert(s['domain'])
                    break
                except ValueError:
                    if attempt % 10 == 0:
                        log(f'等待正式证书：{attempt * 3}/180 秒')
                    time.sleep(3)
            else:
                raise ValueError('正式证书申请超时；恢复旧配置，不生成 insecure 链接')
            if s['hy2']:
                publish_cert(s)
            proposed = tmp / 'config.json'
            jwrite(proposed, config)
            run(candidate, 'check', '-c', proposed, capture=True)
            # Install only after candidate config passes validation.
            atomic(BIN, candidate.read_bytes(), 0o755)
            BASE.mkdir(parents=True, exist_ok=True)
            os.chown(BASE, 0, gid)
            BASE.chmod(0o750)
            jwrite(BASE / 'config.json', config, mode=0o640, group=gid)
            jwrite(STATE, s)
            atomic(BASE / 'domain.txt', s['domain'] + '\n')
            atomic(BASE / 'node_info.txt', links(s))
            write_units()
            write_runtime()
            run('systemctl', 'daemon-reload')
            # Validate as actual unprivileged service user, including certificate access.
            run('runuser', '-u', 'sing-box', '--', BIN, 'check', '-c', BASE / 'config.json', capture=True)
            run('systemctl', 'enable', 'sing-box', 'sb-v52-cert-sync.timer')
            run('systemctl', 'restart', 'sing-box', 'sb-v52-cert-sync.timer')
            time.sleep(3)
            health(s)
        log('安装成功。节点在 /etc/sing-box/node_info.txt；管理命令 sb-v52 --help')
        log('备份包含密钥，请妥善保管。安全补丁和 Caddy 更新仍需自行维护')
    except BaseException:
        log('部署失败，开始自动恢复')
        restore(backup)
        raise


def upgrade(args):
    preflight()
    if not STATE.exists():
        raise ValueError('请先 install 迁移到 v5.2')
    if not args.version:
        raise ValueError('升级需明确指定 --version 1.14.x')
    s = load(STATE)
    with tempfile.TemporaryDirectory(prefix='sb-v52-upgrade-') as tmp:
        candidate = Path(tmp) / 'sing-box'
        download(args.version, candidate)
        run(candidate, 'check', '-c', BASE / 'config.json', capture=True)
        backup = snapshot()
        try:
            run('systemctl', 'stop', 'sb-v52-cert-sync.timer')
            atomic(BIN, candidate.read_bytes(), 0o755)
            run('runuser', '-u', 'sing-box', '--', BIN, 'check', '-c', BASE / 'config.json', capture=True)
            run('systemctl', 'restart', 'sing-box', 'sb-v52-cert-sync.timer')
            time.sleep(3)
            health(s)
            s['sb_version'] = args.version
            jwrite(STATE, s)
            log('升级成功。需要时可 sb-v52 rollback --backup ' + str(backup))
        except BaseException:
            restore(backup)
            raise


def sync(s):
    if not s['hy2']:
        log('HY2 未启用，无需同步')
        return
    changed, old = publish_cert(s)
    if not changed:
        log('证书未变化')
        return
    try:
        run('runuser', '-u', 'sing-box', '--', BIN, 'check', '-c', BASE / 'config.json', capture=True)
        run('systemctl', 'restart', 'sing-box')
        time.sleep(2)
        if not status('sing-box'):
            raise ValueError('同步后服务启动失败')
    except BaseException:
        revert_cert(old)
        run('systemctl', 'restart', 'sing-box', check=False)
        raise
    # Keep current + previous valid pair, deleting older copies only after success.
    keep = {old, os.readlink(BASE / 'cert/current')}
    for p in (BASE / 'cert').glob('pair-*'):
        if p.name not in keep and p.is_dir() and not p.is_symlink():
            shutil.rmtree(p)
    log('证书同步完成；有效期不足 7 天时 health 会报告异常')


def uninstall(args):
    preflight()
    if not STATE.exists():
        log('未找到 v5.2 状态文件；不删除未知部署。旧 v5.1 请先 install 迁移')
        return
    s = load(STATE)
    validate_state(s)
    if not SERVICE.exists() or 'Description=sing-box (sb-v52)' not in SERVICE.read_text():
        raise ValueError('Sing-Box 服务文件已被替换，不自动卸载未知服务')
    cfg, expected_caddy = configs(s)
    if not (BASE / 'config.json').exists() or load(BASE / 'config.json') != cfg:
        raise ValueError('Sing-Box 配置已由其他工具修改，请先人工检查；本次未卸载')
    owned_caddy = CADDY.exists() and CADDY.read_text() == expected_caddy
    log('将备份并删除本部署的节点配置、服务、程序和管理命令；保留备份、系统包与账户')
    if owned_caddy:
        log('Caddyfile 与本脚本生成内容一致，将停用本部署网站；保留 Caddy 包及证书存储')
    else:
        log('Caddyfile 已改变，将完整保留 Caddy 网站和网页目录；请自行检查残留反代规则')
    if not args.yes and prompt('确认卸载请输入 UNINSTALL', '') != 'UNINSTALL':
        log('已取消，无文件变更')
        return
    backup = snapshot()
    try:
        # Disable the timer before deleting the manager so it cannot race with uninstall.
        run('systemctl', 'stop', 'sb-v52-cert-sync.timer')
        run('systemctl', 'stop', 'sb-v52-cert-sync.service', check=False)
        run('systemctl', 'stop', 'sing-box')
        run('systemctl', 'disable', 'sing-box', 'sb-v52-cert-sync.timer')
        if owned_caddy:
            run('systemctl', 'stop', 'caddy')
            run('systemctl', 'disable', 'caddy')
            remove(CADDY)
            # Keep added personal pages; only delete our exact generated landing page.
            page = WEB / 'index.html'
            expected_page = ('<!doctype html><html lang="en"><meta charset="utf-8">'
                '<meta name="viewport" content="width=device-width,initial-scale=1">'
                '<title>Personal site</title><body><main><h1>Welcome</h1>'
                '<p>This is a personal website.</p></main></body></html>\n')
            if page.exists() and page.read_text() == expected_page:
                remove(page)
            if WEB.is_dir() and not any(WEB.iterdir()):
                WEB.rmdir()
        for path in (SERVICE, SYNC_UNIT, TIMER):
            remove(path)
        # Remove our pair generations, leaving unrelated user files in /etc/sing-box.
        cert = BASE / 'cert'
        current = cert / 'current'
        if current.is_symlink() and re.fullmatch(r'pair-[0-9a-f]{16}', os.readlink(current)):
            current.unlink()
        if cert.is_dir() and not cert.is_symlink():
            for pair in cert.glob('pair-*'):
                if re.fullmatch(r'pair-[0-9a-f]{16}', pair.name) and pair.is_dir() and not pair.is_symlink():
                    remove(pair)
            if not any(cert.iterdir()):
                cert.rmdir()
        # Credentials in backups stay available for deliberate recovery.
        for name in ('config.json', 'state-v52.json', 'domain.txt', 'node_info.txt'):
            remove(BASE / name)
        if not any(BASE.iterdir()):
            BASE.rmdir()
        if BIN.exists():
            output = run(BIN, 'version', capture=True).stdout
            if f"sing-box version {s['sb_version']}\n" in output:
                remove(BIN)
            else:
                log('程序版本已改变，保留 /usr/local/bin/sing-box 供人工检查')
        for path in (Path('/usr/local/bin/sb-v52'), Path('/usr/local/bin/sb-sync-cert'), ENGINE):
            remove(path)
        if ENGINE.parent.is_dir() and not any(ENGINE.parent.iterdir()):
            ENGINE.parent.rmdir()
        run('systemctl', 'daemon-reload')
        run('systemctl', 'reset-failed', 'sing-box', 'sb-v52-cert-sync.service',
            'sb-v52-cert-sync.timer', check=False)
        log(f'卸载完成。备份保留在 {backup}，内含私钥，请妥善保管')
        log('需要恢复时，使用下载的 install.sh rollback --backup ' + str(backup))
    except BaseException:
        log('卸载失败，恢复卸载前状态')
        restore(backup)
        raise


def main():
    parser = argparse.ArgumentParser(description='v5.2 Caddy + Reality + HY2 deployment manager')
    parser.add_argument('action', nargs='?', default='install',
        choices=['install', 'upgrade', 'rollback', 'health', 'sync-cert', 'links', 'uninstall'])
    parser.add_argument('--version')
    parser.add_argument('--backup')
    parser.add_argument('--adopt-caddy', action='store_true')
    parser.add_argument('--yes', action='store_true', help='卸载时跳过交互确认')
    args = parser.parse_args()
    if os.geteuid() != 0:
        parser.error('需要 root 权限')
    os.umask(0o077)
    with open('/run/lock/sb-v52.lock', 'a') as lock:
        try:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ValueError('另一个安装/同步/管理操作正在运行，请稍后重试')
        if args.action == 'install':
            install(args)
        elif args.action == 'upgrade':
            upgrade(args)
        elif args.action == 'uninstall':
            uninstall(args)
        elif args.action == 'rollback':
            if not args.backup:
                parser.error('需要 --backup 完整备份目录')
            # Save the current state so manual rollback itself is reversible.
            preflight()
            snapshot()
            restore(args.backup)
        else:
            if not STATE.exists():
                raise ValueError('尚未安装 v5.2，请先执行 install')
            s = load(STATE)
            validate_state(s)
            if args.action == 'health':
                health(s)
            elif args.action == 'sync-cert':
                sync(s)
            else:
                print(links(s), end='')


if __name__ == '__main__':
    try:
        main()
    except (Exception, KeyboardInterrupt) as exc:
        # Do not print generated config or credential-bearing command arguments.
        if isinstance(exc, subprocess.CalledProcessError):
            print(f'[ERROR] 命令失败：{Path(str(exc.cmd[0])).name}，退出码 {exc.returncode}。请检查系统日志', file=sys.stderr)
        else:
            print(f'[ERROR] {exc}', file=sys.stderr)
        sys.exit(1)
PYTHON
python3 "$TASK_FILE" "$@"
