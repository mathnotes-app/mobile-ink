import { appendFileSync } from "node:fs";
import { getNpmVersionStatus } from "./npm-registry.mjs";

const result = await getNpmVersionStatus({
  packageName: process.env.PACKAGE_NAME,
  packageVersion: process.env.PACKAGE_VERSION,
  registryUrl: process.env.NPM_REGISTRY_URL,
});

if (process.env.GITHUB_OUTPUT) {
  appendFileSync(
    process.env.GITHUB_OUTPUT,
    `should_publish=${result.shouldPublish}\nregistry_status=${result.status}\n`,
  );
} else {
  process.stdout.write(`${JSON.stringify(result)}\n`);
}
