// Step-logged repro of the kit's SMTP client against Mailpit.
const host = Deno.env.get("SMTP_HOST") ?? "172.20.0.7";
const port = Number(Deno.env.get("SMTP_PORT") ?? "1025");
console.log(`connecting ${host}:${port}`);
const conn = await Deno.connect({ hostname: host, port });
console.log("connected");
const buf = new Uint8Array(4096);
let pending = "";

async function readReply(code: string): Promise<void> {
  for (;;) {
    const nl = pending.indexOf("\r\n");
    if (nl >= 0) {
      const line = pending.slice(0, nl);
      pending = pending.slice(nl + 2);
      console.log(`  S: ${line}`);
      if (!line.startsWith(code)) throw new Error(`expected ${code}, got "${line}"`);
      if (line[code.length] === " ") return; // final line of the reply
      continue; // "250-..." continuation
    }
    const n = await conn.read(buf);
    if (n === null) throw new Error("connection closed");
    pending += new TextDecoder().decode(buf.subarray(0, n));
  }
}

async function cmd(line: string, code: string): Promise<void> {
  console.log(`  C: ${line}`);
  await conn.write(new TextEncoder().encode(`${line}\r\n`));
  await readReply(code);
}

await readReply("220");
await cmd("EHLO mediasart-kit", "250");
await cmd("MAIL FROM:<no-reply@mediasart.com>", "250");
await cmd("RCPT TO:<repro@kit.test>", "250");
await cmd("DATA", "354");
await conn.write(new TextEncoder().encode("From: no-reply@mediasart.com\r\nTo: repro@kit.test\r\nSubject: repro\r\n\r\nhello\r\n.\r\n"));
console.log("  C: <message + .>");
await readReply("250");
await cmd("QUIT", "221");
conn.close();
console.log("DONE");
