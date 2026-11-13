# Textley Claude directory submission

- Portal: [Anthropic developer portal](https://claude.ai/directory/manage)
- Submission type: **Plugin bundle**
- Repository: [protomota/mcp](https://github.com/protomota/mcp)
- Plugin path: `plugins/textley-mcp`
- Tracked branch: `main`
- Validated plugin version: `0.1.1` at [b09f95d](https://github.com/protomota/mcp/commit/b09f95d392a99ad6888e7a46e69ec8f638d144c9)
- Listing: **Textley MCP**
- Product: [textley.ai](https://textley.ai)
- Setup: [textley.ai/mcp](https://textley.ai/mcp/)
- Support: [textley.ai/support](https://textley.ai/support/)
- Privacy: [textley.ai/privacy/#mcp](https://textley.ai/privacy/#mcp)
- Mac installer: [Textley 1.0.1](https://textley.ai/download/Textley-1.0.1.dmg)

The launcher connects to the installed macOS app. A reviewer can install the signed build from the website, save the sample `examples/Trail Log.md` to a new folder, open that folder in Textley, and follow the plugin README. The sample and all three prompts are in the plugin directory. Textley does not require a product account.

The disk image served by textley.ai matches the mounted installer. The app inside the image passes strict signature and notarization checks, and the image includes an Applications shortcut.

## Data handling

Textley can read user-selected local vaults and open files, which may contain personal information. It uses local storage for those files and settings. The plugin routes tool calls to the app on loopback. When a user asks Claude to use a tool, the arguments and results reach Claude under Anthropic’s privacy terms. The Textley launcher has no hosted data store or analytics. The app stores its local token in macOS Keychain and controls reading and writing in Settings. The general-purpose editor is not marketed to children.

## Portal steps

1. Select **Submit new → Plugin bundle** and enter the repository, path, and branch above. Choose **Validate**.
2. Confirm the listing preview matches the manifest and README. Complete **Data handling** using the scope above.
3. In **Compliance**, confirm the Protomota review contact and review the [Directory Terms](https://support.claude.com/en/articles/13145338-anthropic-software-directory-terms) and [Directory Policy](https://support.claude.com/en/articles/13145358-anthropic-software-directory-policy). Accept the acknowledgements only after the authorized account owner approves.
4. Under **Review and submit**, choose **Scheduled check only**, leave auto-publish off, and choose **Submit for review**. Record the dashboard URL and tracked commit shown after submission.

[Anthropic’s submission guide](https://claude.com/docs/plugins/submit)

## Submission receipt

Submitted TEXTLEY MCP `0.1.1` for Claude Code on November 11, 2026, from `main` at `b09f95d`. The portal showed **Scanning** and flagged the launcher script and MCP server command for policy review. Scheduled checks are enabled and auto-publish is off. [View the submission](https://claude.ai/directory/manage/plugins/f2ba56e0-f814-427f-83e4-365ff45b0d2e)

Pushed the Textley MCP rename as `0.1.2` to the tracked `main` branch at [32e11e0](https://github.com/protomota/mcp/commit/32e11e0e5d09b2ebf5510e0f3d73854b2893fabe). Claude Code plugin and marketplace validation passed. The directory scan result for this commit is pending verification.
