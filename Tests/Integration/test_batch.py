"""Real-process TCP regression tests. Run after swift build (stdlib only)."""
import os
from pathlib import Path
import signal
import socket
import subprocess
import tempfile
import threading
import unittest

BINARY = str(Path(os.environ.get("ELMTERM_BINARY", ".build/debug/ELMterm")).resolve())


class BatchTests(unittest.TestCase):
    def run_adapter(self, responses, commands=("ATI",), extra=(), interrupt=False):
        received, errors = [], []
        ready = threading.Event()
        with socket.socket() as server:
            server.bind(("127.0.0.1", 0))
            server.listen()
            server.settimeout(5)
            port = server.getsockname()[1]

            def serve():
                try:
                    with server.accept()[0] as connection:
                        connection.settimeout(5)
                        pending = b""
                        for response in responses:
                            while b"\r" not in pending:
                                chunk = connection.recv(4096)
                                if not chunk:
                                    return
                                pending += chunk
                            command, pending = pending.split(b"\r", 1)
                            received.append(command.decode())
                            ready.set()
                            if response is None:
                                return  # disconnect before the prompt
                            if response:
                                connection.sendall(response)
                            else:
                                # A silent adapter waits for the client to close.
                                while connection.recv(4096):
                                    pass
                                return
                        while connection.recv(4096):
                            pass
                except Exception as error:
                    errors.append(error)

            worker = threading.Thread(target=serve, daemon=True)
            worker.start()
            args = [BINARY, f"tcp://127.0.0.1:{port}", "--plain", "--response-timeout", "0.5"]
            for command in commands:
                args.extend(["--exec", command])
            args.extend(extra)
            with subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) as process:
                if interrupt:
                    self.assertTrue(ready.wait(5), "Client never sent a command")
                    process.send_signal(signal.SIGINT)
                try:
                    stdout, stderr = process.communicate(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.communicate()
                    self.fail("ELMterm hung")
            worker.join(5)
            self.assertFalse(worker.is_alive(), "Mock adapter did not stop")
            self.assertFalse(errors, errors)
            return process.returncode, stdout, stderr, received

    def test_success_waits_for_each_prompt(self):
        code, out, err, commands = self.run_adapter(
            [b"ELM327 v2.3\r\n>", b"41 0C 1A F8\r>"], ("ATI", "010C"))
        self.assertEqual(code, 0, err)
        self.assertEqual(commands, ["ATI", "010C"])
        self.assertIn("ELM327 v2.3", out)
        self.assertIn("41 0C 1A F8", out)
        self.assertNotIn("\x1b", out)

    def test_timeout_fails_and_does_not_send_remaining_commands(self):
        code, out, err, commands = self.run_adapter([b""], ("ATI", "010C"))
        self.assertNotEqual(code, 0)
        self.assertIn("Timed out", err)
        self.assertEqual(commands, ["ATI"])
        self.assertNotIn("010C", out)

    def test_disconnect_fails(self):
        code, out, err, commands = self.run_adapter([None], ("ATI", "010C"))
        self.assertNotEqual(code, 0)
        self.assertIn("Batch interrupted", err)
        self.assertEqual(commands, ["ATI"])
        self.assertNotIn("Stopping:", out)

    def test_interrupt_fails(self):
        code, _, err, _ = self.run_adapter([b""], interrupt=True)
        self.assertNotEqual(code, 0)
        self.assertIn("Interrupted", err)

    def test_init_crlf_precedes_exec(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "init.txt"
            path.write_bytes(b"# setup\r\n\r\nATE0\r\nATSP6\r\n")
            code, _, err, commands = self.run_adapter(
                [b"OK\r>", b"OK\r>", b"ELM327 v2.3\r>"], extra=("--init", str(path)))
            self.assertEqual(code, 0, err)
            self.assertEqual(commands, ["ATE0", "ATSP6", "ATI"])

    def test_cli_history_depth_overrides_config(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "config.json"
            path.write_text('{"historyDepth": -1}')
            code, _, err, _ = self.run_adapter(
                [b"OK\r>"], extra=("--config", str(path), "--history-depth", "0"))
            self.assertEqual(code, 0, err)

    def test_connection_failure_exits(self):
        # Reserve a port without listening, so the connect is refused.
        with socket.socket() as reserved:
            reserved.bind(("127.0.0.1", 0))
            result = subprocess.run(
                [BINARY, f"tcp://127.0.0.1:{reserved.getsockname()[1]}", "--exec", "ATI", "--timeout", "0.2"],
                capture_output=True, text=True, timeout=5)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Error:", result.stderr)
        self.assertNotIn("Error:", result.stdout)


if __name__ == "__main__":
    unittest.main()
