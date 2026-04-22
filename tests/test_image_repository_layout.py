import pathlib
import unittest


class ImageRepositoryLayoutTests(unittest.TestCase):
    """验证仓库已经拆成两个可独立发布的镜像上下文。"""

    @classmethod
    def setUpClass(cls) -> None:
        # 统一从仓库根目录读取文件，避免测试依赖当前工作目录。
        cls.repo_root = pathlib.Path(__file__).resolve().parents[1]
        cls.compose_text = (cls.repo_root / "docker-compose.yml").read_text(encoding="utf-8")
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
        self.assertNotIn("COPY scripts/", self.vpn_dockerfile_text)
        self.assertNotIn("COPY ../scripts/", self.vpn_dockerfile_text)

    def test_proxy_image_uses_dedicated_build_context(self) -> None:
        # 代理镜像也必须独立构建，不能复用根目录上下文。
        self.assertIn("context: ./proxy", self.compose_text)
        self.assertNotIn("dockerfile: proxy/Dockerfile", self.compose_text)
        self.assertIn("COPY entrypoint.sh /app/proxy-entrypoint.sh", self.proxy_dockerfile_text)
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
