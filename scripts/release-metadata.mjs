import { appendFileSync, readFileSync } from "node:fs";

const EXPECTED_PACKAGE_NAME = "@mathnotes/mobile-ink";
const EXPECTED_REPOSITORY_URL = "git+https://github.com/mathnotes-app/mobile-ink.git";
const STABLE_SEMVER_PATTERN = /^(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)$/;

const packageJson = JSON.parse(readFileSync("package.json", "utf8"));
const packageLock = JSON.parse(readFileSync("package-lock.json", "utf8"));
const changelog = readFileSync("CHANGELOG.md", "utf8");

if (packageJson.name !== EXPECTED_PACKAGE_NAME) {
  throw new Error(`Refusing to publish unexpected package: ${packageJson.name}`);
}

if (
  typeof packageJson.version !== "string" ||
  packageJson.version.trim() !== packageJson.version ||
  !STABLE_SEMVER_PATTERN.test(packageJson.version)
) {
  throw new Error(`Refusing to publish invalid version: ${packageJson.version}`);
}

if (
  packageLock.version !== packageJson.version ||
  packageLock.packages?.[""]?.version !== packageJson.version
) {
  throw new Error("Refusing to publish mismatched package and lockfile versions");
}

if (!changelog.includes(`## [${packageJson.version}]`)) {
  throw new Error(`Refusing to publish without a ${packageJson.version} changelog entry`);
}

if (packageJson.repository?.url !== EXPECTED_REPOSITORY_URL) {
  throw new Error(
    `Refusing to publish package with unexpected repository: ${packageJson.repository?.url}`,
  );
}

const metadata = {
  name: packageJson.name,
  version: packageJson.version,
};

if (process.env.GITHUB_OUTPUT) {
  appendFileSync(
    process.env.GITHUB_OUTPUT,
    `name=${metadata.name}\nversion=${metadata.version}\n`,
  );
} else {
  process.stdout.write(`${JSON.stringify(metadata)}\n`);
}
