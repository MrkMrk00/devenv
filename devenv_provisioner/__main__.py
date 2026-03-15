from .provision import ProvisionVMCommand
from argparse import ArgumentParser

_HANDLER_KEY = '__handler'

commands = {
    'new': ProvisionVMCommand()
}

def main() -> int:
    parser = ArgumentParser()
    subparsers = parser.add_subparsers(required=True)
    for command, handler in commands.items():
        p = subparsers.add_parser(command)
        handler.define_args(p)
        p.set_defaults(**{_HANDLER_KEY: handler.handle})

    args = parser.parse_args()
    handler = getattr(args, _HANDLER_KEY)

    handler(args)

    return 0

if __name__ == '__main__':
    raise SystemExit(main())
