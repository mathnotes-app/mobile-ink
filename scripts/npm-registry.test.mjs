import assert from "node:assert/strict";
import { after, before, test } from "node:test";
import { createServer } from "node:http";
import { getNpmVersionStatus } from "./npm-registry.mjs";

const PACKAGE_NAME = "@mathnotes/mobile-ink";
let registryUrl;
let server;

before(async () => {
  server = createServer((request, response) => {
    const version = decodeURIComponent(request.url.split("/").at(-1));
    response.setHeader("content-type", "application/json");

    if (version === "0.3.2") {
      response.end(JSON.stringify({ name: PACKAGE_NAME, version }));
      return;
    }
    if (version === "0.3.3") {
      response.statusCode = 404;
      response.end(JSON.stringify({ error: "Not found" }));
      return;
    }
    if (version === "0.3.4") {
      response.statusCode = 503;
      response.end(JSON.stringify({ error: "Unavailable" }));
      return;
    }

    response.end(JSON.stringify({ name: "wrong-package", version }));
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const address = server.address();
  registryUrl = `http://127.0.0.1:${address.port}/`;
});

after(async () => {
  await new Promise((resolve, reject) => {
    server.close((error) => error ? reject(error) : resolve());
  });
});

test("skips a version that is already published", async () => {
  assert.deepEqual(
    await getNpmVersionStatus({
      packageName: PACKAGE_NAME,
      packageVersion: "0.3.2",
      registryUrl,
    }),
    { shouldPublish: false, status: "published" },
  );
});

test("publishes only when the registry returns not found", async () => {
  assert.deepEqual(
    await getNpmVersionStatus({
      packageName: PACKAGE_NAME,
      packageVersion: "0.3.3",
      registryUrl,
    }),
    { shouldPublish: true, status: "missing" },
  );
});

test("fails closed when the registry is unavailable", async () => {
  await assert.rejects(
    getNpmVersionStatus({
      packageName: PACKAGE_NAME,
      packageVersion: "0.3.4",
      registryUrl,
    }),
    /npm registry returned 503/,
  );
});

test("fails closed when registry metadata does not match", async () => {
  await assert.rejects(
    getNpmVersionStatus({
      packageName: PACKAGE_NAME,
      packageVersion: "0.3.5",
      registryUrl,
    }),
    /mismatched metadata/,
  );
});
