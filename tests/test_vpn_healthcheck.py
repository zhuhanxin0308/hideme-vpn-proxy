import os
import pathlib
import stat
import subprocess
import tempfile
import textwrap
import unittest


class VpnHealthcheckTests(unittest.TestCase):
    """验证 VPN 健康检查脚本会做真实解析检查。"""

    @classmethod
    def setUpClass(cls) -> None:
        # 统一定位仓库根目录，避免测试依赖当前工作目录。
        cls.repo_root = pathlib.Path(__file__).resolve().parents[1]
        cls.healthcheck_path = cls.repo_root / "vpn" / "healthcheck.sh"

    def _write_executable(self, path: pathlib.Path, content: str) -> None:
        # 健康检查依赖外部命令，测试里统一伪造这些可执行文件。
        path.write_text(content, encoding="utf-8")
        path.chmod(path.stat().st_mode | stat.S_IEXEC)

    def _run_healthcheck(self, *, lookup_success: bool) -> tuple[subprocess.CompletedProcess[str], pathlib.Path]:
        temp_dir = tempfile.TemporaryDirectory()
        self.addCleanup(temp_dir.cleanup)

        temp_path = pathlib.Path(temp_dir.name)
        fake_bin_dir = temp_path / "fake-bin"
        fake_bin_dir.mkdir()

        ready_file = temp_path / "vpn.ready"
        ready_file.write_text("ready\n", encoding="utf-8")
        resolv_conf = temp_path / "resolv.conf"
        resolv_conf.write_text("nameserver 10.58.180.1\nnameserver 8.8.8.8\n", encoding="utf-8")
        getent_log = temp_path / "getent.log"

        self._write_executable(
            fake_bin_dir / "ip",
            textwrap.dedent(
                """\
                #!/bin/sh
                set -eu

                if [ "$1" = "link" ] && [ "$2" = "show" ]; then
                  exit 0
                fi

                if [ "$1" = "-o" ] && [ "$2" = "addr" ] && [ "$3" = "show" ]; then
                  printf '3: vpn    inet 10.58.180.201/32 scope global vpn\\n'
                  exit 0
                fi

                if [ "$1" = "rule" ] && [ "$2" = "show" ]; then
                  printf '0: from all lookup local\\n'
                  printf '10: from all lookup 55555\\n'
                  printf '32766: from all lookup main\\n'
                  printf '32767: from all lookup default\\n'
                  exit 0
                fi

                if [ "$1" = "route" ] && [ "$2" = "show" ] && [ "$3" = "table" ] && [ "$4" = "55555" ]; then
                  printf '0.0.0.0/1 via 10.58.180.1 dev vpn mtu 1392\\n'
                  printf '128.0.0.0/1 via 10.58.180.1 dev vpn mtu 1392\\n'
                  exit 0
                fi

                if [ "$1" = "-6" ] && [ "$2" = "route" ] && [ "$3" = "show" ] && [ "$4" = "table" ] && [ "$5" = "55555" ]; then
                  exit 0
                fi

                exit 1
                """
            ),
        )

        lookup_script = (
            f"printf '%s\\n' \"$*\" > \"{getent_log}\"\n"
            + ("printf '198.18.0.38 www.google.com\\n'\n" if lookup_success else "exit 2\n")
        )
        self._write_executable(
            fake_bin_dir / "getent",
            "#!/bin/sh\nset -eu\n" + lookup_script,
        )

        self._write_executable(
            fake_bin_dir / "timeout",
            textwrap.dedent(
                """\
                #!/bin/sh
                set -eu

                duration="$1"
                shift
                exec "$@"
                """
            ),
        )

        env = os.environ.copy()
        env.update(
            {
                "VPN_READY_FILE": str(ready_file),
                "VPN_RESOLV_CONF_PATH": str(resolv_conf),
                "PATH": f"{fake_bin_dir}:{env['PATH']}",
            }
        )

        completed = subprocess.run(
            ["/bin/sh", str(self.healthcheck_path)],
            cwd=self.repo_root,
            env=env,
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )

        return completed, getent_log

    def test_healthcheck_performs_real_dns_lookup(self) -> None:
        # DNS 健康检查必须执行真实域名解析，而不是只验证 53 端口可连。
        completed, getent_log = self._run_healthcheck(lookup_success=True)

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(getent_log.read_text(encoding="utf-8").strip(), "hosts www.google.com")

    def test_healthcheck_fails_when_dns_lookup_fails(self) -> None:
        # 当域名解析失败时，VPN 健康检查必须转为失败状态。
        completed, _ = self._run_healthcheck(lookup_success=False)

        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("dns lookup failed", completed.stderr)


if __name__ == "__main__":
    unittest.main()
