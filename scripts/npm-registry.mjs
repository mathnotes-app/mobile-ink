const EXPECTED_PACKAGE_NAME = "@mathnotes/mobile-ink";
const STABLE_SEMVER_PATTERN = /^(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)$/;

export const getNpmVersionStatus = async ({
  packageName,
  packageVersion,
  registryUrl = "https://registry.npmjs.org/",
}) => {
  if (packageName !== EXPECTED_PACKAGE_NAME) {
    throw new Error(`Refusing to query unexpected package: ${packageName}`);
  }
  if (!STABLE_SEMVER_PATTERN.test(packageVersion)) {
    throw new Error(`Refusing to query invalid version: ${packageVersion}`);
  }

  const registryBaseUrl = new URL(registryUrl);
  const versionUrl = new URL(
    `${encodeURIComponent(packageName)}/${encodeURIComponent(packageVersion)}`,
    registryBaseUrl,
  );
  const response = await fetch(versionUrl, {
    headers: { accept: "application/json" },
    signal: AbortSignal.timeout(15_000),
  });

  if (response.status === 404) {
    return { shouldPublish: true, status: "missing" };
  }
  if (!response.ok) {
    throw new Error(
      `npm registry returned ${response.status} for ${packageName}@${packageVersion}`,
    );
  }

  const metadata = await response.json();
  if (metadata.name !== packageName || metadata.version !== packageVersion) {
    throw new Error(
      `npm registry returned mismatched metadata for ${packageName}@${packageVersion}`,
    );
  }

  return { shouldPublish: false, status: "published" };
};
