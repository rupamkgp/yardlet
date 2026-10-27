#!/bin/zsh
# Makes the showcase's demo projects (`--ui-fixture=showcase`) as real Git repositories under
# <root>, so the session rail and the review panel read real branches and real uncommitted work:
#
#   <root>/acme-web        branch feat/settings-sections (pull request #128 in the fixture), with the
#                          dark mode toggle of the fixture's latest Codex turn left uncommitted
#   <root>/payments-api    branch main
#   <root>/design-system   branch main
#   <worktrees>/acme-web/fix-flaky-checkout
#                          a linked worktree of acme-web on fix/flaky-checkout, with the Claude Code
#                          task's one-line fix uncommitted
#
# <worktrees> defaults to <root>/../.yardlet/worktrees, where Yardlet keeps the worktrees it makes
# (with <root> at <qa home>/Developer, that is the QA home's ~/.yardlet/worktrees).
# Every commit is by the fixture's made-up person. Nothing is pushed and no remote is added.
# usage: make-projects.sh <root> [<worktrees>]
set -euo pipefail
root=${1:?usage: make-projects.sh <root> [<worktrees>]}
root=${root:A}
worktrees=${2:-${root:h}/.yardlet/worktrees}
worktrees=${worktrees:A}
[[ ! -e "$root/acme-web" ]] || { echo "$root/acme-web already exists" >&2; exit 1; }

export GIT_AUTHOR_NAME="Jordan Park" GIT_AUTHOR_EMAIL="jordan@example.com"
export GIT_COMMITTER_NAME="Jordan Park" GIT_COMMITTER_EMAIL="jordan@example.com"
git_in() {
    local folder=$1; shift
    /usr/bin/git -C "$folder" -c core.hooksPath=/dev/null -c commit.gpgSign=false -c init.defaultBranch=main "$@"
}
write() { mkdir -p "${1:h}"; cat > "$1"; }

# MARK: acme-web

web=$root/acme-web
mkdir -p "$web"
git_in "$web" init --quiet

write "$web/package.json" <<'EOF'
{
  "name": "acme-web",
  "private": true,
  "scripts": {
    "dev": "next dev",
    "build": "next build",
    "test": "vitest run",
    "lint": "next lint",
    "e2e": "playwright test"
  },
  "dependencies": {
    "next": "16.1.0",
    "react": "19.2.0",
    "react-dom": "19.2.0"
  }
}
EOF
write "$web/README.md" <<'EOF'
# acme-web

The Acme storefront: product pages, checkout and account settings.

    pnpm install
    pnpm dev
EOF
write "$web/AGENTS.md" <<'EOF'
# acme-web

- Next.js App Router, TypeScript, pnpm.
- Run `pnpm test` and `pnpm lint` before handing work back.
- Components live in `src/components`, one per file.
EOF
write "$web/src/app/layout.tsx" <<'EOF'
import "./globals.css";

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en" data-theme="light">
      <body>{children}</body>
    </html>
  );
}
EOF
write "$web/src/lib/theme.ts" <<'EOF'
export type Theme = "light";

export const defaultTheme: Theme = "light";

export function applyTheme(theme: Theme) {
  document.documentElement.dataset.theme = theme;
}
EOF
write "$web/src/lib/theme.test.ts" <<'EOF'
import { describe, expect, it } from "vitest";
import { defaultTheme } from "./theme";

describe("theme", () => {
  it("has a default", () => {
    expect(defaultTheme).toBeTruthy();
  });
});
EOF
write "$web/src/app/settings/page.tsx" <<'EOF'
export default function SettingsPage() {
  return (
    <main className="settings">
      <h1>Settings</h1>
      <ProfileForm />
      <NotificationPreferences />
    </main>
  );
}
EOF
write "$web/tests/e2e/checkout.spec.ts" <<'EOF'
import { expect, test } from "@playwright/test";

test("a signed-in shopper can pay for their cart", async ({ page }) => {
  await page.goto("/cart");
  await page.getByRole("button", { name: "Check out" }).click();
  await page.getByLabel("Card number").fill("4242 4242 4242 4242");
  await page.waitForTimeout(500);
  await page.getByRole("button", { name: "Pay" }).click();
  await expect(page.getByText("Thanks for your order")).toBeVisible();
});
EOF
git_in "$web" add -A
git_in "$web" commit --quiet -m "Start the storefront"

git_in "$web" switch --quiet -c feat/settings-sections
write "$web/src/components/Section.tsx" <<'EOF'
export function Section({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <section className="settings-section">
      <h2>{title}</h2>
      {children}
    </section>
  );
}
EOF
write "$web/src/app/settings/page.tsx" <<'EOF'
import { Section } from "@/components/Section";

export default function SettingsPage() {
  return (
    <main className="settings">
      <h1>Settings</h1>
      <Section title="Profile">
        <ProfileForm />
      </Section>
      <Section title="Appearance">
        {/* TODO: theme */}
      </Section>
      <Section title="Notifications">
        <NotificationPreferences />
      </Section>
    </main>
  );
}
EOF
git_in "$web" add -A
git_in "$web" commit --quiet -m "Split settings into sections"

# The fixture's latest Codex turn, left uncommitted.
write "$web/src/lib/theme.ts" <<'EOF'
export type Theme = "system" | "light" | "dark";

export const defaultTheme: Theme = "system";
const storageKey = "acme.theme";

export function savedTheme(): Theme {
  const value = localStorage.getItem(storageKey);
  return value === "light" || value === "dark" ? value : defaultTheme;
}

export function applyTheme(theme: Theme) {
  localStorage.setItem(storageKey, theme);
  const dark = theme === "dark"
    || (theme === "system" && matchMedia("(prefers-color-scheme: dark)").matches);
  document.documentElement.dataset.theme = dark ? "dark" : "light";
}
EOF
write "$web/src/components/ThemeToggle.tsx" <<'EOF'
"use client";

import { useEffect, useState } from "react";
import { applyTheme, savedTheme, type Theme } from "@/lib/theme";

const choices: { value: Theme; label: string }[] = [
  { value: "system", label: "System" },
  { value: "light", label: "Light" },
  { value: "dark", label: "Dark" },
];

export function ThemeToggle() {
  const [theme, setTheme] = useState<Theme>("system");

  useEffect(() => setTheme(savedTheme()), []);

  function choose(next: Theme) {
    setTheme(next);
    applyTheme(next);
  }

  return (
    <div role="radiogroup" aria-label="Theme" className="segmented">
      {choices.map((choice) => (
        <button
          key={choice.value}
          role="radio"
          aria-checked={theme === choice.value}
          onClick={() => choose(choice.value)}
        >
          {choice.label}
        </button>
      ))}
    </div>
  );
}
EOF
write "$web/src/app/settings/page.tsx" <<'EOF'
import { Section } from "@/components/Section";
import { ThemeToggle } from "@/components/ThemeToggle";

export default function SettingsPage() {
  return (
    <main className="settings">
      <h1>Settings</h1>
      <Section title="Profile">
        <ProfileForm />
      </Section>
      <Section title="Appearance">
        <ThemeToggle />
      </Section>
      <Section title="Notifications">
        <NotificationPreferences />
      </Section>
    </main>
  );
}
EOF
# Untracked files count as new in the review panel only once Git knows them.
git_in "$web" add --intent-to-add src/components/ThemeToggle.tsx

# The Claude Code task's worktree, with its fix uncommitted.
fix=$worktrees/acme-web/fix-flaky-checkout
mkdir -p "${fix:h}"
git_in "$web" worktree add --quiet -b fix/flaky-checkout "$fix" main
/usr/bin/perl -0pi -e 's/  await page\.waitForTimeout\(500\);\n  await page\.getByRole\("button", \{ name: "Pay" \}\)\.click\(\);\n/  const pay = page.getByRole("button", { name: "Pay" });\n  await expect(pay).toBeEnabled();\n  await pay.click();\n/' \
    "$fix/tests/e2e/checkout.spec.ts"

# MARK: payments-api

api=$root/payments-api
mkdir -p "$api"
git_in "$api" init --quiet
write "$api/README.md" <<'EOF'
# payments-api

Orders, refunds and search for the Acme storefront.
EOF
write "$api/src/routes/search.ts" <<'EOF'
import { Router } from "express";
import { rateLimit } from "../middleware/rateLimit";

export const search = Router();

search.get("/v2/search", rateLimit({ perMinute: 60 }), async (request, response) => {
  response.json(await request.services.catalog.search(String(request.query.q ?? "")));
});
EOF
write "$api/src/middleware/rateLimit.ts" <<'EOF'
import type { RequestHandler } from "express";

export function rateLimit({ perMinute }: { perMinute: number }): RequestHandler {
  const hits = new Map<string, { count: number; resetAt: number }>();
  return (request, response, next) => {
    const now = Date.now();
    const key = request.ip ?? "unknown";
    const entry = hits.get(key);
    if (!entry || entry.resetAt < now) {
      hits.set(key, { count: 1, resetAt: now + 60_000 });
      return next();
    }
    if (++entry.count > perMinute) {
      response.setHeader("Retry-After", Math.ceil((entry.resetAt - now) / 1000));
      return response.status(429).json({ error: "Too many requests" });
    }
    next();
  };
}
EOF
git_in "$api" add -A
git_in "$api" commit --quiet -m "Rate-limit the public search endpoint"

# MARK: design-system

design=$root/design-system
mkdir -p "$design"
git_in "$design" init --quiet
write "$design/README.md" <<'EOF'
# design-system

Tokens and components shared by Acme's web apps.
EOF
write "$design/tokens/color.json" <<'EOF'
{
  "text": { "primary": "#1d1d1f", "secondary": "#5e5e66" },
  "surface": { "base": "#ffffff", "raised": "#f5f5f7" },
  "accent": { "default": "#3157d5", "hover": "#2647b8" }
}
EOF
git_in "$design" add -A
git_in "$design" commit --quiet -m "Add color tokens"

echo "$root"
