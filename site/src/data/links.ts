const repository = "https://github.com/stefanovalloncini/Parola";

export const links = {
  repository,
  releases: `${repository}/releases`,
  download: `${repository}/releases/latest`,
  license: `${repository}/blob/main/LICENSE`,
  mcpDocs: `${repository}/blob/main/docs/mcp.md`,
  deploymentDocs: `${repository}/blob/main/docs/deployment.md`,
  issues: `${repository}/issues`,
  feedbackEmail: "stefano.valloncini@gmail.com",
} as const;

export const requirements = "macOS 26 on a Mac with Apple Silicon";
