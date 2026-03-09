# prepare-new-resolver.sh

Interactive wizard that generates a new product resolver for initcaseenv.sh.

## What it does

1. Asks for required info: product type, description, container image pattern
2. Asks for optional info with sensible defaults: container prefix, command, env vars
3. Optionally configures database support (name, user, env vars with placeholders)
4. Optionally configures custom image build (Containerfile name)
5. Generates `resolve-<type>.sh` in the same directory, ready for use

## Usage

```bash
lib/case/env/lib/prepare-new-resolver.sh
```

No arguments — fully interactive. Can be called from anywhere (resolves its own location via symlink).

## Output

Creates `resolve-<type>.sh` in the same directory as this script. The generated resolver follows the standard interface:

```
resolve-<type>.sh <version> [--cached VALUE] [--env-dir DIR]
```

And outputs `RESOLVE_*` key-value pairs on stdout (see resolve-rhbk.sh or resolve-eap.sh for examples).

## Author

Daniele Mammarella <dmammare@redhat.com>
