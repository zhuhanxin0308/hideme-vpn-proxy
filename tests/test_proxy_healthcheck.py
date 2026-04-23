import os
import pathlib
import socket
import stat
import subprocess
import tempfile
import textwrap
import unittest


class ProxyHealthcheckTests(unittest.TestCase):
    """验证代理健康检查脚本只检查监听状态。"""

    @classmethod
    def setUpClass(cls) -> None:
        # 统一定位仓库根目录，避免测试依赖当前工作目录。
        cls.repo_root = pathlib.Path(__file__).resolve().parents[1]
        cls.healthcheck_path = cls.repo_root / "proxy" / "healthcheck.sh"

    def _write_executable(self, path: pathlib.Path, content: str) -> None:
        # 通过伪造 nc，确保健康检查不会再偷偷发起本地连接。
        path.write_text(content, encoding="utf-8")
        path.chmod(path.stat().st_mode | stat.S_IEXEC)

    def _run_healthcheck(self, *, port: int, ready_file_exists: bool = True) -> subprocess.CompletedProcess[str]:
        temp_dir = tempfile.TemporaryDirectory()
        self.addCleanup(temp_dir.cleanup)

        temp_path = pathlib.Path(temp_dir.name)
        fake_bin_dir = temp_path / "fake-bin"
        fake_bin_dir.mkdir()
        ready_file = temp_path / "vpn.ready"
        if ready_file_exists:
            ready_file.write_text("ready\n", encoding="utf-8")

        self._write_executable(
            fake_bin_dir / "nc",
            textwrap.dedent(
                """\
                #!/bin/sh
                set -eu

                echo "healthcheck must not execute nc" >&2
                exit 91
                """
            ),
        )

        env = os.environ.copy()
        env.update(
            {
                "PROXY_PORT": str(port),
                "VPN_READY_FILE": str(ready_file),
                "PATH": f"{fake_bin_dir}:{env['PATH']}",
            }
        )

        return subprocess.run(
            ["/bin/sh", str(self.healthcheck_path)],
            cwd=self.repo_root,
            env=env,
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )

    def test_healthcheck_passes_when_proxy_port_is_listening(self) -> None:
        # 只要端口进入 LISTEN，健康检查就应成功，且不能依赖 nc 或真实 HTTP 请求。
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as server:
            server.bind(("0.0.0.0", 0))
            server.listen()

            port = server.getsockname()[1]
            completed = self._run_healthcheck(port=port)

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertNotIn("must not execute nc", completed.stderr)

    def test_healthcheck_fails_when_proxy_port_is_not_listening(self) -> None:
        # 没有任何进程监听目标端口时，健康检查必须失败。
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
            probe.bind(("127.0.0.1", 0))
            unused_port = probe.getsockname()[1]

        completed = self._run_healthcheck(port=unused_port)

        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("proxy port is not listening", completed.stderr)


if __name__ == "__main__":
    unittest.main()
