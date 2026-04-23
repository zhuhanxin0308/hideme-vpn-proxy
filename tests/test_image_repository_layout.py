import pathlib
import unittest


class ImageRepositoryLayoutTests(unittest.TestCase):
    """验证仓库已经拆成两个可独立发布的镜像上下文。"""

    @classmethod
    def setUpClass(cls) -> None:
        # 统一从仓库根目录读取文件，避免测试依赖当前工作目录。
        cls.repo_root = pathlib.Path(__file__).resolve().parents[1]
        cls.compose_text = (cls.repo_root / "docker-compose.yml").read_text(encoding="utf-8")
        cls.env_example_text = (cls.repo_root / ".env.example").read_text(encoding="utf-8")
        cls.vpn_dockerfile_text = (cls.repo_root / "vpn" / "Dockerfile").read_text(encoding="utf-8")
        cls.proxy_dockerfile_text = (cls.repo_root / "proxy" / "Dockerfile").read_text(encoding="utf-8")
        cls.workflow_path = cls.repo_root / ".github" / "workflows" / "publish-images.yml"
        cls.workflow_text = cls.workflow_path.read_text(encoding="utf-8") if cls.workflow_path.exists() else ""

    def test_duplicate_inner_project_directory_is_removed(self) -> None:
        # 内层重复目录会造成错误构建上下文，必须彻底移除。
        self.assertFalse((self.repo_root / "hideme-vpn-http-proxy").exists())

    def test_shared_scripts_directory_is_removed(self) -> None:
        # 每个镜像都应拥有自己的入口脚本，不能再依赖仓库级共享脚本目录。
        self.assertFalse((self.repo_root / "scripts").exists())

    def test_vpn_image_uses_dedicated_build_context(self) -> None:
        # VPN 镜像必须从自己的目录独立构建，方便单独发布。
        self.assertIn("context: ./vpn", self.compose_text)
        self.assertNotIn("dockerfile: vpn/Dockerfile", self.compose_text)
        self.assertIn("COPY entrypoint.sh /app/vpn-entrypoint.sh", self.vpn_dockerfile_text)
        self.assertIn("COPY healthcheck.sh /app/vpn-healthcheck.sh", self.vpn_dockerfile_text)
        self.assertNotIn("COPY scripts/", self.vpn_dockerfile_text)
        self.assertNotIn("COPY ../scripts/", self.vpn_dockerfile_text)

    def test_proxy_image_uses_dedicated_build_context(self) -> None:
        # 代理镜像也必须独立构建，不能复用根目录上下文。
        self.assertIn("context: ./proxy", self.compose_text)
        self.assertNotIn("dockerfile: proxy/Dockerfile", self.compose_text)
        self.assertIn("COPY entrypoint.sh /app/proxy-entrypoint.sh", self.proxy_dockerfile_text)
        self.assertIn("COPY healthcheck.sh /app/proxy-healthcheck.sh", self.proxy_dockerfile_text)
        self.assertNotIn("COPY scripts/", self.proxy_dockerfile_text)
        self.assertNotIn("COPY ../scripts/", self.proxy_dockerfile_text)

    def test_proxy_image_uses_alpine_base(self) -> None:
        # Alpine 迁移后，代理镜像不能再保留 Debian/apt 依赖链。
        self.assertIn("FROM alpine:", self.proxy_dockerfile_text)
        self.assertIn("apk add --no-cache", self.proxy_dockerfile_text)
        self.assertNotIn("FROM debian:", self.proxy_dockerfile_text)
        self.assertNotIn("apt-get install", self.proxy_dockerfile_text)

    def test_vpn_image_uses_alpine_base(self) -> None:
        # VPN 镜像也必须统一切到 Alpine，并移除 Debian 专属架构探测。
        self.assertIn("FROM alpine:", self.vpn_dockerfile_text)
        self.assertIn("apk add --no-cache", self.vpn_dockerfile_text)
        self.assertIn('arch="$(apk --print-arch)"', self.vpn_dockerfile_text)
        self.assertNotIn("FROM debian:", self.vpn_dockerfile_text)
        self.assertNotIn("apt-get install", self.vpn_dockerfile_text)
        self.assertNotIn("dpkg --print-architecture", self.vpn_dockerfile_text)

    def test_token_host_defaults_to_any(self) -> None:
        # Access-Token 默认主机必须与官方脚本保持一致，不能再回到错误的 free.hideservers.net。
        self.assertIn("HIDEME_TOKEN_HOST=any", self.env_example_text)
        self.assertIn("HIDEME_TOKEN_HOST: ${HIDEME_TOKEN_HOST:-any}", self.compose_text)
        self.assertNotIn("free.hideservers.net", self.env_example_text)

    def test_vpn_healthcheck_uses_dedicated_script(self) -> None:
        # VPN 健康检查必须调用自己的脚本，不能误接到 proxy 的检查逻辑。
        self.assertIn('test: ["CMD", "/app/vpn-healthcheck.sh"]', self.compose_text)
        self.assertNotIn('test: ["CMD", "/app/proxy-healthcheck.sh"]', self.compose_text.split("  proxy:")[0])

    def test_vpn_fallback_dns_defaults_to_google_public_dns(self) -> None:
        # 运行时需要把 8.8.8.8 注入 resolv.conf，因此默认配置必须显式暴露出来。
        self.assertIn("VPN_FALLBACK_DNS=8.8.8.8", self.env_example_text)
        self.assertIn("VPN_FALLBACK_DNS: ${VPN_FALLBACK_DNS:-8.8.8.8}", self.compose_text)

    def test_proxy_legacy_pool_settings_are_removed(self) -> None:
        # 新版 tinyproxy 已不再使用旧进程池参数，仓库默认配置里不能继续暴露这些无效项。
        self.assertNotIn("PROXY_MIN_SPARE_SERVERS", self.env_example_text)
        self.assertNotIn("PROXY_MAX_SPARE_SERVERS", self.env_example_text)
        self.assertNotIn("PROXY_START_SERVERS", self.env_example_text)
        self.assertNotIn("PROXY_MIN_SPARE_SERVERS", self.compose_text)
        self.assertNotIn("PROXY_MAX_SPARE_SERVERS", self.compose_text)
        self.assertNotIn("PROXY_START_SERVERS", self.compose_text)

    def test_proxy_healthcheck_checks_listen_state_without_netcat(self) -> None:
        # proxy 健康检查只需要判断端口是否已进入监听，不应再依赖 nc 或 HTTP CONNECT。
        self.assertIn('test: ["CMD", "/app/proxy-healthcheck.sh"]', self.compose_text)
        self.assertNotIn("netcat-openbsd", self.proxy_dockerfile_text)

    def test_publish_workflow_exists(self) -> None:
        # 发布工作流是交付目标之一，文件必须存在。
        self.assertTrue(self.workflow_path.exists())

    def test_publish_workflow_builds_vpn_and_proxy_images(self) -> None:
        # workflow 必须分别发布 vpn 和 proxy 两个镜像。
        self.assertIn("publish-vpn:", self.workflow_text)
        self.assertIn("publish-proxy:", self.workflow_text)
        self.assertIn("docker/login-action", self.workflow_text)
        self.assertIn("docker/build-push-action", self.workflow_text)
        self.assertIn("DOCKERHUB_USERNAME", self.workflow_text)
        self.assertIn("DOCKERHUB_TOKEN", self.workflow_text)
        self.assertIn("hideme-vpn", self.workflow_text)
        self.assertIn("hideme-proxy", self.workflow_text)


if __name__ == "__main__":
    unittest.main()
