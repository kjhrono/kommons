// Redirect allow-list matching shared by the kit functions (sso-handoff).
// Same globs as GoTrue's ADDITIONAL_REDIRECT_URLS / GOTRUE_URI_ALLOW_LIST.

/** GoTrue-style glob: `**` spans anything, `*` stops at `.` and `/`. */
export function globToRegExp(glob: string): RegExp {
  let re = "";
  for (let i = 0; i < glob.length; i++) {
    const c = glob[i];
    if (c === "*") {
      if (glob[i + 1] === "*") {
        re += ".*";
        i++;
      } else {
        re += "[^./]*";
      }
    } else {
      re += c.replace(/[.+?^${}()|[\]\\]/g, "\\$&");
    }
  }
  return new RegExp(`^${re}$`);
}

/** The redirect target without its fragment, or null when not allowed. */
export function allowedRedirect(raw: unknown, globs: string[]): string | null {
  if (typeof raw !== "string" || raw.length === 0 || raw.length > 2048) return null;
  let url: URL;
  try {
    url = new URL(raw);
  } catch {
    return null;
  }
  // Never javascript:/data: — only web origins or an app's own scheme.
  if (["javascript:", "data:", "file:", "blob:", "vbscript:"].includes(url.protocol)) return null;
  if (url.protocol === "http:" && !["localhost", "127.0.0.1"].includes(url.hostname)) return null;
  url.hash = "";
  const target = url.toString();
  // URL() normalises "kognitio://auth" without a trailing slash, but adds
  // one to bare web origins — match both spellings against the list.
  const bare = target.endsWith("/") ? target.slice(0, -1) : target;
  return globs.some((g) => {
    const re = globToRegExp(g);
    return re.test(target) || re.test(bare);
  })
    ? target
    : null;
}
