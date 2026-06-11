use zed_extension_api::{self as zed, Result};

struct SsExtension;

impl zed::Extension for SsExtension {
    fn new() -> Self {
        Self
    }

    fn language_server_command(
        &mut self,
        _language_server_id: &zed::LanguageServerId,
        worktree: &zed::Worktree,
    ) -> Result<zed::Command> {
        let command = worktree.which("ss").unwrap_or_else(|| "ss".to_string());
        Ok(zed::Command {
            command,
            args: vec!["lsp".to_string()],
            env: Default::default(),
        })
    }
}

zed::register_extension!(SsExtension);
