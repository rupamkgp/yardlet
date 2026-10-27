import { env } from "cloudflare:workers";
import { afterEach, describe, expect, it, vi } from "vitest";
import { fromBase64Url } from "../src/keys";
import { openMac, type Peer } from "./helpers";

const TOKEN_URL = "https://oauth2.googleapis.com/token";
const FCM_URL = "https://fcm.googleapis.com/v1/projects/relay-test/messages:send";

interface Captured {
  url: string;
  headers: Headers;
  body: string;
}

function push(id: string, fields: Record<string, unknown> = {}) {
  return JSON.stringify({
    t: "push",
    id,
    to: "registration-token-1",
    urgent: true,
    collapse: "0123456789abcdef",
    ttl: 3600,
    data: { v: "1", k: "0011223344556677", y: "c2VhbGVk" },
    ...fields,
  });
}

/** Answers the OAuth token endpoint and FCM; `fcm` decides FCM's response. */
function fakeGoogle(fcm: (body: Record<string, any>) => Response = () => Response.json({ name: "projects/relay-test/messages/1" })) {
  const requests: Captured[] = [];
  vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => {
    const request = new Request(input, init);
    const body = new TextDecoder().decode(await request.arrayBuffer());
    const captured = { url: request.url, headers: request.headers, body };
    requests.push(captured);
    if (captured.url === TOKEN_URL) return Response.json({ access_token: "access-1", expires_in: 3599, token_type: "Bearer" });
    if (captured.url === FCM_URL) return fcm(JSON.parse(captured.body));
    return new Response("unexpected", { status: 599 });
  });
  return requests;
}

async function pushed(mac: Peer, count = 1): Promise<Record<string, unknown>[]> {
  const replies = [];
  for (let i = 0; i < count; i += 1) replies.push(await mac.json());
  return replies;
}

afterEach(() => {
  vi.restoreAllMocks();
});

describe("push", () => {
  // First in this file: the access token is cached for the isolate.
  it("signs one OAuth assertion and sends FCM data messages", async () => {
    const requests = fakeGoogle();
    const { mac } = await openMac();

    mac.ws.send(push("p1"));
    expect(await pushed(mac)).toEqual([{ t: "pushed", id: "p1", ok: true }]);
    mac.ws.send(push("p2", { urgent: false, collapse: "fedcba9876543210", ttl: 60 }));
    expect(await pushed(mac)).toEqual([{ t: "pushed", id: "p2", ok: true }]);

    const tokenRequests = requests.filter((r) => r.url === TOKEN_URL);
    expect(tokenRequests).toHaveLength(1);
    const form = new URLSearchParams(tokenRequests[0].body);
    expect(form.get("grant_type")).toBe("urn:ietf:params:oauth:grant-type:jwt-bearer");
    const [header, claims, signature] = form.get("assertion")!.split(".");
    const decode = (part: string) => JSON.parse(new TextDecoder().decode(fromBase64Url(part)!));
    expect(decode(header)).toEqual({ alg: "RS256", typ: "JWT" });
    const payload = decode(claims);
    expect(payload).toMatchObject({
      iss: "relay-test@example.test",
      scope: "https://www.googleapis.com/auth/firebase.messaging",
      aud: TOKEN_URL,
    });
    expect(payload.exp - payload.iat).toBe(3600);
    const publicKey = await crypto.subtle.importKey(
      "jwk",
      JSON.parse((env as unknown as { TEST_FCM_PUBLIC_JWK: string }).TEST_FCM_PUBLIC_JWK),
      { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
      false,
      ["verify"],
    );
    const signed = new TextEncoder().encode(`${header}.${claims}`);
    expect(await crypto.subtle.verify("RSASSA-PKCS1-v1_5", publicKey, fromBase64Url(signature)!, signed)).toBe(true);

    const sends = requests.filter((r) => r.url === FCM_URL);
    expect(sends.map((r) => r.headers.get("authorization"))).toEqual(["Bearer access-1", "Bearer access-1"]);
    expect(sends.map((r) => JSON.parse(r.body))).toEqual([
      {
        message: {
          token: "registration-token-1",
          data: { v: "1", k: "0011223344556677", y: "c2VhbGVk" },
          android: { priority: "HIGH", collapse_key: "0123456789abcdef", ttl: "3600s" },
        },
      },
      {
        message: {
          token: "registration-token-1",
          data: { v: "1", k: "0011223344556677", y: "c2VhbGVk" },
          android: { priority: "NORMAL", collapse_key: "fedcba9876543210", ttl: "60s" },
        },
      },
    ]);
  });

  it("maps FCM errors", async () => {
    const answers = [
      Response.json({ error: { code: 404, status: "NOT_FOUND", details: [{ errorCode: "UNREGISTERED" }] } }, { status: 404 }),
      Response.json({ error: { code: 400, status: "INVALID_ARGUMENT" } }, { status: 400 }),
      Response.json({ error: { code: 429, status: "RESOURCE_EXHAUSTED" } }, { status: 429 }),
      Response.json({ error: { code: 503, status: "UNAVAILABLE" } }, { status: 503 }),
    ];
    fakeGoogle(() => answers.shift()!);
    const { mac } = await openMac();
    const errors = [];
    for (const id of ["p1", "p2", "p3", "p4"]) {
      mac.ws.send(push(id));
      errors.push((await mac.json()).error);
    }
    expect(errors).toEqual(["unregistered", "invalid", "rateLimited", "unavailable"]);
  });

  it("sends at most 60 a minute per room", async () => {
    const requests = fakeGoogle();
    const { mac } = await openMac();
    for (let i = 0; i < 61; i += 1) mac.ws.send(push(`p${i}`));
    const replies = await pushed(mac, 61);
    expect(replies.filter((r) => r.ok === true)).toHaveLength(60);
    expect(replies.filter((r) => r.ok === false)).toEqual([{ t: "pushed", id: "p60", ok: false, error: "rateLimited" }]);
    expect(requests.filter((r) => r.url === FCM_URL)).toHaveLength(60);
  });
});
