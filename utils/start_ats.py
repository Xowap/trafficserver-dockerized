#!/usr/bin/env python3
import os
import re
import sys
from pathlib import Path
from signal import signal, SIGTERM
from sys import stderr
from typing import Sequence, Iterator, NamedTuple

import yaml

ETC_DIR = Path("/etc/trafficserver")
TPL_RE = re.compile(r"{{\s*(?P<name>[^}\s]+)\s*}}")
TPL_FILE_NAME_RE = re.compile(r"^(?P<base>.*)(\.tpl)(?P<ext>\.[^.]+)?$")


class TrafficPatchError(Exception):
    pass


def sigterm_handler(_, __):
    raise SystemExit(1)


def extract_records(records):
    stack = [([], records)]

    while stack:
        path, node = stack.pop()

        if isinstance(node, dict):
            for k, v in node.items():
                stack.append(([*path, k], v))
        else:
            yield path, node


def generate_config(flat_records):
    out = ""

    for path, value in flat_records:
        str_path = ".".join(path)

        if isinstance(value, str):
            t = "STRING"
        elif isinstance(value, bool):
            value = 1 if value else 0
            t = "INT"
        elif isinstance(value, int):
            t = "INT"
        elif (
            isinstance(value, Sequence)
            and len(value) == 2
            and isinstance(value[0], int)
            and value[1] in ["K", "M", "G", "T"]
        ):
            t = "INT"
            value = f"{value[0]}{value[1]}"
        elif isinstance(value, float):
            t = "FLOAT"
        else:
            continue

        out += f"CONFIG {str_path} {t} {value}\n"

    return out


class TemplatePath(NamedTuple):
    template_path: Path
    target_path: Path


def find_template_files() -> Iterator[TemplatePath]:
    """Find all template files in /etc/trafficserver by browsing the folder
    recursively. The file is a template if its extension is or is prefixed by
    .tlp, as defined by the TPL_FILE_NAME_RE regex."""

    for path in ETC_DIR.rglob("*"):
        m = TPL_FILE_NAME_RE.match(path.name)

        if path.is_file() and m:
            target_path = path.parent / (m.group("base") + m.group("ext"))
            yield TemplatePath(path, target_path)


def process_template(tp: TemplatePath):
    """We're processing the whole template file using the TPL_RE to find
    sections to substitute with environment variables. Then the output is
    written to the target file."""

    with open(tp.template_path, "r") as f:
        content = f.read()

    try:
        with open(tp.target_path, "w") as f:
            f.write(TPL_RE.sub(lambda m: os.environ[m.group("name")], content))
    except KeyError as e:
        raise TrafficPatchError(f"Missing environment variable: {e}")


def resolve_templates():
    """Resolve all templates in /etc/trafficserver"""

    for tp in find_template_files():
        process_template(tp)


def flatten_records():
    """Because the default syntax of records.config is completely unreadable,
    we allow the user to define a YAML file which contains the records
    structured in a more human-friendly way. We'll then flatten the records
    and write the result to /etc/trafficserver/records.config"""

    records_path = ETC_DIR / "records.config.yaml"

    if not records_path.exists():
        return

    try:
        with open(records_path, "r") as f:
            records = yaml.safe_load(f)
    except FileNotFoundError:
        raise TrafficPatchError(f"Patch file not found")
    except Exception as e:
        raise TrafficPatchError(f"Error reading records file: {e}")

    config = generate_config(extract_records(records))
    (ETC_DIR / "records.config").write_text(config)


def get_value(type_, value):
    if value == 'nullptr' or value == 'NULL':
        return None

    type_upper = type_.upper()
    if type_upper == 'FLOAT':
        try:
            return float(value)
        except ValueError:
            return value
    elif type_upper == 'INT':
        if value.startswith('0x') or any(value.endswith(m) for m in ('K', 'M', 'G', 'T')):
            return str(value)
        else:
            try:
                return int(value)
            except ValueError:
                return value
    elif type_upper == 'STRING':
        val_str = str(value)
        if len(val_str) >= 2 and (
            (val_str.startswith('"') and val_str.endswith('"')) or
            (val_str.startswith("'") and val_str.endswith("'"))
        ):
            return val_str[1:-1]
        return val_str
    return value


def add_object(config, var, value, type_, track_info):
    parts = var.split('.')
    current = config
    for i, part in enumerate(parts[:-1]):
        if part not in current:
            current[part] = {}
        elif not isinstance(current[part], dict):
            line, rec = track_info
            raise TrafficPatchError(
                f"Conflict at line {line} for record '{rec}': node '{part}' is already a value, cannot be a map."
            )
        current = current[part]

    last_part = parts[-1]
    if last_part in current and isinstance(current[last_part], dict):
        line, rec = track_info
        raise TrafficPatchError(
            f"Conflict at line {line} for record '{rec}': node '{last_part}' is already a map, cannot be a value."
        )
    current[last_part] = get_value(type_, value)


def convert_records_config_to_yaml():
    """Convert /etc/trafficserver/records.config to /etc/trafficserver/records.yaml
    following the migration guide, and remove the legacy records.config file."""
    records_config_path = ETC_DIR / "records.config"
    records_yaml_path = ETC_DIR / "records.yaml"

    if not records_config_path.exists():
        return

    renamed_records = {
        'proxy.config.output.logfile': 'proxy.config.output.logfile.name',
        'proxy.config.exec_thread.autoconfig': 'proxy.config.exec_thread.autoconfig.enabled',
        'proxy.config.hostdb': 'proxy.config.hostdb.enabled',
        'proxy.config.tunnel.prewarm': 'proxy.config.tunnel.prewarm.enabled',
        'proxy.config.ssl.origin_session_cache': 'proxy.config.ssl.origin_session_cache.enabled',
        'proxy.config.ssl.session_cache': 'proxy.config.ssl.session_cache.mode',
        'proxy.config.ssl.TLSv1_3': 'proxy.config.ssl.TLSv1_3.enabled',
        'proxy.config.ssl.client.TLSv1_3': 'proxy.config.ssl.client.TLSv1_3.enabled',
        'proxy.local.incoming_ip_to_bind': 'proxy.config.incoming_ip_to_bind',
        'proxy.local.outgoing_ip_to_bind': 'proxy.config.outgoing_ip_to_bind',
        'proxy.local.http.parent_proxy.disable_connect_tunneling': 'proxy.config.http.parent_proxy.disable_connect_tunneling'
    }

    config = {}

    try:
        with open(records_config_path, "r") as f:
            lines = f.readlines()
    except Exception as e:
        raise TrafficPatchError(f"Error reading records.config: {e}")

    for idx, line in enumerate(lines):
        line = line.strip()
        if not line or line.startswith('#'):
            continue

        parts = line.split(None, 3)
        if len(parts) < 4:
            continue

        _, name, type_, value = parts
        value = value.rstrip('\n')

        if name in renamed_records:
            name = renamed_records[name]

        if name.startswith("proxy.config."):
            name = name[len("proxy.config."):]
        elif name.startswith("local.config."):
            name = name[len("local.config."):]

        track_info = (idx + 1, name)
        add_object(config, name, value, type_, track_info)

    ts = {"records": config}

    try:
        with open(records_yaml_path, "w") as f:
            yaml.safe_dump(ts, f, default_flow_style=False)
    except Exception as e:
        raise TrafficPatchError(f"Error writing records.yaml: {e}")

    try:
        records_config_path.unlink()
    except Exception as e:
        raise TrafficPatchError(f"Error removing records.config: {e}")


def exec_ats():
    """When all is in place, we execute the traffic_server binary by replacing
    the current process. We forward all the CLI arguments to the new
    process."""

    os.execv("/usr/bin/traffic_server", ["traffic_server", *sys.argv[1:]])


def main():
    """The main function of the script. It resolves all templates, flattens
    the records.config file, and converts records.config to records.yaml."""

    resolve_templates()
    flatten_records()
    convert_records_config_to_yaml()
    exec_ats()


def __main__():
    signal(SIGTERM, sigterm_handler)

    try:
        main()
    except KeyboardInterrupt:
        stderr.write("ok, bye\n")
        exit(1)
    except TrafficPatchError as e:
        stderr.write(f"Error: {e}\n")
        exit(1)


if __name__ == "__main__":
    __main__()
