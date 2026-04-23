import os
import pathlib
import stat
import subprocess
import tempfile
import textwrap
import unittest


class VpnEntrypointTests(unittest.TestCase):
    """验证 VPN 入口脚本传给 hide.me 的关键参数。"""

    @classmethod
    def setUpClass(cls) -> None:
        # 统一定位仓库根目录，避免测试依赖当前工作目录。
        cls.repo_root = pathlib.Path(__file__).resolve().parents[1]
        cls.entrypoint_path = cls.repo_root / "vpn" / "entrypoint.sh"

    def _write_executable(self, path: pathlib.Path, content: str) -> None:
        # 测试需要伪造外部命令，因此统一生成可执行脚本。
        path.write_text(content, encoding="utf-8")
        path.chmod(path.stat().st_mode | stat.S_IEXEC)

    def _run_entrypoint(
        self,
        kill_switch: str,
        token_host: str | None = None,
    ) -> tuple[subprocess.CompletedProcess[str], pathlib.Path, pathlib.Path, pathlib.Path, pathlib.Path, pathlib.Path]:
        # 通过临时目录隔离 token、ready 标记和伪造命令日志，避免污染宿主环境。
        temp_dir = tempfile.TemporaryDirectory()
        self.addCleanup(temp_dir.cleanup)

        temp_path = pathlib.Path(temp_dir.name)
        fake_bin_dir = temp_path / "fake-bin"
        fake_bin_dir.mkdir()

        ca_file = temp_path / "CA.pem"
        ca_file.write_text("test ca", encoding="utf-8")
        resolv_conf = temp_path / "resolv.conf"
        resolv_conf.write_text("nameserver 127.0.0.11\n", encoding="utf-8")

        conf_dir = temp_path / "hide-me-runtime"
        ready_file = temp_path / "vpn.ready"
        invocation_log = temp_path / "hide-me-invocations.log"
        curl_log = temp_path / "curl-invocations.log"

        self._write_executable(
            fake_bin_dir / "hide.me",
            textwrap.dedent(
                """\
                #!/bin/sh
                set -eu

                printf '%s\n' "$*" >> "$TEST_HIDE_ME_LOG"

                for arg in "$@"; do
                  if [ "$arg" = "connect" ]; then
                    sleep 1
                    exit 0
                  fi
                done

                exit 0
                """
            ),
        )

        self._write_executable(
            fake_bin_dir / "ip",
            textwrap.dedent(
                """\
                #!/bin/sh
                set -eu

                if [ "$1" = "link" ] && [ "$2" = "show" ]; then
                  exit 0
                fi

                if [ "$1" = "rule" ] && [ "$2" = "show" ]; then
                  printf '0: from all lookup local\\n'
                  printf '10: from all lookup 55555\\n'
                  printf '32766: from all lookup main\\n'
                  printf '32767: from all lookup default\\n'
                  exit 0
                fi

                if [ "$1" = "route" ] && [ "$2" = "show" ] && [ "$3" = "default" ]; then
                  exit 0
                fi

                if [ "$1" = "route" ] && [ "$2" = "show" ] && [ "$3" = "table" ] && [ "$4" = "55555" ]; then
                  printf '0.0.0.0/1 via 10.34.152.1 dev vpn mtu 1392\\n'
                  printf 'default dev lo\\n'
                  printf '10.34.152.1 dev vpn scope link mtu 1392\\n'
                  printf '128.0.0.0/1 via 10.34.152.1 dev vpn mtu 1392\\n'
                  printf 'throw 127.0.0.0/8\\n'
                  exit 0
                fi

                if [ "$1" = "-6" ] && [ "$2" = "route" ] && [ "$3" = "show" ] && [ "$4" = "table" ] && [ "$5" = "55555" ]; then
                  exit 0
                fi

                exit 1
                """
            ),
        )

        self._write_executable(
            fake_bin_dir / "curl",
            textwrap.dedent(
                """\
                #!/bin/sh
                set -eu

                printf '%s\n' "$*" >> "$TEST_CURL_LOG"
                printf '"test-access-token"'
                """
            ),
        )

        env = os.environ.copy()
        env.update(
            {
                "HIDEME_USERNAME": "demo-user",
                "HIDEME_PASSWORD": "demo-pass",
                "HIDEME_NODE": "any",
                "HIDEME_INTERFACE": "vpn",
                "HIDEME_KILL_SWITCH": kill_switch,
                "HIDEME_CONF_DIR": str(conf_dir),
                "HIDEME_BIN_PATH": str(fake_bin_dir / "hide.me"),
                "HIDEME_CA_CERT_PATH": str(ca_file),
                "VPN_RESOLV_CONF_PATH": str(resolv_conf),
                "VPN_READY_FILE": str(ready_file),
                "TEST_HIDE_ME_LOG": str(invocation_log),
                "TEST_CURL_LOG": str(curl_log),
                "PATH": f"{fake_bin_dir}:{env['PATH']}",
            }
        )
        if token_host is not None:
            env["HIDEME_TOKEN_HOST"] = token_host

        completed = subprocess.run(
            ["/bin/sh", str(self.entrypoint_path)],
            cwd=self.repo_root,
            env=env,
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )

        return completed, invocation_log, ready_file, conf_dir, curl_log, resolv_conf

    def test_entrypoint_passes_ca_bundle_and_true_kill_switch(self) -> None:
        # 默认启用 kill-switch 时，脚本必须通过配置文件提供凭据，而不是走命令行密码。
        completed, invocation_log, ready_file, conf_dir, curl_log, resolv_conf = self._run_entrypoint("true")

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertIn("vpn ready; proxy port 3128 is expected in shared namespace", completed.stdout)

        invocations = invocation_log.read_text(encoding="utf-8").strip().splitlines()
        self.assertEqual(len(invocations), 2)

        connect_line, disconnect_line = invocations
        expected_token_file = conf_dir / "accessToken.txt"
        expected_ca_file = ready_file.parent / "CA.pem"
        expected_config_file = conf_dir / "hide.me.yml"
        generated_config = expected_config_file.read_text(encoding="utf-8")
        curl_line = curl_log.read_text(encoding="utf-8").strip()

        self.assertIn(f"-c {expected_config_file}", connect_line)
        self.assertIn(f"-c {expected_config_file} disconnect", disconnect_line)
        self.assertIn(f"--cacert {expected_ca_file}", curl_line)
        self.assertIn('{"domain":"hide.me","host":"any","username":"demo-user","password":"demo-pass"}', curl_line)
        self.assertIn("https://any.hideservers.net:432/v1.0.0/accessToken", curl_line)
        self.assertEqual(expected_token_file.read_text(encoding="utf-8"), "test-access-token")
        self.assertIn("client:", generated_config)
        self.assertIn(f"CA: '{expected_ca_file}'", generated_config)
        self.assertIn(f"accessTokenPath: '{expected_token_file}'", generated_config)
        self.assertIn("username: 'demo-user'", generated_config)
        self.assertIn("password: 'demo-pass'", generated_config)
        self.assertIn("nameserver 8.8.8.8", resolv_conf.read_text(encoding="utf-8"))
        self.assertIn("-k=true", connect_line)
        self.assertNotIn("-P", connect_line)
        self.assertNotIn("-u", connect_line)
        self.assertNotIn(" token ", connect_line)
        self.assertIn("connect any", connect_line)

    def test_entrypoint_passes_false_kill_switch_value(self) -> None:
        # 显式关闭 kill-switch 时，也必须以 hide.me 接受的值传递给 connect 命令。
        completed, invocation_log, _, _, _, _ = self._run_entrypoint("false")

        self.assertEqual(completed.returncode, 0, completed.stderr)
        connect_line = next(
            line
            for line in invocation_log.read_text(encoding="utf-8").strip().splitlines()
            if " connect " in f" {line} "
        )
        self.assertIn("-k=false", connect_line)

    def test_entrypoint_normalizes_legacy_free_token_host_to_any(self) -> None:
        # 旧版本把 free.hideservers.net 当成默认 token 主机，这里要兼容映射到官方默认 any。
        completed, _, _, _, curl_log, _ = self._run_entrypoint("true", token_host="free.hideservers.net")

        self.assertEqual(completed.returncode, 0, completed.stderr)
        curl_line = curl_log.read_text(encoding="utf-8").strip()
        self.assertIn("https://any.hideservers.net:432/v1.0.0/accessToken", curl_line)
        self.assertIn('"host":"any"', curl_line)


if __name__ == "__main__":
    unittest.main()
