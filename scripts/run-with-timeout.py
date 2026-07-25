#!/usr/bin/env python3

import argparse
import os
import signal
import subprocess
import sys
from pathlib import Path


TIMEOUT_EXIT_CODE = 124
TERMINATION_GRACE_SECONDS = 5


class CommandInterrupted(Exception):
    def __init__(self, signal_number: int):
        self.signal_number = signal_number


def stop_process_group(process: subprocess.Popen[bytes], log) -> None:
    if process.poll() is not None:
        return
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    try:
        process.wait(timeout=TERMINATION_GRACE_SECONDS)
    except subprocess.TimeoutExpired:
        log.write(b"error: process group ignored SIGTERM; sending SIGKILL\n")
        log.flush()
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait()


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Run a command in a dedicated process group with a hard timeout."
    )
    parser.add_argument("--timeout", required=True, type=int, help="Timeout in seconds.")
    parser.add_argument("--log", required=True, type=Path, help="File that receives command output.")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    arguments = parser.parse_args()

    command = arguments.command
    if command[:1] == ["--"]:
        command = command[1:]
    if arguments.timeout < 1:
        parser.error("--timeout must be a positive integer")
    if not command:
        parser.error("a command is required after --")

    arguments.log.parent.mkdir(parents=True, exist_ok=True)
    with arguments.log.open("wb") as log:
        process = subprocess.Popen(
            command,
            stdout=log,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )

        def interrupt(signal_number, _frame) -> None:
            raise CommandInterrupted(signal_number)

        previous_handlers = {
            signal_number: signal.signal(signal_number, interrupt)
            for signal_number in (signal.SIGINT, signal.SIGTERM)
        }
        try:
            return_code = process.wait(timeout=arguments.timeout)
        except subprocess.TimeoutExpired:
            log.write(
                f"\nerror: command timed out after {arguments.timeout} seconds\n".encode()
            )
            log.flush()
            stop_process_group(process, log)
            raise SystemExit(TIMEOUT_EXIT_CODE)
        except CommandInterrupted as interruption:
            log.write(f"\nerror: interrupted by signal {interruption.signal_number}\n".encode())
            log.flush()
            stop_process_group(process, log)
            raise SystemExit(128 + interruption.signal_number)
        finally:
            for signal_number, handler in previous_handlers.items():
                signal.signal(signal_number, handler)

    raise SystemExit(return_code)


if __name__ == "__main__":
    main()
