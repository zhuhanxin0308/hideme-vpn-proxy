import os
import pathlib
import stat
import subprocess
import tempfile
import textwrap
import unittest


class ProxyEntrypointTests(unittest.TestCase):
    """验证代理入口脚本生成的 tinyproxy 配置。"""

    @classmethod
    def setUpClass(cls) -> None:
        # 统一定位仓库根目录，避免测试依赖当前工作目录。
        cls.repo_root = pathlib.Path(__file__).resolve().parents[1]
        cls.entrypoint_path = cls.repo_root / "proxy" / "entrypoint.sh"

    def _write_executable(self, path: pathlib.Path, content: str) -> None:
        # 测试需要伪造 tinyproxy 进程，因此统一生成可执行脚本。
        path.write_text(content, encoding="utf-8")
        path.chmod(path.stat().st_mode | stat.S_IEXEC)

    def _run_entrypoint(
        self,
        env_overrides: dict[str, str],
    ) -> tuple[subprocess.CompletedProcess[str], pathlib.Path, pathlib.Path]:
        # 每个用例用独立临时目录保存 ready 标记和配置快照，避免测试间互相污染。
        temp_dir = tempfile.TemporaryDirectory()
        self.addCleanup(temp_dir.cleanup)

        temp_path = pathlib.Path(temp_dir.name)
        fake_bin_dir = temp_path / "fake-bin"
        fake_bin_dir.mkdir()

        ready_file = temp_path / "vpn.ready"
        ready_file.write_text("ready\n", encoding="utf-8")
        config_snapshot = temp_path / "tinyproxy.conf.snapshot"
        tinyproxy_log = temp_path / "tinyproxy.log"

        self._write_executable(
            fake_bin_dir / "tinyproxy",
            textwrap.dedent(
                f"""\
                #!/bin/sh
                set -eu

                printf '%s\\n' "$*" > "{tinyproxy_log}"
                conf_file=""
                while [ "$#" -gt 0 ]; do
                  if [ "$1" = "-c" ]; then
                    conf_file="$2"
                    break
                  fi
                  shift
                done
                cp "$conf_file" "{config_snapshot}"
                """
            ),
        )

        env = os.environ.copy()
        env.update({
            "VPN_READY_FILE": str(ready_file),
            "PROXY_PORT": "3128",
            "PROXY_LISTEN": "0.0.0.0",
            "PROXY_TIMEOUT": "600",
            "PROXY_MAX_CLIENTS": "200",
            "PROXY_MAX_REQUEST_SIZE": "0",
            "PROXY_ALLOW": "",
            "PROXY_BASIC_AUTH_USER": "",
            "PROXY_BASIC_AUTH_PASSWORD": "",
            "PROXY_REQUIRE_AUTH": "false",
            "PATH": f"{fake_bin_dir}:{env['PATH']}",
        })
        env.update(env_overrides)

        completed = subprocess.run(
            ["/bin/sh", str(self.entrypoint_path)],
            cwd=self.repo_root,
            env=env,
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )

        return completed, config_snapshot, tinyproxy_log

    def test_entrypoint_writes_trimmed_tinyproxy_config(self) -> None:
        # 代理配置应保留必要指令，同时移除会触发告警的旧进程池参数。
        completed, config_snapshot, tinyproxy_log = self._run_entrypoint({
            "PROXY_MAX_REQUEST_SIZE": "1024",
            "PROXY_ALLOW": "10.0.0.0/8,192.168.0.0/16",
            "PROXY_BASIC_AUTH_USER": "demo-user",
            "PROXY_BASIC_AUTH_PASSWORD": "demo-pass",
        })

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertIn("starting tinyproxy on 0.0.0.0:3128", completed.stdout)
        self.assertEqual(tinyproxy_log.read_text(encoding="utf-8").strip(), "-d -c /tmp/tinyproxy.conf")

        config_text = config_snapshot.read_text(encoding="utf-8")
        self.assertIn("Port 3128", config_text)
        self.assertIn("Listen 0.0.0.0", config_text)
        self.assertIn("MaxClients 200", config_text)
        self.assertIn("MaxRequestSize 1024", config_text)
        self.assertIn("BasicAuth demo-user demo-pass", config_text)
        self.assertIn("Allow 10.0.0.0/8", config_text)
        self.assertIn("Allow 192.168.0.0/16", config_text)
        self.assertNotIn("User tinyproxy", config_text)
        self.assertNotIn("Group tinyproxy", config_text)
        self.assertNotIn("MinSpareServers", config_text)
        self.assertNotIn("MaxSpareServers", config_text)
        self.assertNotIn("StartServers", config_text)
        self.assertNotIn("MaxRequestsPerChild", config_text)

    def test_entrypoint_writes_upstream_for_public_ingress(self) -> None:
        # 公网入口代理必须把 HTTP/HTTPS 请求转发给 VPN 命名空间里的出口代理。
        completed, config_snapshot, _ = self._run_entrypoint({
            "PROXY_UPSTREAM_TYPE": "http",
            "PROXY_UPSTREAM_HOST": "vpn",
            "PROXY_UPSTREAM_PORT": "3129",
            "PROXY_BASIC_AUTH_USER": "demo-user",
            "PROXY_BASIC_AUTH_PASSWORD": "demo-pass",
            "PROXY_REQUIRE_AUTH": "true",
        })

        self.assertEqual(completed.returncode, 0, completed.stderr)
        config_text = config_snapshot.read_text(encoding="utf-8")
        self.assertIn("Upstream http vpn:3129", config_text)
        self.assertIn("BasicAuth demo-user demo-pass", config_text)

    def test_entrypoint_rejects_public_proxy_without_auth(self) -> None:
        # 允许任意来源连接时，缺少认证会形成开放代理，入口脚本必须直接失败。
        completed, config_snapshot, _ = self._run_entrypoint({
            "PROXY_REQUIRE_AUTH": "true",
            "PROXY_BASIC_AUTH_USER": "",
            "PROXY_BASIC_AUTH_PASSWORD": "",
        })

        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("PROXY_REQUIRE_AUTH is true", completed.stderr)
        self.assertFalse(config_snapshot.exists())

    def test_entrypoint_rejects_incomplete_upstream_settings(self) -> None:
        # 上游代理配置必须一次性给全，不能生成 tinyproxy 无法解析的半截配置。
        completed, config_snapshot, _ = self._run_entrypoint({
            "PROXY_UPSTREAM_TYPE": "http",
            "PROXY_UPSTREAM_HOST": "vpn",
            "PROXY_UPSTREAM_PORT": "",
        })

        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("incomplete upstream configuration", completed.stderr)
        self.assertFalse(config_snapshot.exists())


if __name__ == "__main__":
    unittest.main()
