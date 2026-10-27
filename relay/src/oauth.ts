import { base32, fromBase64Url, sha256, toBase64Url } from "./keys";

export type Provider = "github" | "google";

const PROVIDERS: Provider[] = ["github", "google"];
const STATE_TTL_MS = 10 * 60_000;
const USER_AGENT = "yardlet-relay";
const encoder = new TextEncoder();

export interface ProviderConfig {
  provider: Provider;
  clientId: string;
  clientSecret: string;
  stateSecret: string;
  callbackUrl: string;
}

export interface Identity {
  subject: string;
  name: string;
}

/** The relay signs this as its provider `state`, so the flow keeps nothing until the account is known. */
export interface FlowState {
  /** provider */
  p: Provider;
  /** the app's PKCE code challenge */
  c: string;
  /** the app's own state */
  s: string;
  /** expiry, ms since the epoch */
  e: number;
}

export function providerConfig(env: Env, provider: string): ProviderConfig | null {
  if (!env.AUTH_STATE_SECRET || !env.PUBLIC_URL) return null;
  let clientId: string | undefined;
  let clientSecret: string | undefined;
  if (provider === "github") [clientId, clientSecret] = [env.GITHUB_CLIENT_ID, env.GITHUB_CLIENT_SECRET];
  else if (provider === "google") [clientId, clientSecret] = [env.GOOGLE_CLIENT_ID, env.GOOGLE_CLIENT_SECRET];
  else return null;
  if (!clientId || !clientSecret) return null;
  return {
    provider,
    clientId,
    clientSecret,
    stateSecret: env.AUTH_STATE_SECRET,
    callbackUrl: `${env.PUBLIC_URL.replace(/\/+$/, "")}/v1/auth/${provider}/callback`,
  };
}

export function configuredProviders(env: Env): Provider[] {
  return PROVIDERS.filter((provider) => providerConfig(env, provider));
}

export function authorizeUrl(config: ProviderConfig, state: string): string {
  if (config.provider === "github") {
    const query = new URLSearchParams({ client_id: config.clientId, redirect_uri: config.callbackUrl, state });
    return `https://github.com/login/oauth/authorize?${query}`;
  }
  const query = new URLSearchParams({
    client_id: config.clientId,
    redirect_uri: config.callbackUrl,
    response_type: "code",
    scope: "openid profile",
    state,
  });
  return `https://accounts.google.com/o/oauth2/v2/auth?${query}`;
}

async function hmacKey(secret: string): Promise<CryptoKey> {
  return crypto.subtle.importKey("raw", encoder.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign", "verify"]);
}

export async function signState(secret: string, payload: FlowState): Promise<string> {
  const body = toBase64Url(encoder.encode(JSON.stringify(payload)));
  const mac = await crypto.subtle.sign("HMAC", await hmacKey(secret), encoder.encode(body));
  return `${body}.${toBase64Url(new Uint8Array(mac))}`;
}

/** The signed state if it is genuine, unexpired and for `provider`. */
export async function readState(secret: string, state: string, provider: Provider): Promise<FlowState | null> {
  const [body, mac, extra] = state.split(".");
  const signature = mac === undefined ? null : fromBase64Url(mac);
  if (extra !== undefined || !body || !signature) return null;
  if (!(await crypto.subtle.verify("HMAC", await hmacKey(secret), signature, encoder.encode(body)))) return null;
  try {
    const payload = JSON.parse(new TextDecoder().decode(fromBase64Url(body) ?? new Uint8Array())) as FlowState;
    if (payload.p !== provider || typeof payload.c !== "string" || typeof payload.s !== "string") return null;
    return typeof payload.e === "number" && Date.now() < payload.e ? payload : null;
  } catch {
    return null;
  }
}

export function stateExpiry(): number {
  return Date.now() + STATE_TTL_MS;
}

/** `base32(SHA-256("yardlet-account/1\n" + provider + "\n" + subject)[0..<20])` */
export async function accountIdFor(provider: Provider, subject: string): Promise<string> {
  return base32((await sha256(encoder.encode(`yardlet-account/1\n${provider}\n${subject}`))).subarray(0, 20));
}

/** Exchanges the provider's code and reads the user's stable number and display name. */
export async function fetchIdentity(config: ProviderConfig, code: string): Promise<Identity | null> {
  try {
    return config.provider === "github" ? await githubIdentity(config, code) : await googleIdentity(config, code);
  } catch {
    return null;
  }
}

async function githubIdentity(config: ProviderConfig, code: string): Promise<Identity | null> {
  const tokenResponse = await fetch("https://github.com/login/oauth/access_token", {
    method: "POST",
    headers: { accept: "application/json", "user-agent": USER_AGENT },
    body: new URLSearchParams({
      client_id: config.clientId,
      client_secret: config.clientSecret,
      code,
      redirect_uri: config.callbackUrl,
    }),
  });
  const token = (await tokenResponse.json()) as { access_token?: unknown };
  if (!tokenResponse.ok || typeof token.access_token !== "string") return failed("GitHub token", tokenResponse.status);
  const userResponse = await fetch("https://api.github.com/user", {
    headers: {
      authorization: `Bearer ${token.access_token}`,
      accept: "application/vnd.github+json",
      "user-agent": USER_AGENT,
    },
  });
  const user = (await userResponse.json()) as { id?: unknown; login?: unknown };
  if (!userResponse.ok || typeof user.id !== "number") return failed("GitHub user", userResponse.status);
  return { subject: String(user.id), name: typeof user.login === "string" ? user.login : "" };
}

async function googleIdentity(config: ProviderConfig, code: string): Promise<Identity | null> {
  const tokenResponse = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    body: new URLSearchParams({
      client_id: config.clientId,
      client_secret: config.clientSecret,
      code,
      grant_type: "authorization_code",
      redirect_uri: config.callbackUrl,
    }),
  });
  const token = (await tokenResponse.json()) as { access_token?: unknown };
  if (!tokenResponse.ok || typeof token.access_token !== "string") return failed("Google token", tokenResponse.status);
  const userResponse = await fetch("https://openidconnect.googleapis.com/v1/userinfo", {
    headers: { authorization: `Bearer ${token.access_token}` },
  });
  const user = (await userResponse.json()) as { sub?: unknown; name?: unknown };
  if (!userResponse.ok || typeof user.sub !== "string" || user.sub === "") return failed("Google userinfo", userResponse.status);
  return { subject: user.sub, name: typeof user.name === "string" ? user.name : "" };
}

function failed(step: string, status: number): null {
  console.warn(`${step} request failed`, status);
  return null;
}
