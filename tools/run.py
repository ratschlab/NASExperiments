#!/usr/bin/env python
import argparse
import sys

from basecall import basecall
from utils import truncate_signal

def main():
    """
    Parses command-line arguments and calls the specified function.
    """
    parser = argparse.ArgumentParser(
        description="A script to dynamically call a function by name with positional and keyword arguments.",
        epilog="Examples:\n"
               "  python %(prog)s greet\n"
               "  python %(prog)s say_hello World\n"
               "  python %(prog)s add 10 20\n"
               "  python %(prog)s profile Alice age=30\n"
               "  python %(prog)s profile Bob age=25 city=Paris",
        formatter_class=argparse.RawTextHelpFormatter
    )

    parser.add_argument("function_name", help="The name of the function to call.")
    parser.add_argument("args", nargs="*", help="Arguments for the function. Use key=value for named arguments.")

    args = parser.parse_args()

    # Get the function from the global scope based on the provided name.
    function_to_call = globals().get(args.function_name)

    # Check if the name corresponds to a real, callable function.
    if not (function_to_call and callable(function_to_call)):
        print(f"Error: Function '{args.function_name}' not found or is not callable.")
        sys.exit(1)

    # Separate positional and keyword arguments
    positional_args = []
    keyword_args = {}
    for arg in args.args:
        if "=" in arg:
            try:
                key, value = arg.split("=", 1)
                # A simple check to ensure key is a valid identifier.
                if not key.isidentifier():
                     print(f"Error: Invalid keyword argument name: '{key}'")
                     sys.exit(1)
                keyword_args[key] = value
            except ValueError:
                # This should not happen with the split("=", 1) but is good practice.
                print(f"Error: Malformed keyword argument '{arg}'. Expected format is key=value.")
                sys.exit(1)
        else:
            positional_args.append(arg)

    try:
        # The '*' operator unpacks the list into positional arguments.
        # The '**' operator unpacks the dictionary into keyword arguments.
        function_to_call(*positional_args, **keyword_args)
    except TypeError as e:
        # This catches mismatches in arguments.
        print(f"Error: Argument mismatch for function '{args.function_name}'.")
        print(f"Details: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()