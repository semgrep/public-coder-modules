locals {
  claude_post_install_script = file("${path.module}/scripts/claude.sh")
  codex_post_install_script  = file("${path.module}/scripts/codex.sh")
}
