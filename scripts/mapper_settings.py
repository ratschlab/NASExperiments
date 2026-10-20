#!/usr/bin/env python3
"""
Print parts of the [mapper_settings.<plugin>] section of a readfish TOML.

    mapper_settings.py <toml> module   importable module of the plugin
    mapper_settings.py <toml> paths    absolute path values, one per line
    mapper_settings.py <toml> args     "k=v k=v ..." for benchmark_aligner.py --plugin-args
"""
import importlib.util
import sys
try:
    import tomllib
except ModuleNotFoundError:  # python < 3.11
    import tomli as tomllib


def main():
    if len(sys.argv) != 3 or sys.argv[2] not in ("module", "paths", "args"):
        sys.exit(__doc__)
    with open(sys.argv[1], "rb") as fh:
        conf = tomllib.load(fh)
    (plugin, params), = conf["mapper_settings"].items()

    if sys.argv[2] == "module":
        # readfish resolves its built-in plugins (e.g. mappy_rs) under readfish.plugins
        builtin = f"readfish.plugins.{plugin}"
        if importlib.util.find_spec("readfish.plugins") and importlib.util.find_spec(builtin):
            print(builtin)
        else:
            print(plugin)
    elif sys.argv[2] == "paths":
        for v in params.values():
            if isinstance(v, str) and v.startswith("/"):
                print(v)
    else:
        print(" ".join(f"{k}={str(v).lower() if isinstance(v, bool) else v}"
                       for k, v in params.items()))


if __name__ == "__main__":
    main()
