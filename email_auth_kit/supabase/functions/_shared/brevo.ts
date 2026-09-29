// email_auth_kit — shared Brevo sender for all functions.
//
// Sends via the Brevo transactional API (SMTP relay account already
// domain-verified for mediasart.com). Dev/self-hosted-local fallback:
// without BREVO_API_KEY the function logs the mail instead of failing,
// so `supabase functions serve` + Inbucket-less local dev still works.

export interface MailInput {
  to: string;
  subject: string;
  text: string;
  html: string;
}

export interface MailResult {
  delivered: boolean; // false = logged-only (no API key configured)
}

const API = "https://api.brevo.com/v3/smtp/email";

// ---------------------------------------------------------------------
// Minimal SMTP delivery — used when BREVO_SMTP_HOST is set. This is the
// self-hosted/dev path: point it at the local stack's Inbucket (host
// `inbucket`, port 2500) and every message lands in its mailbox UI/API
// instead of needing a Brevo account. Plain SMTP, no TLS, no auth —
// exactly what a local capture server offers.
// ---------------------------------------------------------------------

async function smtpSend(host: string, port: number, input: MailInput, from: string): Promise<void> {
  const conn = await Deno.connect({ hostname: host, port });
  const buf = new Uint8Array(4096);
  let pending = "";

  const readReply = async (code: string): Promise<void> => {
    for (;;) {
      const nl = pending.indexOf("\r\n");
      if (nl >= 0) {
        const line = pending.slice(0, nl);
        pending = pending.slice(nl + 2);
        if (!line.startsWith(code)) throw new Error(`smtp: expected ${code}, got "${line}"`);
        if (line[code.length] === " ") return; // final line of the reply
        continue; // "250-..." continuation line
      }
      const n = await conn.read(buf);
      if (n === null) throw new Error("smtp: connection closed");
      pending += new TextDecoder().decode(buf.subarray(0, n));
    }
  };

  const cmd = async (line: string, code: string): Promise<void> => {
    await conn.write(new TextEncoder().encode(`${line}\r\n`));
    await readReply(code);
  };

  await readReply("220");
  await cmd(`EHLO mediasart-kit`, "250");
  await cmd(`MAIL FROM:<${from}>`, "250");
  await cmd(`RCPT TO:<${input.to}>`, "250");
  await cmd("DATA", "354");
  const dotStuffed = input.html.replace(/(^|\r\n)\./g, "$1..");
  const message =
    `From: ${from}\r\nTo: ${input.to}\r\nSubject: ${input.subject}\r\n` +
    `MIME-Version: 1.0\r\nContent-Type: text/html; charset=utf-8\r\n\r\n${dotStuffed}\r\n.`;
  await conn.write(new TextEncoder().encode(`${message}\r\n`));
  await readReply("250");
  await cmd("QUIT", "221");
  conn.close();
}

export async function sendMail(input: MailInput): Promise<MailResult> {
  const apiKey = Deno.env.get("BREVO_API_KEY");
  const senderEmail = Deno.env.get("BREVO_SENDER") ?? "no-reply@mediasart.com";
  const senderName = Deno.env.get("BREVO_SENDER_NAME") ?? "mediasart";
  const smtpHost = Deno.env.get("BREVO_SMTP_HOST");

  if (smtpHost) {
    // SMTP capture path (Inbucket et al.) — takes precedence so local
    // stacks never touch the real Brevo API even with a key present.
    const smtpPort = Number(Deno.env.get("BREVO_SMTP_PORT") ?? "2500");
    await smtpSend(smtpHost, smtpPort, input, senderEmail);
    return { delivered: true };
  }

  if (!apiKey) {
    console.log(
      `[brevo:dev] BREVO_API_KEY not set — logging mail instead of sending\n` +
        `  to: ${input.to}\n  subject: ${input.subject}\n${input.text}`,
    );
    return { delivered: false };
  }

  const res = await fetch(API, {
    method: "POST",
    headers: {
      "api-key": apiKey,
      "content-type": "application/json",
      accept: "application/json",
    },
    body: JSON.stringify({
      sender: { name: senderName, email: senderEmail },
      to: [{ email: input.to }],
      subject: input.subject,
      textContent: input.text,
      htmlContent: input.html,
    }),
  });

  if (!res.ok) {
    const body = await res.text();
    console.error(`[brevo] send failed ${res.status}: ${body}`);
    throw new Error(`brevo_send_failed_${res.status}`);
  }
  return { delivered: true };
}

export function page(title: string, body: string): string {
  return `<!doctype html><html><body style="font-family:sans-serif;margin:0;padding:32px;background:#f6f7f9">
<div style="max-width:520px;margin:auto;background:#fff;border-radius:8px;padding:28px;border:1px solid #e4e7ec">
<h2 style="margin-top:0">${title}</h2>${body}
<p style="color:#667085;font-size:12px;margin-top:28px">You received this e-mail because a sign-up or password action was requested for this address. If it wasn't you, ignore this message.</p>
</div></body></html>`;
}
