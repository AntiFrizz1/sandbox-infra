#!/usr/bin/env python3
"""Allowlist check of a project's Compose model before it reaches the host daemon.

Usage: lint-compose.py <project> <domain> <workdir> <compose-file> < config.json

config.json is `docker compose config --format json --no-path-resolution
--no-env-resolution --profile '*'` of the same file, interpolated with the
environment that `up` will use. The raw file is parsed as well, because
Compose merges `include` and `extends: file` silently: the rendered model no
longer shows that another file on the host was read.

Anything not explicitly allowed is refused. The goal is that a commit cannot
use Compose to reach host paths, host namespaces, extra privileges, other
projects' volumes or networks, the Caddy control network, or hostnames that
belong to someone else. Code inside the containers is not constrained here.
"""
import json
import os
import re
import sys

import yaml

SERVICE_KEYS = {
    'annotations', 'attach', 'build', 'command', 'depends_on',
    'deploy', 'dns', 'dns_opt', 'dns_search', 'domainname', 'entrypoint',
    'env_file', 'environment', 'expose', 'extra_hosts', 'group_add',
    'healthcheck', 'hostname', 'image', 'init', 'labels', 'links',
    'mem_reservation', 'networks', 'platform',
    'profiles', 'pull_policy', 'read_only', 'restart', 'scale',
    'security_opt', 'shm_size', 'stdin_open', 'stop_grace_period',
    'stop_signal', 'tmpfs', 'tty', 'user', 'volumes', 'working_dir',
    'cap_drop',
}
BUILD_KEYS = {'context', 'dockerfile', 'dockerfile_inline', 'args', 'target',
              'labels', 'no_cache', 'pull', 'platforms', 'shm_size', 'extra_hosts'}
DEPLOY_KEYS = {'resources', 'restart_policy', 'placement', 'replicas'}
RESOURCE_KEYS = {'cpus', 'memory'}
NETWORK_KEYS = {'name', 'ipam', 'driver', 'internal', 'labels', 'attachable',
                'enable_ipv6', 'external'}
SERVICE_NETWORK_KEYS = {'aliases', 'priority'}
VOLUME_KEYS = {'name', 'driver', 'labels'}
MOUNT_KEYS = {'type', 'source', 'target', 'read_only', 'bind', 'volume',
              'tmpfs', 'consistency'}
ALLOWED_SECURITY_OPT = {'no-new-privileges', 'no-new-privileges:true'}
UPSTREAMS = re.compile(r'^\{\{\s*upstreams(\s+(https?\s+)?[0-9]{1,5})?\s*\}\}$')
CADDY_LABEL = re.compile(r'^caddy(_[0-9]{1,3})?(\.reverse_proxy)?$')

errors = []


def err(msg):
    errors.append(msg)


def inside(workdir, base, rel):
    """rel resolved against base must stay under workdir, links included."""
    if not isinstance(rel, str) or not rel or rel.startswith('/') or '://' in rel:
        return False
    real = os.path.realpath(os.path.join(base, rel))
    return real == workdir or real.startswith(workdir + os.sep)


def check_hosts(project, domain, value, where):
    if not domain:
        err(f'{where}: caddy labels need SANDBOX_DOMAIN')
        return
    own = re.compile(r'^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)*' + re.escape(f'{project}.{domain}') + r'$')
    hosts = [h for h in re.split(r'[\s,]+', str(value)) if h]
    if not hosts:
        err(f'{where}: empty caddy address')
    for host in hosts:
        bare = re.sub(r'^https?://', '', host)
        if not own.match(bare):
            err(f'{where}: address {host!r} is not under {project}.{domain}')


def check_labels(project, domain, labels, where):
    for key, value in (labels or {}).items():
        if key.startswith('com.docker.'):
            err(f'{where}: label {key} is reserved')
        if not key.startswith('caddy'):
            continue
        if not CADDY_LABEL.match(key):
            err(f'{where}: caddy label {key} is not allowed (only caddy and caddy.reverse_proxy)')
        elif key.endswith('.reverse_proxy'):
            if not UPSTREAMS.match(str(value)):
                err(f'{where}: {key} must be {{{{upstreams [port]}}}}')
        else:
            check_hosts(project, domain, value, f'{where} label {key}')


def check_raw(path):
    with open(path) as f:
        raw = yaml.safe_load(f)
    if not isinstance(raw, dict):
        err('compose file is not a mapping')
        return set()
    if 'include' in raw:
        err('include is not allowed: it reads files outside the project')
    for key in raw:
        # Checked on the raw file too: unused top-level entries vanish from the model.
        if key not in ('name', 'services', 'networks', 'volumes', 'include') \
                and not str(key).startswith('x-'):
            err(f'top-level {key} is not allowed')
    services = raw.get('services') or {}
    for name, svc in services.items():
        ext = (svc or {}).get('extends')
        if isinstance(ext, dict) and 'file' in ext:
            err(f'service {name}: extends from another file is not allowed')
    return set(services)


def main():
    project, domain, workdir, compose_file = sys.argv[1:5]
    workdir = os.path.realpath(workdir)
    model = json.load(sys.stdin)
    raw_services = check_raw(compose_file)

    for key in model:
        if key not in ('name', 'services', 'networks', 'volumes') and not key.startswith('x-'):
            err(f'top-level {key} is not allowed')

    services = model.get('services') or {}
    if set(services) != raw_services:
        err('services differ from the compose file itself (include/extends merged others in)')

    volumes = model.get('volumes') or {}
    for name, vol in volumes.items():
        vol = vol or {}
        for key in vol:
            if key not in VOLUME_KEYS:
                err(f'volume {name}: {key} is not allowed')
        if vol.get('name', f'{project}_{name}') != f'{project}_{name}':
            err(f'volume {name}: custom name would reach another project\'s data')
        if vol.get('driver', 'local') != 'local':
            err(f'volume {name}: only the local driver is allowed')

    networks = model.get('networks') or {}
    for name, net in networks.items():
        net = net or {}
        for key in net:
            if key not in NETWORK_KEYS:
                err(f'network {name}: {key} is not allowed')
        if net.get('external'):
            if name != 'sandbox_net' or net.get('name', name) != 'sandbox_net':
                err(f'network {name}: the only external network allowed is sandbox_net')
            continue
        if net.get('name', f'{project}_{name}') != f'{project}_{name}':
            err(f'network {name}: custom name would join another network')
        if net.get('driver', 'bridge') != 'bridge':
            err(f'network {name}: only the bridge driver is allowed')
        if (net.get('ipam') or {}) != {}:
            err(f'network {name}: ipam is not allowed')

    for sname, svc in services.items():
        where = f'service {sname}'
        for key in svc:
            if key not in SERVICE_KEYS and not key.startswith('x-'):
                err(f'{where}: {key} is not allowed')
        for opt in svc.get('security_opt') or []:
            if opt not in ALLOWED_SECURITY_OPT:
                err(f'{where}: security_opt {opt} is not allowed')
        check_labels(project, domain, svc.get('labels'), where)

        build = svc.get('build')
        if build is not None:
            for key in build:
                if key not in BUILD_KEYS:
                    err(f'{where}: build.{key} is not allowed')
            context = build.get('context', '.')
            if not inside(workdir, workdir, context):
                err(f'{where}: build context {context!r} must stay inside the project')
            elif 'dockerfile' in build and not inside(
                    workdir, os.path.join(workdir, context), build['dockerfile']):
                err(f'{where}: dockerfile must stay inside the project')
            check_labels(project, domain, build.get('labels'), f'{where} build')
            image = svc.get('image')
            if image is not None and not re.match(
                    r'^' + re.escape(project) + r'([-_/][a-z0-9._/-]*)?(:[\w.-]+)?$', image):
                err(f'{where}: a built image must be named {project}-*, not {image!r}')

        for entry in svc.get('env_file') or []:
            path = entry.get('path') if isinstance(entry, dict) else entry
            if not inside(workdir, workdir, path):
                err(f'{where}: env_file {path!r} must stay inside the project')

        for mount in svc.get('volumes') or []:
            for key in mount:
                if key not in MOUNT_KEYS:
                    err(f'{where}: volume option {key} is not allowed')
            kind = mount.get('type')
            if kind == 'bind':
                if not inside(workdir, workdir, mount.get('source')):
                    err(f'{where}: bind {mount.get("source")!r} must stay inside the project')
                propagation = (mount.get('bind') or {}).get('propagation')
                if propagation not in (None, 'private', 'rprivate'):
                    err(f'{where}: bind propagation {propagation} is not allowed')
            elif kind == 'volume':
                source = mount.get('source')
                if source and source not in volumes:
                    err(f'{where}: volume {source!r} is not declared by this project')
            elif kind != 'tmpfs':
                err(f'{where}: mount type {kind} is not allowed')

        for net, opts in (svc.get('networks') or {}).items():
            if net not in networks:
                err(f'{where}: network {net} is not declared')
            for key in opts or {}:
                if key not in SERVICE_NETWORK_KEYS:
                    err(f'{where}: network option {key} is not allowed')

        deploy = svc.get('deploy') or {}
        for key in deploy:
            if key not in DEPLOY_KEYS:
                err(f'{where}: deploy.{key} is not allowed')
        if deploy.get('placement'):
            err(f'{where}: deploy.placement is not allowed')
        resources = deploy.get('resources') or {}
        for key in resources:
            if key != 'reservations':
                # Limits come only from the root policy (sandbox override file).
                err(f'{where}: deploy.resources.{key} is not allowed')
        for key in resources.get('reservations') or {}:
            if key not in RESOURCE_KEYS:
                err(f'{where}: deploy.resources.reservations.{key} is not allowed')

    for line in errors:
        print(f'compose policy: {line}')
    return 1 if errors else 0


if __name__ == '__main__':
    sys.exit(main())
