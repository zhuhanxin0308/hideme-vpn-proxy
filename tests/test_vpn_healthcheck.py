import os
import pathlib
import stat
import subprocess
import tempfile
import textwrap
import unittest


class VpnHealthcheckTests(unittest.TestCase):
    """验证 VPN 健康检查脚本只检查 Google 访问能力。"""

    @classmethod
    def setUpClass(cls) -> None:
        # 统一定位仓库根目录，避免测试依赖当前工作目录。
        cls.repo_root = pathlib.Path(__file__).resolve().parents[1]
        cls.healthcheck_path = cls.repo_root / "vpn" / "healthcheck.sh"

    def _write_executable(self, path: pathlib.Path, content: str) -> None:
        # 健康检查依赖外部命令，测试里统一伪造这些可执行文件。
        path.write_text(content, encoding="utf-8")
        path.chmod(path.stat().st_mode | stat.S_IEXEC)

    def _run_healthcheck(self, *, access_success: bool) -> tuple[subprocess.CompletedProcess[str], pathlib.Path]:
        temp_dir = tempfile.TemporaryDirectory()
        self.addCleanup(temp_dir.cleanup)

        temp_path = pathlib.Path(temp_dir.name)
        fake_bin_dir = temp_path / "fake-bin"
        fake_bin_dir.mkdir()
        curl_log = temp_path / "curl.log"

        self._write_executable(
            fake_bin_dir / "curl",
            textwrap.dedent(
                f"""\
                #!/bin/sh
                set -eu

                printf '%s\\n' "$*" > "{curl_log}"
                if [ "$TEST_GOOGLE_ACCESS" = "true" ]; then
                  exit 0
                fi
                exit 22
                """
            ),
        )

        for command_name in ("ip", "getent", "timeout"):
            self._write_executable(
                fake_bin_dir / command_name,
                textwrap.dedent(
                    f"""\
                    #!/bin/sh
                    set -eu

                    echo "vpn healthcheck must not execute {command_name}" >&2
                    exit 91
                    """
                ),
            )

        env = os.environ.copy()
        env.update(
            {
                "TEST_GOOGLE_ACCESS": "true" if access_success else "false",
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

        return completed, curl_log

    def test_healthcheck_only_curls_google_without_extra_checks(self) -> None:
        # 健康检查只应访问 Google，不能再因为 ready 文件、接口、路由或 resolv.conf 状态触发重启。
        completed, curl_log = self._run_healthcheck(access_success=True)

        self.assertEqual(completed.returncode, 0, completed.stderr)
        curl_args = curl_log.read_text(encoding="utf-8").strip()
        self.assertIn("--fail", curl_args)
        self.assertIn("--max-time 5", curl_args)
        self.assertIn("https://www.google.com/", curl_args)

    def test_healthcheck_fails_when_google_is_unreachable(self) -> None:
        # 只有 Google 访问失败时，VPN 健康检查才应失败。
        completed, _ = self._run_healthcheck(access_success=False)

        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("cannot access https://www.google.com/", completed.stderr)


if __name__ == "__main__":
    unittest.main()
