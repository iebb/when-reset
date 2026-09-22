// Intentionally reveal only the dashboard recovery key, to a local terminal.
// Refuse redirected output so this helper cannot accidentally feed a log or pipe.
if (!process.stdin.isTTY || !process.stdout.isTTY) {
  console.error("Open a private interactive terminal to view the dashboard access key. Redirected output is refused.");
  process.exitCode = 1;
} else {
  const key = process.env.REGISTRATION_ACCESS_KEY;
  if (typeof key !== "string" || key.length < 32 || /[\r\n\x00-\x1f\x7f]/.test(key)) {
    console.error("The dashboard access key is missing or invalid.");
    process.exitCode = 1;
  } else {
    process.stdout.write(`Dashboard access key (keep private):\n${key}\n`);
  }
}
