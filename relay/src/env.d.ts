declare namespace Cloudflare {
  interface GlobalProps {
    mainModule: typeof import("./index");
    durableNamespaces: "Room" | "Account";
  }
  interface Env {
    ROOM: DurableObjectNamespace<import("./room").Room>;
    ACCOUNT: DurableObjectNamespace<import("./account").Account>;
    /** The Firebase service account's JSON key. */
    FCM_SERVICE_ACCOUNT?: string;
    FCM_PROJECT_ID?: string;
    GITHUB_CLIENT_ID?: string;
    GITHUB_CLIENT_SECRET?: string;
    GOOGLE_CLIENT_ID?: string;
    GOOGLE_CLIENT_SECRET?: string;
    /** Signs the relay's own OAuth `state`. */
    AUTH_STATE_SECRET?: string;
    /** The relay's https base URL, for OAuth callbacks. */
    PUBLIC_URL?: string;
  }
}

interface Env extends Cloudflare.Env {}
